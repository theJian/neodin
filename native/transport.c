#include <uv.h>
#include <stdlib.h>
#include <string.h>

/* libuv owns platform-specific sockets, named pipes, and queued writes. */
typedef struct {
    uv_loop_t loop;
    union { uv_pipe_t pipe; uv_tcp_t tcp; } handle;
    uv_stream_t *stream;
    unsigned char *data;
    size_t size, capacity;
    int error, connected;
} transport;
typedef struct { uv_write_t request; uv_buf_t buffer; } write_job;

static void allocate(uv_handle_t *h, size_t suggested, uv_buf_t *b) {
    (void)h; b->len = suggested; b->base = malloc(suggested);
    if (!b->base) b->len = 0;
}
static void received(uv_stream_t *s, ssize_t n, const uv_buf_t *b) {
    transport *t = s->data;
    if (n < 0) { t->error = (int)n; uv_read_stop(s); }
    if (n > 0) {
        size_t needed = t->size + (size_t)n;
        if (needed > 64 * 1024 * 1024) { t->error = UV_ENOBUFS; uv_read_stop(s); }
        else {
            if (needed > t->capacity) {
                size_t capacity = needed * 2;
                void *data = realloc(t->data, capacity);
                if (!data) { t->error = UV_ENOMEM; uv_read_stop(s); }
                else { t->data = data; t->capacity = capacity; }
            }
            if (!t->error) { memcpy(t->data + t->size, b->base, (size_t)n); t->size = needed; }
        }
    }
    free(b->base);
}
static void connected(uv_connect_t *request, int status) {
    transport *t = request->data;
    t->error = status; t->connected = status == 0;
    if (!status) t->error = uv_read_start(t->stream, allocate, received);
}
static void close_handle(uv_handle_t *handle, void *unused) {
    (void)unused;
    if (!uv_is_closing(handle)) uv_close(handle, NULL);
}
void nd_transport_free(transport *t) {
    if (!t) return;
    uv_walk(&t->loop, close_handle, NULL);
    uv_run(&t->loop, UV_RUN_DEFAULT);
    uv_loop_close(&t->loop); free(t->data); free(t);
}
void *nd_transport_connect(const char *address) {
    transport *t = calloc(1, sizeof(*t));
    if (!t || uv_loop_init(&t->loop)) { free(t); return NULL; }
    uv_connect_t request = {0}; request.data = t;
    const char *colon = strrchr(address, ':');
    if (colon && !strchr(address, '/') && !strchr(address, '\\')) {
        char *host = malloc((size_t)(colon-address)+1);
        if (!host) { nd_transport_free(t); return NULL; }
        memcpy(host, address, (size_t)(colon-address)); host[colon-address] = 0;
        if (host[0] == '[') { memmove(host, host+1, strlen(host)); char *end = strchr(host, ']'); if (end) *end = 0; }
        struct addrinfo hints = {0}; hints.ai_socktype = SOCK_STREAM;
        uv_getaddrinfo_t resolver = {0};
        int result = uv_getaddrinfo(&t->loop, &resolver, NULL, host, colon+1, &hints);
        free(host);
        if (result) { nd_transport_free(t); return NULL; }
        result = uv_tcp_init(&t->loop, &t->handle.tcp);
        t->stream = (uv_stream_t *)&t->handle.tcp; t->stream->data = t;
        if (!result) result = uv_tcp_connect(&request, &t->handle.tcp, resolver.addrinfo->ai_addr, connected);
        uv_freeaddrinfo(resolver.addrinfo);
        if (result) t->error = result;
    } else {
        t->error = uv_pipe_init(&t->loop, &t->handle.pipe, 0);
        t->stream = (uv_stream_t *)&t->handle.pipe; t->stream->data = t;
        if (!t->error) uv_pipe_connect(&request, &t->handle.pipe, address, connected);
    }
    uint64_t start = uv_hrtime();
    while (!t->connected && !t->error && uv_hrtime()-start < 3000000000ULL) {
        uv_run(&t->loop, UV_RUN_NOWAIT); uv_sleep(1);
    }
    if (!t->connected || t->error) { nd_transport_free(t); return NULL; }
    return t;
}
size_t nd_transport_read(transport *t, char *data, size_t size) {
    uv_run(&t->loop, UV_RUN_NOWAIT);
    size_t n = size < t->size ? size : t->size;
    if (n) { memcpy(data, t->data, n); t->size -= n; memmove(t->data, t->data+n, t->size); return n; }
    return t->error ? (size_t)-1 : 0;
}
int nd_transport_eof(transport *t) { return t->error == UV_EOF; }
static void written(uv_write_t *request, int status) {
    transport *t = request->handle->data;
    if (status) t->error = status;
    write_job *job = (write_job *)request; free(job->buffer.base); free(job);
}
int nd_transport_write(transport *t, const char *data, size_t size) {
    if (t->error || size > 64 * 1024 * 1024 || uv_stream_get_write_queue_size(t->stream) > 64 * 1024 * 1024) return 0;
    write_job *job = calloc(1, sizeof(*job));
    if (!job) return 0;
    job->buffer.base = malloc(size); job->buffer.len = size;
    if (!job->buffer.base) { free(job); return 0; }
    memcpy(job->buffer.base, data, size);
    int result = uv_write(&job->request, t->stream, &job->buffer, 1, written);
    if (result) { free(job->buffer.base); free(job); return 0; }
    uv_run(&t->loop, UV_RUN_NOWAIT); return !t->error;
}
