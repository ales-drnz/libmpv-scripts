// Copyright © 2026 & onwards, Alessandro Di Ronza <ales.drnz@gmail.com>.
// All rights reserved.
// Use of this source code is governed by BSD 3-Clause license that can be found in the LICENSE file.

// The SMB protocol of patches/ffmpeg/libsmb2.c against a live server, built
// by network_test.sh with AddressSanitizer. It opens an smb2:// URL through
// libavformat with an interrupt_callback, as mpv's stream does with its
// cancel, and raises the interrupt from another thread, as mpv's stop and
// quit do. network_test.sh runs impacket's server (smb_server.py) and
// passes its pid in SMB_SERVER_PID: the modes that stop it use SIGSTOP, as
// docker pause or a sleeping NAS do, so the TCP connection stays up.
// timeout_us goes to the "timeout" option like mpv's network-timeout; "-"
// leaves it out (network-timeout 0).
//   open        open, read 1 s of audio, close. network_test.sh passes a
//               URL with a port, no user and an '@' in the file name (F85:
//               r17 took the port and the path for a password).
//   slow-open   open through slow_connect.py, whose TCP connect takes about
//               3 s: with no timeout it must still open (F84; r17 gave the
//               connect less than 2 s).
//   dir         list the share: long.wav and a@b.wav are there.
//   sum         read to the end and compare with the local <file>.
//   read-stop   read 1 s, stop the server, interrupt the blocked read: the
//               read and then the close return within STOP_LIMIT s (F83;
//               r17 waited for the timeout twice, forever without one).
//   kill-read   as read-stop, but the server is killed: the close after a
//               dropped connection (F83; r17 wrote into freed memory).
//   open-stop   stop the server, open, interrupt after 1 s: the open
//               returns within STOP_LIMIT s (F83).
//   open-hang   stop the server, open with no timeout and no interrupt: the
//               open fails at the 30 s connect deadline (F84; r17 blocked
//               forever).
//   pause-read  read 1 s, stop the server for PAUSE s (35, more than the
//               connect deadline), resume it: the read goes on, no limit
//               holds after the connect (F84).
//   close-hang  read 1 s, stop the server, close with no timeout and no
//               interrupt: the close returns at its own 5 s deadline, twice
//               at most (the file, then the share) (F5-7; r24 waits for a
//               server that went silent until a stop).
//   stress      30 opens with the server running, each read cut by the
//               interrupt at a random point: AddressSanitizer finds nothing.
// A blocked call fails the mode once its limit is past.
//
// Usage: SMB_SERVER_PID=<pid> smb_client_test <mode> <url> <timeout_us|-> [file]
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <libavformat/avformat.h>
#include <libavutil/error.h>

static double now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec / 1e9;
}

static const char *url, *timeout_us;
static pid_t server;
static int fails;

static void check(int ok, const char *what)
{
    printf("%s %s\n", ok ? "ok  " : "FAIL", what);
    fflush(stdout);
    fails += !ok;
}

static int result(const char *summary)
{
    if (fails)
        printf("RESULT FAIL (%d): %s\n", fails, summary);
    else
        printf("RESULT PASS: %s\n", summary);
    return fails ? 1 : 0;
}

static void resume_server(void)
{
    if (server > 0)
        kill(server, SIGCONT);
}

// Watchdog: a call still blocked past its limit fails the mode. A blocked
// libsmb2 call cannot be joined, so it ends the process.
static pthread_mutex_t wd_lock = PTHREAD_MUTEX_INITIALIZER;
static const char *wd_what;
static double wd_deadline, wd_limit;

static void watch(const char *what, double limit)
{
    pthread_mutex_lock(&wd_lock);
    wd_what = what;
    wd_limit = limit;
    wd_deadline = now() + limit;
    pthread_mutex_unlock(&wd_lock);
}

static void unwatch(void) { watch(NULL, 0); }

static void *watchdog(void *arg)
{
    for (;;) {
        usleep(20000);
        pthread_mutex_lock(&wd_lock);
        if (wd_what && now() > wd_deadline) {
            printf("RESULT FAIL: %s still blocked after %.1f s\n", wd_what, wd_limit);
            fflush(stdout);
            resume_server();
            _exit(1);
        }
        pthread_mutex_unlock(&wd_lock);
    }
    return NULL;
}

static atomic_int interrupted;
static int interrupt_cb(void *opaque) { return atomic_load(&interrupted); }

static int open_input(AVFormatContext **fc, const char *in)
{
    AVDictionary *opts = NULL;
    *fc = avformat_alloc_context();
    (*fc)->interrupt_callback.callback = interrupt_cb;
    if (timeout_us)
        av_dict_set(&opts, "timeout", timeout_us, 0);
    int r = avformat_open_input(fc, in, NULL, &opts);
    av_dict_free(&opts);
    return r;
}

// Reads packets worth secs seconds of audio, or until an error.
static int read_secs(AVFormatContext *fc, double secs)
{
    AVPacket *pkt = av_packet_alloc();
    AVStream *st = fc->streams[0];
    double got = 0;
    int r = 0;
    while (got < secs) {
        r = av_read_frame(fc, pkt);
        if (r < 0)
            break;
        got += pkt->duration * av_q2d(st->time_base);
        av_packet_unref(pkt);
    }
    av_packet_free(&pkt);
    return r < 0 ? r : 0;
}

// The blocking call of the thread modes: an open, or a read of reader_secs.
static AVFormatContext *shared_fc;
static double reader_secs = 1e9;
static atomic_int call_done;
static double call_back;
static int call_ret;

static void *reader(void *arg)
{
    call_ret = read_secs(shared_fc, reader_secs);
    call_back = now();
    atomic_store(&call_done, 1);
    return NULL;
}

static void *opener(void *arg)
{
    call_ret = open_input(&shared_fc, url);
    call_back = now();
    atomic_store(&call_done, 1);
    return NULL;
}

static void start_call(pthread_t *th, void *(*fn)(void *))
{
    atomic_store(&call_done, 0);
    pthread_create(th, NULL, fn, NULL);
}

// Waits for the call under the watchdog, then joins it.
static void wait_call(pthread_t th, const char *what, double limit)
{
    watch(what, limit);
    while (!atomic_load(&call_done))
        usleep(5000);
    unwatch();
    pthread_join(th, NULL);
}

static double stop_limit(void)
{
    return getenv("STOP_LIMIT") ? atof(getenv("STOP_LIMIT")) : 5;
}

static int mode_open(int slow)
{
    AVFormatContext *fc;
    char err[128], msg[160];
    double t0 = now();
    watch("open", 40);
    int r = open_input(&fc, url);
    unwatch();
    double t = now() - t0;
    if (r < 0) {
        av_strerror(r, err, sizeof err);
        snprintf(msg, sizeof msg, "the open failed after %.2f s: %s", t, err);
        check(0, msg);
        return result(msg);
    }
    check(read_secs(fc, 1) == 0, "1 s of audio read");
    avformat_close_input(&fc);
    // A connect the proxy did not hold would prove nothing.
    if (slow)
        check(t >= 2, "the proxy held the connect for 2 s or more");
    snprintf(msg, sizeof msg, "opened after %.2f s", t);
    return result(msg);
}

static int mode_dir(void)
{
    AVIODirContext *d = NULL;
    AVIODirEntry *e = NULL;
    AVDictionary *opts = NULL;
    char err[128], msg[64];
    if (timeout_us)
        av_dict_set(&opts, "timeout", timeout_us, 0);
    int r = avio_open_dir(&d, url, &opts);
    av_dict_free(&opts);
    if (r < 0) {
        av_strerror(r, err, sizeof err);
        check(0, "the directory opens");
        return result(err);
    }
    int n = 0, wav = 0, at = 0;
    while (avio_read_dir(d, &e) >= 0 && e) {
        printf("entry %s %lld\n", e->name, (long long)e->size);
        n++;
        wav += !strcmp(e->name, "long.wav");
        at += !strcmp(e->name, "a@b.wav");
        avio_free_directory_entry(&e);
    }
    avio_close_dir(&d);
    check(wav == 1, "long.wav listed");
    check(at == 1, "a@b.wav listed");
    snprintf(msg, sizeof msg, "%d entries", n);
    return result(msg);
}

// Bytes and FNV-1a hash of every packet to the end; returns the last error.
static int sum(const char *in, uint64_t *bytes, uint64_t *hash)
{
    AVFormatContext *fc;
    int r = open_input(&fc, in);
    if (r < 0)
        return r;
    AVPacket *pkt = av_packet_alloc();
    *hash = 1469598103934665603ULL;
    *bytes = 0;
    while ((r = av_read_frame(fc, pkt)) >= 0) {
        for (int i = 0; i < pkt->size; i++)
            *hash = (*hash ^ pkt->data[i]) * 1099511628211ULL;
        *bytes += pkt->size;
        av_packet_unref(pkt);
    }
    av_packet_free(&pkt);
    avformat_close_input(&fc);
    return r;
}

static int mode_sum(const char *file)
{
    uint64_t b1 = 0, h1 = 0, b2 = 0, h2 = 0;
    char msg[160];
    if (!file)
        return 2;
    double t0 = now();
    watch("sum", 60);
    int r1 = sum(url, &b1, &h1);
    unwatch();
    double t = now() - t0;
    int r2 = sum(file, &b2, &h2);
    check(r1 == AVERROR_EOF, "the SMB read ends at the end of the file");
    check(r2 == AVERROR_EOF, "the local read ends at the end of the file");
    check(b1 == b2 && h1 == h2, "the same bytes as the local file");
    snprintf(msg, sizeof msg, "%llu bytes in %.2f s, fnv %016llx (local %016llx)",
             (unsigned long long)b1, t, (unsigned long long)h1, (unsigned long long)h2);
    return result(msg);
}

static int mode_read_stop(int kill_server)
{
    char err[128], msg[200];
    double limit = stop_limit();
    watch("open", 40);
    int r = open_input(&shared_fc, url);
    unwatch();
    if (r < 0) {
        av_strerror(r, err, sizeof err);
        check(0, "the open");
        return result(err);
    }
    if (read_secs(shared_fc, 1) < 0) {
        check(0, "the first second");
        return result("the first second of audio failed");
    }
    kill(server, kill_server ? SIGKILL : SIGSTOP);
    pthread_t th;
    start_call(&th, reader);
    struct timespec c0, c1;
    clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &c0);
    // The read is blocked on the server; 1.55 s puts the interrupt midway
    // through one of the protocol's 100 ms waits, not at its end.
    usleep(1550 * 1000);
    clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &c1);
    double cpu = (c1.tv_sec - c0.tv_sec) + (c1.tv_nsec - c0.tv_nsec) / 1e9;
    double t0 = now();
    atomic_store(&interrupted, 1);
    wait_call(th, "the read after the interrupt", limit);
    double back = call_back - t0;
    double t1 = now();
    watch("the close after the interrupt", limit);
    avformat_close_input(&shared_fc);
    unwatch();
    double close = now() - t1;
    av_strerror(call_ret, err, sizeof err);
    if (!kill_server)
        check(cpu < 0.5, "the blocked read does not spin");
    check(call_ret < 0, "the read returns an error");
    // Once the server is killed, the read may fail before the interrupt.
    snprintf(msg, sizeof msg, "the read returned %.3f s %s the interrupt (%s), "
             "the close took %.3f s, %.0f ms of CPU while blocked",
             back < 0 ? -back : back, back < 0 ? "before" : "after", err, close, cpu * 1e3);
    resume_server();
    return result(msg);
}

static int mode_open_stop(void)
{
    char err[128], msg[160];
    kill(server, SIGSTOP);
    pthread_t th;
    start_call(&th, opener);
    usleep(1050 * 1000);
    double t0 = now();
    atomic_store(&interrupted, 1);
    wait_call(th, "the open after the interrupt", stop_limit());
    av_strerror(call_ret, err, sizeof err);
    check(call_ret < 0, "the open fails");
    if (call_ret >= 0)
        avformat_close_input(&shared_fc);
    snprintf(msg, sizeof msg, "the open returned %.3f s after the interrupt (%s)",
             call_back - t0, err);
    resume_server();
    return result(msg);
}

static int mode_open_hang(void)
{
    char err[128], msg[160];
    kill(server, SIGSTOP);
    pthread_t th;
    double t0 = now();
    start_call(&th, opener);
    // LIBSMB2_CONNECT_TIMEOUT is 30 s.
    wait_call(th, "the open of a stopped server", 45);
    double t = call_back - t0;
    av_strerror(call_ret, err, sizeof err);
    check(call_ret < 0, "the open fails");
    check(t >= 20, "the open waits for the connect deadline");
    if (call_ret >= 0)
        avformat_close_input(&shared_fc);
    snprintf(msg, sizeof msg, "the open returned after %.2f s (%s)", t, err);
    resume_server();
    return result(msg);
}

static int mode_close_hang(void)
{
    char msg[160];
    watch("open", 40);
    int r = open_input(&shared_fc, url);
    unwatch();
    if (r < 0 || read_secs(shared_fc, 1) < 0) {
        check(0, "the open and the first second");
        return result("no playback to close");
    }
    kill(server, SIGSTOP);
    double t0 = now();
    // LIBSMB2_CLOSE_TIMEOUT is 5 s; the close that times out breaks the
    // context, so the disconnect after it does not wait.
    watch("the close of a stopped server", 15);
    avformat_close_input(&shared_fc);
    unwatch();
    double t = now() - t0;
    check(t >= 3, "the close waits for its deadline");
    snprintf(msg, sizeof msg, "the close returned after %.2f s", t);
    resume_server();
    return result(msg);
}

static int mode_pause_read(void)
{
    char err[128], msg[160];
    int pause = getenv("PAUSE") ? atoi(getenv("PAUSE")) : 35;
    watch("open", 40);
    int r = open_input(&shared_fc, url);
    unwatch();
    if (r < 0 || read_secs(shared_fc, 1) < 0) {
        check(0, "the open and the first second");
        return result("no playback to pause");
    }
    kill(server, SIGSTOP);
    pthread_t th;
    double t0 = now();
    reader_secs = 10;
    start_call(&th, reader);
    sleep(pause);
    kill(server, SIGCONT);
    wait_call(th, "the read after the server resumed", 30);
    av_strerror(call_ret, err, sizeof err);
    check(call_ret == 0, "the read goes on after the pause");
    check(call_back - t0 >= pause, "the read waited for the server");
    avformat_close_input(&shared_fc);
    snprintf(msg, sizeof msg, "the read returned %.2f s into a %d s pause: %s",
             call_back - t0, pause, call_ret ? err : "ok");
    return result(msg);
}

static int mode_stress(void)
{
    char msg[64];
    int cut = 0;
    srand(getpid());
    for (int i = 0; i < 30; i++) {
        atomic_store(&interrupted, 0);
        watch("a stress round", 20);
        if (open_input(&shared_fc, url) < 0) {
            snprintf(msg, sizeof msg, "open %d of 30 failed", i + 1);
            check(0, msg);
            return result(msg);
        }
        pthread_t th;
        start_call(&th, reader);
        usleep(rand() % 300000);
        atomic_store(&interrupted, 1);
        while (!atomic_load(&call_done))
            usleep(5000);
        pthread_join(th, NULL);
        cut += call_ret == AVERROR_EXIT;
        avformat_close_input(&shared_fc);
        unwatch();
    }
    snprintf(msg, sizeof msg, "30 rounds, %d reads cut by the interrupt", cut);
    return result(msg);
}

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: SMB_SERVER_PID=<pid> %s <mode> <url> <timeout_us|-> [file]\n", argv[0]);
        return 2;
    }
    const char *mode = argv[1];
    url = argv[2];
    timeout_us = strcmp(argv[3], "-") ? argv[3] : NULL;
    server = getenv("SMB_SERVER_PID") ? atoi(getenv("SMB_SERVER_PID")) : 0;
    av_log_set_level(getenv("LOGLEVEL") ? atoi(getenv("LOGLEVEL")) : AV_LOG_ERROR);
    setvbuf(stdout, NULL, _IOLBF, 0);
    pthread_t wd;
    pthread_create(&wd, NULL, watchdog, NULL);
    pthread_detach(wd);

    if (!strcmp(mode, "open"))
        return mode_open(0);
    if (!strcmp(mode, "slow-open"))
        return mode_open(1);
    if (!strcmp(mode, "dir"))
        return mode_dir();
    if (!strcmp(mode, "sum"))
        return mode_sum(argc > 4 ? argv[4] : NULL);
    if (!strcmp(mode, "stress"))
        return mode_stress();
    // The modes below stop or kill the server.
    if (server <= 0) {
        fprintf(stderr, "%s needs SMB_SERVER_PID\n", mode);
        return 2;
    }
    if (!strcmp(mode, "read-stop"))
        return mode_read_stop(0);
    if (!strcmp(mode, "kill-read"))
        return mode_read_stop(1);
    if (!strcmp(mode, "open-stop"))
        return mode_open_stop();
    if (!strcmp(mode, "open-hang"))
        return mode_open_hang();
    if (!strcmp(mode, "pause-read"))
        return mode_pause_read();
    if (!strcmp(mode, "close-hang"))
        return mode_close_hang();
    return 2;
}
