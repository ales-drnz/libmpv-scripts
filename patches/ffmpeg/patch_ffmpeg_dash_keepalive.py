#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""
Patches FFmpeg's DASH demuxer to support HTTP persistent connections.

Upstream ffmpeg's ``libavformat/dashdec.c`` opens a brand-new HTTP
URLContext (and therefore a fresh TCP connection) for every segment
GET. This matters for audio-streaming clients because:

  - On LAN it's mostly invisible.
  - On higher-latency networks the extra 1.5 RTT per segment adds up
    (a DASH audio segment is typically ~2 s → ~30 handshakes/minute).
  - It stresses NAT/firewall state tables and the server's socket pool.
  - It amplifies the window during which a stale Plex transcode
    session can 404: more connection churn = more chances to hit a
    mid-GET session cleanup race.

The HLS demuxer in the same ffmpeg tree already solves this via an
``http_persistent`` option + an ``open_url_keepalive`` helper that
reuses an existing HTTP ``URLContext`` through
``ff_http_do_new_request2`` (defined in ``libavformat/http.h``). The
DASH demuxer has no such logic.

This patch ports the HLS pattern to DASH. Steady-state impact:
exactly one TCP handshake per representation for the lifetime of the
stream, instead of one per segment. The option defaults to ``1`` so
the win is automatic; set ``stream-lavf-o=http_persistent=0`` (or the
ffmpeg CLI equivalent) to restore upstream per-segment behaviour.

Changes applied to ``libavformat/dashdec.c``:

  1. ``#include "http.h"`` for ``ff_http_do_new_request2``.
  2. ``int input_read_done`` on ``struct representation`` — marks a
     representation whose segment is exhausted but whose underlying
     HTTP connection must stay alive for the next GET.
  3. ``int http_persistent`` on ``DASHContext`` — the new option.
  4. New static helper ``open_url_keepalive()`` — exact analogue of
     the HLS one: resolve the existing URLContext, reset eof, issue
     the next GET via ``ff_http_do_new_request2``.
  5. ``open_url()`` rewritten to try the keepalive path first when
     the URL is http, ``http_persistent`` is enabled, and an existing
     ``*pb`` is available. Falls back to a fresh
     ``ffio_open_whitelist`` on any failure (bad host match, stale
     socket, etc.) so behavior degrades gracefully.
  6. ``read_data()`` treats ``v->input_read_done`` the same way it
     treats ``!v->input``: a trigger to open the next segment. Clears
     the flag on successful open.
  7. Segment-end handling in ``dash_read_packet()``: if the current
     input is an http stream under ``http_persistent``, set
     ``input_read_done = 1`` rather than closing the socket.
  8. ``http_persistent`` registered in ``dash_options`` (default 1,
     matching HLS).

The patch is MARKER-guarded for idempotency: ``MAK_DASH_KEEPALIVE_V1``
appears in every inserted hunk, and a pre-flight check skips the file
if the marker is already present.

Usage:
    python3 patch_ffmpeg_dash_keepalive.py <ffmpeg_src_dir>
"""
import sys
import os
import re


MARKER = 'MAK_DASH_KEEPALIVE_V1'


def patch_dashdec_c(path: str) -> None:
    with open(path) as f:
        text = f.read()

    if MARKER in text:
        print(f'Already patched: {path}')
        return

    original_len = len(text)

    # ─── Edit 1 ──────────────────────────────────────────────────────
    # Add three includes right after #include "url.h":
    #   - "config_components.h": defines the CONFIG_*_PROTOCOL macros.
    #     Without it, `#if !CONFIG_HTTP_PROTOCOL` reads as `#if !0` → the
    #     helper always short-circuits to AVERROR_PROTOCOL_NOT_FOUND and
    #     keep-alive never actually runs. HLS has this include; DASH
    #     doesn't, so upstream DASH wouldn't even compile this pattern —
    #     we're adding it along with the new `#if` block.
    #   - "libavutil/avassert.h": provides `av_assert0`, used by our
    #     keep-alive helper to sanity-check the URLContext pointer.
    #   - "http.h": exposes `ff_http_do_new_request2`, the keep-alive
    #     primitive our helper wraps.
    pattern_include = re.compile(
        r'#include "url\.h"\n',
    )
    replacement_include = (
        '#include "url.h"\n'
        '#include "config_components.h"  /* ' + MARKER + ' — CONFIG_HTTP_PROTOCOL */\n'
        '#include "libavutil/avassert.h"  /* ' + MARKER + ' — av_assert0 */\n'
        '#include "http.h"  /* ' + MARKER + ' — ff_http_do_new_request2 */\n'
    )
    text, n = pattern_include.subn(replacement_include, text, count=1)
    if n != 1:
        raise RuntimeError('Edit 1 failed: #include "url.h" not found')

    # ─── Edit 2 ──────────────────────────────────────────────────────
    # Add input_read_done field to struct representation. Placed next
    # to is_restart_needed because they're the two "pending action"
    # flags on the representation.
    pattern_rep = re.compile(
        r'(    int is_restart_needed;\n)(\};\n)',
    )
    replacement_rep = (
        r'\1'
        '    int input_read_done;  /* ' + MARKER + ' — segment done,'
        ' TCP kept open for next GET */\n'
        r'\2'
    )
    text, n = pattern_rep.subn(replacement_rep, text, count=1)
    if n != 1:
        raise RuntimeError(
            'Edit 2 failed: struct representation tail not matched'
        )

    # ─── Edit 3 ──────────────────────────────────────────────────────
    # Add http_persistent option field to DASHContext.
    pattern_ctx = re.compile(
        r'(    int is_init_section_common_subtitle;\n)(\n\} DASHContext;\n)',
    )
    replacement_ctx = (
        r'\1'
        '\n'
        '    /* ' + MARKER + ' */\n'
        '    int http_persistent;\n'
        r'\2'
    )
    text, n = pattern_ctx.subn(replacement_ctx, text, count=1)
    if n != 1:
        raise RuntimeError(
            'Edit 3 failed: DASHContext tail not matched'
        )

    # ─── Edit 4 ──────────────────────────────────────────────────────
    # Insert open_url_keepalive() static helper right before open_url.
    # Modeled 1:1 on hls.c's function of the same name.
    pattern_helper_anchor = (
        'static int open_url(AVFormatContext *s, AVIOContext **pb, '
        'const char *url,\n'
        '                    AVDictionary **opts, AVDictionary *opts2, '
        'int *is_http)\n'
    )
    helper_code = (
        '/* ' + MARKER + ' ─── keep-alive helper: reuse the existing\n'
        ' * HTTP URLContext for the next GET instead of opening a new\n'
        ' * TCP connection. Mirrors hls.c\'s open_url_keepalive. */\n'
        'static int open_url_keepalive(AVFormatContext *s, AVIOContext **pb,\n'
        '                              const char *url, AVDictionary **options)\n'
        '{\n'
        '#if !CONFIG_HTTP_PROTOCOL\n'
        '    return AVERROR_PROTOCOL_NOT_FOUND;\n'
        '#else\n'
        '    int ret;\n'
        '    URLContext *uc = ffio_geturlcontext(*pb);\n'
        '    av_assert0(uc);\n'
        '    (*pb)->eof_reached = 0;\n'
        '    ret = ff_http_do_new_request2(uc, url, options);\n'
        '    if (ret < 0) {\n'
        '        ff_format_io_close(s, pb);\n'
        '    }\n'
        '    return ret;\n'
        '#endif\n'
        '}\n'
        '\n'
    )
    if pattern_helper_anchor not in text:
        raise RuntimeError(
            'Edit 4 failed: open_url signature anchor not found'
        )
    text = text.replace(
        pattern_helper_anchor,
        helper_code + pattern_helper_anchor,
        1,
    )

    # ─── Edit 5 ──────────────────────────────────────────────────────
    # Rewrite the open block inside open_url to try keepalive first.
    pattern_open = re.compile(
        r'    av_freep\(pb\);\n'
        r'    av_dict_copy\(&tmp, \*opts, 0\);\n'
        r'    av_dict_copy\(&tmp, opts2, 0\);\n'
        r'    ret = ffio_open_whitelist\(pb, url, AVIO_FLAG_READ,'
        r' c->interrupt_callback, &tmp,'
        r' s->protocol_whitelist, s->protocol_blacklist\);\n',
    )
    replacement_open = (
        '    /* ' + MARKER + ' ─── try keep-alive first when we have a\n'
        '     * live HTTP context for this representation. On failure\n'
        '     * (host mismatch, stale socket, server closed) fall back\n'
        '     * to a fresh connection so behaviour degrades gracefully. */\n'
        '    {\n'
        '        int is_http_url = av_strstart(proto_name, "http", NULL);\n'
        '        int tried_keepalive = 0;\n'
        '        av_dict_copy(&tmp, *opts, 0);\n'
        '        av_dict_copy(&tmp, opts2, 0);\n'
        '        /* Ask the http protocol to send `Connection: keep-alive`\n'
        '         * so the server keeps the socket open after each response\n'
        '         * and ff_http_do_new_request2 can actually reuse it. */\n'
        '        if (is_http_url && c->http_persistent) {\n'
        '            av_dict_set(&tmp, "multiple_requests", "1", 0);\n'
        '        }\n'
        '        if (is_http_url && c->http_persistent && *pb) {\n'
        '            tried_keepalive = 1;\n'
        '            ret = open_url_keepalive(s, pb, url, &tmp);\n'
        '            if (ret < 0 && ret != AVERROR_EXIT) {\n'
        '                if (ret != AVERROR_EOF)\n'
        '                    av_log(s, AV_LOG_WARNING,\n'
        '                        "DASH keepalive request failed for \'%s\' '
        '(%s); retrying with new connection\\n",\n'
        '                        url, av_err2str(ret));\n'
        '                av_dict_free(&tmp);\n'
        '                av_dict_copy(&tmp, *opts, 0);\n'
        '                av_dict_copy(&tmp, opts2, 0);\n'
        '                av_freep(pb);\n'
        '                ret = ffio_open_whitelist(pb, url, AVIO_FLAG_READ,'
        ' c->interrupt_callback, &tmp, s->protocol_whitelist,'
        ' s->protocol_blacklist);\n'
        '            }\n'
        '        } else {\n'
        '            av_freep(pb);\n'
        '            ret = ffio_open_whitelist(pb, url, AVIO_FLAG_READ,'
        ' c->interrupt_callback, &tmp, s->protocol_whitelist,'
        ' s->protocol_blacklist);\n'
        '        }\n'
        '        (void)tried_keepalive;\n'
        '    }\n'
    )
    # Use a lambda to bypass re.sub's escape-processing of the
    # replacement string. Without this, '\\n' in the replacement (a
    # literal backslash-n, which is what the C compiler needs to see
    # for the newline escape inside the warning message) would be
    # re-interpreted by re.sub as a newline *character* and break the
    # string literal across two physical lines in the emitted C.
    text, n = pattern_open.subn(
        lambda _m: replacement_open, text, count=1
    )
    if n != 1:
        raise RuntimeError(
            'Edit 5 failed: open_url body pattern not matched'
        )

    # ─── Edit 6 ──────────────────────────────────────────────────────
    # read_data: treat input_read_done like !v->input (trigger reopen),
    # and clear the flag on successful open_input.
    pattern_read_data = re.compile(
        r'restart:\n'
        r'    if \(!v->input\) \{\n'
        r'        free_fragment\(&v->cur_seg\);\n'
    )
    replacement_read_data = (
        'restart:\n'
        '    /* ' + MARKER + ' */\n'
        '    if (!v->input || v->input_read_done) {\n'
        '        v->input_read_done = 0;\n'
        '        free_fragment(&v->cur_seg);\n'
    )
    text, n = pattern_read_data.subn(replacement_read_data, text, count=1)
    if n != 1:
        raise RuntimeError(
            'Edit 6 failed: read_data entry pattern not matched'
        )

    # ─── Edit 7 ──────────────────────────────────────────────────────
    # Segment-end close in dash_read_packet: keep socket alive when
    # http_persistent and current input is http. We detect http by
    # peeking at the URLContext protocol name — safer than tracking
    # an extra flag.
    pattern_seg_close = re.compile(
        r'(        if \(cur->is_restart_needed\) \{\n'
        r'            cur->cur_seg_offset = 0;\n'
        r'            cur->init_sec_buf_read_offset = 0;\n'
        r'            cur->is_restart_needed = 0;\n'
        r')            ff_format_io_close\(cur->parent, &cur->input\);\n',
    )
    replacement_seg_close = (
        r'\1'
        '            /* ' + MARKER + ' ─── preserve the TCP socket for the\n'
        '             * next segment GET when persistent connections are on\n'
        '             * and the current input is an HTTP URLContext.\n'
        '             * Otherwise fall back to the upstream close-per-seg. */\n'
        '            {\n'
        '                int keep_alive = 0;\n'
        '                if (c->http_persistent && cur->input) {\n'
        '                    URLContext *uc = ffio_geturlcontext(cur->input);\n'
        '                    if (uc && uc->prot && uc->prot->name &&\n'
        '                        (!strcmp(uc->prot->name, "http") ||\n'
        '                         !strcmp(uc->prot->name, "https"))) {\n'
        '                        keep_alive = 1;\n'
        '                    }\n'
        '                }\n'
        '                if (keep_alive) {\n'
        '                    cur->input_read_done = 1;\n'
        '                } else {\n'
        '                    ff_format_io_close(cur->parent, &cur->input);\n'
        '                }\n'
        '            }\n'
    )
    text, n = pattern_seg_close.subn(replacement_seg_close, text, count=1)
    if n != 1:
        raise RuntimeError(
            'Edit 7 failed: segment-end close pattern not matched'
        )

    # ─── Edit 8 ──────────────────────────────────────────────────────
    # Register http_persistent in dash_options. Default 1 to match HLS.
    # Anchored on the last real option before the {NULL} terminator —
    # `cenc_decryption_keys`, added in FFmpeg 8.x (the 7.x array ended
    # with `cenc_decryption_key`).
    pattern_options = re.compile(
        r'(    \{ "cenc_decryption_keys", "Media decryption keys by KID'
        r' \(hex\)", OFFSET\(cenc_decryption_keys\), AV_OPT_TYPE_STRING,'
        r' \{\.str = NULL\}, INT_MIN, INT_MAX, \.flags = FLAGS \},\n)'
        r'(    \{NULL\}\n)',
    )
    replacement_options = (
        r'\1'
        '    /* ' + MARKER + ' */\n'
        '    { "http_persistent", "Use persistent HTTP connections",\n'
        '        OFFSET(http_persistent), AV_OPT_TYPE_BOOL, {.i64 = 1}, 0, 1,'
        ' FLAGS },\n'
        r'\2'
    )
    text, n = pattern_options.subn(replacement_options, text, count=1)
    if n != 1:
        raise RuntimeError(
            'Edit 8 failed: dash_options terminator not matched'
        )

    # ─── Write back ──────────────────────────────────────────────────
    with open(path, 'w') as f:
        f.write(text)

    added = len(text) - original_len
    print(f'Patched: {path} (+{added} bytes across 8 edits)')


def main() -> None:
    if len(sys.argv) < 2:
        print(f'Usage: {sys.argv[0]} <ffmpeg_src_dir>')
        sys.exit(1)

    ffmpeg_dir = sys.argv[1]
    patch_dashdec_c(os.path.join(ffmpeg_dir, 'libavformat', 'dashdec.c'))


if __name__ == '__main__':
    main()
