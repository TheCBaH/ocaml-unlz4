# Unreleased

Changes since the squashed history at `f5446ab`.

## Fixes

- `Frame.decode` returns a failed decoder's sticky error before checking the `eof`
  contract, so repeated calls with `eof:true` return the same `Error`.
- A foreign exception from a `resolve_dictionary` callback (or `Out_of_memory`)
  counts the call's progress, re-raises, and leaves the decoder unusable: later
  `decode` calls raise `Invalid_argument`.
- Linked frames slide their 64 KiB history lazily instead of after every block.
  Many tiny linked blocks decode about 12x faster.
- `Error.decoded_offset` for an error inside a block is documented: it can exceed
  `Frame.total_out`.

## API

- `Block.decompress_into ?prefix` decodes linked blocks into one buffer.
- `Block.decompress_string_into` and `Frame.decode_string` read a string without
  copying it.
- `Frame.reset` reuses a decoder and its buffers.
- `Frame.decompress_with ?buffer_size`.
- `Unlz4.Private` is gone; `Xxh32` lives in the `unlz4.private` sub-library, which
  only the tests link.

## Performance

- XXH32 reads words with `Bytes.get_int32_le`: block and content checksums
  decode about 4x faster and allocate 8x less (native).
- The block collector grows to the largest block seen, not the frame maximum.
- `Block.decompress`, `Frame.decompress` and `Dictionary.of_string` copy less.

## Packaging and tests

- The test corpus is checked in (`test/corpus`); tests need neither the `vendor/lz4`
  submodule nor a C compiler. `make corpus-generate` / `corpus-check` regenerate and
  verify it, and the reference build is enabled by `UNLZ4_REFERENCE=true`.
- `make release-test` builds `git archive HEAD`.
- New corpus frames: real 4 MiB blocks, 1 MiB linked blocks, flushed tiny blocks.
- `make test-counts` asserts equal case counts on native, js_of_ocaml and Melange.
- The bench has one-setting pairs and reports bytes allocated.
- The dune language floor is 3.20 (the Melange 1.0 extension needs it).
- The devcontainer has the `sshd` feature.
