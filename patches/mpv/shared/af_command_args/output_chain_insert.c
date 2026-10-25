/* MAK_AF_COMMAND_ARGS_PATCH_V1 ─── the filter lists, as options.c
 * declares them. */
extern const struct m_obj_list af_obj_list;
extern const struct m_obj_list vf_obj_list;

/* MAK_AF_COMMAND_ARGS_PATCH_V1 ─── runs cmd on the user filter u. Only a
 * filter of the generic lavfi bridge (lavfi-<name>, or a name that no
 * filter of the list has, as mp_create_user_filter decides) is created
 * with the arguments of its entry, so only it may save a command into them
 * (filters/f_lavfi.c); lavfi-bridge, for one, takes them as name= and
 * opts=. When it did, its creation args take the new arguments, so an
 * update with a list that holds them keeps u and one with the old values
 * builds it again. The caller then gets the old arguments (cmd->mak_old,
 * under cmd->mak_ta) and the index of u among the user filters
 * (cmd->mak_index), which is the one of its entry among the enabled ones
 * of the list. */
static bool mak_chain_command(struct chain *p, struct mp_user_filter *u,
                              struct mp_filter_command *cmd)
{
    const struct m_obj_list *list =
        p->type == MP_OUTPUT_CHAIN_VIDEO ? &vf_obj_list : &af_obj_list;
    struct m_obj_desc desc;
    void *ta = cmd->mak_ta;
    if (cmd->type != MP_FILTER_COMMAND_TEXT || !u->args || !u->name ||
        m_obj_list_find(&desc, list, bstr0(u->name)))
        cmd->mak_ta = NULL;
    bool ok = mp_filter_command(u->f, cmd);
    if (!cmd->mak_ta)
        cmd->mak_saved = false;
    cmd->mak_ta = ta;
    if (!ok || !cmd->mak_saved)
        return ok;
    struct m_option strl = {.type = &m_option_type_string_list};
    cmd->mak_old = mp_dup_str_array(cmd->mak_ta, u->args[0].attribs);
    m_option_copy(&strl, &u->args[0].attribs, &cmd->mak_opts);
    for (int n = 0; n < p->num_user_filters; n++) {
        if (p->user_filters[n] == u)
            cmd->mak_index = n;
    }
    return true;
}

