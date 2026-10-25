// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// af_command_args_test <mode> <fixtures> <tmpdir>: an af-command that
// succeeds becomes part of the arguments the filter keeps
// (patch_af_command_args.py). The files are constant (DC): a bass stage
// (a low shelf, whose gain at DC is exactly its gain) doubles the level for
// about +6 dB, and the PCM tap reads the level after the filters.
//   prop      af-command-saves-args reads yes
//   seek      bass at gain 0, af-command gain 6, then a seek: the level
//             stays doubled; af holds gain 6 and its observers hear of it
//   track     the same, then the second audio track (aid 2)
//   extern    the same, then audio-add of another file, selected
//   reload    the same, then audio-reload
//   next      the same, then the next playlist entry
//   keep      the same, then af set with the kit's string for the live
//             value and a new stage: the bass stage is kept, not rebuilt
//   rollback  F50: af-command gain 6 on top of a refused af set, then af
//             set of the accepted chain (gain 0): the level goes back
//   order     equalizer: a key af-command adds goes in name order, a value
//             back at its default drops the key (the kit's form), an alias
//             keeps its spelling; bass with every key at its default has
//             no arguments left
//   fail      refused commands (out of range, unknown option, unknown
//             label, other filter, a value the running filter refuses)
//             change neither af nor, after a seek, the level (control,
//             green before and after)
//   labels    two labelled bass stages and a lavfi graph: a command changes
//             the stage it names only; the graph and the "all" target keep
//             the arguments they had, as upstream
//   bridge    lavfi-bridge, whose entry holds name= and opts=: the command
//             plays and the arguments stay, as upstream (control)
#include "playback_test.h"

#define DB6 1.9953 // the gain of 6 dB

static int m_seek, m_track, m_extern, m_reload, m_next, m_keep, m_rollback;
static int af_changes; // property-change events of af
static struct pb_ev ev;

// Drains the events for up to ms into ev and af_changes.
static void pump(mpv_handle *h, int ms)
{
    double until = mt_now() + ms / 1000.0;
    for (;;) {
        double left = until - mt_now();
        mpv_event *e = mpv_wait_event(h, left > 0 ? left : 0);
        if (e->event_id == MPV_EVENT_NONE) {
            if (left <= 0)
                return;
            continue;
        }
        if (e->event_id == MPV_EVENT_PROPERTY_CHANGE && e->reply_userdata == 1)
            af_changes++;
        if (e->event_id == MPV_EVENT_LOG_MESSAGE) {
            mpv_event_log_message *m = e->data;
            for (int i = 0; i < 4 && ev.needle[i]; i++)
                if (strstr(m->text, ev.needle[i]))
                    ev.hits[i]++;
        }
        if (e->event_id == MPV_EVENT_FILE_LOADED)
            ev.loaded++;
    }
}

// The mean of the PCM tap window: the level of a constant file.
static int level(mpv_handle *h, double *out)
{
    mpv_node n;
    if (mpv_get_property(h, "pcm-tap-frame", MPV_FORMAT_NODE, &n) < 0)
        return -1;
    mpv_node *s = pb_field(&n, "samples");
    int ok = s && s->format == MPV_FORMAT_BYTE_ARRAY && s->u.ba->size >= sizeof(float);
    if (ok) {
        const float *f = s->u.ba->data;
        size_t num = s->u.ba->size / sizeof(float);
        double sum = 0;
        for (size_t i = 0; i < num; i++)
            sum += f[i];
        *out = sum / num;
    }
    mpv_free_node_contents(&n);
    return ok ? 0 : -1;
}

static int near(double v, double want) { return v > want - 0.04 && v < want + 0.04; }

// Waits up to 4 s for three reads in a row at want.
static int wait_level(mpv_handle *h, double want, const char *what)
{
    double t0 = mt_now(), v = 0;
    int got = -1, in_row = 0;
    while (mt_now() - t0 < 4) {
        pump(h, 30);
        got = level(h, &v);
        in_row = got == 0 && near(v, want) ? in_row + 1 : 0;
        if (in_row == 3)
            break;
    }
    mt_check(in_row == 3, "%s: level %.4f (want %.4f)", what,
             got == 0 ? v : -9.0, want);
    return in_row == 3;
}

// Reads for ms: every read at want.
static int hold_level(mpv_handle *h, double want, int ms, const char *what)
{
    double t0 = mt_now(), v = 0, worst = want;
    int reads = 0, off = 0;
    while (mt_now() - t0 < ms / 1000.0) {
        pump(h, 30);
        if (level(h, &v) < 0)
            continue;
        reads++;
        if (!near(v, want)) {
            off++;
            worst = v;
        }
    }
    mt_check(reads > 0 && off == 0, "%s: %d of %d reads off (%.4f, want %.4f)",
             what, off, reads, worst, want);
    return reads > 0 && off == 0;
}

// af as "@label:name=k=v:k=v,...", without the escapes of its string form.
static void af_plain(mpv_handle *h, char *out, size_t size)
{
    mpv_node n;
    out[0] = 0;
    if (mpv_get_property(h, "af", MPV_FORMAT_NODE, &n) < 0) {
        snprintf(out, size, "<error>");
        return;
    }
    size_t len = 0;
    for (int i = 0; n.format == MPV_FORMAT_NODE_ARRAY && i < n.u.list->num; i++) {
        mpv_node *e = &n.u.list->values[i];
        mpv_node *name = pb_field(e, "name"), *label = pb_field(e, "label"),
                 *params = pb_field(e, "params");
        len += snprintf(out + len, size - len, "%s", i ? "," : "");
        if (label && label->format == MPV_FORMAT_STRING)
            len += snprintf(out + len, size - len, "@%s:", label->u.string);
        len += snprintf(out + len, size - len, "%s",
                        name && name->format == MPV_FORMAT_STRING ? name->u.string : "?");
        for (int k = 0; params && params->format == MPV_FORMAT_NODE_MAP &&
                        k < params->u.list->num; k++) {
            mpv_node *v = &params->u.list->values[k];
            len += snprintf(out + len, size - len, "%s%s=%s", k ? ":" : "=",
                            params->u.list->keys[k],
                            v->format == MPV_FORMAT_STRING ? v->u.string : "?");
        }
    }
    mpv_free_node_contents(&n);
}

static int af_is(mpv_handle *h, const char *want, const char *what)
{
    char got[1024];
    af_plain(h, got, sizeof got);
    int ok = !strcmp(got, want);
    mt_check(ok, "%s: af %s", what, got);
    if (!ok)
        printf("     want %s\n", want);
    return ok;
}

static int af_set(mpv_handle *h, const char *chain)
{
    return mt_cmd(h, "af", "set", chain, NULL);
}

static int af_command(mpv_handle *h, const char *label, const char *opt,
                      const char *value, const char *target)
{
    const char *args[] = {"af-command", label, opt, value, target, NULL};
    int r = mpv_command(h, args);
    printf("     af-command %s %s %s %s: %s\n", label, opt, value, target,
           mpv_error_string(r));
    return r;
}

static void seek_to(mpv_handle *h, const char *pos)
{
    mt_cmd(h, "seek", pos, "absolute", NULL);
}

static int load(mpv_handle *h, const char *fx, const char *file)
{
    char path[4096];
    snprintf(path, sizeof path, "%s/%s", fx, file);
    int before = ev.loaded;
    mt_cmd(h, "loadfile", path, NULL, NULL);
    double t0 = mt_now();
    while (ev.loaded == before && mt_now() - t0 < 5)
        pump(h, 20);
    return ev.loaded > before;
}

// seek, track, extern, reload, next, keep and rollback: bass at gain 0,
// af-command gain 6, then what the mode does.
static void mode_live(mpv_handle *h, const char *fx)
{
    char path[4096];
    const char *file = m_track ? "dc2.mka" : "dc20.flac";
    af_set(h, "@aek_bass_0:lavfi-bass");
    mt_check(load(h, fx, file), "%s loaded", file);
    if (m_next) {
        snprintf(path, sizeof path, "%s/dcm20.flac", fx);
        mt_cmd(h, "loadfile", path, "append", NULL);
    }
    wait_level(h, 0.25, "bass at gain 0");
    if (m_rollback) {
        // B of F50: a chain mpv refuses keeps the one that plays.
        mt_check(af_set(h, "@aek_bass_0:lavfi-bass,lavfi-equalizer=f=abc") < 0,
                 "af set with a stage that cannot start is refused");
    }
    int before = af_changes;
    mt_check(af_command(h, "aek_bass_0", "gain", "6.000", "bass") >= 0,
             "af-command gain 6 succeeds");
    wait_level(h, 0.25 * DB6, "after af-command gain 6");
    af_is(h, "@aek_bass_0:lavfi-bass=gain=6.000", "after af-command");
    pump(h, 100);
    mt_check(af_changes > before, "af observers heard of the command (%d events)",
             af_changes - before);

    if (m_seek) {
        seek_to(h, "10");
        wait_level(h, 0.25 * DB6, "after a seek");
        hold_level(h, 0.25 * DB6, 1000, "a second after the seek");
    } else if (m_track) {
        mt_cmd(h, "set", "aid", "2", NULL);
        wait_level(h, -0.25 * DB6, "on the second track");
        hold_level(h, -0.25 * DB6, 1000, "a second on the second track");
    } else if (m_extern) {
        snprintf(path, sizeof path, "%s/dcm20.flac", fx);
        mt_cmd(h, "audio-add", path, "select", NULL);
        wait_level(h, -0.25 * DB6, "on the added track");
    } else if (m_reload) {
        mt_cmd(h, "audio-reload", NULL, NULL, NULL);
        wait_level(h, 0.25 * DB6, "after audio-reload");
    } else if (m_next) {
        mt_cmd(h, "playlist-next", NULL, NULL, NULL);
        wait_level(h, -0.25 * DB6, "on the next entry");
        af_is(h, "@aek_bass_0:lavfi-bass=gain=6.000", "on the next entry");
    } else if (m_keep) {
        ev.needle[0] = "[lavfi-bass] ";
        ev.needle[1] = "[lavfi-treble] ";
        pump(h, 0);
        ev.hits[0] = ev.hits[1] = 0;
        mt_check(af_set(h, "@aek_bass_0:lavfi-bass=gain=6.000,"
                           "@aek_treble_0:lavfi-treble") >= 0,
                 "af set with the live value and a new stage");
        hold_level(h, 0.25 * DB6, 1500, "after the new stage");
        mt_check(ev.hits[1] > 0, "the new stage got audio (%d)", ev.hits[1]);
        mt_check(ev.hits[0] == 0, "the bass stage was kept, not rebuilt (%d)",
                 ev.hits[0]);
    } else if (m_rollback) {
        mt_check(af_set(h, "@aek_bass_0:lavfi-bass") >= 0,
                 "af set of the accepted chain (gain 0)");
        wait_level(h, 0.25, "after the rollback");
        af_is(h, "@aek_bass_0:lavfi-bass", "after the rollback");
    }
}

static void mode_order(mpv_handle *h, const char *fx)
{
    const char *eq = "@aek_equalizer_0:lavfi-equalizer";
    char want[256];
    af_set(h, "@aek_equalizer_0:lavfi-equalizer=frequency=1000:width=2");
    mt_check(load(h, fx, "dc20.flac"), "dc20.flac loaded");
    wait_level(h, 0.25, "the equalizer plays");
    af_command(h, "aek_equalizer_0", "gain", "3.000", "equalizer");
    snprintf(want, sizeof want, "%s=frequency=1000:gain=3.000:width=2", eq);
    af_is(h, want, "gain goes between frequency and width");
    af_command(h, "aek_equalizer_0", "gain", "0.000", "equalizer");
    snprintf(want, sizeof want, "%s=frequency=1000:width=2", eq);
    af_is(h, want, "gain back at its default drops the key");
    af_command(h, "aek_equalizer_0", "width_type", "q", "equalizer");
    af_is(h, want, "width_type set to its default adds no key");
    af_command(h, "aek_equalizer_0", "width", "1.000", "equalizer");
    snprintf(want, sizeof want, "%s=frequency=1000", eq);
    af_is(h, want, "width back at its default drops the key");
    af_command(h, "aek_equalizer_0", "width_type", "o", "equalizer");
    snprintf(want, sizeof want, "%s=frequency=1000:width_type=o", eq);
    af_is(h, want, "a named constant is kept as sent");
    af_command(h, "aek_equalizer_0", "width_type", "q", "equalizer");
    snprintf(want, sizeof want, "%s=frequency=1000", eq);
    af_is(h, want, "a named constant back at its default drops the key");

    af_set(h, "@e:lavfi-equalizer=f=1000:g=2,@b:lavfi-bass=gain=2.000");
    pump(h, 300);
    af_command(h, "e", "gain", "4.000", "equalizer");
    af_command(h, "b", "gain", "0.000", "bass");
    af_is(h, "@e:lavfi-equalizer=f=1000:g=4.000,@b:lavfi-bass",
          "an alias keeps its spelling; every key at its default leaves none");
}

static void mode_fail(mpv_handle *h, const char *fx)
{
    const char *chain = "@aek_bass_0:lavfi-bass=gain=6.000";
    af_set(h, chain);
    mt_check(load(h, fx, "dc20.flac"), "dc20.flac loaded");
    wait_level(h, 0.25 * DB6, "bass at gain 6");
    mt_check(af_command(h, "aek_bass_0", "gain", "1000", "bass") < 0,
             "gain out of range is refused");
    mt_check(af_command(h, "aek_bass_0", "nope", "1", "bass") < 0,
             "an unknown option is refused");
    mt_check(af_command(h, "missing", "gain", "0", "bass") < 0,
             "an unknown label is refused");
    mt_check(af_command(h, "aek_bass_0", "gain", "0", "volume") < 0,
             "another filter's name is refused");
    // The option takes 0 and the filter then refuses it (biquads, while it
    // runs). Last: the refused value stays in the live filter.
    mt_check(af_command(h, "aek_bass_0", "frequency", "0", "bass") < 0,
             "a frequency the running filter refuses is refused");
    af_is(h, chain, "after the refused commands");
    seek_to(h, "10");
    wait_level(h, 0.25 * DB6, "after a seek");
}

static void mode_labels(mpv_handle *h, const char *fx)
{
    const double db3 = 1.41254; // 3.000 dB
    af_set(h, "@a:lavfi-bass,@b:lavfi-bass,@g:lavfi=[bass]");
    mt_check(load(h, fx, "dc20.flac"), "dc20.flac loaded");
    wait_level(h, 0.25, "three stages at gain 0");
    af_command(h, "b", "gain", "3.000", "bass");
    wait_level(h, 0.25 * db3, "b at gain 3");
    af_is(h, "@a:lavfi-bass,@b:lavfi-bass=gain=3.000,@g:lavfi=graph=bass",
          "only b changes");
    seek_to(h, "5");
    wait_level(h, 0.25 * db3, "b after a seek");
    af_command(h, "a", "gain", "3.000", "bass");
    af_is(h, "@a:lavfi-bass=gain=3.000,@b:lavfi-bass=gain=3.000,@g:lavfi=graph=bass",
          "then a changes");
    seek_to(h, "8");
    wait_level(h, 0.25 * db3 * db3, "a and b after a seek");
    // A graph keeps its string: the command plays until the graph restarts.
    mt_check(af_command(h, "g", "gain", "6.000", "bass") >= 0,
             "a command reaches the bass of the graph");
    wait_level(h, 0.25 * db3 * db3 * DB6, "the graph's bass at gain 6");
    af_is(h, "@a:lavfi-bass=gain=3.000,@b:lavfi-bass=gain=3.000,@g:lavfi=graph=bass",
          "the graph's arguments stay");
    seek_to(h, "11");
    wait_level(h, 0.25 * db3 * db3, "the graph after a seek is back at gain 0");
    // "all" reaches every stage and saves nothing, as upstream.
    af_command(h, "all", "gain", "0.000", "bass");
    af_is(h, "@a:lavfi-bass=gain=3.000,@b:lavfi-bass=gain=3.000,@g:lavfi=graph=bass",
          "the all target keeps the arguments");
}

static void mode_bridge(mpv_handle *h, const char *fx)
{
    const char *chain = "@r:lavfi-bridge=name=bass:opts=gain=0";
    af_set(h, "@r:lavfi-bridge=name=bass:opts=[gain=0]");
    mt_check(load(h, fx, "dc20.flac"), "dc20.flac loaded");
    af_is(h, chain, "the bridge");
    wait_level(h, 0.25, "the bridge at gain 0");
    mt_check(af_command(h, "r", "gain", "6.000", "bass") >= 0,
             "a command reaches the bridge's filter");
    wait_level(h, 0.25 * DB6, "the bridge at gain 6");
    af_is(h, chain, "the bridge's arguments stay");
    seek_to(h, "10");
    wait_level(h, 0.25, "the bridge after a seek is back at gain 0");
}

int main(int argc, char **argv)
{
    if (argc < 4)
        return 2;
    const char *mode = argv[1], *fx = argv[2];
    m_seek = !strcmp(mode, "seek");
    m_track = !strcmp(mode, "track");
    m_extern = !strcmp(mode, "extern");
    m_reload = !strcmp(mode, "reload");
    m_next = !strcmp(mode, "next");
    m_keep = !strcmp(mode, "keep");
    m_rollback = !strcmp(mode, "rollback");
    int live = m_seek || m_track || m_extern || m_reload || m_next || m_keep ||
               m_rollback;
    int m_prop = !strcmp(mode, "prop"), m_order = !strcmp(mode, "order"),
        m_fail = !strcmp(mode, "fail"), m_labels = !strcmp(mode, "labels"),
        m_bridge = !strcmp(mode, "bridge");
    if (!(live || m_prop || m_order || m_fail || m_labels || m_bridge)) {
        printf("unknown mode %s\n", mode);
        return 2;
    }

    mpv_handle *h = pb_create();
    mpv_set_option_string(h, "keep-open", "yes");
    if (mpv_initialize(h) < 0)
        return 2;
    mpv_request_log_messages(h, "v");
    mpv_observe_property(h, 1, "af", MPV_FORMAT_NONE);
    double v;
    level(h, &v); // the first read arms the tap

    if (m_prop) {
        int flag = -1;
        int r = mpv_get_property(h, "af-command-saves-args", MPV_FORMAT_FLAG, &flag);
        mt_check(r >= 0 && flag == 1, "af-command-saves-args is yes (%s, %d)",
                 mpv_error_string(r), flag);
        r = mpv_set_property_string(h, "af-command-saves-args", "no");
        mt_check(r < 0, "af-command-saves-args is read-only (%s)", mpv_error_string(r));
    } else if (live) {
        mode_live(h, fx);
    } else if (m_order) {
        mode_order(h, fx);
    } else if (m_fail) {
        mode_fail(h, fx);
    } else if (m_bridge) {
        mode_bridge(h, fx);
    } else {
        mode_labels(h, fx);
    }
    mpv_terminate_destroy(h);
    return mt_result();
}
