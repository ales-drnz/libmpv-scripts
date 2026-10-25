/* MAK_AF_COMMAND_ARGS_PATCH_V1 ─── the filter a command reached saved
 * the arguments the command set (filters/f_lavfi.c, f_output_chain.c): its
 * entry in af or vf takes them. af then reads the live value, a chain made
 * again from the option (another track, the next file) starts with it, and
 * an af set with the old value builds the filter again. The chain holds one
 * filter per enabled entry, in order, so the entry is the enabled one at
 * fc->mak_index; its arguments must still be the ones the filter had.
 * m_config_notify_change_opt_ptr tells the observers of the option and
 * does not run set_filters. */
static void mak_filter_command_saved(struct MPContext *mpctx,
                                     enum stream_type type,
                                     struct mp_filter_command *fc)
{
    struct m_config_option *co =
        m_config_get_co(mpctx->mconfig, bstr0(filter_opt[type]));
    if (!co)
        return;
    struct m_obj_settings *list = *(struct m_obj_settings **)co->data;
    int index = 0;
    for (int n = 0; list && list[n].name; n++) {
        if (!list[n].enabled || index++ != fc->mak_index)
            continue;
        char **a = list[n].attribs, **b = fc->mak_old;
        int i = 0;
        while (a && b && a[i] && b[i] && strcmp(a[i], b[i]) == 0)
            i++;
        if ((a && a[i]) || (b && b[i]))
            break;
        struct m_option strl = {.type = &m_option_type_string_list};
        m_option_copy(&strl, &list[n].attribs, &fc->mak_opts);
        m_config_notify_change_opt_ptr(mpctx->mconfig, co->data);
        return;
    }
    MP_WARN(mpctx, "%s: no entry matches the filter the command changed\n",
            filter_opt[type]);
}

