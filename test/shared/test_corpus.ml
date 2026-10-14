(* Differential replay of the upstream-generated corpus: identical plain text and consumed length
   on every fixture, under varied input fragmentation and output capacity, plus mutations that must
   fail safely. *)

open Unlz4_test_support
open Harness
module C = Corpus
module F = Unlz4.Frame
module E = Unlz4.Error

let has opt f = List.mem opt (String.split_on_char ',' f.C.opts)

let dictionary_of f =
  match Lazy.force f.C.dict with None -> None | Some d -> Some (Unlz4.Dictionary.of_string d)

(* Frames with a dictionary ID get it from a resolver; others take it directly. *)
let frame_args f =
  match dictionary_of f with
  | None -> (None, None)
  | Some d ->
      if has "dictid=0x00000000" f then (Some d, None) else (None, Some (fun (_ : int32) -> Some d))

let decode_frame ?chunk ?out_cap f =
  let dictionary, resolve_dictionary = frame_args f in
  let o = Drive.frames ?dictionary ?resolve_dictionary ?chunk ?out_cap f.C.compressed in
  (match o.Drive.result with Ok _ -> () | Error e -> failf "%s: %s" f.C.name (show_error e));
  check_int ~msg:(f.C.name ^ " consumed") ~expected:(String.length f.C.compressed) o.Drive.consumed;
  check_string ~msg:f.C.name ~expected:(Lazy.force f.C.plain) o.Drive.output

let mutate s r =
  let b = Bytes.of_string s in
  let i = Gen.below r (Bytes.length b) in
  Bytes.set b i (Char.chr (Char.code (Bytes.get b i) lxor (1 + Gen.below r 255)));
  Bytes.unsafe_to_string b

let no_dict_frames () = List.filter (fun f -> Lazy.force f.C.dict = None) C.frames

let cases =
  [
    case "corpus: present" (fun () ->
        check ~msg:"fixtures" (List.length C.blocks >= 20 && List.length C.frames >= 10);
        check ~msg:"xxh32 vectors" (List.length C.xxh32_vectors >= 20));
    case "corpus: xxh32 vectors from upstream" (fun () ->
        let r = Gen.rng 5 in
        List.iter
          (fun (data, v) ->
            let n = String.length data in
            check_int32 ~msg:(Printf.sprintf "length %d" n) ~expected:v
              (Unlz4.Private.Xxh32.string data);
            let h = Unlz4.Private.Xxh32.create () in
            let b = Bytes.of_string data in
            let pos = ref 0 in
            while !pos < n do
              let k = min (n - !pos) (Gen.below r 40) in
              Unlz4.Private.Xxh32.update h b !pos k;
              pos := !pos + k
            done;
            check_int32
              ~msg:(Printf.sprintf "chunked length %d" n)
              ~expected:v (Unlz4.Private.Xxh32.digest h))
          C.xxh32_vectors);
    case "corpus: raw blocks" (fun () ->
        List.iter
          (fun f ->
            let plain = Lazy.force f.C.plain in
            let n = String.length plain in
            let dictionary = dictionary_of f in
            (match Unlz4.Block.decompress ?dictionary ~max_output:n f.C.compressed with
            | Ok s -> check_string ~msg:f.C.name ~expected:plain s
            | Error e -> failf "%s: %s" f.C.name (show_error e));
            (match Unlz4.Block.decompress ?dictionary ~max_output:(n + 100) f.C.compressed with
            | Ok s -> check_string ~msg:f.C.name ~expected:plain s
            | Error e -> failf "%s: %s" f.C.name (show_error e));
            if n > 0 then
              match Unlz4.Block.decompress ?dictionary ~max_output:(n - 1) f.C.compressed with
              | Error e when E.kind e = E.Limit_exceeded -> ()
              | _ -> failf "%s: undersized output accepted" f.C.name)
          C.blocks);
    case "corpus: frames, whole buffer" (fun () ->
        List.iter
          (fun f ->
            let dictionary, resolve_dictionary = frame_args f in
            match F.decompress ?dictionary ?resolve_dictionary f.C.compressed with
            | Ok s -> check_string ~msg:f.C.name ~expected:(Lazy.force f.C.plain) s
            | Error e -> failf "%s: %s" f.C.name (show_error e))
          C.frames);
    case "corpus: frames, fragmented input and output" (fun () ->
        List.iteri
          (fun i f ->
            decode_frame f;
            decode_frame
              ~chunk:(Drive.random_schedule (i + 1) 70000)
              ~out_cap:(Drive.random_schedule (i + 100) 70000)
              f;
            decode_frame ~chunk:(Drive.random_schedule (i + 200) 300) f;
            decode_frame ~out_cap:(Drive.random_schedule (i + 300) 300) f;
            if String.length f.C.compressed < 2000 then (
              decode_frame ~chunk:(fun _ -> 1) f;
              decode_frame ~out_cap:(fun _ -> 1) f))
          C.frames);
    case "corpus: blocks needing a dictionary fail without it" (fun () ->
        List.iter
          (fun f ->
            if Lazy.force f.C.dict <> None then
              let plain = Lazy.force f.C.plain in
              match Unlz4.Block.decompress ~max_output:(String.length plain) f.C.compressed with
              | Ok s when String.equal s plain ->
                  failf "%s: decoded without its dictionary" f.C.name
              | Ok _ | Error _ -> ())
          C.blocks);
    case "corpus: frames needing a dictionary fail without it" (fun () ->
        List.iter
          (fun f ->
            if Lazy.force f.C.dict <> None then
              match F.decompress f.C.compressed with
              | Ok s when String.equal s (Lazy.force f.C.plain) ->
                  failf "%s: decoded without its dictionary" f.C.name
              | Ok _ | Error _ -> ())
          C.frames);
    case "corpus: concatenated frames and skippable frames" (fun () ->
        let fs = no_dict_frames () in
        let input =
          String.concat ""
            (List.mapi
               (fun i f ->
                 Builder.skippable ~nibble:(i land 15) (String.make i 's') ^ f.C.compressed)
               fs)
        in
        let expected = String.concat "" (List.map (fun f -> Lazy.force f.C.plain) fs) in
        check_string ~expected (Drive.ok input);
        check_string ~expected
          (Drive.ok ~chunk:(Drive.random_schedule 9 5000) ~out_cap:(Drive.random_schedule 10 5000)
             input));
    case "corpus: single-frame mode stops after each frame" (fun () ->
        let fs = no_dict_frames () in
        let input = String.concat "" (List.map (fun f -> f.C.compressed) fs) in
        let rec go off = function
          | [] -> check_int ~msg:"all consumed" ~expected:(String.length input) off
          | f :: rest ->
              let o =
                Drive.frames ~mode:F.Single (String.sub input off (String.length input - off))
              in
              check_string ~msg:f.C.name ~expected:(Lazy.force f.C.plain) o.Drive.output;
              check_int ~msg:f.C.name ~expected:(String.length f.C.compressed) o.Drive.consumed;
              go (off + o.Drive.consumed) rest
        in
        go 0 fs);
    case "corpus: truncated frames" (fun () ->
        let r = Gen.rng 11 in
        List.iter
          (fun f ->
            let n = String.length f.C.compressed in
            for _ = 1 to 5 do
              let k = Gen.below r n in
              let dictionary, resolve_dictionary = frame_args f in
              match
                F.decompress ?dictionary ?resolve_dictionary (String.sub f.C.compressed 0 k)
              with
              | Error e when E.kind e = E.Truncated_input -> ()
              | Ok _ -> failf "%s cut at %d: decoded" f.C.name k
              | Error e -> failf "%s cut at %d: %s" f.C.name k (show_error e)
            done)
          C.frames);
    case "corpus: corrupted block payload with block checksums" (fun () ->
        let f = List.find (fun f -> f.C.name = "f-64k-indep-bcs") C.frames in
        (* Flip a byte inside the second block's payload. *)
        let s = f.C.compressed in
        let hdr = 7 in
        let size0 =
          Char.code s.[hdr] lor (Char.code s.[hdr + 1] lsl 8) lor (Char.code s.[hdr + 2] lsl 16)
        in
        let second = hdr + 4 + size0 + 4 in
        let b = Bytes.of_string s in
        Bytes.set b (second + 10) (Char.chr (Char.code s.[second + 10] lxor 1));
        match F.decompress (Bytes.to_string b) with
        | Error e ->
            check ~msg:(show_error e) (E.kind e = E.Checksum_mismatch && E.block_index e = Some 1)
        | Ok _ -> failf "decoded");
    case "corpus: corrupted content checksum" (fun () ->
        let f = List.find (fun f -> f.C.name = "f-64k-linked") C.frames in
        let s = f.C.compressed in
        let n = String.length s in
        let b = Bytes.of_string s in
        Bytes.set b (n - 1) (Char.chr (Char.code s.[n - 1] lxor 0x80));
        match F.decompress (Bytes.to_string b) with
        | Error e ->
            check ~msg:(show_error e) (E.kind e = E.Checksum_mismatch && E.block_index e = None)
        | Ok _ -> failf "decoded");
    case "corpus: random mutations fail safely" (fun () ->
        let r = Gen.rng 12 in
        List.iter
          (fun f ->
            for _ = 1 to 40 do
              let m = mutate f.C.compressed r in
              match f.C.kind with
              | C.Frame -> (
                  let dictionary, resolve_dictionary = frame_args f in
                  match F.decompress ?dictionary ?resolve_dictionary m with
                  | Ok s ->
                      if has "ccs=1" f && not (String.equal s (Lazy.force f.C.plain)) then
                        failf "%s: corrupted frame passed its content checksum" f.C.name
                  | Error _ -> ())
              | C.Block -> (
                  let n = String.length (Lazy.force f.C.plain) in
                  match
                    Unlz4.Block.decompress ?dictionary:(dictionary_of f) ~max_output:(n + 64) m
                  with
                  | Ok _ | Error _ -> ())
            done)
          C.fixtures);
  ]
