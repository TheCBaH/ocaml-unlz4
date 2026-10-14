(** LZ4 frame decompression filters for {{:https://erratique.ch/software/bytesrw}Bytesrw}: an
    example of a host driver over {!Unlz4.Frame.decode}.

    Errors are raised as {!Bytesrw.Bytes.Stream.Error} with the {!Error} case, format ["lz4"].
    Exceptions raised by the underlying reader or writer pass through unchanged. After an error
    the filter raises the same error again.

    Bytesrw positions are [int]s. The filters cap their decoded output so that their own position
    never exceeds [max_int], reporting [Limit_exceeded] first. The wrapped reader's or writer's
    own position must not overflow either; that is the caller's responsibility. *)

open Bytesrw

type Bytes.Stream.error += Error of Unlz4.Error.t

val decompress_reads :
  ?limits:Unlz4.Limits.t ->
  ?mode:Unlz4.Frame.mode ->
  ?dictionary:Unlz4.Dictionary.t ->
  ?resolve_dictionary:(int32 -> Unlz4.Dictionary.t option) ->
  unit ->
  Bytes.Reader.filter
(** [decompress_reads () r] reads the decompressed frames of [r]. Its position starts at [pos]
    (default [0]) and its slices are at most [slice_length] (default {!Bytes.Slice.io_buffer_size})
    bytes; each is valid until the next read. In [Single] mode (default [Concatenated]) the
    bytes after the first modern frame are pushed back on [r] before {!Bytes.Slice.eod} is
    returned, so [r] can be read again from there. While the filter is in use [r] must not be
    read directly. *)

val decompress_writes :
  ?limits:Unlz4.Limits.t ->
  ?dictionary:Unlz4.Dictionary.t ->
  ?resolve_dictionary:(int32 -> Unlz4.Dictionary.t option) ->
  unit ->
  Bytes.Writer.filter
(** [decompress_writes () ~eod w] decompresses the concatenated frames written on it and writes
    the result on [w], in slices of at most [w]'s slice length. The input is fully consumed before
    each write returns. On {!Bytes.Slice.eod} the stream is verified to end at a frame boundary;
    only then, and only if [eod] is [true], is {!Bytes.Slice.eod} written on [w]. *)
