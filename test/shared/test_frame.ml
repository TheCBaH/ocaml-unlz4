open Unlz4_test_support
open Harness
module F = Unlz4.Frame
module E = Unlz4.Error
module D = Drive

let b = Builder.flags
let lb = Builder.literal_block
let text n = Gen.generate Gen.Mix ~seed:(n + 7) n

(* A linked frame whose second block copies from the first. *)
let first = "The quick brown fox jumps over the lazy dog. "
let second_seqs = [ ("", Some (String.length first, String.length first)); ("0123456789ab", None) ]
let second = Builder.expand ~history:first second_seqs

let linked_frame ?(independent = false) () =
  Builder.frame ~f:{ b with independent }
    [ Builder.Compressed (lb first); Builder.Compressed (Builder.block second_seqs) ]

let frame_of ?(f = b) s = Builder.frame ~f ~content:s [ Builder.Compressed (lb s) ]
let hello = frame_of "hello, world"

let check_kind kind e =
  if E.kind e <> kind then failf "expected %s, got %s" (E.kind_to_string kind) (E.to_string e)

let cases =
  [
    case "frame: empty modern frame" (fun () -> check_string ~expected:"" (D.ok (Builder.frame [])));
    case "frame: literal frame" (fun () -> check_string ~expected:"hello, world" (D.ok hello));
    case "frame: decompress whole buffer" (fun () ->
        match F.decompress (hello ^ hello) with
        | Ok s -> check_string ~expected:"hello, worldhello, world" s
        | Error e -> failf "%s" (E.to_string e));
    case "frame: stored blocks, and an empty stored block is not the end mark" (fun () ->
        let f = Builder.frame [ Builder.Stored "abc"; Builder.Stored ""; Builder.Stored "def" ] in
        check_string ~expected:"abcdef" (D.ok f));
    case "frame: every standard block maximum" (fun () ->
        List.iter
          (fun code ->
            let s = text 1000 in
            check_string ~expected:s (D.ok (frame_of ~f:{ b with bd_code = code } s));
            match F.decompress (frame_of ~f:{ b with bd_code = code } "") with
            | Ok _ -> ()
            | Error e -> failf "%s" (E.to_string e))
          [ 4; 5; 6; 7 ]);
    case "frame: info" (fun () ->
        let f =
          {
            b with
            bd_code = 5;
            block_checksum = true;
            content_checksum = true;
            content_size = Some 3L;
            dict_id = None;
            independent = false;
          }
        in
        let d = F.create () in
        let src = Bytes.of_string (Builder.frame ~f ~content:"abc" [ Builder.Stored "abc" ]) in
        (match
           F.decode d ~src ~src_off:0 ~src_len:(Bytes.length src) ~eof:true ~dst:(Bytes.create 8)
             ~dst_off:0 ~dst_len:8 ()
         with
        | Ok { status = F.Frame_end; produced = 3; _ } -> ()
        | _ -> failf "decode");
        match F.info d with
        | Some i ->
            check_int ~expected:262144 i.F.block_max_size;
            check ~msg:"flags"
              (i.F.block_checksum && i.F.content_checksum && not i.F.block_independent);
            check ~msg:"size" (i.F.content_size = Some 3L)
        | None -> failf "no info");
    case "frame: invalid block maximum codes" (fun () ->
        List.iter
          (fun c -> D.fails E.Invalid_frame (frame_of ~f:{ b with bd_code = c } "x"))
          [ 0; 1; 2; 3 ]);
    case "frame: unsupported versions" (fun () ->
        List.iter
          (fun v -> D.fails E.Unsupported_feature (frame_of ~f:{ b with version = v } "x"))
          [ 0; 2; 3 ]);
    case "frame: reserved bits" (fun () ->
        D.fails E.Invalid_frame (frame_of ~f:{ b with reserved_flg = true } "x");
        List.iter
          (fun r -> D.fails E.Invalid_frame (frame_of ~f:{ b with reserved_bd = r } "x"))
          [ 1; 4; 8 ];
        D.fails E.Invalid_frame (frame_of ~f:{ b with bd_code = 12 } "x"));
    case "frame: descriptor checksum" (fun () ->
        let d = Builder.descriptor b in
        let bad = (Char.code d.[String.length d - 1] + 1) land 0xFF in
        let e = D.error (Builder.frame ~hc:bad []) in
        check_kind E.Checksum_mismatch e;
        check_int64 ~msg:"offset" ~expected:6L (E.compressed_offset e);
        check ~msg:"frame index" (E.frame_index e = Some 0));
    case "frame: block larger than the block maximum" (fun () ->
        let big = String.make 65537 'a' in
        D.fails E.Invalid_frame (Builder.frame [ Builder.Stored big ]);
        check_string ~expected:big
          (D.ok (Builder.frame ~f:{ b with bd_code = 5 } [ Builder.Stored big ])));
    case "frame: decoded block larger than the block maximum" (fun () ->
        let block = Builder.block [ ("a", Some (1, 70000)); ("0123456789ab", None) ] in
        D.fails E.Invalid_block (Builder.frame [ Builder.Compressed block ]));
    case "frame: block checksum" (fun () ->
        let f = { b with block_checksum = true } in
        check_string ~expected:"abc" (D.ok (Builder.frame ~f [ Builder.Compressed (lb "abc") ]));
        let payload = lb "abc" in
        let raw = Builder.u32 (Int32.of_int (String.length payload)) ^ payload ^ Builder.u32 0l in
        let e = D.error (Builder.frame ~f [ Builder.Raw raw ]) in
        check_kind E.Checksum_mismatch e;
        check ~msg:"block index" (E.block_index e = Some 0);
        check_int64 ~msg:"offset"
          ~expected:(Int64.of_int (7 + 4 + String.length payload))
          (E.compressed_offset e);
        (* Empty stored blocks carry a checksum too. *)
        check_string ~expected:"" (D.ok (Builder.frame ~f [ Builder.Stored "" ])));
    case "frame: content checksum" (fun () ->
        let f = { b with content_checksum = true } in
        check_string ~expected:"abc"
          (D.ok (Builder.frame ~f ~content:"abc" [ Builder.Stored "abc" ]));
        D.fails E.Checksum_mismatch (Builder.frame ~f ~content:"abd" [ Builder.Stored "abc" ]);
        (* The output is delivered before the footer reveals the mismatch. *)
        let o = D.frames (Builder.frame ~f ~content:"abd" [ Builder.Stored "abc" ]) in
        check_string ~expected:"abc" o.D.output);
    case "frame: content size" (fun () ->
        let f n = { b with content_size = Some n } in
        check_string ~expected:"abc" (D.ok (Builder.frame ~f:(f 3L) [ Builder.Stored "abc" ]));
        check_string ~expected:"" (D.ok (Builder.frame ~f:(f 0L) []));
        D.fails E.Content_size_mismatch (Builder.frame ~f:(f 2L) [ Builder.Stored "abc" ]);
        D.fails E.Content_size_mismatch (Builder.frame ~f:(f 4L) [ Builder.Stored "abc" ]);
        D.fails E.Content_size_mismatch (Builder.frame ~f:(f 1L) []);
        (* Too large: rejected before the block is emitted. *)
        let o = D.frames (Builder.frame ~f:(f 2L) [ Builder.Stored "abc" ]) in
        check_string ~expected:"" o.D.output;
        D.fails E.Limit_exceeded (Builder.frame ~f:(f Int64.min_int) []);
        D.fails E.Limit_exceeded (Builder.frame ~f:(f (-1L)) []);
        check_string ~expected:"" (D.ok (Builder.frame ~f:(f 0L) [ Builder.Stored "" ])));
    case "frame: linked and independent blocks" (fun () ->
        check_string ~expected:(first ^ second) (D.ok (linked_frame ()));
        D.fails E.Invalid_block (linked_frame ~independent:true ()));
    case "frame: linked history rolls over 64 KiB" (fun () ->
        (* Blocks of 50000 literals; each later block also copies from 65535 bytes back. *)
        let parts = List.init 5 (fun i -> Gen.generate Gen.Lit ~seed:(100 + i) 50000) in
        let blocks, plain =
          List.fold_left
            (fun (blocks, plain) p ->
              if plain = "" then ([ Builder.Compressed (lb p) ], p)
              else
                let seqs = [ (p, Some (65535, 20)); ("0123456789ab", None) ] in
                ( blocks @ [ Builder.Compressed (Builder.block seqs) ],
                  plain ^ Builder.expand ~history:plain seqs ))
            ([], "") parts
        in
        let f = { b with independent = false; bd_code = 5 } in
        check_string ~expected:plain (D.ok (Builder.frame ~f blocks));
        check_string ~expected:plain
          (D.ok ~chunk:(D.random_schedule 1 5000) ~out_cap:(D.random_schedule 2 3000)
             (Builder.frame ~f blocks)));
    case "frame: legacy magic" (fun () ->
        D.fails E.Unsupported_feature "\x02\x21\x4c\x18\x00\x00\x00\x00");
    case "frame: empty input" (fun () ->
        let e = D.error "" in
        check_kind E.Truncated_input e);
    case "frame: unknown magic and trailing garbage" (fun () ->
        D.fails E.Invalid_frame "garbage!";
        let e = D.error (hello ^ "garbage!") in
        check_kind E.Invalid_frame e;
        check_int64 ~msg:"offset"
          ~expected:(Int64.of_int (String.length hello))
          (E.compressed_offset e);
        D.fails E.Truncated_input (hello ^ "\x04\x22");
        D.fails E.Truncated_input (hello ^ Builder.magic));
    case "frame: truncation at every position" (fun () ->
        let f =
          {
            b with
            block_checksum = true;
            content_checksum = true;
            content_size = Some 12L;
            dict_id = None;
          }
        in
        let full =
          Builder.frame ~f ~content:"hello, world" [ Builder.Compressed (lb "hello, world") ]
        in
        for k = 0 to String.length full - 1 do
          D.fails E.Truncated_input (String.sub full 0 k)
        done);
    case "frame: skippable frames" (fun () ->
        for nibble = 0 to 15 do
          let s = Builder.skippable ~nibble "ignored" in
          check_string ~expected:"" (D.ok s);
          check_string ~expected:"hello, world" (D.ok (s ^ hello ^ s))
        done;
        check_string ~expected:"" (D.ok (Builder.skippable ""));
        D.fails E.Truncated_input (String.sub (Builder.skippable "abcdef") 0 10);
        D.fails E.Truncated_input (String.sub (Builder.skippable "abcdef") 0 6));
    case "frame: large skippable size" (fun () ->
        let s = "\x50\x2a\x4d\x18\xff\xff\xff\xff" ^ "abc" in
        D.fails E.Truncated_input s;
        D.fails ~limits:(Unlz4.Limits.make ~max_skipped:100L ()) E.Limit_exceeded s);
    case "frame: concatenation with different options" (fun () ->
        let f1 = frame_of ~f:{ b with content_checksum = true } "one " in
        let f2 = frame_of ~f:{ b with block_checksum = true; bd_code = 7 } "two " in
        let f3 = linked_frame () in
        check_string
          ~expected:("one two " ^ first ^ second)
          (D.ok (f1 ^ Builder.skippable "x" ^ f2 ^ f3)));
    case "frame: statuses" (fun () ->
        let d = F.create () in
        let src = Bytes.of_string (hello ^ hello) and dst = Bytes.create 100 in
        let call off len =
          match
            F.decode d ~src ~src_off:off ~src_len:len ~eof:true ~dst ~dst_off:0 ~dst_len:100 ()
          with
          | Ok p -> p
          | Error e -> failf "%s" (E.to_string e)
        in
        let n = String.length hello in
        let p = call 0 (2 * n) in
        check ~msg:"first Frame_end" (p.F.status = F.Frame_end && p.F.consumed = n);
        let p = call n n in
        check ~msg:"second Frame_end" (p.F.status = F.Frame_end && p.F.consumed = n);
        let p = call (2 * n) 0 in
        check ~msg:"Stream_end" (p.F.status = F.Stream_end);
        let p = call (2 * n) 0 in
        check ~msg:"sticky" (p.F.status = F.Stream_end && p.F.produced = 0);
        check_int64 ~msg:"total_in" ~expected:(Int64.of_int (2 * n)) (F.total_in d);
        check_int64 ~msg:"total_out" ~expected:24L (F.total_out d));
    case "frame: single mode leaves the rest" (fun () ->
        let skip = Builder.skippable "zz" in
        let input = skip ^ hello ^ "rest of the stream" in
        let o = D.frames ~mode:F.Single input in
        check ~msg:"Frame_end" (o.D.result = Ok F.Frame_end);
        check_string ~expected:"hello, world" o.D.output;
        check_int ~expected:(String.length skip + String.length hello) o.D.consumed;
        (* Byte by byte too. *)
        let o = D.frames ~mode:F.Single ~chunk:(fun _ -> 1) input in
        check_int ~expected:(String.length skip + String.length hello) o.D.consumed;
        D.fails ~mode:F.Single E.Truncated_input skip;
        D.fails ~mode:F.Single E.Truncated_input "");
    case "frame: dictionaries" (fun () ->
        let dict = "0123456789abcdefghij" in
        let seqs = [ ("", Some (20, 30)); ("0123456789ab", None) ] in
        let plain = Builder.expand ~history:dict seqs in
        let mk ?id ~independent () =
          Builder.frame
            ~f:{ b with dict_id = id; independent }
            [ Builder.Compressed (Builder.block seqs); Builder.Compressed (Builder.block seqs) ]
        in
        let two = plain ^ Builder.expand ~history:(dict ^ plain) seqs in
        let two_indep = plain ^ plain in
        let d = Unlz4.Dictionary.of_string dict in
        let did = Unlz4.Dictionary.of_string ~id:0xCAFEF00Dl dict in
        check_string ~expected:two (D.ok ~dictionary:d (mk ~independent:false ()));
        check_string ~expected:two_indep (D.ok ~dictionary:d (mk ~independent:true ()));
        D.fails E.Invalid_block (mk ~independent:true ());
        let id = 0xCAFEF00Dl in
        check_string ~expected:two_indep (D.ok ~dictionary:did (mk ~id ~independent:true ()));
        check_string ~expected:two_indep (D.ok ~dictionary:d (mk ~id ~independent:true ()));
        D.fails E.Missing_dictionary (mk ~id ~independent:true ());
        D.fails
          ~dictionary:(Unlz4.Dictionary.of_string ~id:1l dict)
          E.Dictionary_id_mismatch (mk ~id ~independent:true ());
        let calls = ref [] in
        let resolve_dictionary i =
          calls := i :: !calls;
          if Int32.equal i id then Some did else None
        in
        check_string ~expected:(two_indep ^ two_indep)
          (D.ok ~resolve_dictionary (mk ~id ~independent:true () ^ mk ~id ~independent:true ()));
        check ~msg:"resolver once per frame" (!calls = [ id; id ]);
        D.fails ~resolve_dictionary E.Missing_dictionary (mk ~id:7l ~independent:true ());
        D.fails
          ~resolve_dictionary:(fun _ -> Some (Unlz4.Dictionary.of_string ~id:9l dict))
          E.Dictionary_id_mismatch (mk ~id ~independent:true ());
        (* A high-bit ID survives as an int32 bit pattern. *)
        let hi = 0xFEDCBA98l in
        let seen = ref 0l in
        ignore
          (D.ok
             ~resolve_dictionary:(fun i ->
               seen := i;
               Some d)
             (mk ~id:hi ~independent:true ()));
        check_int32 ~expected:hi !seen);
    case "frame: limits" (fun () ->
        let l = Unlz4.Limits.make in
        D.fails ~limits:(l ~max_block_size:65536 ()) E.Limit_exceeded
          (frame_of ~f:{ b with bd_code = 7 } "x");
        ignore (D.ok ~limits:(l ~max_block_size:65536 ()) hello);
        D.fails ~limits:(l ~max_output:11L ()) E.Limit_exceeded hello;
        ignore (D.ok ~limits:(l ~max_output:12L ()) hello);
        D.fails
          ~limits:(l ~max_input:(Int64.of_int (String.length hello - 1)) ())
          E.Limit_exceeded hello;
        ignore (D.ok ~limits:(l ~max_input:(Int64.of_int (String.length hello)) ()) hello);
        D.fails ~limits:(l ~max_frames:1L ()) E.Limit_exceeded (hello ^ hello);
        D.fails ~limits:(l ~max_frames:1L ()) E.Limit_exceeded (Builder.skippable "" ^ hello);
        D.fails ~limits:(l ~max_skipped:3L ()) E.Limit_exceeded (Builder.skippable "abcd");
        ignore (D.ok ~limits:(l ~max_skipped:4L ()) (Builder.skippable "abcd"));
        raises_invalid_arg (fun () -> l ~max_block_size:65535 ());
        raises_invalid_arg (fun () -> l ~max_output:(-1L) ()));
    case "frame: errors are terminal" (fun () ->
        let d = F.create () in
        let src = Bytes.of_string "garbage!" and dst = Bytes.create 10 in
        let call () =
          F.decode d ~src ~src_off:0 ~src_len:8 ~eof:false ~dst ~dst_off:0 ~dst_len:10 ()
        in
        match (call (), call ()) with
        | Error e1, Error e2 -> check ~msg:"same error" (e1 == e2)
        | _ -> failf "expected errors");
    case "frame: eof contract and arguments" (fun () ->
        let src = Bytes.of_string hello and dst = Bytes.create 4 in
        let d = F.create () in
        (match
           F.decode d ~src ~src_off:0 ~src_len:(Bytes.length src) ~eof:true ~dst ~dst_off:0
             ~dst_len:4 ()
         with
        | Ok { status = F.Need_output; consumed; _ } ->
            let rest = Bytes.length src - consumed in
            raises_invalid_arg (fun () ->
                F.decode d ~src ~src_off:consumed ~src_len:rest ~eof:false ~dst ~dst_off:0
                  ~dst_len:4 ());
            raises_invalid_arg (fun () ->
                F.decode d ~src ~src_off:consumed ~src_len:(rest - 1) ~eof:true ~dst ~dst_off:0
                  ~dst_len:4 ())
        | _ -> failf "expected Need_output");
        raises_invalid_arg (fun () ->
            F.decode (F.create ()) ~src ~src_off:0 ~src_len:1 ~eof:false ~dst:src ~dst_off:0
              ~dst_len:1 ());
        raises_invalid_arg (fun () ->
            F.decode (F.create ()) ~src ~src_off:1 ~src_len:(Bytes.length src) ~eof:false ~dst
              ~dst_off:0 ~dst_len:1 ());
        raises_invalid_arg (fun () ->
            F.decode (F.create ()) ~src ~src_off:0 ~src_len:1 ~eof:false ~dst ~dst_off:0 ~dst_len:5
              ()));
    case "frame: zero output space does not spin" (fun () ->
        let d = F.create () in
        let src = Bytes.of_string hello and dst = Bytes.create 1 in
        match
          F.decode d ~src ~src_off:0 ~src_len:(Bytes.length src) ~eof:false ~dst ~dst_off:0
            ~dst_len:0 ()
        with
        | Ok { status = F.Need_output; produced = 0; consumed; _ } ->
            check ~msg:"consumed the block" (consumed > 0)
        | _ -> failf "expected Need_output");
    case "frame: every input split and output capacity" (fun () ->
        let input = hello ^ Builder.skippable "abc" ^ linked_frame () in
        let expected = "hello, world" ^ first ^ second in
        for k = 0 to String.length input do
          let chunk i = if i = 0 then k else max_int in
          check_string ~msg:(Printf.sprintf "split %d" k) ~expected (D.ok ~chunk input)
        done;
        check_string ~msg:"bytewise" ~expected (D.ok ~chunk:(fun _ -> 1) input);
        List.iter
          (fun c ->
            check_string ~msg:(Printf.sprintf "out %d" c) ~expected
              (D.ok ~out_cap:(fun _ -> c) input))
          [ 1; 2; 3; 11; 12; 13; 45 ];
        check_string ~msg:"alternating zero output" ~expected
          (D.ok ~chunk:(fun _ -> 1) ~out_cap:(fun i -> i land 1) input));
    case "frame: stream counters beyond 2^32" (fun () ->
        (* Two skippable frames of 2^32 - 1 bytes each, fed from one reused buffer, then garbage:
           the counters and the error offset must be exact int64 values on every backend. *)
        let d = F.create () in
        let dst = Bytes.create 16 in
        let feed src off len =
          match
            F.decode d ~src ~src_off:off ~src_len:len ~eof:false ~dst ~dst_off:0 ~dst_len:16 ()
          with
          | Ok p -> check_int ~msg:"all consumed" ~expected:len p.F.consumed
          | Error e -> failf "%s" (E.to_string e)
        in
        let chunk = Bytes.make (1 lsl 20) 'x' in
        let skip_size = 0xFFFFFFFFL in
        for _ = 1 to 2 do
          let hdr = Bytes.of_string "\x5f\x2a\x4d\x18\xff\xff\xff\xff" in
          feed hdr 0 8;
          let left = ref skip_size in
          while Int64.compare !left 0L > 0 do
            let n =
              if Int64.compare !left (Int64.of_int (1 lsl 20)) < 0 then Int64.to_int !left
              else 1 lsl 20
            in
            feed chunk 0 n;
            left := Int64.sub !left (Int64.of_int n)
          done
        done;
        let expected = Int64.add (Int64.mul 2L skip_size) 16L in
        check_int64 ~msg:"total_in" ~expected (F.total_in d);
        let junk = Bytes.of_string "junk" in
        match
          F.decode d ~src:junk ~src_off:0 ~src_len:4 ~eof:true ~dst ~dst_off:0 ~dst_len:16 ()
        with
        | Error e ->
            check_kind E.Invalid_frame e;
            check_int64 ~msg:"error offset" ~expected (E.compressed_offset e)
        | Ok _ -> failf "garbage accepted");
    case "frame: many empty blocks do not grow the stack" (fun () ->
        let blocks = List.init 100_000 (fun _ -> Builder.Stored "") in
        check_string ~expected:"" (D.ok (Builder.frame blocks)));
  ]
