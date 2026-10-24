#!/usr/bin/env python3
# Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
# All rights reserved.
# Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

"""
Makes FFmpeg 8.1.1 audio filters refuse values that read or write out of
their buffers, or leak, instead of running with them.

mpv_audio_kit checks the typed effects before they reach mpv, but a
RawAudioEffect, a live af-command or an `af` set by hand go straight to
the filter. Each edit below turns an accepted value that misbehaves into
the error the filter already gives for other bad input:

  - af_compand.c: attacks and decays with no number in either list
    matched at 0 and copied channel -1 into every channel.
  - af_aiir.c: zeros or poles of modulus 0 (or infinitely far) left the
    outmost pole or the nearest zero at -1, and the next loop read the
    coefficients at index -2 and -1.
  - aeval.c: val() clamped the channel only from above, so val(-1) read
    before the channel array and val(1/0) or val(0/0) indexed it with
    INT_MIN. A NaN or negative channel now reads 0.
  - af_chorus.c: the list counts were compared with && instead of ||, so
    lists of different lengths passed and the shorter ones were read past
    their end. NaN, a negative delay or depth, or a speed with less than
    one sample per period moved the modulation index out of the delay
    line.
  - af_aecho.c: the delay and decay range checks were false for NaN, and
    a NaN delay became INT_MIN as an index.
  - af_pan.c: an input channel named UNK, UNSD or AMBIn has an id from
    0x200 up, and indexed 64 slot arrays on the stack.
  - af_mcompand.c: an empty attack or decay rate ran av_strtok out of
    items and handed NULL to sscanf; a NaN crossover frequency passed its
    range check.
  - af_anequalizer.c: a NaN frequency passed the range check and a band
    that is not finite turned the audio to NaN. It is ignored like a band
    out of range, and refused by the change command.
  - af_adelay.c: the delays command multiplied the new delay by the
    sample size with no overflow check, so a huge delay grew the buffer
    by a few bytes and then cleared gigabytes past it.
  - af_dynaudnorm.c, af_adrc.c: every command reparsed the curve or the
    transfer expression over the old one without freeing it. The new
    expression replaces the old one only when it parses.

Every hunk carries MARKER, a file that already has it is left alone, and
the files are written only once every anchor has matched exactly once, so
a changed FFmpeg layout stops the build with the tree as it was.

Usage:
    python3 patch_ffmpeg_filter_bounds.py <ffmpeg_src_dir>
"""
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / '_lib'))
import anchor  # noqa: E402


MARKER = 'MAK_FILTER_BOUNDS_V1'


def macro(lines):
    """Lines of a multi-line macro body, backslash at column 105."""
    return ''.join(line.ljust(104) + '\\\n' for line in lines)


EDITS = {
    'libavfilter/af_compand.c': [(
        '    for (i = nb_decays; i < channels; i++) {\n',
        '    /* ' + MARKER + ': with no number in either list the counts\n'
        '     * match at 0, and the loop below would copy channel -1. */\n'
        '    if (nb_decays < 1) {\n'
        '        av_log(ctx, AV_LOG_ERROR,\n'
        '                "At least one attack and one decay must be set.\\n");\n'
        '        uninit(ctx);\n'
        '        return AVERROR(EINVAL);\n'
        '    }\n'
        '\n'
        '    for (i = nb_decays; i < channels; i++) {\n',
    )],
    'libavfilter/af_aiir.c': [(
        '                if (mag > max_mag) {\n'
        '                    max_mag = mag;\n'
        '                    outmost_pole.a = i;\n'
        '                }\n'
        '            }\n'
        '\n',
        '                if (mag > max_mag) {\n'
        '                    max_mag = mag;\n'
        '                    outmost_pole.a = i;\n'
        '                }\n'
        '            }\n'
        '\n'
        '            /* ' + MARKER + ': the loop below indexes with it. */\n'
        '            if (outmost_pole.a < 0)\n'
        '                return AVERROR(EINVAL);\n'
        '\n',
    ), (
        '                if (distance < min_distance) {\n'
        '                    min_distance = distance;\n'
        '                    nearest_zero.a = i;\n'
        '                }\n'
        '            }\n'
        '\n',
        '                if (distance < min_distance) {\n'
        '                    min_distance = distance;\n'
        '                    nearest_zero.a = i;\n'
        '                }\n'
        '            }\n'
        '\n'
        '            /* ' + MARKER + ': the loop below indexes with it. */\n'
        '            if (nearest_zero.a < 0)\n'
        '                return AVERROR(EINVAL);\n'
        '\n',
    )],
    'libavfilter/aeval.c': [(
        '    EvalContext *eval = priv;\n'
        '    return eval->channel_values[FFMIN((int)ch, eval->nb_in_channels-1)];\n',
        '    EvalContext *eval = priv;\n'
        '    /* ' + MARKER + ': a NaN or negative channel reads 0, and the\n'
        '     * clamp runs on the double, before the cast. */\n'
        '    if (!(ch >= 0))\n'
        '        return 0;\n'
        '    return eval->channel_values[(int)FFMIN(ch, eval->nb_in_channels - 1)];\n',
    )],
    'libavfilter/af_chorus.c': [(
        '    if (nb_delays != nb_decays && nb_delays != nb_speeds && nb_delays != nb_depths) {\n',
        '    /* ' + MARKER + ': || where upstream has &&. */\n'
        '    if (nb_delays != nb_decays || nb_delays != nb_speeds || nb_delays != nb_depths) {\n',
    ), (
        '    s->channels = outlink->ch_layout.nb_channels;\n'
        '\n'
        '    for (n = 0; n < s->num_chorus; n++) {\n',
        '    s->channels = outlink->ch_layout.nb_channels;\n'
        '\n'
        '    /* ' + MARKER + ': NaN, a negative delay or depth, or a speed\n'
        '     * that leaves less than one sample per period moves the\n'
        '     * modulation index out of the delay line. */\n'
        '    for (n = 0; n < s->num_chorus; n++) {\n'
        '        double samples = ((double)s->delays[n] + s->depths[n]) * outlink->sample_rate / 1000.0;\n'
        '        double length  = outlink->sample_rate / (double)s->speeds[n];\n'
        '\n'
        '        if (!(s->delays[n] >= 0 && s->depths[n] >= 0 && samples < INT_MAX &&\n'
        '              length >= 1 && length < INT_MAX / sizeof(int32_t) &&\n'
        '              isfinite(s->decays[n]))) {\n'
        '            av_log(ctx, AV_LOG_ERROR,\n'
        '                   "Invalid delay, decay, speed or depth for voice %d.\\n", n + 1);\n'
        '            return AVERROR(EINVAL);\n'
        '        }\n'
        '    }\n'
        '\n'
        '    for (n = 0; n < s->num_chorus; n++) {\n',
    )],
    'libavfilter/af_aecho.c': [(
        '        if (s->delay[i] <= 0 || s->delay[i] > 90000) {\n',
        '        /* ' + MARKER + ': written so that NaN fails it. */\n'
        '        if (!(s->delay[i] > 0 && s->delay[i] <= 90000)) {\n',
    ), (
        '        if (s->decay[i] <= 0 || s->decay[i] > 1) {\n',
        '        if (!(s->decay[i] > 0 && s->decay[i] <= 1)) {\n',
    )],
    'libavfilter/af_pan.c': [(
        '            nb_in_channels[named]++;\n',
        '            /* ' + MARKER + ': UNK, UNSD and AMBIn have ids from\n'
        '             * 0x200 up, past the arrays this id indexes. */\n'
        '            if (in_ch_id >= MAX_CHANNELS) {\n'
        '                av_log(ctx, AV_LOG_ERROR,\n'
        '                       "Can not use in channel %d, the limit is %d\\n",\n'
        '                       in_ch_id, MAX_CHANNELS);\n'
        '                ret = AVERROR(EINVAL);\n'
        '                goto fail;\n'
        '            }\n'
        '            nb_in_channels[named]++;\n',
    )],
    'libavfilter/af_mcompand.c': [(
        '            p3 = NULL;\n'
        '            sscanf(tstr3, "%lf", &s->bands[i].attack_rate[k]);\n'
        '            tstr3 = av_strtok(p3, ",", &saveptr3);\n'
        '            sscanf(tstr3, "%lf", &s->bands[i].decay_rate[k]);\n',
        '            p3 = NULL;\n'
        '            /* ' + MARKER + ': av_strtok skips empty items, so a\n'
        '             * list with one runs out before the count says. */\n'
        '            if (!tstr3) {\n'
        '                av_log(ctx, AV_LOG_ERROR, "attack rate %d is empty\\n", k + 1);\n'
        '                return AVERROR(EINVAL);\n'
        '            }\n'
        '            sscanf(tstr3, "%lf", &s->bands[i].attack_rate[k]);\n'
        '            tstr3 = av_strtok(p3, ",", &saveptr3);\n'
        '            if (!tstr3) {\n'
        '                av_log(ctx, AV_LOG_ERROR, "decay rate %d is empty\\n", k + 1);\n'
        '                return AVERROR(EINVAL);\n'
        '            }\n'
        '            sscanf(tstr3, "%lf", &s->bands[i].decay_rate[k]);\n',
    ), (
        '        if (s->bands[i].topfreq < 0 || s->bands[i].topfreq >= outlink->sample_rate / 2.0) {\n',
        '        /* ' + MARKER + ': written so that NaN fails it. */\n'
        '        if (!(s->bands[i].topfreq >= 0 && s->bands[i].topfreq < outlink->sample_rate / 2.0)) {\n',
    )],
    'libavfilter/af_anequalizer.c': [(
        '        if (s->filters[s->nb_filters].freq < 0 ||\n'
        '            s->filters[s->nb_filters].freq > inlink->sample_rate / 2.0)\n'
        '            s->filters[s->nb_filters].ignore = 1;\n',
        '        /* ' + MARKER + ': NaN fails the range too, and a band\n'
        '         * that is not finite turns the audio to NaN. */\n'
        '        if (!(s->filters[s->nb_filters].freq >= 0 &&\n'
        '              s->filters[s->nb_filters].freq <= inlink->sample_rate / 2.0) ||\n'
        '            !isfinite(s->filters[s->nb_filters].width) ||\n'
        '            !isfinite(s->filters[s->nb_filters].gain))\n'
        '            s->filters[s->nb_filters].ignore = 1;\n',
    ), (
        '        if (freq < 0 || freq > inlink->sample_rate / 2.0)\n'
        '            return AVERROR(EINVAL);\n',
        '        /* ' + MARKER + ': as in config_input. */\n'
        '        if (!(freq >= 0 && freq <= inlink->sample_rate / 2.0) ||\n'
        '            !isfinite(width) || !isfinite(gain))\n'
        '            return AVERROR(EINVAL);\n',
    )],
    'libavfilter/af_adelay.c': [(
        macro([
            '        d->delay_index = 0;',
            '        return 0;',
            '    }',
            '',
            '    samples = (type *) av_fast_realloc(d->samples, &d->samples_size, new_delay * sizeof(type));',
        ]),
        macro([
            '        d->delay_index = 0;',
            '        return 0;',
            '    }',
            '',
            '    /* ' + MARKER + ': the size below must not wrap. */',
            '    if (new_delay > SIZE_MAX / sizeof(type)) {',
            '        return AVERROR(EINVAL);',
            '    }',
            '',
            '    samples = (type *) av_fast_realloc(d->samples, &d->samples_size, new_delay * sizeof(type));',
        ]),
    )],
    'libavfilter/af_dynaudnorm.c': [(
        '    if (s->expr_str) {\n'
        '        ret = av_expr_parse(&s->expr, s->expr_str, var_names, NULL, NULL,\n'
        '                            NULL, NULL, 0, ctx);\n'
        '        if (ret < 0)\n'
        '            return ret;\n'
        '    }\n'
        '    return 0;\n',
        '    if (s->expr_str) {\n'
        '        /* ' + MARKER + ': the old expression is freed, not leaked,\n'
        '         * and kept when the new one does not parse. */\n'
        '        AVExpr *expr = NULL;\n'
        '\n'
        '        ret = av_expr_parse(&expr, s->expr_str, var_names, NULL, NULL,\n'
        '                            NULL, NULL, 0, ctx);\n'
        '        if (ret < 0)\n'
        '            return ret;\n'
        '        av_expr_free(s->expr);\n'
        '        s->expr = expr;\n'
        '    }\n'
        '    return 0;\n',
    )],
    'libavfilter/af_adrc.c': [(
        '    if (ret >= 0 && strcmp(old_expr_str, s->expr_str)) {\n'
        '        ret = av_expr_parse(&s->expr, s->expr_str, var_names, NULL, NULL,\n'
        '                            NULL, NULL, 0, ctx);\n'
        '    }\n',
        '    if (ret >= 0 && strcmp(old_expr_str, s->expr_str)) {\n'
        '        /* ' + MARKER + ': the old expression is freed, not leaked,\n'
        '         * and kept when the new one does not parse. */\n'
        '        AVExpr *expr = NULL;\n'
        '\n'
        '        ret = av_expr_parse(&expr, s->expr_str, var_names, NULL, NULL,\n'
        '                            NULL, NULL, 0, ctx);\n'
        '        if (ret >= 0) {\n'
        '            av_expr_free(s->expr);\n'
        '            s->expr = expr;\n'
        '        }\n'
        '    }\n',
    )],
}


def apply(p):
    # A missing or repeated anchor means the FFmpeg layout changed: a partial
    # patch would leave the filter as unsafe as before, so no file is written.
    for rel, edits in EDITS.items():
        p.edits(rel, edits)


anchor.main(apply, 'patch_ffmpeg_filter_bounds', marker=MARKER,
            usage='<ffmpeg_src_dir>')
