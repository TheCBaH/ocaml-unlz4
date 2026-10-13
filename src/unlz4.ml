module Error = struct
  include Error

  let kind e = e.kind
  let compressed_offset e = e.compressed_offset
  let decoded_offset e = e.decoded_offset
  let frame_index e = e.frame_index
  let block_index e = e.block_index
  let message e = e.message
end

module Dictionary_impl = Dictionary

module Dictionary = struct
  type t = Dictionary.t

  let of_bytes = Dictionary.of_bytes
  let of_string = Dictionary.of_string
  let id (d : t) = d.id
  let length (d : t) = Bytes.length d.data
end

module Limits = struct
  type t = Limits.t

  let default = Limits.default
  let make = Limits.make
  let max_block_size (t : t) = t.max_block_size
  let max_input (t : t) = t.max_input
  let max_output (t : t) = t.max_output
  let max_frames (t : t) = t.max_frames
  let max_skipped (t : t) = t.max_skipped
  let with_max_output = Limits.with_max_output
end

module Block = struct
  let decompress_into ?(dictionary = Dictionary_impl.empty) ~src ~src_off ~src_len ~dst ~dst_off
      ~dst_len () =
    if src_off < 0 || src_len < 0 || src_off > Bytes.length src - src_len then
      invalid_arg "Unlz4.Block.decompress_into: invalid source range";
    if dst_off < 0 || dst_len < 0 || dst_off > Bytes.length dst - dst_len then
      invalid_arg "Unlz4.Block.decompress_into: invalid destination range";
    if src == dst then
      invalid_arg "Unlz4.Block.decompress_into: source and destination are the same buffer";
    let ext = dictionary.Dictionary_impl.data in
    Buf.touch dst dst_off dst_len;
    match
      Block_decoder.decode ~src ~sp:src_off ~se:(src_off + src_len) ~dst ~hist:dst_off ~dp0:dst_off
        ~de:(dst_off + dst_len) ~ext ~ext_off:0 ~ext_len:(Bytes.length ext)
    with
    | e -> Ok (e - dst_off)
    | exception Block_decoder.Fail (f, ip, op, message) ->
        let kind =
          match f with
          | Malformed -> Error.Invalid_block
          | Truncated -> Error.Truncated_input
          | Overflow -> Error.Limit_exceeded
        in
        Error
          {
            Error.kind;
            compressed_offset = Int64.of_int (ip - src_off);
            decoded_offset = Int64.of_int (op - dst_off);
            frame_index = None;
            block_index = None;
            message;
          }

  let decompress ?dictionary ~max_output s =
    if max_output < 0 then invalid_arg "Unlz4.Block.decompress: negative max_output";
    let src = Bytes.of_string s and dst = Buf.create max_output in
    match
      decompress_into ?dictionary ~src ~src_off:0 ~src_len:(Bytes.length src) ~dst ~dst_off:0
        ~dst_len:max_output ()
    with
    | Ok n -> Ok (Bytes.sub_string dst 0 n)
    | Error _ as e -> e
end

module Frame = Frame_decoder

module Private = struct
  module Xxh32 = Xxh32
end
