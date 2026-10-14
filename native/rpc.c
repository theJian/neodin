#include "mpack.h"
#include <stdlib.h>

/* Keep MPack's implementation and platform-dependent layout out of Odin. */
typedef size_t (*read_fn)(void *, char *, size_t);
typedef struct { mpack_tree_t tree; read_fn read; void *context; } reader;
typedef struct { mpack_writer_t writer; char *data; size_t size; } writer;
static size_t read_stream(mpack_tree_t *tree, char *buffer, size_t count) {
    reader *r = mpack_tree_context(tree);
    size_t n = r->read(r->context, buffer, count);
    if (n == (size_t)-1) { mpack_tree_flag_error(tree, mpack_error_io); return 0; }
    return n;
}
void *nd_reader_new(read_fn read, void *context) {
    reader *r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    r->read = read; r->context = context;
    mpack_tree_init_stream(&r->tree, read_stream, r, 64 * 1024 * 1024, 1024 * 1024);
    return r;
}
int nd_reader_parse(reader *r) { return mpack_tree_try_parse(&r->tree); }
int nd_reader_error(reader *r) { return mpack_tree_error(&r->tree); }
mpack_node_t nd_reader_root(reader *r) { return mpack_tree_root(&r->tree); }
void nd_reader_free(reader *r) { mpack_tree_destroy(&r->tree); free(r); }
int nd_kind(mpack_node_t n) { return mpack_node_type(n); }
int64_t nd_int(mpack_node_t n) { return mpack_node_i64(n); }
double nd_number(mpack_node_t n) { return mpack_node_double(n); }
int64_t nd_handle(mpack_node_t n) {
    if (mpack_node_type(n) != mpack_type_ext) return mpack_node_i64(n);
    mpack_reader_t r;
    mpack_reader_init_data(&r, mpack_node_data(n), mpack_node_data_len(n));
    int64_t value = mpack_expect_i64(&r);
    if (mpack_reader_destroy(&r) != mpack_ok) mpack_tree_flag_error(n.tree, mpack_error_data);
    return value;
}
bool nd_bool(mpack_node_t n) { return mpack_node_bool(n); }
const char *nd_str(mpack_node_t n) { return mpack_node_str(n); }
uint32_t nd_strlen(mpack_node_t n) { return mpack_node_strlen(n); }
uint32_t nd_count(mpack_node_t n) { return mpack_node_array_length(n); }
mpack_node_t nd_at(mpack_node_t n, uint32_t i) { return mpack_node_array_at(n, i); }
mpack_node_t nd_get(mpack_node_t n, const char *key) { return mpack_node_map_cstr_optional(n, key); }
void *nd_writer_new(void) {
    writer *w = calloc(1, sizeof(*w));
    if (w) mpack_writer_init_growable(&w->writer, &w->data, &w->size);
    return w;
}
void nd_array(writer *w, uint32_t n) { mpack_start_array(&w->writer, n); }
void nd_array_end(writer *w) { mpack_finish_array(&w->writer); }
void nd_map(writer *w, uint32_t n) { mpack_start_map(&w->writer, n); }
void nd_map_end(writer *w) { mpack_finish_map(&w->writer); }
void nd_write_int(writer *w, int64_t n) { mpack_write_i64(&w->writer, n); }
void nd_write_bool(writer *w, bool b) { mpack_write_bool(&w->writer, b); }
void nd_write_nil(writer *w) { mpack_write_nil(&w->writer); }
void nd_write_str(writer *w, const char *p, uint32_t n) { mpack_write_str(&w->writer, p, n); }
int nd_writer_finish(writer *w, char **data, size_t *size) {
    int error = mpack_writer_destroy(&w->writer);
    *data = w->data; *size = w->size; free(w); return error;
}
void nd_free(void *p) { free(p); }
