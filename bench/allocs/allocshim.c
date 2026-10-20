// Heap allocations per response (tools/allocs/run). LD_PRELOAD: counts malloc/calloc/realloc/free
// (and writev, one per HTTP/1 response, to count responses) while recording, and keeps a backtrace
// of every SAMPLE-th call. SIGUSR2 starts recording; the next SIGUSR2 writes $ALLOCSHIM_OUT and stops.
// Frames in the app are written as their symbol, or as an address for addr2line when it has none
// (SQLite's static functions).
#define _GNU_SOURCE
#include <dlfcn.h>
#include <execinfo.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/uio.h>
#include <unistd.h>
#include <pthread.h>

extern void *__libc_malloc(size_t);
extern void *__libc_calloc(size_t, size_t);
extern void *__libc_realloc(void *, size_t);
extern void __libc_free(void *);

#define SAMPLE 8
#define DEPTH 40
#define MAX_SAMPLES 400000
enum { MALLOC, CALLOC, REALLOC, FREE, KINDS };
static const char *NAMES[] = {"malloc", "calloc", "realloc", "free"};
typedef struct { int kind; int depth; size_t size; void *frames[DEPTH]; } Sample;
static Sample *samples;
static atomic_long sample_count, counts[KINDS], bytes, writes;
static atomic_int recording;
static __thread int busy, tick;

static void record(int kind, size_t size) {
    if (!atomic_load_explicit(&recording, memory_order_relaxed) || busy) return;
    atomic_fetch_add_explicit(&counts[kind], 1, memory_order_relaxed);
    if (kind != FREE) atomic_fetch_add_explicit(&bytes, (long) size, memory_order_relaxed);
    if (++tick % SAMPLE) return;
    long i = atomic_fetch_add(&sample_count, 1);
    if (i >= MAX_SAMPLES) return;
    busy = 1;
    samples[i].kind = kind; samples[i].size = size;
    samples[i].depth = backtrace(samples[i].frames, DEPTH);
    busy = 0;
}

void *malloc(size_t n) { record(MALLOC, n); return __libc_malloc(n); }
void *calloc(size_t a, size_t b) { record(CALLOC, a * b); return __libc_calloc(a, b); }
void *realloc(void *p, size_t n) { record(REALLOC, n); return __libc_realloc(p, n); }
void free(void *p) { if (p) record(FREE, 0); __libc_free(p); }

static ssize_t (*real_writev)(int, const struct iovec *, int);
ssize_t writev(int fd, const struct iovec *iov, int count) {
    if (!real_writev) real_writev = dlsym(RTLD_NEXT, "writev");
    if (atomic_load_explicit(&recording, memory_order_relaxed)) atomic_fetch_add(&writes, 1);
    return real_writev(fd, iov, count);
}

static void dump(void) {
    const char *path = getenv("ALLOCSHIM_OUT");
    busy = 1;
    FILE *f = fopen(path ? path : "/tmp/allocshim.txt", "w");
    if (!f) return;
    fprintf(f, "writes %ld\n", atomic_load(&writes));
    for (int k = 0; k < KINDS; k++) fprintf(f, "count %s %ld\n", NAMES[k], atomic_load(&counts[k]));
    fprintf(f, "bytes %ld\nsample %d\n", atomic_load(&bytes), SAMPLE);
    long n = atomic_load(&sample_count); if (n > MAX_SAMPLES) n = MAX_SAMPLES;
    for (long i = 0; i < n; i++) {
        fprintf(f, "S %s %zu", NAMES[samples[i].kind], samples[i].size);
        for (int d = 1; d < samples[i].depth; d++) {
            Dl_info info;
            void *a = samples[i].frames[d];
            if (dladdr(a, &info) && info.dli_fname) {
                const char *base = strrchr(info.dli_fname, '/'); base = base ? base + 1 : info.dli_fname;
                // The main executable isn't PIE: its addresses are file addresses for addr2line.
                fprintf(f, " %s:%s", base, info.dli_sname ? info.dli_sname : "?");
                // The app isn't PIE, so its addresses are what addr2line takes.
                if (!info.dli_sname) fprintf(f, "@%lx", (unsigned long) a - 1);
            } else fprintf(f, " ?:%p", a);
        }
        fprintf(f, "\n");
    }
    fclose(f);
    busy = 0;
}

static atomic_int dump_requested;

static void on_signal(int s) {
    (void) s;
    if (!atomic_load(&recording)) atomic_store(&recording, 1);
    else { atomic_store(&recording, 0); atomic_store(&dump_requested, 1); }
}

// Dumps outside the signal handler, which may have interrupted malloc itself.
static void *dumper(void *unused) {
    (void) unused;
    for (;;) {
        usleep(20000);
        if (atomic_exchange(&dump_requested, 0)) dump();
    }
    return NULL;
}

__attribute__((constructor)) static void start(void) {

    samples = __libc_malloc(sizeof(Sample) * MAX_SAMPLES);
    void *warm[2]; backtrace(warm, 2);  // Loads libgcc's unwinder now, not inside a signal or malloc.
    struct sigaction action = {0};
    action.sa_handler = on_signal;
    sigaction(SIGUSR2, &action, NULL);
    pthread_t thread;
    pthread_create(&thread, NULL, dumper, NULL);
}
