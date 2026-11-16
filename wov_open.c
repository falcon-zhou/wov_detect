/* wov_open.c - open SOF WoV capture PCM with alsa-lib directly (same API arecord uses).
 * Build (no alsa headers needed): gcc -O2 -o wov_open wov_open.c /usr/lib/x86_64-linux-gnu/libasound.so.2
 * Usage: ./wov_open [-D hw:0,12] [-r 16000] [-c 1] [-f S16_LE|S24_LE|S32_LE] [-o out.raw] [-d]
 *   -d : only dump supported hw params and exit
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <time.h>
#include <sys/time.h>

typedef struct _snd_pcm snd_pcm_t;
typedef struct _snd_pcm_hw_params snd_pcm_hw_params_t;
typedef struct _snd_output snd_output_t;
typedef unsigned long snd_pcm_uframes_t;
typedef long snd_pcm_sframes_t;
/* alsa-lib API prototypes (from <alsa/pcm.h>) */
int  snd_pcm_open(snd_pcm_t **, const char *, int, int);
int  snd_pcm_close(snd_pcm_t *);
int  snd_pcm_hw_params_malloc(snd_pcm_hw_params_t **);
void snd_pcm_hw_params_free(snd_pcm_hw_params_t *);
int  snd_pcm_hw_params_any(snd_pcm_t *, snd_pcm_hw_params_t *);
int  snd_pcm_hw_params_set_access(snd_pcm_t *, snd_pcm_hw_params_t *, int);
int  snd_pcm_hw_params_set_format(snd_pcm_t *, snd_pcm_hw_params_t *, int);
int  snd_pcm_hw_params_set_channels(snd_pcm_t *, snd_pcm_hw_params_t *, unsigned);
int  snd_pcm_hw_params_set_rate_near(snd_pcm_t *, snd_pcm_hw_params_t *, unsigned *, int *);
int  snd_pcm_hw_params(snd_pcm_t *, snd_pcm_hw_params_t *);
int  snd_pcm_hw_params_dump(snd_pcm_hw_params_t *, snd_output_t *);
int  snd_output_stdio_attach(snd_output_t **, FILE *, int);
int  snd_pcm_prepare(snd_pcm_t *);
int  snd_pcm_start(snd_pcm_t *);
int  snd_pcm_recover(snd_pcm_t *, int, int);
int  snd_pcm_wait(snd_pcm_t *, int);
snd_pcm_sframes_t snd_pcm_readi(snd_pcm_t *, void *, snd_pcm_uframes_t);
const char *snd_strerror(int);

#define CAPTURE 1
#define RW_INTERLEAVED 3
#define PCM_NONBLOCK 1
#include <errno.h>

static volatile sig_atomic_t stop;
static void on_sig(int s) { (void)s; stop = 1; }

static void ts(void) {
    struct timeval tv; gettimeofday(&tv, NULL);
    char b[16]; strftime(b, sizeof b, "%H:%M:%S", localtime(&tv.tv_sec));
    printf("[%s.%03ld] ", b, tv.tv_usec / 1000);
}
#define CHK(x, what) do { int _e = (x); if (_e < 0) { fprintf(stderr, "%s: %s\n", what, snd_strerror(_e)); return 1; } } while (0)

int main(int argc, char **argv) {
    const char *dev = "hw:0,12", *fmt_s = "S16_LE", *out = NULL;
    unsigned rate = 16000, ch = 1; int dump = 0, opt;
    while ((opt = getopt(argc, argv, "D:r:c:f:o:dh")) != -1) switch (opt) {
        case 'D': dev = optarg; break;
        case 'r': rate = atoi(optarg); break;
        case 'c': ch = atoi(optarg); break;
        case 'f': fmt_s = optarg; break;
        case 'o': out = optarg; break;
        case 'd': dump = 1; break;
        default: fprintf(stderr, "usage: %s [-D dev] [-r rate] [-c ch] [-f S16_LE|S24_LE|S32_LE] [-o file] [-d]\n", argv[0]); return 2;
    }
    int fmt, bps;
    if      (!strcmp(fmt_s, "S16_LE")) { fmt = 2;  bps = 2; }
    else if (!strcmp(fmt_s, "S24_LE")) { fmt = 6;  bps = 4; }
    else if (!strcmp(fmt_s, "S32_LE")) { fmt = 10; bps = 4; }
    else { fprintf(stderr, "unsupported format %s\n", fmt_s); return 2; }

    snd_pcm_t *pcm; snd_pcm_hw_params_t *hw; snd_output_t *log;
    snd_output_stdio_attach(&log, stdout, 0);
    CHK(snd_pcm_open(&pcm, dev, CAPTURE, PCM_NONBLOCK), "snd_pcm_open");
    snd_pcm_hw_params_malloc(&hw);
    CHK(snd_pcm_hw_params_any(pcm, hw), "hw_params_any");
    if (dump) { printf("supported hw params of %s:\n", dev); snd_pcm_hw_params_dump(hw, log); snd_pcm_close(pcm); return 0; }
    CHK(snd_pcm_hw_params_set_access(pcm, hw, RW_INTERLEAVED), "set_access");
    CHK(snd_pcm_hw_params_set_format(pcm, hw, fmt), "set_format");
    CHK(snd_pcm_hw_params_set_channels(pcm, hw, ch), "set_channels");
    CHK(snd_pcm_hw_params_set_rate_near(pcm, hw, &rate, 0), "set_rate");
    CHK(snd_pcm_hw_params(pcm, hw), "snd_pcm_hw_params");
    snd_pcm_hw_params_free(hw);
    CHK(snd_pcm_prepare(pcm), "prepare");
    CHK(snd_pcm_start(pcm), "start");

    signal(SIGINT, on_sig); signal(SIGTERM, on_sig);
    FILE *fo = out ? fopen(out, "wb") : NULL;
    size_t frames = rate / 10; char *buf = malloc(frames * ch * bps);
    unsigned long total = 0;
    setvbuf(stdout, NULL, _IOLBF, 0);
    ts(); printf("opened %s %s %uHz %uch, RUNNING, waiting for keyword...\n", dev, fmt_s, rate, ch);
    while (!stop) {
        snd_pcm_sframes_t n = snd_pcm_readi(pcm, buf, frames);
        if (n == -EAGAIN) {                 /* no data yet: DSP still waiting for keyword */
            snd_pcm_wait(pcm, 1000);        /* poll(), no kernel EIO timeout */
            continue;
        }
        if (n < 0) {
            if (stop) break;
            ts(); printf("read error: %s, re-arming stream\n", snd_strerror((int)n));
            if (snd_pcm_recover(pcm, (int)n, 1) < 0) { snd_pcm_prepare(pcm); }
            snd_pcm_start(pcm);
            continue;
        }
        if (n == 0) continue;
        if (total == 0) { ts(); printf(">>> first PCM data arrived (keyword detected?)\n"); }
        total += n;
        if (fo) fwrite(buf, bps * ch, n, fo);
    }
    ts(); printf("stopped, total frames=%lu (%.2fs)\n", total, (double)total / rate);
    if (fo) fclose(fo);
    snd_pcm_close(pcm);
    return 0;
}
