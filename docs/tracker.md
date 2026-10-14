# unlz4 tracker

Status of the tasks in [plan.md](plan.md). States: `todo`, `doing`, `done`,
`deferred` (with the reason). Update this file in the same change as the work.

Verified locally on OCaml 4.14.4 (Melange 7.0.1-414) and OCaml 5.4.1 (Melange 7.0.1-54), Dune
3.24.2, js_of_ocaml 6.4.1, Bytesrw 0.4.1, Node 24: `make ci test-js test-melange consumer-test
release-test` (2026-10-14, after the host-driver change); `make reference-test`, and `make
corpus-generate` reproducing the checked-in corpus byte for byte (2026-10-13; neither depends on
that change). The 32-bit legs (i386, arm/v7) run only in CI.

## M0: repository and toolchain

| Task | State | Notes |
| --- | --- | --- |
| Review and update design | done | Naming (`unlz4`: opam `lz4` is taken), toolchain, concrete API; Bytesrw moved to an example (2026-10-14) |
| `vendor/lz4` submodule at v1.10.0 (`ebb370ca`) | done | |
| Compatibility spike | done | `Int32`/`Int64` agreement across backends. Bytesrw under Melange also worked (rebuilt with melange-bigarray) but is no longer needed |
| dune-project, opam files, Makefile, .ocamlformat, LICENSE, README | done | `opam lint` passes; license MIT |
| Devcontainer | done | Debian 13; OCaml feature with `OCAML_VERSION`; Melange optional; `bytesrw` for the example |
| CI workflow (devcontainer-based) | done | `.github/workflows/ci.yml`: 4.14.4 and 5.4.1 on amd64/arm64 (full), 4.14.4 on i386/arm/v7 (native, no submodule). Not yet run on GitHub |

## M1: raw blocks

| Task | State | Notes |
| --- | --- | --- |
| Block decoder core | done | `src/block_decoder.ml`; doubling blits for overlapping matches |
| Dictionary snapshot and history crossing | done | |
| End-of-block rules | done | Last 5 bytes literals, last match ≥ 12 bytes before the end, only for blocks with a match |
| Handcrafted block tests | done | `test/shared/test_block.ml`, incl. random valid sequences vs a reference expander |

## M2: XXH32 and frames

| Task | State | Notes |
| --- | --- | --- |
| XXH32 (one-shot and incremental) | done | Int32 only; checked against upstream vectors |
| Frame state machine | done | In-place decode when a payload is wholly in the input |
| Limits and error offsets | done | `total_out` includes the failing call's output |
| `Frame.decompress` | done | Output capped at `Sys.max_string_length` |
| Handcrafted frame tests and fragmentation | done | Every split, bytewise, output capacities 0/1/…, 100k empty blocks, counters beyond 2^32 |

## M3: reference oracle and corpus

| Task | State | Notes |
| --- | --- | --- |
| C reference generator | done | `test/reference/unlz4_ref.c`; verifies every fixture with the upstream safe decoders |
| Corpus generation and manifest | done | 43 fixtures (29 blocks, 14 frames), 1.1 MB, 23 XXH32 vectors; plain text as recipes |
| Corpus embedding and check | done | `tools/embed.ml`, `make corpus-check` (SHA256SUMS + sizes) |
| Differential replay | done | `test/shared/test_corpus.ml`: fragmentation, concatenation, single mode, truncation, mutations |
| `reference-test` (bounded upstream fuzzer/frametest) | done | Built out of tree; the submodule stays clean |

## M4: JavaScript backends

| Task | State | Notes |
| --- | --- | --- |
| jsoo runner | done | 78 cases, same as native |
| Melange mirror and runner | done | `melange/`, `UNLZ4_MELANGE=true`; 78 cases |

## M5: host drivers

| Task | State | Notes |
| --- | --- | --- |
| `Frame.decompress_with` | done | Reads only on `Need_input`; output written before errors; `Frame.decompress` built on it |
| Driver tests on three backends | done | `test/shared/test_driver.ml`, 5 cases |
| Channel and Unix examples | done | `examples/unlz4_cat.ml`, `examples/unlz4_unix.ml`; `@runtest` compares them |
| Bytesrw adapter example | done | `examples/bytesrw/`: reader/writer filters, single-mode push-back, cat; 12 native cases. Skipped (cat is a stub) without `bytesrw` |
| Remove the `unlz4-bytesrw` package and Melange Bytesrw rebuild | done | Drops melange-bigarray and the Melange Bytesrw tests |

## M6: examples, consumers, measurements

| Task | State | Notes |
| --- | --- | --- |
| Native examples | done | See M5 |
| Async JS example | done | `examples/js/`: Node stream host; `@runtest-jsoo` compares it with `unlz4_cat` |
| Installed consumer build | done | `make consumer-test` (native) |
| Benchmarks | done | `make bench`/`bench-js`. Overall corpus throughput, 4.14.4 x86-64 devcontainer: native ≈ 1590 MB/s, jsoo/Node ≈ 150 MB/s |
| Melange benchmark, bundle size, allocation/peak memory | deferred | Not measured yet; correctness first |

## M7: release readiness

| Task | State | Notes |
| --- | --- | --- |
| README usage, opam lint | done | |
| Release-archive test | done | `make release-test`: tracked files without `vendor/`, `dune build -p` + tests |
| Coverage review | done | All rows of the design's pre-release table covered; see below |

### Coverage review

Every row of design.md's "Coverage required before the first release" has tests, with these
limits:

- Counters beyond 2^53 are not exercised (only beyond 2^32, by skipping 8 GiB of skippable
  frames); all counters are `Int64` throughout.
- Installed-package consumer builds are native only; JS consumer projects are deferred.

## Open

| Item | Notes |
| --- | --- |
| First CI run on GitHub | Needs the repository pushed; devcontainer images are cached in its registry |
| Browser smoke tests, nightly fuzzing, sanitizer builds | Later, per plan.md |
