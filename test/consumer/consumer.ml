(* Built by `make consumer-test` against the installed package only. *)

(* An LZ4 frame of "hello, world": one literal-only block, no checksums. *)
let frame = "\x04\x22\x4d\x18\x60\x40\x82\x0d\x00\x00\x00\xc0hello, world\x00\x00\x00\x00"

let () =
  let direct = match Unlz4.Frame.decompress frame with Ok s -> s | Error e -> failwith (Format.asprintf "%a" Unlz4.Error.pp e) in
  let fed = ref false and out = Buffer.create 16 in
  let read b off _ =
    if !fed then 0
    else (
      fed := true;
      Bytes.blit_string frame 0 b off (String.length frame);
      String.length frame)
  in
  (match Unlz4.Frame.decompress_with ~read ~write:(Buffer.add_subbytes out) () with
  | Ok () -> ()
  | Error e -> failwith (Format.asprintf "%a" Unlz4.Error.pp e));
  assert (direct = "hello, world" && Buffer.contents out = direct);
  print_endline "consumer: ok"
