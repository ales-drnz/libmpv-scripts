/* MAK_AF_COMMAND_ARGS_PATCH_V1 ─── the option an argument of the direct
 * filter names: its name or an alias, looked up as mp_set_avopts_pos sets
 * it (on the filter context and its children), or its position "@N",
 * counted as resolve_positional_arg of common/av_common.c counts it. *obj
 * is the object that holds the option. */
static const AVOption *mak_arg_option(AVFilterContext *filter, const char *key,
                                      void **obj)
{
    *obj = NULL;
    if (key[0] != '@')
        return av_opt_find2(filter, key, NULL, 0, AV_OPT_SEARCH_CHILDREN, obj);
    char *end = NULL;
    long pos = strtol(key + 1, &end, 10);
    if (!end || *end || pos < 0)
        return NULL;
    const AVOption *o = NULL;
    int offset = -1;
    while ((o = av_opt_next(filter->priv, o))) {
        if (o->offset != offset && o->type != AV_OPT_TYPE_CONST)
            pos--;
        if (pos < 0) {
            *obj = filter->priv;
            return o;
        }
        offset = o->offset;
    }
    return NULL;
}

/* MAK_AF_COMMAND_ARGS_PATCH_V1 ─── whether value is one the option takes,
 * and whether it is the option's default, checked on a filter of the same
 * kind that is never started (the live one may not store a value its
 * command set: volume keeps only the parsed expression). No threads: a
 * graph starts its thread pool with its first filter otherwise. */
static bool mak_check_value(const AVFilter *f, const char *name,
                            const char *value, bool *is_default)
{
    *is_default = false;
    AVFilterGraph *g = avfilter_graph_alloc();
    if (!g)
        return false;
    g->thread_type = 0;
    AVFilterContext *t = avfilter_graph_alloc_filter(g, f, "mak_check");
    bool ok = t && t->priv &&
              av_opt_set(t->priv, name, value, AV_OPT_SEARCH_CHILDREN) >= 0;
    if (ok)
        *is_default = av_opt_is_set_to_default_by_name(t->priv, name,
                                                       AV_OPT_SEARCH_CHILDREN) > 0;
    avfilter_graph_free(&g);
    return ok;
}

/* MAK_AF_COMMAND_ARGS_PATCH_V1 ─── a command that set an option of a
 * direct filter (lavfi-<name>) becomes part of the arguments the graph is
 * created from again at every reset (seek, loop, format change), so the
 * value stays. Called once avfilter_graph_send_command succeeded, when the
 * caller keeps its copies of the arguments in sync (cmd->mak_ta): the new
 * arguments go to cmd->mak_opts, allocated under it, and cmd->mak_saved
 * is set.
 *
 * Only an option of the filter that takes commands (the flags
 * ff_filter_process_command asks for) is saved, and only when the target
 * names this filter. The value replaces the one of the argument that sets
 * the same option (its name, an alias or its position), which keeps its
 * spelling; a later argument for that option goes. An option with no
 * argument gets one before the first argument whose name sorts after its
 * own, so arguments in name order (the order mpv_audio_kit writes) stay in
 * it. A value equal to the option's default drops the argument, as
 * mpv_audio_kit leaves defaults out. The client then reads in af the
 * string it would write for these values, and an af set with that string
 * keeps the filter. A value the option itself refuses (a command handled
 * by the filter's own code) is not saved, since the graph would then fail
 * to start. */
static void mak_lavfi_save_command(struct lavfi *c,
                                   struct mp_filter_command *cmd)
{
    if (!cmd->mak_ta || !c->direct_filter || !cmd->cmd || !cmd->arg)
        return;
    AVFilterContext *filter = avfilter_graph_get_filter(c->graph, "filter");
    if (!filter || !filter->priv)
        return;
    const char *target = cmd->target ? cmd->target : "all";
    if (strcmp(target, "all") != 0 && strcmp(target, filter->name) != 0 &&
        strcmp(target, filter->filter->name) != 0)
        return;
    void *obj = NULL;
    const AVOption *o = av_opt_find2(filter->priv, cmd->cmd, NULL,
                                     AV_OPT_FLAG_RUNTIME_PARAM |
                                     AV_OPT_FLAG_FILTERING_PARAM,
                                     AV_OPT_SEARCH_CHILDREN, &obj);
    if (!o)
        return;
    bool is_default;
    if (!mak_check_value(filter->filter, cmd->cmd, cmd->arg, &is_default)) {
        MP_VERBOSE(c, "%s=%s is not a value of the option: not kept\n",
                   cmd->cmd, cmd->arg);
        return;
    }

    char **old = c->direct_filter_opts;
    int num = 0;
    while (old && old[num * 2])
        num++;
    // At most one argument more than now: key, value, then the NULL.
    char **res = talloc_zero_array(c, char *, num * 2 + 3);
    int n_res = 0, at = -1;
    bool found = false;
    for (int n = 0; n < num; n++) {
        const char *k = old[n * 2], *v = old[n * 2 + 1];
        void *kobj = NULL;
        const AVOption *ko = mak_arg_option(filter, k, &kobj);
        if (ko && kobj == obj && ko->offset == o->offset) {
            if (found || is_default)
                continue;
            found = true;
            v = cmd->arg;
        } else if (at < 0 && strcmp(k, cmd->cmd) > 0) {
            at = n_res;
        }
        res[n_res * 2] = talloc_strdup(res, k);
        res[n_res * 2 + 1] = talloc_strdup(res, v);
        n_res++;
    }
    if (!found && !is_default) {
        if (at < 0)
            at = n_res;
        memmove(&res[at * 2 + 2], &res[at * 2], (n_res - at) * 2 * sizeof(char *));
        res[at * 2] = talloc_strdup(res, cmd->cmd);
        res[at * 2 + 1] = talloc_strdup(res, cmd->arg);
        n_res++;
    }
    res[n_res * 2] = NULL;

    // The old strings may be children of c (mp_dup_str_array) or of the
    // old array (an earlier save): free each one.
    for (int n = 0; old && old[n]; n++)
        talloc_free(old[n]);
    talloc_free(old);
    c->direct_filter_opts = n_res ? res : NULL;
    if (!n_res)
        talloc_free(res);
    cmd->mak_opts = mp_dup_str_array(cmd->mak_ta, c->direct_filter_opts);
    cmd->mak_saved = true;
}

