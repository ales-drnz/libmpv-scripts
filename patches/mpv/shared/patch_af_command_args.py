# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""af-command that updates the arguments the filter keeps.

Upstream af-command (and vf-command) moves only the live libavfilter
graph. mpv keeps the arguments of every filter in three places, and none
of them learns the new value:

    filters/f_lavfi.c        direct_filter_opts, which the graph is created
                             from again at every reset: a seek, a loop or a
                             format change brings the old value back
    filters/f_output_chain.c the creation args of each user filter, which an
                             af set compares to keep a filter: an af set
                             with the old value keeps the live one (F50)
    player/command.c         the af and vf options: af reads the old value,
                             and a chain made again from them (another
                             audio track, the next file) starts with it

mpv_audio_kit worked around it by writing the whole chain again after a
seek or a track switch, and its rollback after a refused write could not
bring the audio back (F50).

===== One authority =====

lavfi, which knows the AVOptions, decides. When avfilter_graph_send_command
succeeded on a direct filter (lavfi-<name>), the target names it and the
command is an option of the filter that takes commands, it updates
direct_filter_opts and hands the new arguments up in struct
mp_filter_command (mak_opts). f_output_chain copies them into the filter's
creation args and command.c into the entry of af or vf, both equal. The
three stay equal to the live values: a reset makes the graph with them, a
track switch or the next file keeps them, an af set with the old values
builds the filter again, and an af set with the live ones keeps it.

The new value replaces the argument of the same option (name, alias or
position), keeping its spelling. An option with no argument gets one in
name order, the order mpv_audio_kit writes (its codegen sorts the options
by name, not by the AVOption table). A value equal to the option's default
drops the argument, as mpv_audio_kit leaves defaults out. So af reads the
string the kit would write for the live values, and its next af set keeps
the filter instead of building it again. A value that the option refuses
(a command the filter's own code handles) is not saved, since the graph
would no longer start.

A lavfi=[graph] filter, lavfi-bridge (whose entry holds name= and opts=,
not the filter's arguments), a command that is not an option, a refused
command and the "all" target keep the arguments as they were, as
upstream.

===== Capability =====

The read-only flag af-command-saves-args is yes. Without the patch it does
not exist, so a client knows which behaviour it has.

Files patched
=============

    filters/filter.h          struct mp_filter_command: mak_ta, mak_saved,
                              mak_opts, mak_old, mak_index
    filters/f_lavfi.c         lavfi_command saves the arguments
                              (af_command_args/lavfi_insert.c)
    filters/f_output_chain.c  mp_output_chain_command copies them for a
                              lavfi-<name> filter
                              (af_command_args/output_chain_insert.c); the
                              "all" target saves nothing
    player/command.c          cmd_filter_command updates af or vf
                              (af_command_args/command_insert.c), the
                              af-command-saves-args property
                              (af_command_args/property_insert.c)

Usage: patch_af_command_args.py <mpv source dir>
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / '_lib'))
import anchor  # noqa: E402

MARKER = 'MAK_AF_COMMAND_ARGS_PATCH_V1'

FILTER_H = 'filters/filter.h'
LAVFI = 'filters/f_lavfi.c'
CHAIN = 'filters/f_output_chain.c'
COMMAND = 'player/command.c'


# ─── filter.h ──────────────────────────────────────────────────────────

FILTER_CMD = (
    '    // For MP_FILTER_COMMAND_IS_ACTIVE\n'
    '    bool is_active;\n'
    '};\n'
)

FILTER_CMD_NEW = (
    '    // For MP_FILTER_COMMAND_IS_ACTIVE\n'
    '    bool is_active;\n'
    '\n'
    '    /* ' + MARKER + ' ─── for MP_FILTER_COMMAND_TEXT. The caller sets\n'
    '     * mak_ta when it keeps the arguments of the filter in sync. A lavfi\n'
    '     * filter whose option the command set then saves the value: it sets\n'
    '     * mak_saved and mak_opts, its new arguments (key, value, ...,\n'
    '     * NULL) under mak_ta. mp_output_chain_command copies them into the\n'
    '     * filter\'s creation args and sets mak_old, the old ones, and\n'
    '     * mak_index, the index of the filter among the user filters. */\n'
    '    void *mak_ta;\n'
    '    bool mak_saved;\n'
    '    char **mak_opts;\n'
    '    char **mak_old;\n'
    '    int mak_index;\n'
    '};\n'
)


# ─── f_lavfi.c ─────────────────────────────────────────────────────────

LAVFI_COMMAND = (
    'static bool lavfi_command(struct mp_filter *f, struct mp_filter_command *cmd)\n'
)

LAVFI_SEND = (
    '    case MP_FILTER_COMMAND_TEXT: {\n'
    '        return avfilter_graph_send_command(c->graph, cmd->target,\n'
    '                                           cmd->cmd, cmd->arg,\n'
    '                                           &(char){0}, 0, 0) >= 0;\n'
    '    }\n'
)

LAVFI_SEND_NEW = (
    '    case MP_FILTER_COMMAND_TEXT: {\n'
    '        /* ' + MARKER + ': a value that took is saved. */\n'
    '        if (avfilter_graph_send_command(c->graph, cmd->target,\n'
    '                                        cmd->cmd, cmd->arg,\n'
    '                                        &(char){0}, 0, 0) < 0)\n'
    '            return false;\n'
    '        mak_lavfi_save_command(c, cmd);\n'
    '        return true;\n'
    '    }\n'
)


# ─── f_output_chain.c ──────────────────────────────────────────────────

CHAIN_COMMAND = (
    'bool mp_output_chain_command(struct mp_output_chain *c, const char *target,\n'
    '                             struct mp_filter_command *cmd)\n'
)

CHAIN_ALL = (
    '        // (Following old semantics.)\n'
    '        for (int n = 0; n < p->num_user_filters; n++)\n'
    '            mp_filter_command(p->user_filters[n]->f, cmd);\n'
    '        return true;\n'
)

CHAIN_ALL_NEW = (
    '        // (Following old semantics.)\n'
    '        /* ' + MARKER + ': "all" saves no argument. */\n'
    '        struct mp_filter_command all = *cmd;\n'
    '        all.mak_ta = NULL;\n'
    '        for (int n = 0; n < p->num_user_filters; n++)\n'
    '            mp_filter_command(p->user_filters[n]->f, &all);\n'
    '        return true;\n'
)

CHAIN_ONE = (
    '    struct mp_user_filter *f = find_by_label(p, target);\n'
    '    if (!f)\n'
    '        return false;\n'
    '\n'
    '    return mp_filter_command(f->f, cmd);\n'
    '}\n'
)

CHAIN_ONE_NEW = (
    '    struct mp_user_filter *f = find_by_label(p, target);\n'
    '    if (!f)\n'
    '        return false;\n'
    '\n'
    '    /* ' + MARKER + ': the creation args follow what the filter saved. */\n'
    '    return mak_chain_command(p, f, cmd);\n'
    '}\n'
)


# ─── command.c ─────────────────────────────────────────────────────────

PROPERTY_AF = (
    'static int mp_property_af(void *ctx, struct m_property *prop,\n'
    '                          int action, void *arg)\n'
    '{\n'
    '    return property_filter(prop, action, arg, ctx, STREAM_AUDIO);\n'
    '}\n'
)

TABLE_AF = '    {"af", mp_property_af},\n'

TABLE_AF_NEW = TABLE_AF + (
    '    /* ' + MARKER + ' */\n'
    '    {"af-command-saves-args", mp_property_af_command_saves_args},\n'
)

FILTER_COMMAND = 'static void cmd_filter_command(void *p)\n'

FILTER_COMMAND_RUN = (
    '        .arg = cmd->args[2].v.s,\n'
    '    };\n'
    '    cmd->success = mp_output_chain_command(chain, cmd->args[0].v.s, &filter_cmd);\n'
    '}\n'
)

FILTER_COMMAND_RUN_NEW = (
    '        .arg = cmd->args[2].v.s,\n'
    '        .mak_ta = talloc_new(NULL), /* ' + MARKER + ' */\n'
    '    };\n'
    '    cmd->success = mp_output_chain_command(chain, cmd->args[0].v.s, &filter_cmd);\n'
    '    /* ' + MARKER + ': af or vf takes what the filter saved. */\n'
    '    if (cmd->success && filter_cmd.mak_saved)\n'
    '        mak_filter_command_saved(mpctx, type, &filter_cmd);\n'
    '    talloc_free(filter_cmd.mak_ta);\n'
    '}\n'
)


def apply(p):
    p.edits(FILTER_H, [('struct mp_filter_command end', FILTER_CMD, FILTER_CMD_NEW)])
    p.edits(LAVFI, [
        ('lavfi_command', LAVFI_COMMAND,
         p.asset('af_command_args/lavfi_insert.c') + LAVFI_COMMAND),
        ('lavfi_command text', LAVFI_SEND, LAVFI_SEND_NEW),
    ])
    p.edits(CHAIN, [
        ('mp_output_chain_command', CHAIN_COMMAND,
         p.asset('af_command_args/output_chain_insert.c') + CHAIN_COMMAND),
        ('mp_output_chain_command all', CHAIN_ALL, CHAIN_ALL_NEW),
        ('mp_output_chain_command label', CHAIN_ONE, CHAIN_ONE_NEW),
    ])
    p.edits(COMMAND, [
        ('mp_property_af', PROPERTY_AF,
         PROPERTY_AF + '\n' + p.asset('af_command_args/property_insert.c').rstrip('\n') + '\n'),
        ('property table', TABLE_AF, TABLE_AF_NEW),
        ('cmd_filter_command', FILTER_COMMAND,
         p.asset('af_command_args/command_insert.c') + FILTER_COMMAND),
        ('cmd_filter_command run', FILTER_COMMAND_RUN, FILTER_COMMAND_RUN_NEW),
    ])


anchor.main(apply, 'patch_af_command_args', marker=MARKER)
