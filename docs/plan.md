# unlz4 implementation plan

This plan turns [design.md](design.md) into milestones with exit criteria.
Task-level status lives in [tracker.md](tracker.md); this file changes only
when scope or ordering changes.

## Principles

- One decoding source for native, js_of_ocaml and Melange. Backend-specific code
  is limited to test runners, fixture loading and examples.
- Correctness before speed. Match copies are byte-forward until profiling
  justifies anything else, and any optimization stays under the shared suite.
- Tests replay checked-in fixtures; nothing at test time needs a C compiler,
  network, or the `vendor/lz4` submodule.
- Every CI leg runs inside the repository devcontainer, so local and CI
  toolchains are the same image.

## Milestones

### M0: repository and toolchain

Scaffold the standalone repository: `dune-project` (generating `unlz4.opam`
and `unlz4-bytesrw.opam`), `Makefile`, `.ocamlformat`, `LICENSE`, `README.md`,
`.devcontainer/` and `.github/workflows/ci.yml`; pin `vendor/lz4` at v1.10.0.
Run the compatibility spike: Bytesrw under Melange with melange-bigarray,
`Int32`/`Int64` agreement across backends.

Exit: `make ci` passes locally in a switch matching the devcontainer; the
workflow builds the devcontainer and runs `make ci` on every matrix leg.

### M1: raw blocks

`Unlz4.Block.decompress_into`/`decompress` with checked ranges, terminating
length extensions, offset validation, overlapping forward copies, dictionary
history (dictionary tail plus output as one logical history), the spec's
end-of-block rules, and aliasing rejection. Handcrafted unit tests cover every
row of the design's "Raw blocks" and "Matches" coverage.

Exit: handcrafted block suite green on native.

### M2: XXH32 and frames

Private incremental XXH32; `Unlz4.Frame` resumable state machine (magic,
descriptor, block header, payload, block checksum, decode, emit, footer, skip);
linked/independent history, stored and empty blocks, content size/checksum,
concatenation, skippable frames, single-frame mode, legacy-magic rejection,
dictionary resolution, limits, sticky errors and terminal statuses, structured
error offsets. Whole-buffer `Frame.decompress`.

Exit: handcrafted frame/XXH32 suite green, including every-split
fragmentation of small frames and output capacities 0/1.

### M3: reference oracle and corpus

`test/reference/unlz4_ref.c`, an original C generator built against the
submodule's `lib/`: raw default/fast/HC blocks, dictionary and linked blocks,
frames with explicit preferences, decoded back with the safe C decoders before
writing. `tools/` embeds the corpus into an OCaml module at build time and
checks the manifest (SHA-256, lengths). Make targets `reference-build`,
`reference-test` (bounded upstream `fuzzer`/`frametest`), `corpus-generate`,
`corpus-check`.

Exit: corpus checked in with manifest; differential replay green natively.

### M4: JavaScript backends

The shared suite (handcrafted + corpus) runs under js_of_ocaml/Node and, with
`UNLZ4_MELANGE=true`, under Melange/Node through the `melange/` mirror. Test
runners print backend, fixture digest summary and test counts.

Exit: `make test-js` and `make test-melange` green with the same counts as
native.

### M5: Bytesrw adapter

`Unlz4_bytesrw.decompress_reads`/`decompress_writes` following Bytesrw filter
conventions: push-back of the single-frame remainder, slice validity,
downstream slice lengths, EOD propagation, structured `format_error`,
position-limit guard. Tests for buffer lifetime (poisoned/reused slices),
exceptions passthrough, and reader/writer agreement, on all three backends.

Exit: adapter suite green on native, jsoo and Melange.

### M6: examples, consumers, measurements

Native Bytesrw example (decompress stdin to stdout); asynchronous JS driver
example for jsoo; an installed-package consumer build (`dune install` into a
temporary prefix, then build `test/consumer`); a benchmark executable
reporting throughput on literal-heavy, repetition-heavy, dictionary and mixed
data.

Exit: examples build in CI; consumer build passes; benchmark numbers recorded
in the tracker.

### M7: release readiness

README usage, `opam lint`, `dune build -p unlz4,unlz4-bytesrw` without
Melange, release-archive test (`git archive` without submodules, then build and
test), and a final coverage review against the design's pre-release table.

Exit: release-archive test green; every coverage row is ticked or explicitly
deferred in the tracker.

## Later (not v1)

Browser (Chromium) smoke tests, nightly broad seed sweeps and mutation fuzzing,
sanitizer-built C tools, an installable Melange Bytesrw adapter, chunked match
copying, and JS `Uint8Array` interop packages.
