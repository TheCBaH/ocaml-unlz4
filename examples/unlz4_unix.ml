[@@@ai_disclosure "ai-generated"]
[@@@ai_provider "Anthropic, OpenAI"]

(* unlz4_unix [FILE]: writes the decompressed LZ4 frames of FILE (or stdin) to stdout, with Unix
   file descriptors. *)

let rec read fd b off len =
  try Unix.read fd b off len with Unix.Unix_error (Unix.EINTR, _, _) -> read fd b off len

let rec write fd b off len =
  if len > 0 then
    match Unix.single_write fd b off len with
    | n -> write fd b (off + n) (len - n)
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> write fd b off len

let () =
  let fd =
    match Sys.argv with
    | [| _ |] -> Unix.stdin
    | [| _; f |] -> Unix.openfile f [ Unix.O_RDONLY ] 0
    | _ ->
        prerr_endline "usage: unlz4_unix [FILE]";
        exit 2
  in
  Unlz4.Frame.decompress_with ~read:(read fd) ~write:(write Unix.stdout) ()
  |> Result.iter_error (fun e ->
      Format.eprintf "%a@." Unlz4.Error.pp e;
      exit 1)
