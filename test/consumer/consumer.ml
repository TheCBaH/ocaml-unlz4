(* Built by `make consumer-test` against the installed packages only. *)

open Bytesrw

(* An LZ4 frame of "hello, world": one literal-only block, no checksums. *)
let frame = "\x04\x22\x4d\x18\x60\x40\x82\x0d\x00\x00\x00\xc0hello, world\x00\x00\x00\x00"

let () =
  let direct = match Unlz4.Frame.decompress frame with Ok s -> s | Error e -> failwith (Unlz4.Error.to_string e) in
  let filtered = Bytes.Reader.to_string (Unlz4_bytesrw.decompress_reads () (Bytes.Reader.of_string frame)) in
  assert (direct = "hello, world" && filtered = direct);
  print_endline "consumer: ok"
