# unlz4: a pure OCaml LZ4 decompressor

Status: reviewed and updated for implementation, 2026-10-13. The execution plan
is [plan.md](plan.md) and task status is tracked in [tracker.md](tracker.md).

Build a standalone, pure OCaml decompression library with the same decoding
source for native OCaml, js_of_ocaml (jsoo), and Melange. Support raw LZ4 blocks
and the modern LZ4 frame format. Use Bytesrw through a separate, optional I/O
adapter. Include the upstream LZ4 repository as a pinned development submodule
for specifications, interoperability tests, and fixture generation.

This repository is the standalone home of the library: its own Dune project,
opam packages, documentation, devcontainer and devcontainer-based CI. It must
build and test without any sibling checkout.

### Naming

The opam name `lz4` is taken by existing C bindings
([whitequark/ocaml-lz4](https://github.com/whitequark/ocaml-lz4), module
`LZ4`), as are `lz4_chans` and `conf-lz4`/`conf-liblz4`. This library therefore
uses `unlz4`: it states that the package only decompresses, it is free in
opam-repository, and its top-level module `Unlz4` cannot collide with `LZ4` on
case-insensitive file systems. The Bytesrw adapter is `unlz4-bytesrw` with
module `Unlz4_bytesrw`. The names remain provisional until an opam release.

## Scope and package boundaries

| Component | Proposed public library | Dependencies | Responsibility |
| --- | --- | --- | --- |
| Decoder | `unlz4` / module `Unlz4` | OCaml standard library | Blocks, incremental frames, dictionaries, checksums, errors and limits |
| Bytesrw adapter | `unlz4-bytesrw` / module `Unlz4_bytesrw` | `unlz4`, base `bytesrw` | Reader and writer decompression filters |
| Reference tools | Development executables only | C compiler, pinned upstream LZ4 | Generate compressed inputs and reference results |
| JS interop | Optional examples initially | Backend-specific bindings | Convert `Uint8Array` to/from OCaml bytes and drive incremental decoding |

Publish separate opam packages, `unlz4` and `unlz4-bytesrw`, so the
core remains installable without Bytesrw. The runtime must have no C stubs,
FFI calls to liblz4, WebAssembly decoder, subprocesses, Bigarray requirement,
Unix dependency, or external hash library. In particular, do not depend on
Bytesrw's optional C-backed compression or xxHash packages.

Version one includes raw blocks, modern frames, independent and linked blocks,
uncompressed blocks, checksum verification, concatenation, skippable frames,
and externally supplied dictionaries. Compression, the legacy frame format,
random access, filesystem convenience APIs, and a prebuilt npm package are
outside the initial scope. Recognize legacy frame magic and return an explicit
unsupported-format error. LZ4 HC output uses the same block encoding and must
decode through the ordinary decoder. See the upstream
[library overview](https://github.com/lz4/lz4/blob/v1.10.0/lib/README.md).

## Format contract

### Raw blocks

Raw blocks require an exact compressed range and an output bound supplied by
the caller; they do not carry a frame header or their own size metadata.
Never guess raw-block boundaries or automatically detect blocks as frames.

Decode sequences of token, optional literal-length extension, literal bytes,
offset, and optional match-length extension. Length extensions must terminate,
including a zero extension when a nibble reaches its maximum. Reject zero
offsets and references outside available output/dictionary history. Support
offsets through 65,535 and matches longer than their offsets. Finish only at
the exact end of the supplied compressed range after a literal-only sequence.

Use the specification's end-of-block restrictions as the initial validation
policy, including its exceptions for small and empty inputs. A compressed
empty block is the single token byte `00`; an empty compressed range is
truncated input. Track the last match start and final literal count to check
the terminal restrictions against decoded positions. These rules are defined
by the [block specification](https://github.com/lz4/lz4/blob/v1.10.0/doc/lz4_Block_format.md).

### Frames

Accept current-version descriptors, all four standard maximum block sizes,
optional content sizes and dictionary IDs, and both stored and compressed
blocks. Reject reserved bits, unsupported versions, invalid size codes, and
payloads or decoded blocks above the descriptor's maximum. Distinguish the
end marker from an empty stored block.

Always validate the descriptor checksum and any present block/content
checksums. Check a declared content size at frame completion. Reset frame
state at concatenation boundaries; skip recognized skippable frames in bounded
chunks. A truncated descriptor, payload, checksum, skip payload, or footer
is an error. These rules follow the
[frame specification](https://github.com/lz4/lz4/blob/v1.10.0/doc/lz4_Frame_format.md).

Default stream mode decodes every modern or skippable frame through input EOF.
Trailing garbage is an error. Empty input is a missing-frame error; an empty
modern frame and a complete stream containing only skippable frames succeed.
Single-frame mode stops after one modern frame, consuming any preceding
skippable frames and preserving subsequent bytes for the caller. EOF before
that modern frame is an error. The convenience whole-buffer decoder also
defaults to full consumption.

## Decoder architecture

```mermaid
flowchart LR
    Memory[OCaml bytes] --> Core[Unlz4 incremental frame decoder]
    Host[Host stream or async JS chunks] --> Core
    RW[Bytesrw reader or writer] --> Adapter[Unlz4_bytesrw]
    Adapter --> Core
    Core --> Block[Raw block decoder]
    Core --> Hash[Pure OCaml XXH32]
    Core --> Output[Caller-owned output buffer]
    Upstream[Pinned upstream C tools] --> Fixtures[Checked-in fixtures]
    Fixtures --> Native[Native tests]
    Fixtures --> Jsoo[jsoo tests]
    Fixtures --> Melange[Melange tests]
```

The raw-block decoder is a bounded one-shot operation. The frame decoder is a
resumable state machine; its step function only makes direct self tail calls,
which js_of_ocaml and Melange compile to loops, so many tiny blocks cannot grow
the stack (tested with 100,000 empty stored blocks). Start with whole-block buffering internally rather
than exposing every token as a public streaming state. This gives a small,
auditable core while still bounding memory independently of total stream size.

Frame phases are magic, descriptor, block header, block payload, block
checksum, emit, footer, skippable size and skip payload, plus the terminal
single-frame and stream ends. A block payload that is wholly present in the
caller's input (with its checksum) is verified and decoded in place, without
being copied into the payload buffer. Keep
partial fixed fields and payload fill cursors between calls. Decode one block,
then drain its output before accepting the next block. Avoid per-byte
allocations and recursion proportional to input size.

For maximum block size B, allocate at most B bytes of compressed payload,
B bytes of decoded block, and 64 KiB of owned history, plus small headers and
checksum state. The adapter adds its output slice buffer. With B = 4 MiB the
baseline decoder owns approximately 8 MiB + 64 KiB; measure actual allocation
on every backend. Allocate buffers lazily and reuse them. A caller retaining
all output or input contributes additional memory outside this bound.

Verify a block checksum before decoding/emitting that block. Content checksum
and final content-size errors arrive after earlier output may have been
delivered. Streaming success is established only at frame/stream completion;
the API cannot retract emitted data. Whole-buffer decoding returns output only
after all required validation succeeds.

## Raw-block algorithm and history

Use `Bytes.get`, `Bytes.set`, and `Bytes.blit` with explicit range checks.
js_of_ocaml keeps a fresh `Bytes.create` buffer as a growing JavaScript string
until its first non-appending `Bytes.set`, and reading such a buffer back
between appends is quadratic. Buffers the decoder writes and then reads (the
frame window, the payload buffer, a raw block's output range) are therefore
moved to the array representation once, by rewriting one in-range byte with
its own value.
Validate ranges by subtraction (`len <= capacity - off`) after checking
nonnegative values. Accumulate lengths against the remaining output capacity;
do not add first and check after an overflow.

Literal copies use `Bytes.blit`. A match must behave like a byte-at-a-time
forward copy, so newly generated output feeds later bytes of an overlapping
match; `Bytes.blit` has snapshot-like overlap behavior and cannot do that
alone. When the offset is at least the length, one blit is exact. Otherwise
the first `offset` bytes are copied, and the copied prefix, whose length is
always a multiple of the period `offset`, is doubled by blits from the match
start; a periodic prefix copied at a multiple of its period extends the same
period, so the result equals the forward copy. Random-sequence tests compare
against a byte-at-a-time reference expander.

Treat the supplied dictionary tail followed by already decoded bytes as one
logical history. A match may begin in the dictionary and continue into the
current output, including overlap. Snapshot at most the last 64 KiB of a
dictionary at creation so subsequent caller mutation cannot change decoding.
Reject source/destination buffer aliasing in the public raw-block API.

Linked frames retain the last 64 KiB of dictionary plus decoded content and
update history after compressed and stored blocks, including small blocks.
Independent frames reseed each block from the original dictionary. Frame
boundaries reset history completely. These dictionary semantics are specified
in the upstream [frame API](https://github.com/lz4/lz4/blob/v1.10.0/lib/lz4frame.h).

An explicit dictionary may be supplied for streams without a dictionary ID.
Otherwise resolve an advertised ID with a caller callback; a missing dictionary
is an error, and an explicit dictionary with a conflicting supplied ID is an
error. Dictionary IDs are identifiers, not integrity hashes: the decoder cannot
prove that bytes are correct from an ID alone. Never search files or fetch a
dictionary implicitly. A resolver runs once per modern frame after header
validation and before its first data block.

## Public API

The authoritative interface is `src/unlz4.mli`; this summary records the
decisions it implements. Abstract types hide state. Small counts/indexes are
`int`; stream byte counts are `int64`; dictionary IDs and XXH32 values are
`int32` bit patterns. Configuration constructors validate options and raise
`Invalid_argument` before decoding starts.

```ocaml
module Unlz4 : sig
  module Error : sig
    type kind =
      | Invalid_block | Invalid_frame | Truncated_input
      | Unsupported_feature | Missing_dictionary | Dictionary_id_mismatch
      | Checksum_mismatch | Content_size_mismatch | Limit_exceeded
    type t
    val kind : t -> kind
    val compressed_offset : t -> int64  (* offending field/token *)
    val decoded_offset : t -> int64     (* decoded bytes before the error *)
    val frame_index : t -> int option   (* modern frames, zero-based *)
    val block_index : t -> int option   (* data blocks within the frame *)
    val message : t -> string
    val to_string : t -> string
  end

  module Dictionary : sig
    type t
    val of_bytes : ?id:int32 -> bytes -> t   (* snapshots the last 64 KiB *)
    val of_string : ?id:int32 -> string -> t
    val id : t -> int32 option
    val length : t -> int
  end

  module Limits : sig
    type t
    val default : t
    val make :
      ?max_block_size:int -> ?max_input:int64 -> ?max_output:int64 ->
      ?max_frames:int64 -> ?max_skipped:int64 -> unit -> t
  end

  module Block : sig
    val decompress_into :
      ?dictionary:Dictionary.t ->
      src:bytes -> src_off:int -> src_len:int ->
      dst:bytes -> dst_off:int -> dst_len:int ->
      unit -> (int, Error.t) result
    (* Returns bytes written; consumes exactly src_len on success. *)
    val decompress :
      ?dictionary:Dictionary.t -> max_output:int -> string ->
      (string, Error.t) result
  end

  module Frame : sig
    type t
    type mode = Single | Concatenated
    type status = Need_input | Need_output | Frame_end | Stream_end
    type progress = { consumed : int; produced : int; status : status }
    type info = {
      block_max_size : int; block_independent : bool;
      block_checksum : bool; content_checksum : bool;
      content_size : int64 option; dictionary_id : int32 option;
    }
    val create :
      ?limits:Limits.t -> ?mode:mode -> ?dictionary:Dictionary.t ->
      ?resolve_dictionary:(int32 -> Dictionary.t option) -> unit -> t
    val decode :
      t -> src:bytes -> src_off:int -> src_len:int -> eof:bool ->
      dst:bytes -> dst_off:int -> dst_len:int ->
      unit -> (progress, Error.t) result
    val info : t -> info option          (* the current or last modern frame *)
    val total_in : t -> int64
    val total_out : t -> int64
    val decompress :
      ?limits:Limits.t -> ?dictionary:Dictionary.t ->
      ?resolve_dictionary:(int32 -> Dictionary.t option) ->
      string -> (string, Error.t) result
  end
end
```

`Limits.default` admits every standard block size (4 MiB) and leaves input,
output, frame and skipped-byte totals unbounded (`Int64.max_int`).
`max_block_size` must be at least 64 KiB; a frame whose descriptor advertises a
larger block maximum fails with `Limit_exceeded` before any buffer is
allocated. `Frame.decompress` additionally caps output at
`Sys.max_string_length` and checks the cap while growing its buffer.
`Block.decompress` takes the output bound explicitly because raw blocks carry
no size; it is a convenience over `decompress_into`.

`eof:true` means the supplied range is the final input; after that range is
consumed no new input is permitted, but calls with empty input may drain
pending output. Once a call passes `eof:true`, later calls must also pass
`eof:true` with exactly the unconsumed remainder (raising `Invalid_argument`
otherwise). Input exhaustion without EOF yields `Need_input`, not
truncation. Retain no references to caller buffers after `decode` returns.
Callers advance by `consumed` and `produced` and may reuse those ranges then.
An `Error` result carries no progress record, so `total_in`/`total_out` include
what the failing call consumed and wrote; the difference from the previous
`total_out` locates the decoded prefix in `dst`.
Reject source/output aliasing in this API too. Output buffers may contain a
decoded prefix after an error; neither incremental nor raw-block decoding
promises rollback. Bytes outside the supplied output range remain untouched.

In concatenated mode `Frame_end` reports each completed modern frame and
allows continuation; `consumed` stops at the end of that frame. When the last
frame ends exactly at EOF the call reports `Frame_end` and the next call
reports `Stream_end`. In single mode it is terminal and unconsumed bytes remain
with the caller. `Stream_end` reports validated EOF in concatenated mode.
Skipped frames do not produce `Frame_end`. Terminal statuses are sticky: later
calls return them again with zero progress. Empty output ranges must not spin:
return `Need_output` when decoded output is pending. A nonterminal call with
available input/output must make progress or return a clear suspension status.

A decoding error is terminal and the same error is returned on subsequent
calls. Define error offsets at the offending field/token, frame index, and
block index in the final interface. Invalid API ranges/options raise
`Invalid_argument`; malformed compressed input returns `Error.t`. Do not catch
arbitrary host I/O exceptions and relabel them as compression errors. The
whole-buffer function enforces allocation and output limits during growth.

## Bytesrw interface

Recommend Bytesrw as the standard OCaml stream interface, with the core API
also available to asynchronous JS hosts. Bytesrw's base abstractions separate
resource ownership from byte processing; its optional C extensions are separate
dependencies. See the [Bytesrw overview](https://erratique.ch/software/bytesrw)
and [source interface](https://github.com/dbuenzli/bytesrw/blob/main/src/bytesrw.mli).

Follow the actual reader/writer filter conventions:

```ocaml
open Bytesrw

type Bytes.Stream.error += Error of Unlz4.Error.t

val decompress_reads :
  ?limits:Unlz4.Limits.t -> ?mode:Unlz4.Frame.mode ->
  ?dictionary:Unlz4.Dictionary.t ->
  ?resolve_dictionary:(int32 -> Unlz4.Dictionary.t option) ->
  unit -> Bytes.Reader.filter

val decompress_writes :
  ?limits:Unlz4.Limits.t -> ?dictionary:Unlz4.Dictionary.t ->
  ?resolve_dictionary:(int32 -> Unlz4.Dictionary.t option) ->
  unit -> Bytes.Writer.filter
```

The `unit` argument erases the LZ4 options so the result is an ordinary Bytesrw filter.

Reader filtering is pull based. The output reader defaults its position to
zero and chooses a documented positive slice length. An upstream slice is
valid only until the next read: consume it fully or copy outstanding bytes
before requesting another. An output slice is valid until the next filtered
read; callers retaining it must copy. Keep owned match history separate from
reusable output slices.

In single-frame mode return any unused tail to the upstream reader with
`Bytes.Reader.push_back` before returning filtered EOD. Do this at the exact
consumed boundary; do not use push-back as the internal parsing mechanism.
While the filtered reader is active the caller must not read its source
directly. Abandoning the filter early does not promise source restoration.

Writer filtering accepts compressed slices and writes decoded slices
synchronously. It must consume or copy all input before each write callback
returns, and honor the downstream slice-length preference. Initially support
concatenated mode only: a writer filter has no interface for returning a
single-frame remainder. On input EOD drain output and validate completion;
write downstream EOD only after successful completion and only when `~eod:true`.
Receiving EOD is not a request to close an underlying file or JS stream.

Extend `Bytes.Stream.error` with the structured LZ4 error and construct a
`Bytes.Stream.format_error` using format `lz4`. Raise through reader/writer
error helpers, preserving compressed and decoded `int64` offsets in the
payload even when their position spaces differ. Preserve existing upstream or
downstream exceptions. After failure the filter must reject further decoding.

Bytesrw positions are `int`, whereas the decoder needs larger stream counts.
Check an adapter's effective position limit before advancing its counters or
writing downstream, accounting for nonzero starting positions. Wrapped readers
must also guarantee that their own counters do not overflow: `Reader.read`
advances its counter before the adapter sees the returned slice, and its slice
length is only a hint. Document this source-reader precondition explicitly.
The adapter caps its decoded output at `max_int - pos` by tightening the
decoder's `max_output`, so the filter reports `Limit_exceeded` before its own
position could wrap: 2^62 - 1 natively on 64-bit hosts, 2^30 - 1 natively on
32-bit hosts, 2^31 - 1 under js_of_ocaml and Melange. A test starts the
filter just below `max_int` on every backend. The core incremental API remains
the path for larger JS streams.

Bytesrw is packaged with ocamlbuild/topkg and ships no Melange artifacts, and
its `Bytes.Slice` interface mentions `Bigarray`, which Melange's standard
library lacks. Resolution, verified by the compatibility spike (Bytesrw 0.4.1,
Melange 7.0.1, OCaml 4.14.4):

- [melange-bigarray](https://github.com/TheCBaH/melange-bigarray), pinned by
  commit, provides `melange-bigarray.compat`, an unwrapped `Bigarray` module for
  rebuilding dependencies that use plain `Bigarray`.
- The repository's Melange build copies the *installed* Bytesrw sources
  (`bytesrw.ml`, `bytesrw.mli`, `bytesrw_fmt.ml`, `bytesrw_fmt.mli`, via
  `%{lib:bytesrw:...}`) unmodified, ISC header included, into a Melange-only,
  unwrapped library. The Melange `Bytesrw` therefore has the same source and
  version as the native one, and is the only `Bytesrw` in the Melange build.
- With that, the shared Bytesrw tests run unchanged under Melange, and native
  and Melange produce identical `Int32`/`Int64` results.

This compatibility build is development and test infrastructure. It is not
installed: shipping a module named `Bytesrw` from this package would be a
lookalike. The installed Melange story for `unlz4-bytesrw` waits for upstream
Melange packaging (or a separately published compatibility package); the
installed core `unlz4` is supported on native and jsoo, and its Melange mode is
exercised in-repo.

## JavaScript portability and XXH32

Use shared OCaml source and explicit fixed-width operations. Keep buffer
indexes and block lengths small; use `Int32` for hash words and checked
`Int64` counters for totals. Do not rely on native `int` width, unchecked
`Int32.to_int`, JS floating-point multiplication, or the exact representation
of OCaml bytes in generated JavaScript.

Parse unsigned block/skip sizes and dictionary IDs as `int32` patterns, then
widen before numeric comparisons. Parse content-size fields as unsigned
64-bit values; version one supports total counts through `Int64.max_int` and
reports `Limit_exceeded` for larger declared sizes before allocating or
decoding. Addition to total counters must be checked. JS-facing examples
represent large counts as decimal strings, avoiding Number precision loss.

Implement private, incremental XXH32 in OCaml using `Int32.add`, `Int32.mul`,
logical shifts and rotations. Feed byte ranges directly, with seed zero for
LZ4 validation. Cross-check one-shot and chunked results against the pinned
[upstream xxHash implementation](https://github.com/lz4/lz4/blob/v1.10.0/lib/xxhash.c),
including high-bit words and lengths around its stripe boundaries. This is a
required component even for streams without optional checksums because frame
headers have checksums. Avoid enabling C-backed Bytesrw xxHash accidentally.

Do not require effects or promise-aware reader callbacks. A browser or Node
host awaits input itself, then repeatedly calls `Frame.decode`, draining output
with backpressure. Backend-specific `Uint8Array` conversions belong in examples
or a later interop package. Establish a copying conversion first; do not claim
zero-copy portability between both JS runtimes.

Target OCaml 4.14 and current OCaml 5 releases for native builds. The
devcontainer pins the known-working combination: OCaml 4.14.4 (default) and
5.x, Dune 3.24.2, js_of_ocaml 6.4.1, Melange 7.0.1 (the `-414`/`-5x` variant
matching the compiler), ocamlformat 0.28.1, and melange-bigarray by commit.
The released packages require Dune 3.21 (the floor melange-bigarray needs) and
use the Melange 1.0 Dune extension. jsoo compiles bytecode; Melange needs its
own library artifacts and emission stanza, as described by the
[Melange build documentation](https://melange.re/v5.0.0/build-system.html).

Dune cannot make a library's `modes` conditional, and declaring `melange` mode
puts `melc` rules into `@all`. The Melange build is therefore a parallel tree
under `melange/` that `copy_files` the same sources and is enabled only when
`UNLZ4_MELANGE=true`; the native stanzas are disabled in that configuration.
Release builds (`dune build -p unlz4`) never need Melange.

## Standalone repository and upstream submodule

```text
lz4/                          # repository root (GitHub: ocaml-unlz4)
  dune-project, Makefile, README.md, LICENSE, .gitmodules, .ocamlformat
  unlz4.opam, unlz4-bytesrw.opam  # generated from dune-project
  .devcontainer/              # Dockerfile + devcontainer.json; CI runs inside it
  .github/workflows/ci.yml    # devcontainer-based matrix
  docs/design.md, docs/plan.md, docs/tracker.md
  src/                        # Unlz4 facade and private block/frame/hash modules
  bytesrw/                    # Unlz4_bytesrw
  test/support/               # Shared harness, PRNG, fixtures loader
  test/shared/                # Same assertions on every backend
  test/native/, test/jsoo/    # Runners
  melange/                    # UNLZ4_MELANGE=true mirror: core, adapter, tests
  test/corpus/                # Compressed bytes, plaintext/dictionary, manifest
  test/reference/             # Small original C oracle/generator
  test/consumer/              # Installed-package consumer project
  tools/                      # Corpus embedding, generation and validation
  examples/                   # Native Bytesrw and asynchronous JS drivers
  vendor/lz4/                 # Git submodule; development only
```

Require `https://github.com/lz4/lz4.git` as `vendor/lz4`, pinned initially to
tag `v1.10.0`, commit `ebb370ca83af193212df4dcbadcc5d87bc0de2f0`. This is a
deliberate reference baseline, not a claim about the latest release. Store its
URL/path in `.gitmodules` and its exact commit as a Git gitlink. Initialize with
`git submodule update --init vendor/lz4`; ordinary consumers must not need it.
Exclude `vendor/` from Dune source traversal and installed runtime artifacts.

Normal build/test uses the committed corpus without a C compiler or network.
Reference generation and upstream tests are explicit development targets.
Release archives must contain sufficient fixtures to test without initialized
submodules. An upstream update is a reviewed gitlink change with regenerated
fixtures, their manifest changes, and differential validation.

The submodule is present at the pinned commit; `make reference-build`
compiles the oracle from it.

## Reusing upstream tests and generating new ones

Upstream has a real suite, but its executables call C APIs. Running them does
not exercise the OCaml decoder. Use them to validate the reference build and
identify scenarios; use separate differential tests to exercise this library.
The inspected golden-sample directory contains `skip.bin`, not a broad block
or frame corpus. Relevant sources are the
[test directory](https://github.com/lz4/lz4/tree/v1.10.0/tests),
[test README](https://github.com/lz4/lz4/blob/v1.10.0/tests/README.md), and
[test Makefile](https://github.com/lz4/lz4/blob/v1.10.0/tests/Makefile).

| Upstream source | Planned use |
| --- | --- |
| `tests/fuzzer.c` | Identify raw-block, dictionary and linked-history edge cases; run the C reference with bounded test counts |
| `tests/frametest.c` | Identify frame options, dictionary, fragmented I/O and corruption scenarios |
| `tests/datagen*` | Generate deterministic plaintext using explicit seed, size and compressibility |
| `tests/test-lz4-{basic,contentSize,dict,frame-concatenation,skippable}.sh` | Independently express matching OCaml interoperability scenarios |
| `tests/goldenSamples/skip.bin` | Exercise skipping; record provenance if redistributed |
| `ossfuzz/` | Inform later mutation/differential fuzz harnesses and shrinking |

Build a small original C helper against upstream `lib/lz4.c`, `lz4hc.c`,
`lz4frame.c`, and `xxhash.c`. It must generate raw default/fast/HC blocks,
dictionary and linked blocks, and modern frames with explicit preferences.
The CLI alone cannot generate every raw block or fully controlled frame case.
Use safe C decode functions as the oracle, including
`LZ4_decompress_safe_usingDict` and `LZ4F_decompress_usingDict` where appropriate.
For linked raw-block cases supply the exact rolling dictionary tail.

Generation pipeline:

1. Generate deterministic plaintext/dictionary bytes and record their recipe.
2. Compress with the pinned C implementation and explicit settings.
3. Decode with the C implementation and verify equality to the original bytes.
4. Save compressed bytes, original bytes or a reproducible recipe, dictionary,
   and a manifest recording source commit, seed, options, lengths, and SHA-256
   digests. Manifest wide integers are decimal strings; binary files remain
   binary rather than embedded OCaml string literals.
5. Run that fixture through the same assertions on native, jsoo and Melange,
   varying input fragmentation and output capacity independently.
6. For failures, minimize input and chunk schedule and commit a regression.

Valid-input differential tests require identical plaintext and consumed length.
Malformed input tests require safe termination and stable library error classes;
do not require identical C/OCaml rejection offsets or acceptance of every input
the C decoder tolerates. The spec and documented validation policy decide
conformance, including offset zero and terminal restrictions.

Generate controlled corruptions and handcrafted valid sequences independently
of the C compressor so unreachable compressor patterns are still covered.
Mutations that should reach a block/content error must repair earlier checksums;
otherwise they only test descriptor checksum rejection.

### Coverage required before the first release

| Area | Cases |
| --- | --- |
| Raw blocks | Empty/tiny literals; extension thresholds; terminated and truncated extension chains; exact and undersized destination; nonzero source/destination offsets and guard bytes |
| Matches | Offsets 1, 2, 3, 4 and 65,535; match length greater than offset; long repetition; zero/too-large offsets; dictionary-to-output crossing; terminal-rule violations |
| Frames | Each standard block maximum; independent/linked; stored/compressed/empty blocks; empty modern frame; content size absent/present/correct/incorrect |
| Integrity | Header, block and content checksum combinations; corrupt descriptor/payload/footer; XXH32 empty input and stripe/tail boundaries |
| Dictionaries | No ID with explicit dictionary; resolved/missing/conflicting IDs; dictionary longer than 64 KiB; independent reseeding; linked rollover; caller mutation after snapshot |
| Stream boundaries | Concatenated frames with different options; all skippable magic variants; skip-only input; skip truncation; single-frame remainder in the same slice; garbage and partial next magic |
| Fragmentation | Every split for small fixtures; bytewise input; randomized deterministic chunks for large fixtures; output capacities 0, 1 and around block/slice boundaries; EOF while output is pending |
| Limits/portability | Block limit before allocation; output limit before copying; skipped-byte/frame limits; high-bit IDs/hashes; unsigned sizes; synthetic counters beyond 2^31 and 2^53; declared size beyond supported int64 range |
| Bytesrw | Reused/poisoned source buffers; retained output copies; downstream slice sizes; EOD propagation both settings; upstream/downstream exceptions; position-overflow guards; pull reader/writer agreement |

Use a fixed, repository-owned PRNG for shared chunk schedules; do not assume
`Random` sequences match across compiler versions. For large boundary counts
test arithmetic helpers or injected counter states, without allocating huge
buffers. Include genuinely multi-block fixtures to test history rollover.

Keep default fixtures small and bounded. Use a separate nightly job for broad
seed sweeps, mutation, sanitizer-enabled C tools, and larger frames. Checked-in
reproducer fixtures must not require rerunning the random generator at test time.

## Development commands, CI and licensing

Library targets: `make test` (`dune build @runtest`) for native fixtures;
`make test-js` (`@runtest-jsoo`) and `make test-melange` (`UNLZ4_MELANGE=true`,
`@runtest-melange`) for JS (a browser smoke test is deferred, see the tracker); explicit
`reference-build`, `reference-test`, `corpus-generate`, and `corpus-check`
development commands; `make ci` is what CI runs on every leg. JS jobs run both the core and any supported
Bytesrw adapter. Browser smoke tests import bundles without Node APIs and decode
binary bytes containing zero and values above 127.

Upstream build/run commands verified or inspected for the pinned revision:

```sh
make -C vendor/lz4/tests -j2 datagen fuzzer frametest lz4
vendor/lz4/tests/fuzzer -s1 -i100
vendor/lz4/tests/frametest -s1 -i100
# Run shell scenarios from vendor/lz4/tests with ../programs on PATH.
# Broader upstream suite, separate from OCaml conformance:
make -C vendor/lz4/tests test
```

During design research, the temporary v1.10.0 checkout built successfully.
`fuzzer -s1 -i100`, `frametest -s1 -i100` (including its basic tests), and
`test-lz4-skippable.sh` passed. The full upstream suite was not run. These
checks validate the reference tooling only; no OCaml decoder exists yet.

Do not use the upstream full suite as the ordinary library test target: it
includes C benchmarks and large scenarios. JS fixture replay never compiles C.
CI must test the standalone checkout and release archive without a populated
reference submodule. Record backend versions, fixture
digests, and test counts so omissions cannot appear as success.

Choose the standalone library's license explicitly before publishing. Upstream
`lib/` is BSD-2-Clause; other upstream directories generally use
GPL-2.0-or-later, with file-specific notices. Preserve upstream licenses in the
submodule and any redistributed artifacts. Keep GPL test programs as external
development tools; implement scenarios independently rather than copying their
code into the runtime. Record provenance and applicable notices for copied
golden samples separately from newly generated byte fixtures. See the
[upstream license](https://github.com/lz4/lz4/blob/v1.10.0/LICENSE).

Benchmark after correctness: report throughput, allocations, peak memory and
bundle size for literal-heavy, repetition-heavy, dictionary and mixed data on
all backends. The C decoder is a comparison baseline; do not promise its speed.
Only add unsafe access or backend-specific optimization after profiling and
keep it under the shared conformance suite.

## Implementation sequence and unresolved choices

1. Create the standalone project and pinned upstream submodule. Prove shared
   bytes/Int32/Int64 behavior and a minimal Bytesrw reader/writer pipeline in
   native, jsoo and Melange, including an installed consumer build. Resolve
   Melange packaging and position limits before promising adapter support.
2. Implement checked raw blocks and dictionary history; generate a small C
   oracle corpus and run identical tests on all three backends.
3. Implement XXH32 and modern frames with all block modes, checksums, limits,
   concatenation and skipping. Verify memory bounds and state-machine progress.
4. Implement Bytesrw filters, asynchronous JS examples and buffer-lifetime tests.
   Exercise installed packages in native and JS consumer projects.
5. Broaden differential/mutation coverage, browser checks, reproducible corpus
   regeneration and release-archive testing. Measure performance before tuning.

The milestone breakdown and exit criteria are in [plan.md](plan.md).

Decisions taken after the initial spike: package names `unlz4`/`unlz4-bytesrw`
(see Naming); license MIT, matching the author's sibling libraries and
compatible with upstream's BSD-2-Clause `lib/` (no upstream code is copied
into the runtime); the toolchain above; `Limits.default` as described under
Public API; and the Melange Bytesrw resolution above. Still open: publishing an
installable Melange Bytesrw adapter, which depends on upstream packaging.
Portable decoding, bounded block storage, checksum verification, deterministic
tests, and absence of C runtime dependencies remain requirements.
