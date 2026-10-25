/* MAK_AF_COMMAND_ARGS_PATCH_V1 ─── read-only flag, always yes: a
 * successful af-command or vf-command on a lavfi-<name> filter updates the
 * arguments af and vf keep for it (patch_af_command_args.py). Without the
 * patch the property does not exist; a client reads it to know which of
 * the two it has. */
static int mp_property_af_command_saves_args(void *ctx, struct m_property *prop,
                                             int action, void *arg)
{
    return m_property_bool_ro(action, arg, true);
}

