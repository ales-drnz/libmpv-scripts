/* MAK_LOUDNESS_PATCH ─── offline loudness scan (EBU R128 / BS.1770).
 * See mak_loudness.h for the architecture and the merge math. */
#include <math.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/mem.h>
#include <libavutil/samplefmt.h>
#include <libswresample/swresample.h>

#include "mpv_talloc.h"
#include "osdep/threads.h"
#include <mpv/client.h>

#include "audio/mak_loudness.h"
#include "audio/mak_waveform.h"

/* ─── BS.1770 K-weighting ─────────────────────────────────────────────
 * Two cascaded biquads designed from the analog prototypes so any
 * sample rate gets the exact response the spec tabulates for 48 kHz:
 * a +4 dB high-shelf ("head") and the RLB high-pass. The design
 * constants below are the published exact parameters of those
 * prototypes (the same ones libebur128 and ffmpeg use). */

struct biquad {
    double b0, b1, b2, a1, a2;
};

struct biquad_state {
    double z1, z2;  /* transposed direct form II */
};

static inline float biquad_run(const struct biquad *c,
                               struct biquad_state *s, float x)
{
    double y = c->b0 * x + s->z1;
    s->z1 = c->b1 * x - c->a1 * y + s->z2;
    s->z2 = c->b2 * x - c->a2 * y;
    return (float)y;
}

static void design_k_filters(int rate, struct biquad *shelf,
                             struct biquad *hipass)
{
    /* Stage 1: high-shelf. */
    {
        const double f0 = 1681.974450955533;
        const double G  = 3.999843853973347;
        const double Q  = 0.7071752369554196;

        double K  = tan(M_PI * f0 / rate);
        double Vh = pow(10.0, G / 20.0);
        double Vb = pow(Vh, 0.4996667741545416);

        double a0 = 1.0 + K / Q + K * K;
        shelf->b0 = (Vh + Vb * K / Q + K * K) / a0;
        shelf->b1 = 2.0 * (K * K - Vh) / a0;
        shelf->b2 = (Vh - Vb * K / Q + K * K) / a0;
        shelf->a1 = 2.0 * (K * K - 1.0) / a0;
        shelf->a2 = (1.0 - K / Q + K * K) / a0;
    }
    /* Stage 2: RLB high-pass. */
    {
        const double f0 = 38.13547087602444;
        const double Q  = 0.5003270373238773;

        double K = tan(M_PI * f0 / rate);

        /* The spec's stage-2 table keeps the numerator UN-normalized
         * ({1, -2, 1}); only the denominator is scaled by a0. At 48 kHz
         * this reproduces the published BS.1770 coefficients exactly. */
        double a0 = 1.0 + K / Q + K * K;
        hipass->b0 = 1.0;
        hipass->b1 = -2.0;
        hipass->b2 = 1.0;
        hipass->a1 = 2.0 * (K * K - 1.0) / a0;
        hipass->a2 = (1.0 - K / Q + K * K) / a0;
    }
}

/* ─── true-peak 4× oversampler ────────────────────────────────────────
 * 4-phase polyphase interpolator, 12 taps per phase (48-tap Hann-
 * windowed sinc, cutoff 0.45·fs ≈ the BS.1770-4 Annex 2 design). Each
 * phase is DC-normalized so a DC input interpolates to DC — peaks are
 * never under-read because of window roll-off. */
#define MAK_TP_PHASES 4
#define MAK_TP_TAPS   12  /* per phase */

struct true_peak_fir {
    float coeff[MAK_TP_PHASES][MAK_TP_TAPS];
};

struct true_peak_state {
    /* The last TAPS input samples, mirrored across two contiguous halves
     * (hist[k] == hist[k + TAPS] at all times) so the newest-to-oldest tap
     * window is always a contiguous run — the inner dot product needs no
     * per-tap modulo. */
    float hist[2 * MAK_TP_TAPS];
    int   pos;
};

static void design_true_peak_fir(struct true_peak_fir *f)
{
    const int    N      = MAK_TP_PHASES * MAK_TP_TAPS;  /* 48 */
    const double cutoff = 0.45;                          /* of input fs */
    const double center = (N - 1) / 2.0;
    double       h[MAK_TP_PHASES * MAK_TP_TAPS];

    for (int n = 0; n < N; n++) {
        double x = (n - center) / MAK_TP_PHASES;
        double sinc = (fabs(x) < 1e-12)
                      ? 2.0 * cutoff
                      : sin(2.0 * M_PI * cutoff * x) / (M_PI * x);
        double hann = 0.5 - 0.5 * cos(2.0 * M_PI * n / (N - 1));
        h[n] = sinc * hann;
    }
    /* Split into phases and DC-normalize each phase. */
    for (int p = 0; p < MAK_TP_PHASES; p++) {
        double sum = 0.0;
        for (int j = 0; j < MAK_TP_TAPS; j++)
            sum += h[p + MAK_TP_PHASES * j];
        for (int j = 0; j < MAK_TP_TAPS; j++)
            f->coeff[p][j] = (float)(h[p + MAK_TP_PHASES * j] /
                                     (sum != 0.0 ? sum : 1.0));
    }
}

/* Push one input sample; return the max |y| over its 4 interpolated
 * output samples. */
static inline double true_peak_run(const struct true_peak_fir *f,
                                   struct true_peak_state *s, float x)
{
    /* Write to both mirror slots so the tap window stays contiguous; the newest
     * sample is then at hist[pos + TAPS - 1] and the j-th tap (newest first) is
     * hist[pos + TAPS - 1 - j] with no wraparound. Same coeff*sample pairing and
     * the same newest-to-oldest accumulation order as the modulo ring, so the
     * peak is bit-identical (FP addition is order-sensitive — this order must
     * not change). */
    s->hist[s->pos] = x;
    s->hist[s->pos + MAK_TP_TAPS] = x;
    if (++s->pos == MAK_TP_TAPS) s->pos = 0;
    const float *w = &s->hist[s->pos + MAK_TP_TAPS - 1];  /* w[0] = newest */
    double peak = 0.0;
    for (int p = 0; p < MAK_TP_PHASES; p++) {
        double acc = 0.0;
        for (int j = 0; j < MAK_TP_TAPS; j++)
            acc += (double)f->coeff[p][j] * w[-j];
        double a = fabs(acc);
        if (a > peak) peak = a;
    }
    return peak;
}

/* ─── per-worker accumulator ──────────────────────────────────────── */

#define MAK_LOUD_MAX_CH 16

struct mak_loud_worker {
    SwrContext *swr;             /* source layout → FLT interleaved */
    int         channels;
    int         rate;
    double      ch_weight[MAK_LOUD_MAX_CH];

    struct biquad        shelf, hipass;
    struct biquad_state  shelf_st[MAK_LOUD_MAX_CH];
    struct biquad_state  hipass_st[MAK_LOUD_MAX_CH];

    struct true_peak_fir   tp_fir;
    struct true_peak_state tp_st[MAK_LOUD_MAX_CH];

    int64_t  hop;                /* samples per 100 ms sub-block */
    int64_t  grid_start;         /* first owned sample (= first_k * hop) */
    int64_t  grid_end;           /* one past the last owned sample */
    int64_t  first_subblock;     /* global index of the first owned block */
    int      n_subblocks;
    double  *sums;
    int64_t *counts;

    double   sample_peak;
    double   true_peak;

    float   *buf;                /* interleaved FLT conversion buffer */
    int      buf_capacity;       /* in samples-per-channel */
    bool     failed;
};

static double channel_weight(enum AVChannel ch)
{
    switch (ch) {
        case AV_CHAN_LOW_FREQUENCY:
        case AV_CHAN_LOW_FREQUENCY_2:
            return 0.0;                    /* LFE is excluded */
        case AV_CHAN_BACK_LEFT:
        case AV_CHAN_BACK_RIGHT:
        case AV_CHAN_SIDE_LEFT:
        case AV_CHAN_SIDE_RIGHT:
        case AV_CHAN_BACK_CENTER:
            return 1.41;                   /* surround weighting */
        default:
            return 1.0;
    }
}

struct mak_loud_worker *mak_loud_worker_create(
    const struct AVCodecParameters *par, int sample_rate,
    int64_t slice_sample_start, int64_t slice_sample_end,
    int64_t total_samples)
{
    if (!par || sample_rate <= 0 || par->ch_layout.nb_channels <= 0 ||
        par->ch_layout.nb_channels > MAK_LOUD_MAX_CH ||
        slice_sample_end <= slice_sample_start)
        return NULL;

    struct mak_loud_worker *w = av_mallocz(sizeof(*w));
    if (!w) return NULL;

    w->channels = par->ch_layout.nb_channels;
    w->rate     = sample_rate;
    w->hop      = (sample_rate + MAK_LOUD_SUBBLOCK_HOPS_PER_SEC / 2) /
                  MAK_LOUD_SUBBLOCK_HOPS_PER_SEC;
    if (w->hop <= 0) { av_free(w); return NULL; }

    /* Owned grid: sub-blocks k with k*hop in [start, end), end rounded
     * up to the hop boundary and clamped to the track total. */
    int64_t first_k = (slice_sample_start + w->hop - 1) / w->hop;
    if (slice_sample_start == 0) first_k = 0;
    int64_t end_k = (slice_sample_end + w->hop - 1) / w->hop;
    int64_t total_k = total_samples > 0
                      ? (total_samples + w->hop - 1) / w->hop
                      : end_k;
    if (end_k > total_k) end_k = total_k;
    if (end_k <= first_k) { av_free(w); return NULL; }

    w->first_subblock = first_k;
    w->n_subblocks    = (int)(end_k - first_k);
    w->grid_start     = first_k * w->hop;
    w->grid_end       = end_k * w->hop;
    if (total_samples > 0 && w->grid_end > total_samples)
        w->grid_end = total_samples;

    w->sums   = av_calloc(w->n_subblocks, sizeof(double));
    w->counts = av_calloc(w->n_subblocks, sizeof(int64_t));
    if (!w->sums || !w->counts) goto fail;

    /* Converter: source layout/format → interleaved float, same rate.
     * No resampling — pure format/packing conversion. */
    AVChannelLayout out_layout;
    if (av_channel_layout_copy(&out_layout, &par->ch_layout) < 0) goto fail;
    int ret = swr_alloc_set_opts2(&w->swr,
        &out_layout, AV_SAMPLE_FMT_FLT, sample_rate,
        (AVChannelLayout *)&par->ch_layout, (enum AVSampleFormat)par->format,
        sample_rate, 0, NULL);
    av_channel_layout_uninit(&out_layout);
    if (ret < 0 || !w->swr) goto fail;
    if (swr_init(w->swr) < 0) goto fail;

    for (int c = 0; c < w->channels; c++) {
        enum AVChannel ch =
            av_channel_layout_channel_from_index(&par->ch_layout, c);
        w->ch_weight[c] = channel_weight(ch);
    }

    design_k_filters(sample_rate, &w->shelf, &w->hipass);
    design_true_peak_fir(&w->tp_fir);

    w->buf_capacity = 8192;
    w->buf = av_malloc((size_t)w->buf_capacity * w->channels * sizeof(float));
    if (!w->buf) goto fail;

    return w;

fail:
    mak_loud_worker_destroy(w);
    return NULL;
}

int64_t mak_loud_worker_decode_end(const struct mak_loud_worker *w)
{
    return w ? w->grid_end : 0;
}

int mak_loud_worker_feed(struct mak_loud_worker *w,
                         const struct AVFrame *frame,
                         int64_t abs_sample_pos)
{
    if (!w || w->failed || !frame || frame->nb_samples <= 0) return 0;

    if (frame->nb_samples > w->buf_capacity) {
        int new_cap = frame->nb_samples + 1024;
        float *grown = av_realloc(w->buf,
            (size_t)new_cap * w->channels * sizeof(float));
        if (!grown) { w->failed = true; return -1; }
        w->buf = grown;
        w->buf_capacity = new_cap;
    }
    uint8_t *out_data[1] = { (uint8_t *)w->buf };
    int converted = swr_convert(w->swr, out_data, w->buf_capacity,
                                (const uint8_t **)frame->data,
                                frame->nb_samples);
    if (converted < 0) { w->failed = true; return -1; }

    const int ch = w->channels;
    for (int i = 0; i < converted; i++) {
        int64_t pos = abs_sample_pos + i;
        bool in_grid = pos >= w->grid_start && pos < w->grid_end;
        int64_t local = in_grid ? (pos / w->hop - w->first_subblock) : -1;
        if (local >= w->n_subblocks) { in_grid = false; local = -1; }

        double wsum = 0.0;
        for (int c = 0; c < ch; c++) {
            float x = w->buf[i * ch + c];

            if (in_grid) {
                double tp = true_peak_run(&w->tp_fir, &w->tp_st[c], x);
                if (tp > w->true_peak) w->true_peak = tp;
                double ax = fabs(x);
                if (ax > w->sample_peak) w->sample_peak = ax;
            } else {
                /* warm the FIR history through the pre-roll too */
                (void)true_peak_run(&w->tp_fir, &w->tp_st[c], x);
            }

            float k = biquad_run(&w->shelf, &w->shelf_st[c], x);
            k = biquad_run(&w->hipass, &w->hipass_st[c], k);
            if (in_grid && w->ch_weight[c] > 0.0)
                wsum += w->ch_weight[c] * (double)k * (double)k;
        }
        if (in_grid) {
            w->sums[local]   += wsum;
            w->counts[local] += 1;
        }
    }
    return 0;
}

bool mak_loud_worker_finish(struct mak_loud_worker *w,
                            struct mak_loud_slice *out)
{
    if (out) *out = (struct mak_loud_slice){0};
    if (!w) return false;
    bool ok = !w->failed && w->n_subblocks > 0 && out;
    if (ok) {
        out->subblock_sums   = w->sums;
        out->subblock_counts = w->counts;
        out->first_subblock  = w->first_subblock;
        out->n_subblocks     = w->n_subblocks;
        out->sample_peak     = w->sample_peak;
        out->true_peak       = w->true_peak;
        w->sums = NULL;
        w->counts = NULL;
    }
    mak_loud_worker_destroy(w);
    return ok;
}

void mak_loud_worker_destroy(struct mak_loud_worker *w)
{
    if (!w) return;
    if (w->swr) swr_free(&w->swr);
    if (w->sums) av_free(w->sums);
    if (w->counts) av_free(w->counts);
    if (w->buf) av_free(w->buf);
    av_free(w);
}

void mak_loud_slice_free(struct mak_loud_slice *s)
{
    if (!s) return;
    if (s->subblock_sums) av_free(s->subblock_sums);
    if (s->subblock_counts) av_free(s->subblock_counts);
    *s = (struct mak_loud_slice){0};
}

/* ─── global result store ─────────────────────────────────────────── */

enum mak_loud_state {
    MAK_LOUD_IDLE        = 0,
    MAK_LOUD_SCANNING    = 1,
    MAK_LOUD_READY       = 2,
    MAK_LOUD_FAILED      = 3,
    MAK_LOUD_UNAVAILABLE = 4,
};

static const char *loud_state_string(enum mak_loud_state s)
{
    switch (s) {
        case MAK_LOUD_SCANNING:    return "scanning";
        case MAK_LOUD_READY:       return "ready";
        case MAK_LOUD_FAILED:      return "failed";
        case MAK_LOUD_UNAVAILABLE: return "unavailable";
        case MAK_LOUD_IDLE:
        default:                   return "idle";
    }
}

static atomic_bool g_loud_enabled = false;

static struct {
    enum mak_loud_state state;
    double  integrated_lufs;
    double  lra_lu;
    double  sample_peak;
    double  true_peak;
    int64_t gated_block_count;
} g_loud;   /* zero-init: state == MAK_LOUD_IDLE */
/* The lock lives OUTSIDE the state struct on purpose: Darwin's
 * PTHREAD_MUTEX_INITIALIZER carries a non-zero signature, and a single
 * initialized member drags the WHOLE struct out of __bss into __data —
 * every embedded buffer byte then ships as on-disk zeros (~0.5 MiB per
 * Apple slice for the ring structs). A separate statically-initialized
 * lock plus a zero-init struct keeps identical semantics at zero file
 * cost. (ELF/PE are immune: their static lock initializers are all
 * zero.) */
static mp_mutex g_loud_lock = MP_STATIC_MUTEX_INITIALIZER;

static void loud_set_state(int gen, enum mak_loud_state s)
{
    if (!atomic_load(&g_loud_enabled)) return;
    if (gen != mak_waveform_current_gen()) return;
    mp_mutex_lock(&g_loud_lock);
    g_loud.state = s;
    g_loud.integrated_lufs = 0;
    g_loud.lra_lu = 0;
    g_loud.sample_peak = 0;
    g_loud.true_peak = 0;
    g_loud.gated_block_count = 0;
    mp_mutex_unlock(&g_loud_lock);
}

void mak_loudness_mark_scanning(int gen)    { loud_set_state(gen, MAK_LOUD_SCANNING); }
void mak_loudness_mark_unavailable(int gen) { loud_set_state(gen, MAK_LOUD_UNAVAILABLE); }
void mak_loudness_mark_failed(int gen)      { loud_set_state(gen, MAK_LOUD_FAILED); }

void mak_loudness_reset(void)
{
    mp_mutex_lock(&g_loud_lock);
    g_loud.state = MAK_LOUD_IDLE;
    g_loud.integrated_lufs = 0;
    g_loud.lra_lu = 0;
    g_loud.sample_peak = 0;
    g_loud.true_peak = 0;
    g_loud.gated_block_count = 0;
    mp_mutex_unlock(&g_loud_lock);
}

void mak_loudness_set_enabled(bool on)
{
    atomic_store(&g_loud_enabled, on);
    if (!on)
        mak_loudness_reset();
}

bool mak_loudness_is_enabled(void)
{
    return atomic_load(&g_loud_enabled);
}

/* energy → loudness; the -0.691 offset is the BS.1770 calibration. */
static inline double energy_to_lufs(double e)
{
    return -0.691 + 10.0 * log10(e > 0 ? e : 1e-15);
}

static int cmp_double(const void *a, const void *b)
{
    double da = *(const double *)a, db = *(const double *)b;
    return (da > db) - (da < db);
}

void mak_loudness_publish(struct mak_loud_slice *slices, int n,
                          int sample_rate, int gen)
{
    (void)sample_rate;

    /* Concatenate the slices onto one global sub-block array. */
    int64_t first = INT64_MAX, last = INT64_MIN;
    double sample_peak = 0, true_peak = 0;
    for (int i = 0; i < n; i++) {
        if (slices[i].n_subblocks <= 0) continue;
        if (slices[i].first_subblock < first)
            first = slices[i].first_subblock;
        int64_t e = slices[i].first_subblock + slices[i].n_subblocks;
        if (e > last) last = e;
        if (slices[i].sample_peak > sample_peak)
            sample_peak = slices[i].sample_peak;
        if (slices[i].true_peak > true_peak)
            true_peak = slices[i].true_peak;
    }

    bool want = atomic_load(&g_loud_enabled) &&
                gen == mak_waveform_current_gen();
    if (!want || first == INT64_MAX || last <= first) {
        for (int i = 0; i < n; i++) mak_loud_slice_free(&slices[i]);
        if (want) loud_set_state(gen, MAK_LOUD_FAILED);
        return;
    }

    int total = (int)(last - first);
    double  *sums   = av_calloc(total, sizeof(double));
    int64_t *counts = av_calloc(total, sizeof(int64_t));
    /* worst case one momentary energy per sub-block */
    double *mom = av_malloc((size_t)total * sizeof(double));
    double *st  = av_malloc((size_t)total * sizeof(double));
    if (!sums || !counts || !mom || !st) {
        if (sums) av_free(sums);
        if (counts) av_free(counts);
        if (mom) av_free(mom);
        if (st) av_free(st);
        for (int i = 0; i < n; i++) mak_loud_slice_free(&slices[i]);
        loud_set_state(gen, MAK_LOUD_FAILED);
        return;
    }
    for (int i = 0; i < n; i++) {
        struct mak_loud_slice *s = &slices[i];
        for (int k = 0; k < s->n_subblocks; k++) {
            int64_t g = s->first_subblock + k - first;
            if (g >= 0 && g < total) {
                sums[g]   += s->subblock_sums[k];
                counts[g] += s->subblock_counts[k];
            }
        }
        mak_loud_slice_free(s);
    }

    /* Expected samples per complete sub-block. */
    int64_t hop = (sample_rate + MAK_LOUD_SUBBLOCK_HOPS_PER_SEC / 2) /
                  MAK_LOUD_SUBBLOCK_HOPS_PER_SEC;

    /* Momentary 400 ms blocks: 4 consecutive complete sub-blocks. */
    int n_mom = 0;
    for (int k = 0; k + 4 <= total; k++) {
        double  esum = 0;
        int64_t csum = 0;
        bool complete = true;
        for (int j = 0; j < 4; j++) {
            if (counts[k + j] < hop) { complete = false; break; }
            esum += sums[k + j];
            csum += counts[k + j];
        }
        if (!complete || csum <= 0) continue;
        mom[n_mom++] = esum / (double)csum;
    }

    /* Integrated: absolute gate (-70), then relative gate (-10 LU). */
    double integrated = -HUGE_VAL;
    int64_t gated_blocks = 0;
    {
        double abs_sum = 0; int abs_n = 0;
        for (int k = 0; k < n_mom; k++) {
            if (energy_to_lufs(mom[k]) > -70.0) {
                abs_sum += mom[k];
                abs_n++;
            }
        }
        if (abs_n > 0) {
            double rel_thresh = energy_to_lufs(abs_sum / abs_n) - 10.0;
            double sum = 0; int cnt = 0;
            for (int k = 0; k < n_mom; k++) {
                if (energy_to_lufs(mom[k]) > -70.0 &&
                    energy_to_lufs(mom[k]) > rel_thresh) {
                    sum += mom[k];
                    cnt++;
                }
            }
            if (cnt > 0) {
                integrated = energy_to_lufs(sum / cnt);
                gated_blocks = cnt;
            }
        }
    }

    /* LRA (EBU Tech 3342): short-term 3 s windows on the same hop grid,
     * absolute gate -70, relative gate -20 LU below the abs-gated mean;
     * LRA = p95 - p10 of the surviving distribution. */
    double lra = 0.0;
    {
        int n_st = 0;
        for (int k = 0; k + 30 <= total; k++) {
            double  esum = 0;
            int64_t csum = 0;
            bool complete = true;
            for (int j = 0; j < 30; j++) {
                if (counts[k + j] < hop) { complete = false; break; }
                esum += sums[k + j];
                csum += counts[k + j];
            }
            if (!complete || csum <= 0) continue;
            st[n_st++] = esum / (double)csum;
        }
        double abs_sum = 0; int abs_n = 0;
        for (int k = 0; k < n_st; k++) {
            if (energy_to_lufs(st[k]) > -70.0) {
                abs_sum += st[k];
                abs_n++;
            }
        }
        if (abs_n > 0) {
            double rel = energy_to_lufs(abs_sum / abs_n) - 20.0;
            int cnt = 0;
            for (int k = 0; k < n_st; k++) {
                double l = energy_to_lufs(st[k]);
                if (l > -70.0 && l > rel)
                    st[cnt++] = l;   /* compact in place, as LUFS */
            }
            if (cnt >= 2) {
                qsort(st, cnt, sizeof(double), cmp_double);
                double p10 = st[(int)((cnt - 1) * 0.10 + 0.5)];
                double p95 = st[(int)((cnt - 1) * 0.95 + 0.5)];
                lra = p95 - p10;
            }
        }
    }

    av_free(sums);
    av_free(counts);
    av_free(mom);
    av_free(st);

    mp_mutex_lock(&g_loud_lock);
    if (atomic_load(&g_loud_enabled) && gen == mak_waveform_current_gen()) {
        if (integrated > -HUGE_VAL) {
            g_loud.state             = MAK_LOUD_READY;
            g_loud.integrated_lufs   = integrated;
            g_loud.lra_lu            = lra;
            g_loud.sample_peak       = sample_peak;
            g_loud.true_peak         = true_peak;
            g_loud.gated_block_count = gated_blocks;
        } else {
            /* nothing above the absolute gate — silence-only track */
            g_loud.state             = MAK_LOUD_READY;
            g_loud.integrated_lufs   = -70.0;
            g_loud.lra_lu            = 0;
            g_loud.sample_peak       = sample_peak;
            g_loud.true_peak         = true_peak;
            g_loud.gated_block_count = 0;
        }
    }
    mp_mutex_unlock(&g_loud_lock);
}

int mak_loudness_read(struct mpv_node *out)
{
    if (!out) return -1;

    mp_mutex_lock(&g_loud_lock);
    enum mak_loud_state state = g_loud.state;
    double  integrated = g_loud.integrated_lufs;
    double  lra        = g_loud.lra_lu;
    double  speak      = g_loud.sample_peak;
    double  tpeak      = g_loud.true_peak;
    int64_t blocks     = g_loud.gated_block_count;
    mp_mutex_unlock(&g_loud_lock);

    /* Scanning progress [0,1]: the offline scan rides the bulk waveform decode
     * pass, so its progress IS the waveform's sealed-bin fraction. Read after
     * releasing g_loud_lock — mak_waveform_decode_fraction() takes g_wave_lock,
     * so this avoids nesting the two locks. 1.0 when ready, 0 otherwise. */
    double progress = 0.0;
    if (state == MAK_LOUD_SCANNING)
        progress = mak_waveform_decode_fraction();
    else if (state == MAK_LOUD_READY)
        progress = 1.0;

    struct mpv_node_list *list = talloc_zero(NULL, struct mpv_node_list);
    list->num    = 7;
    list->keys   = talloc_array(list, char *, 7);
    list->values = talloc_array(list, struct mpv_node, 7);

    list->keys[0] = talloc_strdup(list, "state");
    list->values[0] = (struct mpv_node){
        .format = MPV_FORMAT_STRING,
        .u.string = talloc_strdup(list, loud_state_string(state))};
    list->keys[1] = talloc_strdup(list, "integrated_lufs");
    list->values[1] = (struct mpv_node){
        .format = MPV_FORMAT_DOUBLE, .u.double_ = integrated};
    list->keys[2] = talloc_strdup(list, "lra_lu");
    list->values[2] = (struct mpv_node){
        .format = MPV_FORMAT_DOUBLE, .u.double_ = lra};
    list->keys[3] = talloc_strdup(list, "sample_peak");
    list->values[3] = (struct mpv_node){
        .format = MPV_FORMAT_DOUBLE, .u.double_ = speak};
    list->keys[4] = talloc_strdup(list, "true_peak");
    list->values[4] = (struct mpv_node){
        .format = MPV_FORMAT_DOUBLE, .u.double_ = tpeak};
    list->keys[5] = talloc_strdup(list, "gated_block_count");
    list->values[5] = (struct mpv_node){
        .format = MPV_FORMAT_INT64, .u.int64 = blocks};
    /* Live scan progress [0,1] — meaningful while state == "scanning"
     * (1.0 at "ready", 0 otherwise). */
    list->keys[6] = talloc_strdup(list, "progress");
    list->values[6] = (struct mpv_node){
        .format = MPV_FORMAT_DOUBLE, .u.double_ = progress};

    *out = (struct mpv_node){
        .format = MPV_FORMAT_NODE_MAP, .u.list = list};
    return 0;
}
