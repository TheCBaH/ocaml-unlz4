[@@@ai_disclosure "ai-generated"]
[@@@ai_provider "Anthropic, OpenAI"]

(* The Bytesrw adapter example, natively. *)

open Bytesrw
open Unlz4_test_support
open Harness
module C = Corpus
module F = Unlz4.Frame
module E = Unlz4.Error
module U = Unlz4_bytesrw

let hello = Builder.frame [ Builder.Compressed (Builder.literal_block "hello, world") ]
let frames = List.filter (fun f -> Lazy.force f.C.dict = None) C.frames
let stream = String.concat "" (List.map (fun f -> f.C.compressed) frames)
let plain = String.concat "" (List.map (fun f -> Lazy.force f.C.plain) frames)

let read_all ?mode ?slice_length ?(src_slice = 65536) ?pos s =
  let r = Bytes.Reader.of_string ~slice_length:src_slice s in
  let d = U.decompress_reads ?mode () ?pos ?slice_length r in
  (Bytes.Reader.to_string d, r)

(* A reader that serves [s] in slices of [n] from one reused buffer, overwriting the previous
   slice with garbage before each read: a filter that kept a slice too long would see it. *)
let poisoned_reader s n =
  let buf = Bytes.create n and pos = ref 0 in
  Bytes.Reader.make ~slice_length:n (fun () ->
      Bytes.fill buf 0 n '\xAA';
      if !pos >= String.length s then Bytes.Slice.eod
      else
        let k = min n (String.length s - !pos) in
        Bytes.blit_string s !pos buf 0 k;
        pos := !pos + k;
        Bytes.Slice.make buf ~first:0 ~length:k)

let lz4_error f =
  match f () with _ -> failf "no error raised" | exception Bytes.Stream.Error (U.Error e, _) -> e

let write_all ?(eod = true) ?(in_slice = 65536) ?(out_slice = 65536) s =
  let b = Buffer.create 1024 in
  let max_seen = ref 0 in
  let w =
    Bytes.Writer.make ~slice_length:out_slice (fun sl ->
        if not (Bytes.Slice.is_eod sl) then (
          max_seen := max !max_seen (Bytes.Slice.length sl);
          Buffer.add_string b (Bytes.Slice.to_string sl)))
  in
  let d = U.decompress_writes () ~eod w in
  (* Feed from a reused buffer that is poisoned after each write returns. *)
  let tmp = Bytes.create in_slice in
  let pos = ref 0 in
  while !pos < String.length s do
    let k = min in_slice (String.length s - !pos) in
    Bytes.blit_string s !pos tmp 0 k;
    Bytes.Writer.write d (Bytes.Slice.make tmp ~first:0 ~length:k);
    Bytes.fill tmp 0 k '\x55';
    pos := !pos + k
  done;
  Bytes.Writer.write_eod d;
  if !max_seen > out_slice then failf "downstream slice %d > %d" !max_seen out_slice;
  (Buffer.contents b, w)

let cases =
  [
    case "bytesrw: reads, slice lengths" (fun () ->
        List.iter
          (fun (src_slice, slice_length) ->
            check_string
              ~msg:(Printf.sprintf "%d/%d" src_slice slice_length)
              ~expected:plain
              (fst (read_all ~src_slice ~slice_length stream)))
          [ (1, 65536); (7, 100); (4096, 1); (65536, 4096); (1_000_000, 65536) ]);
    case "bytesrw: reads, empty and skip-only streams" (fun () ->
        check_string ~expected:"" (fst (read_all (Builder.frame [])));
        check_string ~expected:"" (fst (read_all (Builder.skippable "abc"))));
    case "bytesrw: reads, poisoned source slices" (fun () ->
        List.iter
          (fun n ->
            let d = U.decompress_reads () (poisoned_reader stream n) in
            check_string ~msg:(string_of_int n) ~expected:plain (Bytes.Reader.to_string d))
          [ 1; 13; 1000; 70000 ]);
    case "bytesrw: reads, output slices are bounded and copies stay valid" (fun () ->
        let r = Bytes.Reader.of_string stream in
        let d = U.decompress_reads () ~slice_length:333 r in
        let b = Buffer.create 1024 in
        let rec go () =
          let s = Bytes.Reader.read d in
          if not (Bytes.Slice.is_eod s) then (
            if Bytes.Slice.length s > 333 then failf "slice %d" (Bytes.Slice.length s);
            Buffer.add_string b (Bytes.Slice.to_string s);
            go ())
        in
        go ();
        check_string ~expected:plain (Buffer.contents b);
        check_int ~msg:"position" ~expected:(String.length plain) (Bytes.Reader.pos d));
    case "bytesrw: reads, single mode pushes back the rest" (fun () ->
        let tail = "and the rest" in
        List.iter
          (fun src_slice ->
            let out, r =
              read_all ~mode:F.Single ~src_slice (Builder.skippable "x" ^ hello ^ tail)
            in
            check_string ~msg:"frame" ~expected:"hello, world" out;
            check_string
              ~msg:(Printf.sprintf "rest, slices of %d" src_slice)
              ~expected:tail (Bytes.Reader.to_string r))
          [ 1; 5; 1000 ];
        let out, r = read_all ~mode:F.Single hello in
        check_string ~expected:"hello, world" out;
        check_string ~msg:"nothing left" ~expected:"" (Bytes.Reader.to_string r));
    case "bytesrw: reads, errors" (fun () ->
        let e = lz4_error (fun () -> read_all (String.sub hello 0 10)) in
        check ~msg:"truncated" (E.kind e = E.Truncated_input);
        let d = U.decompress_reads () (Bytes.Reader.of_string (hello ^ "junk")) in
        let e1 = lz4_error (fun () -> Bytes.Reader.to_string d) in
        check ~msg:"garbage" (E.kind e1 = E.Invalid_frame);
        let e2 = lz4_error (fun () -> Bytes.Reader.read d) in
        check ~msg:"sticky" (e1 == e2);
        match read_all "junk" with
        | _ -> failf "no error"
        | exception Bytes.Stream.Error err ->
            let m = Bytes.Stream.error_message err in
            let contains sub =
              let n = String.length sub in
              let rec go i = i + n <= String.length m && (String.sub m i n = sub || go (i + 1)) in
              go 0
            in
            check ~msg:m (contains "lz4" && contains "unknown magic number"));
    case "bytesrw: upstream and downstream exceptions pass through" (fun () ->
        let r = Bytes.Reader.make (fun () -> raise Exit) in
        (match Bytes.Reader.read (U.decompress_reads () r) with
        | _ -> failf "no exception"
        | exception Exit -> ());
        let w = Bytes.Writer.make (fun _ -> raise Exit) in
        let d = U.decompress_writes () ~eod:true w in
        match Bytes.Writer.write_string d hello with
        | _ -> failf "no exception"
        | exception Exit -> ());
    case "bytesrw: reads, position cap" (fun () ->
        (match read_all ~pos:(max_int - 12) hello with
        | out, _ -> check_string ~expected:"hello, world" out);
        let e = lz4_error (fun () -> read_all ~pos:(max_int - 11) hello) in
        check ~msg:"limit" (E.kind e = E.Limit_exceeded));
    case "bytesrw: writes, slice lengths and poisoned inputs" (fun () ->
        List.iter
          (fun (in_slice, out_slice) ->
            check_string
              ~msg:(Printf.sprintf "%d/%d" in_slice out_slice)
              ~expected:plain
              (fst (write_all ~in_slice ~out_slice stream)))
          [ (1, 65536); (7, 100); (4096, 1); (65536, 4096) ]);
    case "bytesrw: writes, eod propagation" (fun () ->
        let _, w = write_all ~eod:true hello in
        raises_invalid_arg ~msg:"downstream ended" (fun () -> Bytes.Writer.write_string w "x");
        let b = Buffer.create 16 in
        let w = Bytes.Writer.of_buffer b in
        let d = U.decompress_writes () ~eod:false w in
        Bytes.Writer.write_string d hello;
        Bytes.Writer.write_eod d;
        Bytes.Writer.write_string w "!";
        check_string ~expected:"hello, world!" (Buffer.contents b));
    case "bytesrw: writes, errors" (fun () ->
        let e = lz4_error (fun () -> write_all (String.sub hello 0 10)) in
        check ~msg:"truncated" (E.kind e = E.Truncated_input);
        let b = Buffer.create 16 in
        let w = Bytes.Writer.of_buffer b in
        let d = U.decompress_writes () ~eod:true w in
        let e1 = lz4_error (fun () -> Bytes.Writer.write_string d "junk") in
        let e2 = lz4_error (fun () -> Bytes.Writer.write_string d hello) in
        check ~msg:"sticky" (e1 == e2));
    case "bytesrw: reader and writer agree on every frame" (fun () ->
        List.iter
          (fun f ->
            let r = fst (read_all ~src_slice:1000 ~slice_length:777 f.C.compressed) in
            let w = fst (write_all ~in_slice:999 ~out_slice:555 f.C.compressed) in
            check_string ~msg:f.C.name ~expected:(Lazy.force f.C.plain) r;
            check_string ~msg:f.C.name ~expected:r w)
          frames);
  ]

let () = exit (Harness.run ~backend:"native (bytesrw example)" cases)
