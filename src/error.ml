type kind =
  | Invalid_block
  | Invalid_frame
  | Truncated_input
  | Unsupported_feature
  | Missing_dictionary
  | Dictionary_id_mismatch
  | Checksum_mismatch
  | Content_size_mismatch
  | Limit_exceeded

type t = {
  kind : kind;
  compressed_offset : int64;
  decoded_offset : int64;
  frame_index : int option;
  block_index : int option;
  message : string;
}

let kind_name = function
  | Invalid_block -> "invalid block"
  | Invalid_frame -> "invalid frame"
  | Truncated_input -> "truncated input"
  | Unsupported_feature -> "unsupported feature"
  | Missing_dictionary -> "missing dictionary"
  | Dictionary_id_mismatch -> "dictionary ID mismatch"
  | Checksum_mismatch -> "checksum mismatch"
  | Content_size_mismatch -> "content size mismatch"
  | Limit_exceeded -> "limit exceeded"

let pp_kind ppf k = Format.pp_print_string ppf (kind_name k)

let pp ppf e =
  Format.fprintf ppf "lz4: %a: %s (compressed offset %Ld, decoded offset %Ld" pp_kind e.kind
    e.message e.compressed_offset e.decoded_offset;
  (match (e.frame_index, e.block_index) with
  | None, _ -> ()
  | Some f, None -> Format.fprintf ppf ", frame %d" f
  | Some f, Some b -> Format.fprintf ppf ", frame %d block %d" f b);
  Format.pp_print_string ppf ")"
