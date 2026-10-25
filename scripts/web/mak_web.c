/* Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
 * All rights reserved.
 * Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.
 *
 * mak_web.c: the C side of the web module (scripts/build_libmpv_web.sh).
 *
 * - One thread per lavfi graph. av_cpu_count() reads hardwareConcurrency,
 *   and every lavfi filter of mpv's af chain is a graph of its own with a
 *   slice pool that size: 16 workers per filter on a desktop, each one a Web
 *   Worker. The decoders already run on one thread (ad_lavc).
 * - The wakeup bridge. mpv calls the wakeup callback from any of its threads
 *   with its wakeup lock held; the bridge posts one task to the main thread,
 *   which calls Module.onMpvWakeup(handle) to drain mpv_wait_event(h, 0).
 *   A flag per handle keeps at most one task queued; it is cleared before
 *   the JS side drains, so a wakeup during the drain queues the next one.
 * - The layout of the client API structs on wasm32, for the JS decoder.
 * - The version of what a client of the module relies on, MAK_WEB_ABI.
 */
#include <stdatomic.h>
#include <stddef.h>
#include <stdlib.h>

#include <emscripten.h>
#include <emscripten/proxying.h>
#include <emscripten/threading.h>
#include <libavutil/cpu.h>
#include <mpv/client.h>

/* Bumped when a client of the module has to change with it: an export
 * removed or changed, the layout table below, the wakeup bridge, the API of
 * Module.makWebAudio or the makblob:// scheme. build_libmpv_web.sh writes
 * it into build_web.json, and the manifest lists it. */
#define MAK_WEB_ABI 1

__attribute__((constructor)) static void mak_web_one_cpu(void)
{
    av_cpu_force_count(1);
}

struct mak_web_wakeup {
    mpv_handle *handle;
    atomic_int queued;
    int detached;
};

EM_JS(void, mak_web_js_wakeup, (mpv_handle *handle), {
    const f = Module['onMpvWakeup'];
    if (f) f(handle);
});

/* Main thread. */
static void mak_web_wakeup_main(void *arg)
{
    struct mak_web_wakeup *w = arg;
    atomic_store(&w->queued, 0);
    if (w->detached) {
        free(w);
        return;
    }
    mak_web_js_wakeup(w->handle);
}

/* Any mpv thread, wakeup lock held: never blocks. */
static void mak_web_wakeup_cb(void *arg)
{
    struct mak_web_wakeup *w = arg;
    if (atomic_exchange(&w->queued, 1))
        return;
    if (!emscripten_proxy_async(emscripten_proxy_get_system_queue(),
                                emscripten_main_runtime_thread_id(),
                                mak_web_wakeup_main, w))
        atomic_store(&w->queued, 0);
}

/* Main thread. Returns the bridge to pass to mak_web_wakeup_detach. */
EMSCRIPTEN_KEEPALIVE struct mak_web_wakeup *mak_web_wakeup_attach(mpv_handle *h)
{
    struct mak_web_wakeup *w = calloc(1, sizeof(*w));
    if (!w)
        return NULL;
    w->handle = h;
    mpv_set_wakeup_callback(h, mak_web_wakeup_cb, w);
    return w;
}

/* Main thread, before mpv_terminate_destroy. Once mpv_set_wakeup_callback
 * returns no callback runs; a task already queued frees the bridge. */
EMSCRIPTEN_KEEPALIVE void mak_web_wakeup_detach(struct mak_web_wakeup *w)
{
    if (!w)
        return;
    mpv_set_wakeup_callback(w->handle, NULL, NULL);
    if (atomic_load(&w->queued))
        w->detached = 1;
    else
        free(w);
}

/* MAK_WEB_ABI: a client checks it before any other call. */
EMSCRIPTEN_KEEPALIVE int mak_web_abi_version(void)
{
    return MAK_WEB_ABI;
}

/* The two fields patch_read_error.py adds at the end of mpv_event_end_file.
 * build_libmpv_web.sh defines MAK_WEB_READ_ERROR when the archive has the
 * patch; without it the table gives 0 for both, where no field can sit. */
#ifdef MAK_WEB_READ_ERROR
#define MAK_WEB_END_FILE_READ_ERROR offsetof(mpv_event_end_file, mak_read_error)
#define MAK_WEB_END_FILE_SKIPPED offsetof(mpv_event_end_file, mak_skipped_segments)
#else
#define MAK_WEB_END_FILE_READ_ERROR 0
#define MAK_WEB_END_FILE_SKIPPED 0
#endif

/* sizeof and offsetof of the structs the JS side reads, in this order. The
 * glue compares them with its own table at start. */
EMSCRIPTEN_KEEPALIVE const int *mak_web_layout(void)
{
    static const int t[] = {
        sizeof(mpv_node), offsetof(mpv_node, format),
        sizeof(mpv_node_list), offsetof(mpv_node_list, values),
        offsetof(mpv_node_list, keys),
        sizeof(mpv_byte_array), offsetof(mpv_byte_array, size),
        sizeof(mpv_event), offsetof(mpv_event, error),
        offsetof(mpv_event, reply_userdata), offsetof(mpv_event, data),
        sizeof(mpv_event_property), offsetof(mpv_event_property, format),
        offsetof(mpv_event_property, data),
        sizeof(mpv_event_log_message), offsetof(mpv_event_log_message, text),
        offsetof(mpv_event_log_message, log_level),
        sizeof(mpv_event_end_file), offsetof(mpv_event_end_file, error),
        offsetof(mpv_event_end_file, playlist_entry_id),
        offsetof(mpv_event_end_file, playlist_insert_id),
        offsetof(mpv_event_end_file, playlist_insert_num_entries),
        MAK_WEB_END_FILE_READ_ERROR, MAK_WEB_END_FILE_SKIPPED,
        sizeof(mpv_event_hook), offsetof(mpv_event_hook, id),
        -1,
    };
    return t;
}
