#include <string.h>
#include <caml/mlvalues.h>
#include <caml/alloc.h>
#include <caml/memory.h>
#include "lz4.c"

/* decompress src into dst (capacity = length of dst) with dict; returns the length or -1 */
CAMLprim value unlz4_fuzz_decompress(value src, value src_len, value dst, value dict) {
  int n = LZ4_decompress_safe_usingDict((const char *)Bytes_val(src), (char *)Bytes_val(dst),
                                        Int_val(src_len), (int)caml_string_length(dst),
                                        (const char *)Bytes_val(dict), (int)caml_string_length(dict));
  return Val_int(n < 0 ? -1 : n);
}

/* compress src continuing from dict with the given acceleration; "" on failure */
CAMLprim value unlz4_fuzz_compress(value src, value dict, value accel) {
  CAMLparam3(src, dict, accel);
  CAMLlocal1(res);
  int n = (int)caml_string_length(src), cap = LZ4_compressBound(n), len;
  char *out = malloc(cap > 0 ? cap : 1);
  LZ4_stream_t *s = LZ4_createStream();
  LZ4_loadDict(s, (const char *)Bytes_val(dict), (int)caml_string_length(dict));
  len = LZ4_compress_fast_continue(s, (const char *)String_val(src), out, n, cap, Int_val(accel));
  LZ4_freeStream(s);
  if (len < 0) len = 0;
  res = caml_alloc_string(len);
  memcpy(Bytes_val(res), out, len);
  free(out);
  CAMLreturn(res);
}
