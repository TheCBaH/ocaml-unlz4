[@@@ai_disclosure "ai-generated"]
[@@@ai_provider "Anthropic, OpenAI"]

open Unlz4_test_support
open Harness
module B = Unlz4.Block
module E = Unlz4.Error

let kind_name k = show_kind k

let ok ?dictionary ?(max_output = 1 lsl 20) block =
  match B.decompress ?dictionary ~max_output block with
  | Ok s -> s
  | Error e -> failf "unexpected error: %s" (show_error e)

let fails ?dictionary ?(max_output = 1 lsl 20) kind block =
  match B.decompress ?dictionary ~max_output block with
  | Ok _ -> failf "expected %s, decoded successfully" (kind_name kind)
  | Error e -> if E.kind e <> kind then failf "expected %s, got %s" (kind_name kind) (show_error e)

let roundtrip ?history ?dictionary seqs =
  check_string ~expected:(Builder.expand ?history seqs) (ok ?dictionary (Builder.block seqs))

let lits n = Gen.generate Gen.Lit ~seed:(n + 1) n
let tail = "0123456789ab"

(* Random valid blocks: random sequences respecting the end-of-block rules, with the expected
   output from the reference expander. *)
let random_seqs r ~history_len =
  let produced = ref history_len in
  let n = Gen.below r 20 in
  let seqs =
    List.init n (fun _ ->
        let l = if Gen.below r 4 = 0 then Gen.below r 300 else Gen.below r 8 in
        let l = if !produced + l = 0 then 1 else l in
        produced := !produced + l;
        let off = 1 + Gen.below r (min !produced 65535) in
        let ml = 4 + if Gen.below r 4 = 0 then Gen.below r 600 else Gen.below r 16 in
        produced := !produced + ml;
        (Gen.generate Gen.Lit ~seed:(Gen.next r) l, Some (off, ml)))
  in
  seqs @ [ (Gen.generate Gen.Lit ~seed:(Gen.next r) (12 + Gen.below r 20), None) ]

let cases =
  [
    case "block: empty block is a single zero token" (fun () ->
        check_string ~expected:"" (ok "\x00"));
    case "block: empty range is truncated" (fun () -> fails E.Truncated_input "");
    case "block: literal-only lengths across the extension thresholds" (fun () ->
        List.iter
          (fun n -> roundtrip [ (lits n, None) ])
          [ 0; 1; 4; 5; 14; 15; 16; 254; 255; 269; 270; 271; 524; 525; 1000; 70000 ]);
    case "block: 15 literals need an explicit zero extension" (fun () ->
        fails E.Truncated_input ("\xf0" ^ String.make 15 'x'));
    case "block: unterminated length extension" (fun () ->
        fails E.Truncated_input "\xf0\xff\xff";
        fails E.Truncated_input "\x1f\x41\x01\x00\xff\xff");
    case "block: literals past the end" (fun () -> fails E.Truncated_input "\x50abc");
    case "block: truncated offset" (fun () ->
        (* "\x10a" alone is a valid literal-only block. *)
        fails E.Truncated_input "\x10a\x01");
    case "block: exact and undersized destination" (fun () ->
        let seqs = [ ("abcd", Some (4, 40)); (tail, None) ] in
        let block = Builder.block seqs and expected = Builder.expand seqs in
        let n = String.length expected in
        check_string ~expected (ok ~max_output:n block);
        fails ~max_output:(n - 1) E.Limit_exceeded block;
        fails ~max_output:0 E.Limit_exceeded (Builder.literal_block "a"));
    case "block: offsets, guard bytes and returned length" (fun () ->
        let seqs = [ ("hello", Some (5, 20)); (tail, None) ] in
        let block = Bytes.of_string ("XX" ^ Builder.block seqs ^ "YY") in
        let expected = Builder.expand seqs in
        let dst = Bytes.make 100 'G' in
        match
          B.decompress_into ~src:block ~src_off:2
            ~src_len:(Bytes.length block - 4)
            ~dst ~dst_off:7 ~dst_len:80 ()
        with
        | Error e -> failf "%s" (show_error e)
        | Ok n ->
            check_int ~expected:(String.length expected) n;
            check_string ~expected (Bytes.sub_string dst 7 n);
            check_string ~msg:"guard before" ~expected:(String.make 7 'G')
              (Bytes.sub_string dst 0 7);
            check_string ~msg:"guard after"
              ~expected:(String.make (93 - n) 'G')
              (Bytes.sub_string dst (7 + n) (93 - n)));
    case "block: overlapping matches with small offsets" (fun () ->
        List.iter
          (fun off ->
            List.iter
              (fun ml -> roundtrip [ (String.sub "abcdefgh" 0 off, Some (off, ml)); (tail, None) ])
              [ 4; 5; 18; 19; 20; 273; 274; 1000 ])
          [ 1; 2; 3; 4; 5; 7 ]);
    case "block: offset 65535" (fun () ->
        roundtrip [ (lits 65535, Some (65535, 100)); (tail, None) ];
        roundtrip [ (lits 65536, Some (65535, 4)); (tail, None) ]);
    case "block: long repetition" (fun () -> roundtrip [ ("z", Some (1, 300_000)); (tail, None) ]);
    case "block: zero offset" (fun () ->
        fails E.Invalid_block (Builder.block [ ("abcd", Some (0, 4)); (tail, None) ]));
    case "block: offset before the history" (fun () ->
        fails E.Invalid_block (Builder.block [ ("abcd", Some (5, 4)); (tail, None) ]);
        fails E.Invalid_block (Builder.block [ ("", Some (1, 4)); (tail, None) ]));
    case "block: end-of-block rules" (fun () ->
        let m = [ ("abcdefgh", Some (8, 8)) ] in
        roundtrip (m @ [ ("12345", None) ]);
        fails E.Invalid_block (Builder.block (m @ [ ("1234", None) ]));
        (* 12 bytes from the last match start to the end: allowed; 11: not. *)
        roundtrip [ ("abcdefgh", Some (8, 7)); ("12345", None) ];
        fails E.Invalid_block (Builder.block [ ("abcdefgh", Some (8, 6)); ("12345", None) ]);
        (* A block ending with a match has no final literal sequence. *)
        fails E.Truncated_input (Builder.block [ ("abcdefgh", Some (8, 8)) ]));
    case "block: tiny literal-only blocks are exempt" (fun () ->
        List.iter (fun n -> roundtrip [ (lits n, None) ]) [ 0; 1; 2; 3; 4 ]);
    case "block: match crossing from dictionary into output" (fun () ->
        let dict = "0123456789" in
        let dictionary = Unlz4.Dictionary.of_string dict in
        let seqs = [ ("ab", Some (6, 30)); (tail, None) ] in
        roundtrip ~history:dict ~dictionary seqs;
        roundtrip ~history:dict ~dictionary [ ("", Some (10, 4)); (tail, None) ];
        fails ~dictionary E.Invalid_block (Builder.block [ ("", Some (11, 4)); (tail, None) ]));
    case "block: dictionary keeps its last 64 KiB" (fun () ->
        let d = Bytes.of_string (lits 70000) in
        let dictionary = Unlz4.Dictionary.of_bytes d in
        check_int ~expected:65536 (Unlz4.Dictionary.length dictionary);
        let history = Bytes.sub_string d (70000 - 65536) 65536 in
        Bytes.fill d 0 70000 '!';
        let seqs = [ ("", Some (65535, 50)); ("x", Some (65535, 10)); (tail, None) ] in
        roundtrip ~history ~dictionary seqs;
        (* 65536 bytes are kept; with one byte of output, offset 65535 still reaches into them. *)
        roundtrip ~history ~dictionary [ ("y", Some (65535, 4)); (tail, None) ]);
    case "block: random valid sequences" (fun () ->
        let r = Gen.rng 42 in
        for i = 1 to 300 do
          let seqs = random_seqs r ~history_len:0 in
          match B.decompress ~max_output:(1 lsl 22) (Builder.block seqs) with
          | Ok s -> check_string ~msg:(Printf.sprintf "case %d" i) ~expected:(Builder.expand seqs) s
          | Error e -> failf "case %d: %s" i (show_error e)
        done);
    case "block: random valid sequences after a dictionary" (fun () ->
        let r = Gen.rng 43 in
        for i = 1 to 100 do
          let history = Gen.generate Gen.Mix ~seed:i (1 + Gen.below r 70000) in
          let dictionary = Unlz4.Dictionary.of_string history in
          let kept =
            String.sub history
              (String.length history - Unlz4.Dictionary.length dictionary)
              (Unlz4.Dictionary.length dictionary)
          in
          let seqs = random_seqs r ~history_len:(String.length kept) in
          match B.decompress ~dictionary ~max_output:(1 lsl 22) (Builder.block seqs) with
          | Ok s ->
              check_string ~msg:(Printf.sprintf "case %d" i)
                ~expected:(Builder.expand ~history:kept seqs)
                s
          | Error e -> failf "case %d: %s" i (show_error e)
        done);
    case "block: invalid ranges and aliasing" (fun () ->
        let b = Bytes.of_string "\x00" and d = Bytes.create 4 in
        raises_invalid_arg (fun () ->
            B.decompress_into ~src:b ~src_off:0 ~src_len:2 ~dst:d ~dst_off:0 ~dst_len:4 ());
        raises_invalid_arg (fun () ->
            B.decompress_into ~src:b ~src_off:(-1) ~src_len:1 ~dst:d ~dst_off:0 ~dst_len:4 ());
        raises_invalid_arg (fun () ->
            B.decompress_into ~src:b ~src_off:0 ~src_len:1 ~dst:d ~dst_off:3 ~dst_len:2 ());
        raises_invalid_arg (fun () ->
            B.decompress_into ~src:b ~src_off:0 ~src_len:1 ~dst:b ~dst_off:0 ~dst_len:1 ());
        raises_invalid_arg (fun () -> B.decompress ~max_output:(-1) "\x00"));
    case "block: error offsets" (fun () ->
        let block = Builder.block [ ("abcd", Some (0, 4)); (tail, None) ] in
        match B.decompress ~max_output:100 block with
        | Ok _ -> failf "decoded"
        | Error e ->
            check_int64 ~msg:"compressed" ~expected:5L (E.compressed_offset e);
            check_int64 ~msg:"decoded" ~expected:4L (E.decoded_offset e);
            check ~msg:"no frame index" (E.frame_index e = None));
  ]
