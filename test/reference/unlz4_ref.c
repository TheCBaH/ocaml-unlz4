/* unlz4_ref: generates the unlz4 test corpus with the pinned upstream LZ4 library.

   Usage: unlz4_ref OUTDIR [UPSTREAM-COMMIT]

   Every fixture's plain text (and dictionary) is a recipe for the generator below, which
   test/support/gen.ml reimplements exactly; only compressed bytes are written. Each fixture is
   decoded back with the upstream safe decoders and compared before it is written. OUTDIR gets one
   file per fixture and manifest.txt. Copyright (c) 2026 Vladimir Silyaev, MIT License. */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lz4.h"
#include "lz4frame.h"
#include "lz4hc.h"
#include "xxhash.h"

static const char *outdir;
static FILE *manifest;

static void die(const char *what) {
  fprintf(stderr, "unlz4_ref: %s\n", what);
  exit(1);
}

static void *xmalloc(size_t n) {
  void *p = malloc(n ? n : 1);
  if (!p) die("out of memory");
  return p;
}

/* The generator: xorshift32 returning 30-bit values. Keep in step with test/support/gen.ml. */

static uint32_t st;
static uint32_t next(void) {
  st ^= st << 13;
  st ^= st >> 17;
  st ^= st << 5;
  return st >> 2;
}

enum profile { LIT, REP, MIX };
static const char *profile_name[] = {"lit", "rep", "mix"};

static void generate(enum profile p, uint32_t seed, size_t len, unsigned char *b) {
  st = seed ? seed : 0x9E3779B9u;
  if (p == LIT) {
    for (size_t i = 0; i < len; i++) b[i] = next() & 0xFF;
  } else if (p == REP) {
    size_t unit = 1 + next() % 61;
    for (size_t i = 0; i < len; i++) {
      if (i < unit) b[i] = 97 + next() % 26;
      else if (next() % 512 == 0) b[i] = 65 + next() % 26;
      else b[i] = b[i - unit];
    }
  } else {
    size_t pos = 0;
    while (pos < len) {
      uint32_t x = next();
      if (pos >= 8 && x % 4 != 0) {
        size_t window = (x & 64) ? (pos < 65535 ? pos : 65535) : (pos < 1024 ? pos : 1024);
        size_t off = 1 + next() % window;
        size_t ml = 4 + next() % 60;
        for (size_t k = 0; k < ml && pos < len; k++, pos++) b[pos] = b[pos - off];
      } else {
        size_t n = 1 + next() % 16;
        for (size_t k = 0; k < n && pos < len; k++) b[pos++] = 32 + next() % 64;
      }
    }
  }
}

/* A recipe: bytes [from, to) of generate(profile, seed, len). */
struct recipe {
  enum profile p;
  uint32_t seed;
  size_t len, from, to;
};

static unsigned char *make(struct recipe r) {
  unsigned char *all = xmalloc(r.len);
  generate(r.p, r.seed, r.len, all);
  unsigned char *b = xmalloc(r.to - r.from);
  memcpy(b, all + r.from, r.to - r.from);
  free(all);
  return b;
}

static void recipe_string(char *s, size_t n, struct recipe r) {
  snprintf(s, n, "%s:%u:%zu@%zu:%zu", profile_name[r.p], r.seed, r.len, r.from, r.to);
}

static struct recipe whole(enum profile p, uint32_t seed, size_t len) {
  struct recipe r = {p, seed, len, 0, len};
  return r;
}

static void write_fixture(const char *name, const char *kind, const unsigned char *c, size_t clen,
                          struct recipe plain, const char *dict, const char *opts) {
  char path[4096], rs[128];
  snprintf(path, sizeof path, "%s/%s.lz4", outdir, name);
  FILE *f = fopen(path, "wb");
  if (!f || fwrite(c, 1, clen, f) != clen || fclose(f)) die(path);
  recipe_string(rs, sizeof rs, plain);
  fprintf(manifest, "fixture name=%s kind=%s file=%s.lz4 size=%zu plain=%s dict=%s opts=%s\n", name,
          kind, name, clen, rs, dict, opts);
}

static void check_equal(const char *name, const unsigned char *a, size_t alen,
                        const unsigned char *b, size_t blen) {
  if (alen != blen || memcmp(a, b, alen)) {
    fprintf(stderr, "unlz4_ref: %s: upstream decode mismatch\n", name);
    exit(1);
  }
}

/* Raw blocks. level < 0: LZ4_compress_fast with acceleration -level; 0: default; > 0: HC. */

static void block(const char *name, struct recipe plain, int level) {
  size_t n = plain.to - plain.from;
  unsigned char *src = make(plain);
  int cap = LZ4_compressBound((int)n);
  unsigned char *c = xmalloc(cap), *d = xmalloc(n);
  int clen = level < 0 ? LZ4_compress_fast((char *)src, (char *)c, (int)n, cap, -level)
             : level == 0 ? LZ4_compress_default((char *)src, (char *)c, (int)n, cap)
                          : LZ4_compress_HC((char *)src, (char *)c, (int)n, cap, level);
  if (clen <= 0) die(name);
  int dlen = LZ4_decompress_safe((char *)c, (char *)d, clen, (int)n);
  check_equal(name, d, dlen < 0 ? 0 : (size_t)dlen, src, dlen < 0 ? 1 : n);
  char opts[64];
  snprintf(opts, sizeof opts, "level=%d", level);
  write_fixture(name, "block", c, clen, plain, "-", opts);
  free(src), free(c), free(d);
}

/* A block compressed after a dictionary (fast or HC). */
static void dict_block(const char *name, struct recipe dict, struct recipe plain, int level) {
  size_t n = plain.to - plain.from, dn = dict.to - dict.from;
  unsigned char *src = make(plain), *dsrc = make(dict);
  int cap = LZ4_compressBound((int)n);
  unsigned char *c = xmalloc(cap), *d = xmalloc(n);
  int clen;
  if (level <= 0) {
    LZ4_stream_t *s = LZ4_createStream();
    LZ4_loadDict(s, (char *)dsrc, (int)dn);
    clen = LZ4_compress_fast_continue(s, (char *)src, (char *)c, (int)n, cap, level < 0 ? -level : 1);
    LZ4_freeStream(s);
  } else {
    LZ4_streamHC_t *s = LZ4_createStreamHC();
    LZ4_resetStreamHC_fast(s, level);
    LZ4_loadDictHC(s, (char *)dsrc, (int)dn);
    clen = LZ4_compress_HC_continue(s, (char *)src, (char *)c, (int)n, cap);
    LZ4_freeStreamHC(s);
  }
  if (clen <= 0) die(name);
  int dlen = LZ4_decompress_safe_usingDict((char *)c, (char *)d, clen, (int)n, (char *)dsrc, (int)dn);
  check_equal(name, d, dlen < 0 ? 0 : (size_t)dlen, src, dlen < 0 ? 1 : n);
  char ds[128], opts[64];
  recipe_string(ds, sizeof ds, dict);
  snprintf(opts, sizeof opts, "level=%d", level);
  write_fixture(name, "block", c, clen, plain, ds, opts);
  free(src), free(dsrc), free(c), free(d);
}

/* Linked raw blocks: one stream compressing consecutive chunks of one buffer. Block i's dictionary
   is everything before it (the decoder keeps the last 64 KiB). */
static void linked_blocks(const char *name, struct recipe all, size_t chunk) {
  unsigned char *src = make(all);
  size_t n = all.to - all.from;
  LZ4_stream_t *s = LZ4_createStream();
  int cap = LZ4_compressBound((int)chunk);
  unsigned char *c = xmalloc(cap), *d = xmalloc(chunk);
  for (size_t off = 0, i = 0; off < n; off += chunk, i++) {
    size_t len = n - off < chunk ? n - off : chunk;
    int clen = LZ4_compress_fast_continue(s, (char *)src + off, (char *)c, (int)len, cap, 1);
    if (clen <= 0) die(name);
    size_t dict_from = off > 65536 ? off - 65536 : 0;
    int dlen = LZ4_decompress_safe_usingDict((char *)c, (char *)d, clen, (int)len,
                                             (char *)src + dict_from, (int)(off - dict_from));
    check_equal(name, d, dlen < 0 ? 0 : (size_t)dlen, src + off, dlen < 0 ? 1 : len);
    char bname[256], ds[128] = "-";
    snprintf(bname, sizeof bname, "%s-%zu", name, i);
    struct recipe p = all, dr = all;
    p.from = all.from + off, p.to = all.from + off + len;
    dr.to = all.from + off;
    if (off > 0) recipe_string(ds, sizeof ds, dr);
    write_fixture(bname, "block", c, clen, p, ds, "linked");
  }
  LZ4_freeStream(s);
  free(src), free(c), free(d);
}

/* Frames. */

struct fprefs {
  LZ4F_blockSizeID_t bsid;
  int linked, block_checksum, content_checksum, content_size, level, favor_dec_speed;
  unsigned dict_id;
};

static void frame(const char *name, struct recipe plain, struct fprefs fp, const struct recipe *dict) {
  size_t n = plain.to - plain.from;
  unsigned char *src = make(plain);
  unsigned char *dsrc = dict ? make(*dict) : NULL;
  size_t dn = dict ? dict->to - dict->from : 0;
  LZ4F_preferences_t prefs;
  memset(&prefs, 0, sizeof prefs);
  prefs.frameInfo.blockSizeID = fp.bsid;
  prefs.frameInfo.blockMode = fp.linked ? LZ4F_blockLinked : LZ4F_blockIndependent;
  prefs.frameInfo.blockChecksumFlag = fp.block_checksum ? LZ4F_blockChecksumEnabled : LZ4F_noBlockChecksum;
  prefs.frameInfo.contentChecksumFlag = fp.content_checksum ? LZ4F_contentChecksumEnabled : LZ4F_noContentChecksum;
  prefs.frameInfo.contentSize = fp.content_size ? n : 0;
  prefs.frameInfo.dictID = fp.dict_id;
  prefs.compressionLevel = fp.level;
  prefs.favorDecSpeed = fp.favor_dec_speed;
  size_t cap = LZ4F_compressFrameBound(n, &prefs);
  unsigned char *c = xmalloc(cap);
  size_t clen;
  if (dict) {
    LZ4F_cctx *cctx;
    if (LZ4F_isError(LZ4F_createCompressionContext(&cctx, LZ4F_VERSION))) die(name);
    LZ4F_CDict *cd = LZ4F_createCDict(dsrc, dn);
    clen = LZ4F_compressFrame_usingCDict(cctx, c, cap, src, n, cd, &prefs);
    LZ4F_freeCDict(cd);
    LZ4F_freeCompressionContext(cctx);
  } else {
    clen = LZ4F_compressFrame(c, cap, src, n, &prefs);
  }
  if (LZ4F_isError(clen)) die(LZ4F_getErrorName(clen));
  /* Decode back with the upstream frame decoder, in small pieces. */
  LZ4F_dctx *dctx;
  if (LZ4F_isError(LZ4F_createDecompressionContext(&dctx, LZ4F_VERSION))) die(name);
  unsigned char *d = xmalloc(n);
  size_t ip = 0, op = 0, ret = 1;
  while (ip < clen && ret != 0) {
    size_t in = clen - ip < 1000 ? clen - ip : 1000, out = n - op;
    ret = LZ4F_decompress_usingDict(dctx, d + op, &out, c + ip, &in, dsrc, dn, NULL);
    if (LZ4F_isError(ret)) die(LZ4F_getErrorName(ret));
    ip += in, op += out;
  }
  if (ret != 0 || ip != clen) die("incomplete upstream frame decode");
  check_equal(name, d, op, src, n);
  LZ4F_freeDecompressionContext(dctx);
  char ds[128] = "-", opts[160];
  if (dict) recipe_string(ds, sizeof ds, *dict);
  snprintf(opts, sizeof opts, "bsid=%d,linked=%d,bcs=%d,ccs=%d,csize=%d,level=%d,dictid=0x%08x",
           (int)fp.bsid, fp.linked, fp.block_checksum, fp.content_checksum, fp.content_size, fp.level,
           fp.dict_id);
  write_fixture(name, "frame", c, clen, plain, ds, opts);
  free(src), free(dsrc), free(c), free(d);
}

static void xxh32_vectors(void) {
  size_t lens[] = {0, 1, 2, 3, 4, 5, 7, 8, 15, 16, 17, 31, 32, 33, 47, 48, 63, 64, 65, 100, 255, 1000, 65536};
  for (size_t i = 0; i < sizeof lens / sizeof lens[0]; i++) {
    struct recipe r = whole(LIT, 77, lens[i]);
    unsigned char *b = make(r);
    char rs[128];
    recipe_string(rs, sizeof rs, r);
    fprintf(manifest, "xxh32 data=%s value=0x%08x\n", rs, XXH32(b, lens[i], 0));
    free(b);
  }
}

int main(int argc, char **argv) {
  if (argc != 2 && argc != 3) die("usage: unlz4_ref OUTDIR [UPSTREAM-COMMIT]");
  outdir = argv[1];
  char path[4096];
  snprintf(path, sizeof path, "%s/manifest.txt", outdir);
  manifest = fopen(path, "w");
  if (!manifest) die(path);
  fprintf(manifest, "# unlz4 corpus, generated by test/reference/unlz4_ref.c; do not edit.\n");
  fprintf(manifest, "upstream version=%s commit=%s\n", LZ4_versionString(), argc == 3 ? argv[2] : "-");

  xxh32_vectors();

  block("b-empty", whole(LIT, 1, 0), 0);
  size_t tiny[] = {1, 4, 5, 12, 13, 14, 64};
  for (size_t i = 0; i < sizeof tiny / sizeof tiny[0]; i++) {
    char name[64];
    snprintf(name, sizeof name, "b-lit-%zu", tiny[i]);
    block(name, whole(LIT, 2, tiny[i]), 0);
    snprintf(name, sizeof name, "b-rep-%zu", tiny[i]);
    block(name, whole(REP, 3, tiny[i]), 0);
  }
  block("b-lit-4096", whole(LIT, 4, 4096), 0);
  block("b-mix-default", whole(MIX, 5, 100000), 0);
  block("b-mix-fast17", whole(MIX, 5, 100000), -17);
  block("b-mix-hc9", whole(MIX, 5, 100000), 9);
  block("b-mix-hc12", whole(MIX, 5, 100000), 12);
  block("b-rep-default", whole(REP, 6, 200000), 0);
  block("b-rep-hc12", whole(REP, 6, 200000), 12);
  /* Dictionary fixtures continue the dictionary's own stream, so they really refer to it. */
  struct recipe d70k = {MIX, 99, 270000, 0, 70000};
  struct recipe after70k = {MIX, 99, 270000, 70000, 120000};
  dict_block("b-dict-default", d70k, after70k, 0);
  dict_block("b-dict-hc9", d70k, after70k, 9);
  struct recipe d300 = {MIX, 98, 2300, 0, 300}, after300 = {MIX, 98, 2300, 300, 2300};
  dict_block("b-dict-small", d300, after300, 0);
  linked_blocks("b-linked", whole(MIX, 11, 200000), 50000);

  struct fprefs def = {LZ4F_max64KB, 1, 0, 0, 0, 0, 0, 0};
  struct fprefs p;
  frame("f-empty", whole(LIT, 1, 0), def, NULL);
  frame("f-tiny", whole(MIX, 12, 1), def, NULL);
  p = def, p.content_checksum = 1;
  frame("f-64k-linked", whole(MIX, 21, 300000), p, NULL);
  p = def, p.linked = 0, p.block_checksum = 1;
  frame("f-64k-indep-bcs", whole(MIX, 21, 300000), p, NULL);
  p = def, p.bsid = LZ4F_max256KB, p.content_size = 1;
  frame("f-256k-csize", whole(MIX, 22, 600000), p, NULL);
  p = def, p.bsid = LZ4F_max1MB, p.block_checksum = 1, p.content_checksum = 1, p.content_size = 1;
  frame("f-1m-all", whole(MIX, 23, 300000), p, NULL);
  p = def, p.bsid = LZ4F_max4MB, p.linked = 0;
  frame("f-4m", whole(REP, 24, 300000), p, NULL);
  p = def, p.content_checksum = 1;
  frame("f-lit-stored", whole(LIT, 25, 150000), p, NULL);
  p = def, p.level = 12, p.content_checksum = 1;
  frame("f-hc12-linked", whole(MIX, 26, 200000), p, NULL);
  p = def, p.level = 9, p.linked = 0, p.favor_dec_speed = 1;
  frame("f-hc9-indep", whole(MIX, 26, 200000), p, NULL);
  p = def, p.level = -10;
  frame("f-fast10", whole(MIX, 27, 100000), p, NULL);
  p = def, p.dict_id = 0x12345678u, p.content_checksum = 1;
  struct recipe after70k_long = {MIX, 99, 270000, 70000, 270000};
  frame("f-dict-id", after70k_long, p, &d70k);
  p = def, p.linked = 0, p.block_checksum = 1;
  frame("f-dict-noid", after70k_long, p, &d70k);
  p = def, p.dict_id = 0xDEADBEEFu, p.content_size = 1;
  struct recipe after70k_short = {MIX, 99, 270000, 70000, 100000};
  frame("f-dict-highid", after70k_short, p, &d70k);

  if (fclose(manifest)) die("manifest");
  return 0;
}
