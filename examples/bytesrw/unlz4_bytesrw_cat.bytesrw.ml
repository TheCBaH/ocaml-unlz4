(* unlz4_bytesrw_cat [FILE...]: writes the decompressed LZ4 frames of each FILE (or stdin) to
   stdout, through the Bytesrw reader filter. *)

open Bytesrw

let cat ic =
  let r = Bytes.Reader.of_in_channel ic in
  let w = Bytes.Writer.of_out_channel stdout in
  Bytes.Writer.write_reader ~eod:false w (Unlz4_bytesrw.decompress_reads () r);
  Out_channel.flush stdout

let () =
  set_binary_mode_out stdout true;
  let files = List.tl (Array.to_list Sys.argv) in
  match
    if files = [] then cat stdin else List.iter (fun f -> In_channel.with_open_bin f cat) files
  with
  | () -> ()
  | exception Bytes.Stream.Error e ->
      prerr_endline (Bytes.Stream.error_message e);
      exit 1
