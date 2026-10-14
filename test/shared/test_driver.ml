[@@@ai_disclosure "ai-generated"]
[@@@ai_provider "Anthropic, OpenAI"]

(* Frame.decompress_with: the callback driver used for channels and file descriptors. *)

open Unlz4_test_support
open Harness
module C = Corpus
module F = Unlz4.Frame
module E = Unlz4.Error

let hello = Builder.frame [ Builder.Compressed (Builder.literal_block "hello, world") ]
let frames = List.filter (fun f -> Lazy.force f.C.dict = None) C.frames
let stream = String.concat "" (List.map (fun f -> f.C.compressed) frames)
let plain = String.concat "" (List.map (fun f -> Lazy.force f.C.plain) frames)

(* Serves [s] in reads of at most [n] bytes, failing if read is called again after end of input.
   The output is collected from [write], whose buffer is poisoned after each call: a driver that
   reused delivered bytes would be caught. *)
let run ?limits ?dictionary ?resolve_dictionary ?(n = 65536) s =
  let pos = ref 0 and ended = ref false in
  let read b off len =
    if !ended then failf "read after end of input";
    let k = min (min n len) (String.length s - !pos) in
    Bytes.blit_string s !pos b off k;
    pos := !pos + k;
    if k = 0 then ended := true;
    k
  in
  let out = Buffer.create 1024 in
  let write b off len =
    Buffer.add_subbytes out b off len;
    Bytes.fill b off len '\xAA'
  in
  let r = F.decompress_with ?limits ?dictionary ?resolve_dictionary ~read ~write () in
  (r, Buffer.contents out)

let ok ?msg ?n ~expected s =
  match run ?n s with
  | Ok (), out -> check_string ?msg ~expected out
  | Error e, _ -> failf "%s" (show_error e)

let error s = match run s with Ok (), _ -> failf "no error" | Error e, out -> (E.kind e, out)

let cases =
  [
    case "driver: read sizes" (fun () ->
        List.iter
          (fun n -> ok ~msg:(string_of_int n) ~n ~expected:plain stream)
          [ 1; 7; 4096; 65536; 1_000_000 ]);
    case "driver: empty, skip-only and dictionary streams" (fun () ->
        check ~msg:"no frame" (fst (error "") = E.Truncated_input);
        ok ~expected:"" (Builder.frame []);
        ok ~expected:"" (Builder.skippable "abc");
        List.iter
          (fun f ->
            match Lazy.force f.C.dict with
            | None -> ()
            | Some d ->
                let d = Unlz4.Dictionary.of_string d in
                let r, out =
                  run ~dictionary:d ~resolve_dictionary:(fun _ -> Some d) f.C.compressed
                in
                (match r with Ok () -> () | Error e -> failf "%s: %s" f.C.name (show_error e));
                check_string ~msg:f.C.name ~expected:(Lazy.force f.C.plain) out)
          C.frames);
    case "driver: output is written before a later error" (fun () ->
        let k, out = error (hello ^ "junk") in
        check ~msg:"invalid frame" (k = E.Invalid_frame);
        check_string ~msg:"prefix" ~expected:"hello, world" out;
        let k, _ = error (String.sub hello 0 10) in
        check ~msg:"truncated" (k = E.Truncated_input);
        let limits = Unlz4.Limits.make ~max_output:5L () in
        match run ~limits hello with
        | Error e, _ -> check ~msg:"limit" (E.kind e = E.Limit_exceeded)
        | Ok (), _ -> failf "no limit error");
    case "driver: callback exceptions and invalid counts" (fun () ->
        let read _ _ _ = raise Exit and write _ _ _ = () in
        (match F.decompress_with ~read ~write () with _ -> failf "read" | exception Exit -> ());
        let read b off _ =
          Bytes.blit_string hello 0 b off (String.length hello);
          String.length hello
        in
        let write _ _ _ = raise Exit in
        (match F.decompress_with ~read ~write () with _ -> failf "write" | exception Exit -> ());
        raises_invalid_arg ~msg:"negative" (fun () ->
            F.decompress_with ~read:(fun _ _ _ -> -1) ~write ());
        raises_invalid_arg ~msg:"too many" (fun () ->
            F.decompress_with ~read:(fun _ _ len -> len + 1) ~write ()));
    case "driver: pending output is written before the next read" (fun () ->
        (* Ten blocks of 65532 bytes from about 30 compressed bytes each: the whole frame arrives
           in the first read, and the next read (end of input) must come only after all the
           output, many output buffers' worth, was written. *)
        let blk = Builder.block [ ("z", Some (1, 65526)); ("zzzzz", None) ] in
        let f = Builder.frame (List.init 10 (fun _ -> Builder.Compressed blk)) in
        let total = 10 * 65532 in
        let written = ref 0 and served = ref false in
        let read b off len =
          if !served then (
            check_int ~msg:"written before the second read" ~expected:total !written;
            0)
          else (
            if len < String.length f then failf "read buffer %d" len;
            Bytes.blit_string f 0 b off (String.length f);
            served := true;
            String.length f)
        in
        let write _ _ len = written := !written + len in
        (match F.decompress_with ~read ~write () with
        | Ok () -> ()
        | Error e -> failf "%s" (show_error e));
        check_int ~msg:"written" ~expected:total !written);
  ]
