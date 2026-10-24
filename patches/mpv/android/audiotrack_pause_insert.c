/* MAK_AUDIOTRACK_PAUSE_PATCH_V1:
 * pause and resume without a flush. Without set_pause, buffer.c paused
 * this pull output with reset (stop), which flushed what the track held.
 * No p->lock: the thread holds it while it writes. */
static bool set_pause(struct ao *ao, bool paused)
{
    struct priv *p = ao->priv;
    if (!p->audiotrack)
        return false;

    JNIEnv *env = MP_JNI_GET_ENV(ao);
    if (paused) {
        MP_JNI_CALL_VOID(p->audiotrack, AudioTrack.pause);
        MP_JNI_EXCEPTION_LOG(ao);
        return true;
    }
    // A timestamp from before the pause would put the head past it.
    p->timestamp_fetched = 0;
    p->timestamp_set = false;
    MP_JNI_CALL_VOID(p->audiotrack, AudioTrack.play);
    MP_JNI_EXCEPTION_LOG(ao);
    mp_cond_signal(&p->wakeup);
    return true;
}
