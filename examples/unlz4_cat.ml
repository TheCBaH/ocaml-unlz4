(* unlz4_cat [FILE...]: writes the decompressed LZ4 frames of each FILE (or stdin) to stdout, with
   standard library channels. *)

let cat ic =
  match Unlz4.Frame.decompress_with ~read:(input ic) ~write:(output stdout) () with
  | Ok () -> ()
  | Error e ->
      flush stdout;
      prerr_endline (Unlz4.Error.to_string e);
      exit 1

let () =
  set_binary_mode_out stdout true;
  match List.tl (Array.to_list Sys.argv) with
  | [] ->
      set_binary_mode_in stdin true;
      cat stdin
  | files -> List.iter (fun f -> In_channel.with_open_bin f cat) files
