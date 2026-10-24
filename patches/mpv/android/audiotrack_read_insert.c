/* MAK_AUDIOTRACK_IDLE_PATCH_V1:
 * reads the next chunk into p->chunk and returns its size in bytes, 0
 * when mpv's buffer has nothing. With audio-stream-silence the chunk is
 * padded with silence, and the read waits for the buffer lock, so the
 * track is fed silence rather than running dry, and a busy lock is not
 * taken for a gap. */
static int mak_read_chunk(struct ao *ao)
{
    struct priv *p = ao->priv;
    int read_samples = p->chunksize / ao->sstride;
    int64_t ts = mp_time_ns();
    ts += MP_TIME_S_TO_NS(read_samples / (double)(ao->samplerate));
    ts += MP_TIME_S_TO_NS(AudioTrack_getLatency(ao));
    bool silence = ao->stream_silence;
    int samples = ao_read_data(ao, &p->chunk, read_samples, ts, NULL,
                               silence, silence);
    return (silence ? read_samples : samples) * ao->sstride;
}
