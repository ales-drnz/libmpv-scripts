#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""Adds live PCM input to mpv: a built-in stream protocol `mak-pcm://<id>`
fed by an exported C API (mpv_audio_kit issue #27).

Problem
=======

An app that receives PCM as it is produced (a network TTS, a synth, a
capture) has no clean way to hand it to libmpv. A temp file never ends, a
socket or pipe needs a server and platform code, and `mpv_stream_cb_add_ro`
calls the app back on mpv's demuxer thread, which a Dart isolate cannot
serve without blocking.

Design
======

Each id is one source: a growable byte FIFO with a soft capacity. The app
writes with `mak_pcm_write` (never blocks: it takes what fits), ends the
input with `mak_pcm_finish` or cuts it with `mak_pcm_abort`, and lets go with
`mak_pcm_release`. mpv opens `mak-pcm://<id>` as a plain unseekable stream
of unknown size and reads it with the rawaudio demuxer, which the stream
selects itself; the app passes the format as file-local options
(`demuxer-rawaudio-format`, `-rate`, `-channels`).

    mak_pcm_create / write / finish / abort / buffered / consumed /
    state / release / release_all       (see pcm_stream/mak_pcm.h)

- One reader per id: a second open (analysis, prefetch, replay) fails, so
  a read-once source is never split between two readers.
- Ids are process wide (every mpv handle in the process shares them) and
  never reused. The memory goes when the app released the id and the
  reader closed.
- A blocked read wakes at once on mpv's stream cancel (stop, loadfile
  replace, quit) through a child mp_cancel callback, and on finish, abort
  and release. Finish plays the buffer out, then the file ends with reason
  eof. Abort ends it at once.
- The stream sets is_network (demuxer-via-network reads true), not
  streaming, so mpv's network cache and its pause-for-cache stay off by
  default. The analysis never re-opens the scheme (mak_scan.c): the
  waveform rolls and the loudness scan reports unavailable.
- The rawaudio demuxer reads a fixed packet of 1/8 s with a blocking
  stream_read, which on a live source adds up to 125 ms of latency and
  makes the packets arrive in bursts. On a mak-pcm stream it takes what
  the FIFO holds instead, completed to a whole frame.
- demux_packet_shorten (used only by demux_raw) left the AVPacket at its
  allocated size, and the demuxer hands the decoder a copy made from that
  AVPacket: a short packet was decoded at full length, padded with zeros
  (Invalid audio PTS, drifting position). It now shortens both. Upstream
  this only hit the last packet of a raw file.
- Prefetch never opens a mak-pcm entry. It opens the next URL with the
  current entry's options, then drops the result when the entry's own
  file-local rawaudio options differ (UPDATE_DEMUXER), which they always
  do: the stream closed, the one reader was spent and the entry failed.
  The entry opens when it starts; the app buffers it meanwhile.
- force-seekable does not apply to a mak-pcm stream: a forward seek in
  demux_raw skips by reading, which would throw live PCM away.
- A mak-pcm entry plays once, from start to end. With loop-file or an A-B
  loop on, mpv queued a seek back at its end; the seek failed (the stream
  cannot seek and the cache keeps no back buffer), and the next pass of the
  playloop queued it again, with the core spinning and the entry never
  ending. At its end its loops are dropped once, with a warning. An end
  that came from the B point plays on to the real end; then the entry ends
  as with no loop (the keep-open park or the next entry).
- Only mpv's portable thread primitives (mp_mutex, mp_cond, mp_cancel),
  so it builds on every platform.

Exports
=======

The functions carry MPV_EXPORT and are exported next to the mpv_* API:
as a glob in mpv.ver, mpv_android.ver and mpv.exports (lld and ld64 fail
on a named symbol that is not defined, and meson link-tests these flags
with a bare program), by name in mpv.def.

Files patched
=============

    stream/mak_pcm.h          NEW — the C API and the reader side
    stream/mak_pcm.c          NEW — registry and FIFO
    stream/stream_mak_pcm.c   NEW — the mak-pcm stream
    stream/stream.c           protocol registered in stream_list
    demux/demux_raw.c         a live source is read in whole frames as they
                              come, not in blocking 125 ms packets
    demux/packet.c            demux_packet_shorten shortens the AVPacket too
    demux/demux.c             force-seekable leaves a mak-pcm stream unseekable
    player/loadfile.c         prefetch skips a mak-pcm entry
    player/playloop.c         a mak-pcm entry drops its loops at its end and
                              plays on past an A-B loop's B point
    meson.build               new sources added to the build

Usage
=====

    python3 patch_pcm_stream.py <mpv_source_dir>
"""
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / '_lib'))
import anchor  # noqa: E402

# Idempotency marker; also present in the copied sources.
MARKER = 'MAK_PCM_STREAM_PATCH'


# ─── stream/stream.c ─────────────────────────────────────────────────

# Pristine lines lifted from mpv 0.41.0. The protocol goes right after the
# client callback streams, ahead of the catch-all ffmpeg protocols.
STREAM_C = [
    ('stream_info_cb extern',
     'extern const stream_info_t stream_info_cb;\n',
     'extern const stream_info_t stream_info_cb;\n'
     '/* ' + MARKER + ' */\n'
     'extern const stream_info_t stream_info_mak_pcm;\n'),
    ('stream_list cb entry',
     '    &stream_info_cb,\n',
     '    &stream_info_cb,\n'
     '    &stream_info_mak_pcm, /* ' + MARKER + ' */\n'),
]

# ─── demux/demux_raw.c ───────────────────────────────────────────────

DEMUX_RAW_C = [
    ('demux_raw includes',
     '#include "stream/stream.h"\n',
     '#include "stream/stream.h"\n'
     '/* ' + MARKER + ' */\n'
     'extern const stream_info_t stream_info_mak_pcm;\n'),
    ('raw_read_packet stream_read',
     '    int len = stream_read(demuxer->stream, dp->buffer, dp->len);\n',
     '    /* ' + MARKER + ': a live PCM source hands over what it holds,\n'
     '     * completed to a whole frame, instead of blocking until a full\n'
     '     * 1/8 s packet arrived. */\n'
     '    int len;\n'
     '    if (demuxer->stream->info == &stream_info_mak_pcm) {\n'
     '        len = stream_read_partial(demuxer->stream, dp->buffer, dp->len);\n'
     '        int rem = len > 0 ? len % p->frame_size : 0;\n'
     '        if (rem)\n'
     '            len += stream_read(demuxer->stream, dp->buffer + len,\n'
     '                               p->frame_size - rem);\n'
     '    } else {\n'
     '        len = stream_read(demuxer->stream, dp->buffer, dp->len);\n'
     '    }\n'),
]

# ─── demux/packet.c ──────────────────────────────────────────────────

PACKET_C = [
    ('demux_packet_shorten body',
     '        dp->len = len;\n'
     '        memset(dp->buffer + dp->len, 0, AV_INPUT_BUFFER_PADDING_SIZE);\n'
     '    }\n',
     '        dp->len = len;\n'
     '        memset(dp->buffer + dp->len, 0, AV_INPUT_BUFFER_PADDING_SIZE);\n'
     '        /* ' + MARKER + ': demux_copy_packet copies the AVPacket. */\n'
     '        if (dp->avpacket && dp->avpacket->data == dp->buffer)\n'
     '            dp->avpacket->size = len;\n'
     '    }\n'),
]

# ─── demux/demux.c ───────────────────────────────────────────────────

DEMUX_C = [
    ('demux.c stream include',
     '#include "stream/stream.h"\n',
     '#include "stream/stream.h"\n'
     '/* ' + MARKER + ' */\n'
     'extern const stream_info_t stream_info_mak_pcm;\n'),
    ('force-seekable check',
     '        if (!in->d_thread->seekable && opts->force_seekable) {\n',
     '        /* ' + MARKER + ': a live PCM source never seeks. */\n'
     '        if (!in->d_thread->seekable && opts->force_seekable &&\n'
     '            !(stream && stream->info == &stream_info_mak_pcm)) {\n'),
]

# ─── player/loadfile.c ───────────────────────────────────────────────

# The anchor is the same with or without patch_prefetch_hook.py.
LOADFILE_C = [
    ('prefetch_next next entry',
     '    struct playlist_entry *new_entry = mp_next_file(mpctx, +1, false, false);\n',
     '    struct playlist_entry *new_entry = mp_next_file(mpctx, +1, false, false);\n'
     '    /* ' + MARKER + ': a mak-pcm id has one reader. A prefetch opens it\n'
     '     * with the current entry\'s options and is dropped when the entry\'s\n'
     '     * own rawaudio options apply, which would spend the reader. */\n'
     '    if (new_entry && new_entry->filename &&\n'
     '        bstr_case_startswith(bstr0(new_entry->filename), bstr0("mak-pcm://")))\n'
     '        return;\n'),
]

# ─── player/playloop.c ───────────────────────────────────────────────

# handle_loop_file runs when the entry reached its end. mpctx->filename is
# the entry that plays (the demuxer the player sees has no stream).
PLAYLOOP_C = [
    ('handle_loop_file head',
     'static void handle_loop_file(struct MPContext *mpctx)\n'
     '{\n'
     '    if (mpctx->stop_play != AT_END_OF_FILE)\n'
     '        return;\n',
     'static void handle_loop_file(struct MPContext *mpctx)\n'
     '{\n'
     '    if (mpctx->stop_play != AT_END_OF_FILE)\n'
     '        return;\n'
     '\n'
     '    /* ' + MARKER + ': a live PCM entry was read once and cannot\n'
     '     * seek back. A loop seek would fail and be queued again on every\n'
     '     * pass, so its loops are dropped once and it plays to its end. */\n'
     '    if (mpctx->filename &&\n'
     '        bstr_case_startswith(bstr0(mpctx->filename), bstr0("mak-pcm://")))\n'
     '    {\n'
     '        double ab[2];\n'
     '        bool ab_end = get_ab_loop_times(mpctx, ab) && mpctx->ab_loop_clip;\n'
     '        if (ab_end || mpctx->remaining_file_loops) {\n'
     '            MP_WARN(mpctx, "A live PCM source cannot loop, it plays once.\\n");\n'
     '            mpctx->remaining_file_loops = 0;\n'
     '            mpctx->remaining_ab_loops = 0;\n'
     '            mp_notify_property(mpctx, "remaining-file-loops");\n'
     '            mp_notify_property(mpctx, "remaining-ab-loops");\n'
     '        }\n'
     '        if (ab_end) {\n'
     '            /* The end was the B point: what follows it still plays. */\n'
     '            mpctx->stop_play = KEEP_PLAYING;\n'
     '            mp_wakeup_core(mpctx);\n'
     '        }\n'
     '        return;\n'
     '    }\n'),
]

# ─── meson.build ──────────────────────────────────────────────────────

MESON = [
    ('stream/stream_cb.c entry',
     "    'stream/stream_cb.c',\n",
     "    'stream/stream_cb.c',\n"
     "    # " + MARKER + "\n"
     "    'stream/mak_pcm.c',\n"
     "    'stream/stream_mak_pcm.c',\n"),
]


def apply(p):
    # The sources of the protocol, shipped in pcm_stream/.
    for name in ('mak_pcm.h', 'mak_pcm.c', 'stream_mak_pcm.c'):
        p.new_file('stream/' + name, p.asset('pcm_stream/' + name))
    p.edits('stream/stream.c', STREAM_C)
    p.edits('demux/demux_raw.c', DEMUX_RAW_C)
    p.edits('demux/packet.c', PACKET_C)
    p.edits('demux/demux.c', DEMUX_C)
    p.edits('player/loadfile.c', LOADFILE_C)
    p.edits('player/playloop.c', PLAYLOOP_C)
    p.edits('meson.build', MESON)


anchor.main(apply, 'patch_pcm_stream', marker=MARKER, usage='<mpv_src_dir>')
