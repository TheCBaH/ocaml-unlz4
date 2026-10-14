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

let kind_to_string = function
  | Invalid_block -> "invalid block"
  | Invalid_frame -> "invalid frame"
  | Truncated_input -> "truncated input"
  | Unsupported_feature -> "unsupported feature"
  | Missing_dictionary -> "missing dictionary"
  | Dictionary_id_mismatch -> "dictionary ID mismatch"
  | Checksum_mismatch -> "checksum mismatch"
  | Content_size_mismatch -> "content size mismatch"
  | Limit_exceeded -> "limit exceeded"

let to_string e =
  let where =
    match (e.frame_index, e.block_index) with
    | None, _ -> ""
    | Some f, None -> Printf.sprintf ", frame %d" f
    | Some f, Some b -> Printf.sprintf ", frame %d block %d" f b
  in
  Printf.sprintf "lz4: %s: %s (compressed offset %Ld, decoded offset %Ld%s)" (kind_to_string e.kind)
    e.message e.compressed_offset e.decoded_offset where
