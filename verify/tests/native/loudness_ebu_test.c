// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// loudness_ebu_test <mode> <fixtures> <tmpdir>: the figures of
// loudness-scan-data against the values a compliant meter gives, on the
// synthetic signals of EBU Tech 3341 and Tech 3342 that fixtures.sh makes
// (ebu/, 1 kHz sines of a known level). The tolerances are the documents':
// 0.1 LU on the integrated loudness, +0.2 and -0.4 dB on the true peak, 1 LU
// on the loudness range. A local file is measured by the bulk scan, four
// workers whose slices the coordinator merges; a mode ending in "http" reads
// the same files from slow_http.py, so the pass that decodes mpv's cache
// measures them, and checks that no file was downloaded twice.
//   tone      3341 cases 1 and 2: -23 and -33 dBFS stereo read -23.0 and
//             -33.0 LUFS; the sample peak is the sine's.
//   gate      cases 3, 4 and 5: the quiet parts fall under the relative
//             gate (-36), under the absolute one (-72), and the loud middle
//             of case 5 is weighed with what surrounds it: -23.0 LUFS each.
//   surround  case 6, 5.0 with its surrounds weighted 1.41, and the same in
//             5.1 with a loud LFE the measure leaves out: -23.0 LUFS.
//   rate      the K filter at 44.1 and at 96 kHz (-23.0 LUFS), and a mono
//             file, one channel of BS.1770 (-26.0 LUFS).
//   peak      cases 15 to 19: a crest between the samples, -6.0 dBTP four
//             times and +3.0 dBTP, with the sample peak up to 3 dB below.
//   lra       3342 cases 1 to 4: 10, 5, 20 and 15 LU, with the integrated
//             loudness the gates give for each.
#include <math.h>
#include "analysis_test.h"

struct row {
    const char *mode, *file;
    double lufs;        // integrated loudness, within 0.1 LU
    double peak_db;     // sample peak in dBFS, within 0.1 dB; NAN: not checked
    double tp_db;       // true peak in dBTP, +0.2 -0.4 dB; NAN: not checked
    double lra;         // loudness range, within 1 LU; NAN: not checked
};

static const struct row ROWS[] = {
    {"tone", "s23.flac", -23.0, -23.0, NAN, 0},
    {"tone", "s33.flac", -33.0, -33.0, NAN, 0},
    {"gate", "g3.flac", -23.0, -23.0, NAN, NAN},
    {"gate", "g4.flac", -23.0, -23.0, NAN, NAN},
    {"gate", "g5.flac", -23.0, -20.0, NAN, NAN},
    {"surround", "c50.wav", -23.0, -24.0, NAN, 0},
    {"surround", "c51.flac", -23.0, -6.0, NAN, 0},
    {"rate", "r44.flac", -23.0, NAN, NAN, 0},
    {"rate", "r96.flac", -23.0, -23.0, NAN, 0},
    {"rate", "m23.flac", -26.0, -23.0, NAN, 0},
    // 20 log10(0.5 sin 90) and so on: the largest sample of each sine.
    {"peak", "tp15.flac", NAN, -6.02, -6.0, NAN},
    {"peak", "tp16.flac", NAN, -9.03, -6.0, NAN},
    {"peak", "tp17.flac", NAN, -7.27, -6.0, NAN},
    {"peak", "tp18.flac", NAN, -6.71, -6.0, NAN},
    {"peak", "tp19.flac", NAN, -0.03, 3.0, NAN},
    // The integrated loudness is the mean of the energies the relative
    // gate keeps: both halves of the first two, the loud half of the third
    // (the quiet one is 17 LU under the mean), -35 and -20 of the fourth.
    {"lra", "l1.flac", -22.6, -20.0, NAN, 10},
    {"lra", "l2.flac", -16.8, -15.0, NAN, 5},
    {"lra", "l3.flac", -20.0, -20.0, NAN, 20},
    {"lra", "l4.flac", -24.5, -20.0, NAN, 15},
};

struct figures {
    char state[32];
    double lufs, lra, peak, true_peak;
    int64_t blocks;
};

static void read_figures(mpv_handle *h, struct figures *g)
{
    mpv_node n;
    memset(g, 0, sizeof(*g));
    snprintf(g->state, sizeof g->state, "<error>");
    if (mpv_get_property(h, "loudness-scan-data", MPV_FORMAT_NODE, &n) < 0)
        return;
    mpv_node *f = an_field(&n, "state");
    snprintf(g->state, sizeof g->state, "%s",
             f && f->format == MPV_FORMAT_STRING ? f->u.string : "?");
    const char *keys[] = {"integrated_lufs", "lra_lu", "sample_peak", "true_peak"};
    double *out[] = {&g->lufs, &g->lra, &g->peak, &g->true_peak};
    for (int i = 0; i < 4; i++) {
        f = an_field(&n, keys[i]);
        *out[i] = f && f->format == MPV_FORMAT_DOUBLE ? f->u.double_ : NAN;
    }
    f = an_field(&n, "gated_block_count");
    g->blocks = f && f->format == MPV_FORMAT_INT64 ? f->u.int64 : -1;
    mpv_free_node_contents(&n);
}

static double db(double linear)
{
    return linear > 0 ? 20 * log10(linear) : -INFINITY;
}

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s tone|gate|surround|rate|peak|lra[http] <fixtures> <tmpdir>\n", argv[0]);
        return 2;
    }
    char mode[32];
    snprintf(mode, sizeof mode, "%s", argv[1]);
    size_t len = strlen(mode);
    int http = len > 4 && !strcmp(mode + len - 4, "http");
    if (http)
        mode[len - 4] = 0;

    int files = 0;
    for (size_t r = 0; r < sizeof(ROWS) / sizeof(ROWS[0]); r++) {
        const struct row *row = &ROWS[r];
        if (strcmp(row->mode, mode))
            continue;
        files++;
        char file[1024];
        if (http)
            snprintf(file, sizeof file, "http://127.0.0.1:%s/%s",
                     getenv("HTTP_PORT") ? getenv("HTTP_PORT") : "0", row->file);
        else
            snprintf(file, sizeof file, "%s/%s", argv[2], row->file);

        mpv_handle *h = an_create();
        mpv_initialize(h);
        an_flag(h, "waveform-enabled", 1);
        an_flag(h, "loudness-scan-enabled", 1);
        mpv_set_property_string(h, "pause", "yes");
        mt_cmd(h, "loadfile", file, NULL, NULL);
        mt_check(an_wait_event(h, MPV_EVENT_FILE_LOADED, 15), "%s: file loaded", row->file);
        struct an_wave w;
        struct an_loud lo;
        an_wait_final(h, 1, 1, 60, &w, &lo);
        struct figures g;
        read_figures(h, &g);
        printf("     %s: %s, %.3f LUFS (%lld blocks), LRA %.3f LU, sample peak %.3f dBFS, "
               "true peak %.3f dBTP\n", row->file, g.state, g.lufs,
               (long long)g.blocks, g.lra, db(g.peak), db(g.true_peak));
        mt_check(!strcmp(g.state, "ready") && !strcmp(w.state, "ready"),
                 "%s: loudness and waveform ready (%s, %s)", row->file, g.state, w.state);
        if (!isnan(row->lufs))
            mt_check(fabs(g.lufs - row->lufs) <= 0.1,
                     "%s: integrated loudness %.1f LUFS within 0.1 LU (%.3f)",
                     row->file, row->lufs, g.lufs);
        if (!isnan(row->peak_db))
            mt_check(fabs(db(g.peak) - row->peak_db) <= 0.1,
                     "%s: sample peak %.2f dBFS within 0.1 dB (%.3f)",
                     row->file, row->peak_db, db(g.peak));
        if (!isnan(row->tp_db)) {
            double d = db(g.true_peak) - row->tp_db;
            mt_check(d <= 0.2 && d >= -0.4,
                     "%s: true peak %.1f dBTP within +0.2 and -0.4 dB (%.3f)",
                     row->file, row->tp_db, db(g.true_peak));
        }
        // The oversampling filter may read a sample a little low (0.13 dB
        // at a quarter of the rate), inside the tolerance of the true peak.
        mt_check(db(g.true_peak) >= db(g.peak) - 0.4,
                 "%s: the true peak is not under the sample peak by more than "
                 "0.4 dB (%.3f, %.3f)", row->file, db(g.true_peak), db(g.peak));
        if (!isnan(row->lra))
            mt_check(fabs(g.lra - row->lra) <= 1.0,
                     "%s: loudness range %.0f LU within 1 LU (%.3f)",
                     row->file, row->lra, g.lra);
        an_wave_free(&w);
        mpv_terminate_destroy(h);
    }
    if (!files) {
        fprintf(stderr, "unknown mode %s\n", argv[1]);
        return 2;
    }

    if (http) {
        // One line per GET in the server's log. A file measured from the
        // cache is read once from its start; a scan that opens the URL
        // itself reads it from the start again.
        char path[1100], line[256];
        snprintf(path, sizeof path, "%s.http.log", argv[3]);
        FILE *f = fopen(path, "r");
        int from0 = 0;
        while (f && fgets(line, sizeof line, f)) {
            printf("     server: %s", line);
            from0 += strstr(line, "range=0-") != NULL;
        }
        if (f)
            fclose(f);
        mt_check(from0 == files, "no file downloaded twice (%d GETs from the start, %d files)",
                 from0, files);
    }
    return mt_result();
}
