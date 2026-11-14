(** Pure OCaml LZ4 decompression.

    Decodes LZ4 raw blocks ({!Block}) and the LZ4 frame format ({!Frame}): independent and linked
    blocks, stored blocks, block/content checksums, content sizes, dictionaries, concatenated and
    skippable frames. LZ4 HC output uses the same block format and decodes the same way. The
    legacy frame format is recognized and rejected with [Unsupported_feature].

    The library depends only on the standard library and gives the same results natively (63- or
    31-bit [int]), under js_of_ocaml, and under Melange.

    Invalid API arguments (ranges, options) raise [Invalid_argument]; malformed compressed data is
    reported as an {!Error.t}. *)

(** Decoding errors. *)
module Error : sig
  type kind =
    | Invalid_block  (** A block breaks the block format. *)
    | Invalid_frame  (** A frame breaks the frame format, or trailing bytes are not a frame. *)
    | Truncated_input  (** The input ends inside a block, frame, or before any frame. *)
    | Unsupported_feature  (** A frame version or the legacy format. *)
    | Missing_dictionary  (** A frame needs a dictionary that was not supplied. *)
    | Dictionary_id_mismatch  (** The supplied dictionary has a different ID. *)
    | Checksum_mismatch  (** Descriptor, block or content checksum. *)
    | Content_size_mismatch  (** The decoded size differs from the declared content size. *)
    | Limit_exceeded  (** A {!Limits} bound or the output space was exceeded. *)

  type t

  val kind : t -> kind

  val compressed_offset : t -> int64
  (** Offset of the offending field or token: in the compressed stream for frames, from [src_off]
      for raw blocks. *)

  val decoded_offset : t -> int64
  (** Number of decoded bytes that precede the error. For an error inside a frame's block it
      includes the bytes the block had decoded before the fault, which the frame decoder does not
      deliver, so it can exceed [Frame.total_out]; [Block.decompress_into] leaves that prefix in
      [dst]. *)

  val frame_index : t -> int option
  (** Zero-based index of the modern frame, when the error is inside one. *)

  val block_index : t -> int option
  (** Zero-based index of the data block within the frame, when the error is in a block. *)

  val message : t -> string

  val pp_kind : Format.formatter -> kind -> unit
  (** E.g. [invalid block]. *)

  val pp : Format.formatter -> t -> unit
  (** One line: [lz4: kind: message (compressed offset C, decoded offset D, frame F block B)].
      [Format.asprintf "%a" pp e] gives it as a string. *)
end

(** Dictionaries. *)
module Dictionary : sig
  type t

  val of_bytes : ?id:int32 -> bytes -> t
  (** [of_bytes ?id b] copies the last 64 KiB of [b] (all of it if shorter); later changes to [b]
      do not affect the dictionary. [id] is the frame dictionary ID it stands for, if any. *)

  val of_string : ?id:int32 -> string -> t
  val id : t -> int32 option

  val length : t -> int
  (** The number of bytes kept, at most 65536. *)
end

(** Resource bounds for frame decoding. *)
module Limits : sig
  type t

  val default : t
  (** Every standard block size (up to 4 MiB); input, output, frame and skipped-byte totals
      unbounded. *)

  val make :
    ?max_block_size:int ->
    ?max_input:int64 ->
    ?max_output:int64 ->
    ?max_frames:int64 ->
    ?max_skipped:int64 ->
    unit ->
    t
  (** [max_block_size] (default 4 MiB, at least 64 KiB) rejects frames advertising a larger block
      maximum before allocating. [max_input]/[max_output] bound the compressed bytes consumed and
      decoded bytes produced; [max_frames] the number of modern and skippable frames;
      [max_skipped] the total skippable payload. Defaults are unbounded. Raises [Invalid_argument]
      on a value out of range. *)

  val max_block_size : t -> int
  val max_input : t -> int64
  val max_output : t -> int64
  val max_frames : t -> int64
  val max_skipped : t -> int64

  val with_max_output : t -> int64 -> t
  (** [with_max_output t n] is [t] with [max_output] replaced by [n]. *)
end

(** Raw LZ4 blocks: a compressed range with no header, whose decoded size the caller bounds.

    Blocks are validated against the format specification: offset zero is rejected, the last
    sequence carries only literals, and when the block has a match the last 5 bytes are literals and
    the last match starts at least 12 bytes before the end. liblz4's safe decoder is looser in
    places that depend on the output capacity: it can accept an offset of zero, four final literals
    after a long match (19+ bytes; three after 274+), and, with a dictionary or a capacity above
    the decoded size, fewer than 5 final literals or a last match closer than 12 bytes to the end.
    Conversely it rejects every block but a lone zero token when the capacity is zero. A block that
    this decoder accepts is accepted by liblz4 with the same output (checked by [make fuzz]);
    blocks from conforming compressors are decoded identically. *)
module Block : sig
  val decompress_into :
    ?dictionary:Dictionary.t ->
    ?prefix:int ->
    src:bytes ->
    src_off:int ->
    src_len:int ->
    dst:bytes ->
    dst_off:int ->
    dst_len:int ->
    unit ->
    (int, Error.t) result
  (** Decodes exactly [src.[src_off .. src_off + src_len - 1]] into [dst] from [dst_off], writing
      at most [dst_len] bytes, and returns the number written. [dictionary] is the history that
      precedes the block (for linked blocks, the tail of the previously decoded data). [prefix]
      (default 0, at most [dst_off]) is the number of bytes of history already in [dst] just before
      [dst_off], of which the last 64 KiB can be referenced; with linked blocks decoded into one
      buffer it replaces passing a [dictionary] per block. Errors:
      [Invalid_block], [Truncated_input], or [Limit_exceeded] when the output does not fit. On
      error [dst.[dst_off ..]] may hold a decoded prefix; bytes outside the range are untouched.
      Raises [Invalid_argument] for bad ranges, an invalid [prefix], or when [src == dst]. *)

  val decompress_string_into :
    ?dictionary:Dictionary.t ->
    ?prefix:int ->
    src:string ->
    src_off:int ->
    src_len:int ->
    dst:bytes ->
    dst_off:int ->
    dst_len:int ->
    unit ->
    (int, Error.t) result
  (** {!decompress_into} reading its input from a string without copying it. This is sound because
      the decoder never writes [src] and a [dst] that is not [src] cannot alias a string; the
      [src == dst] check still applies to the underlying buffer. *)

  val decompress : ?dictionary:Dictionary.t -> max_output:int -> string -> (string, Error.t) result
  (** [decompress ~max_output s] decodes the block [s] whose decoded size is at most
      [max_output]. A buffer of [max_output] bytes is allocated up front, so keep it a tight
      bound for untrusted input. *)
end

(** The LZ4 frame format, decoded incrementally. *)
module Frame : sig
  type t

  type mode =
    | Single  (** Stop after one modern frame (and any skippable frames before it). *)
    | Concatenated  (** Decode every frame until input EOF (the default). *)

  type status =
    | Need_input  (** All input was consumed; supply more (or [eof:true]). *)
    | Need_output  (** The output range is full and decoded data is pending. *)
    | Frame_end
        (** A modern frame was completed and verified. [consumed] stops at its end. In [Single]
            mode this is terminal and bytes after the frame are left to the caller. *)
    | Stream_end  (** [Concatenated] mode: input EOF at a frame boundary. Terminal. *)

  type progress = { consumed : int; produced : int; status : status }

  type info = {
    block_max_size : int;
    block_independent : bool;
    block_checksum : bool;
    content_checksum : bool;
    content_size : int64 option;
    dictionary_id : int32 option;
  }
  (** A modern frame's descriptor. *)

  val create :
    ?limits:Limits.t ->
    ?mode:mode ->
    ?dictionary:Dictionary.t ->
    ?resolve_dictionary:(int32 -> Dictionary.t option) ->
    unit ->
    t
  (** A decoder. For a frame with a dictionary ID, [resolve_dictionary] is called once, after the
      descriptor is validated and before the first block; without a resolver [dictionary] is used.
      A dictionary whose own ID differs is an error. Frames without an ID use [dictionary] if
      given. *)

  val decode :
    t ->
    src:bytes ->
    src_off:int ->
    src_len:int ->
    eof:bool ->
    dst:bytes ->
    dst_off:int ->
    dst_len:int ->
    unit ->
    (progress, Error.t) result
  (** Consumes input from [src.[src_off ..]] and writes decoded bytes to [dst.[dst_off ..]],
      reporting how much of each was used. No reference to [src] or [dst] is kept. [eof:true]
      means the range is the last input; later calls must pass [eof:true] and exactly the
      unconsumed rest. Decoded output can be delivered before a later content checksum or size
      error; success is only established by [Frame_end]/[Stream_end]. Errors are terminal: later
      calls return the same error, whatever [eof] they pass. Terminal statuses are sticky. Raises [Invalid_argument] for bad
      ranges, [src == dst], or a violated [eof] contract (checked after a sticky error is returned). An exception raised by a [resolve_dictionary] callback, or [Out_of_memory] while allocating buffers, propagates after the call's progress is counted in [total_in]/[total_out]; the decoder is then unusable and later calls raise [Invalid_argument]. *)

  val decode_string :
    t ->
    src:string ->
    src_off:int ->
    src_len:int ->
    eof:bool ->
    dst:bytes ->
    dst_off:int ->
    dst_len:int ->
    unit ->
    (progress, Error.t) result
  (** {!decode} reading its input from a string without copying it; the decoder never writes its
      source, so this is sound. *)

  val reset : t -> unit
  (** Returns [t] to its state after {!create} (same limits, mode, dictionary and resolver),
      clearing errors, counters and a decoder disabled by an exception, but keeping its buffers for
      reuse. *)

  val info : t -> info option
  (** The descriptor of the current or last modern frame. *)

  val total_in : t -> int64
  (** Compressed bytes consumed so far. *)

  val total_out : t -> int64
  (** Decoded bytes written so far. After an error this includes what the failing call wrote, so
      [dst] holds [total_out - previous total_out] bytes of decoded prefix from [dst_off]. *)

  val decompress :
    ?limits:Limits.t ->
    ?dictionary:Dictionary.t ->
    ?resolve_dictionary:(int32 -> Dictionary.t option) ->
    string ->
    (string, Error.t) result
  (** Decodes a whole concatenated stream, returning the output only once everything is verified.
      Output is also capped at [Sys.max_string_length]. *)

  val decompress_with :
    ?limits:Limits.t ->
    ?dictionary:Dictionary.t ->
    ?resolve_dictionary:(int32 -> Dictionary.t option) ->
    ?buffer_size:int ->
    read:(bytes -> int -> int -> int) ->
    write:(bytes -> int -> int -> unit) ->
    unit ->
    (unit, Error.t) result
  (** Decodes a concatenated stream from a blocking source to a sink, with bounded memory.
      [buffer_size] (default 64 KiB, at least 1) sizes the input and output buffers. A block is
      decoded in place, without being collected first, when the buffer holds the whole block and its
      checksum, so a size of the frame's block maximum plus 8 or more gives the decoder more such
      chances; a smaller buffer still decodes correctly.
      [read buf off len] stores at most [len] bytes at [buf.[off]] and returns their number, [0]
      meaning end of input, like [Stdlib.input]; it is not called again after [0]. [write buf off
      len] receives decoded bytes, valid only during the call. [read] is called only when the
      decoder needs input, after all pending output was written. On error, [write] has received
      every byte decoded before it; as with {!decode}, that can precede a later checksum or size
      error. Exceptions from [read] and [write] pass through. Raises [Invalid_argument] if [read]
      returns a count outside [0 .. len].

      For channels: [decompress_with ~read:(input ic) ~write:(output oc) ()]. *)
end

(** Not part of the stable API; exposed for tests. *)
module Private : sig
  module Xxh32 : sig
    type t

    val create : unit -> t
    val reset : t -> unit
    val update : t -> bytes -> int -> int -> unit
    val digest : t -> int32
    val bytes : bytes -> int -> int -> int32
    val string : string -> int32
  end
end
