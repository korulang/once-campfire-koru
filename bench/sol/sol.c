// Verbatim from lucasmeijer/once-campfire-jai (MIT), bench/speed-of-light/sol.c.
// The "speed of light" server: for each request, the least an HTTP/1.1 server can do. One epoll
// loop per CPU (SO_REUSEPORT), read until the end of the head, look the path up, write back a
// precomputed response (status line, headers and gzipped body, byte for byte what the app sent).
// No auth, no session, no database, no rendering, no compression.
//
//   sol PORT PATH=FILE...   FILE holds a whole raw HTTP response.
#define _GNU_SOURCE
#include <errno.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct { char *path; char *bytes; size_t len; } Route;
static Route routes[64];
static int route_count, port;
static const char NOT_FOUND[] = "HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\n\r\n";

typedef struct { int fd; char in[16384]; size_t used; const char *out; size_t out_len, out_off; } Conn;

static const Route *lookup(const char *path, size_t len) {
    for (int i = 0; i < route_count; i++)
        if (strlen(routes[i].path) == len && memcmp(routes[i].path, path, len) == 0) return &routes[i];
    return NULL;
}

// Writes what's pending; 0 when done, 1 when the socket is full, -1 on error.
static int flush(Conn *c) {
    while (c->out_off < c->out_len) {
        ssize_t n = write(c->fd, c->out + c->out_off, c->out_len - c->out_off);
        if (n < 0) return errno == EAGAIN ? 1 : -1;
        c->out_off += (size_t) n;
    }
    c->out = NULL;
    return 0;
}

// Answers every complete request head in the buffer.
static int serve(Conn *c) {
    for (;;) {
        if (c->out) { int r = flush(c); if (r) return r; }
        char *end = memmem(c->in, c->used, "\r\n\r\n", 4);
        if (!end) return 0;
        size_t head = (size_t) (end - c->in) + 4;
        char *sp1 = memchr(c->in, ' ', head);
        char *sp2 = sp1 ? memchr(sp1 + 1, ' ', head - (size_t) (sp1 + 1 - c->in)) : NULL;
        const Route *r = sp2 ? lookup(sp1 + 1, (size_t) (sp2 - sp1 - 1)) : NULL;
        c->out = r ? r->bytes : NOT_FOUND;
        c->out_len = r ? r->len : sizeof NOT_FOUND - 1;
        c->out_off = 0;
        memmove(c->in, c->in + head, c->used - head);
        c->used -= head;
    }
}

static void *loop(void *arg) {
    (void) arg;
    int ls = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0), one = 1;
    setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    setsockopt(ls, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one);
    struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons((unsigned short) port), .sin_addr.s_addr = htonl(INADDR_LOOPBACK) };
    if (bind(ls, (struct sockaddr *) &a, sizeof a) || listen(ls, 1024)) { perror("bind/listen"); exit(1); }
    int ep = epoll_create1(0);
    struct epoll_event ev = { .events = EPOLLIN, .data.ptr = NULL };
    epoll_ctl(ep, EPOLL_CTL_ADD, ls, &ev);
    struct epoll_event events[64];
    for (;;) {
        int n = epoll_wait(ep, events, 64, -1);
        for (int i = 0; i < n; i++) {
            Conn *c = events[i].data.ptr;
            if (!c) {
                int fd;
                while ((fd = accept4(ls, NULL, NULL, SOCK_NONBLOCK)) >= 0) {
                    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
                    Conn *nc = calloc(1, sizeof *nc);
                    nc->fd = fd;
                    struct epoll_event cev = { .events = EPOLLIN | EPOLLOUT | EPOLLET, .data.ptr = nc };
                    epoll_ctl(ep, EPOLL_CTL_ADD, fd, &cev);
                }
                continue;
            }
            int dead = 0;
            if (events[i].events & EPOLLIN) {
                for (;;) {
                    ssize_t r = read(c->fd, c->in + c->used, sizeof c->in - c->used);
                    if (r > 0) { c->used += (size_t) r; if (c->used == sizeof c->in) break; continue; }
                    if (r == 0 || errno != EAGAIN) dead = 1;
                    break;
                }
            }
            if (!dead && serve(c) < 0) dead = 1;
            if (dead || (events[i].events & (EPOLLHUP | EPOLLERR))) { close(c->fd); free(c); }
        }
    }
    return NULL;
}

int main(int argc, char **argv) {
    if (argc < 3) { fprintf(stderr, "usage: sol PORT PATH=FILE...\n"); return 2; }
    port = atoi(argv[1]);
    for (int i = 2; i < argc && route_count < 64; i++) {
        char *eq = strrchr(argv[i], '=');  // The last: paths may have query strings.
        *eq = 0;
        FILE *f = fopen(eq + 1, "rb");
        struct stat st; fstat(fileno(f), &st);
        routes[route_count].path = argv[i];
        routes[route_count].bytes = malloc((size_t) st.st_size);
        routes[route_count].len = fread(routes[route_count].bytes, 1, (size_t) st.st_size, f);
        fclose(f);
        route_count++;
    }
    cpu_set_t set; sched_getaffinity(0, sizeof set, &set);
    int threads = CPU_COUNT(&set);
    pthread_t t[256];
    for (int i = 0; i < threads; i++) pthread_create(&t[i], NULL, loop, NULL);
    fprintf(stderr, "sol: %d routes, %d loops, port %d\n", route_count, threads, port);
    pthread_join(t[0], NULL);
}
