[@@@ai_disclosure "ai-generated"]
[@@@ai_provider "Anthropic, OpenAI"]

(* Differential fuzz of Unlz4.Block against liblz4's LZ4_decompress_safe_usingDict, over valid
   blocks (with and without a dictionary) and their mutations, with a seeded loop.

   - unlz4 never raises, stays inside [dst], and, when it accepts, liblz4 accepts with the same
     output;
   - when liblz4 accepts and unlz4 rejects, the block must have one of the documented differences:
     an offset of zero, four final literals after a match of 19+ bytes or three after 274+, or a
     last match starting less than 12 bytes before the end; conversely liblz4 rejects every block
     but a lone zero token when the capacity is zero. With a dictionary, or a capacity above
     the decoded size, liblz4 also accepts any number of final literals below five after a match.
     Anything else is a failure. *)

external ref_decompress : bytes -> int -> bytes -> bytes -> int = "unlz4_fuzz_decompress"
external ref_compress : string -> bytes -> int -> string = "unlz4_fuzz_compress"

module G = Unlz4_test_support.Gen

let iterations = try int_of_string (Sys.getenv "UNLZ4_FUZZ_ITERATIONS") with Not_found -> 20_000
let seed = try int_of_string (Sys.getenv "UNLZ4_FUZZ_SEED") with Not_found -> 1

type shape = {
  offset_zero : bool;
  final_lits : int;
  last_mlen : int;
  tail : int;  (** Decoded bytes from the start of the last match to the end. *)
}

(* The structure of a block liblz4 accepted; None when it cannot be walked. *)
let shape b n =
  let ip = ref 0 and out = ref 0 in
  let zero = ref false and last = ref None and lits_end = ref 0 in
  let ext () =
    let t = ref 0 and go = ref true in
    while !go && !ip < n do
      let c = Char.code (Bytes.get b !ip) in
      incr ip;
      t := !t + c;
      if c <> 255 then go := false
    done;
    !t
  in
  try
    while !ip < n do
      let token = Char.code (Bytes.get b !ip) in
      incr ip;
      let l = token lsr 4 in
      let l = if l = 15 then 15 + ext () else l in
      ip := !ip + l;
      out := !out + l;
      lits_end := l;
      if !ip < n then (
        let off = Char.code (Bytes.get b !ip) lor (Char.code (Bytes.get b (!ip + 1)) lsl 8) in
        ip := !ip + 2;
        if off = 0 then zero := true;
        let m = token land 15 in
        let m = 4 + if m = 15 then 15 + ext () else m in
        last := Some (!out, m);
        out := !out + m)
    done;
    match !last with
    | None -> Some { offset_zero = !zero; final_lits = !lits_end; last_mlen = 0; tail = 0 }
    | Some (start, m) ->
        Some { offset_zero = !zero; final_lits = !lits_end; last_mlen = m; tail = !out - start }
  with Invalid_argument _ -> None

let allowed ~relaxed s =
  s.offset_zero
  || (s.final_lits = 4 && s.last_mlen >= 19)
  || (s.final_lits = 3 && s.last_mlen >= 274)
  || (s.last_mlen > 0 && s.tail < 12)
  || (relaxed && s.last_mlen > 0 && s.final_lits < 5)

let hex b n =
  String.concat ""
    (List.init (min n 64) (fun i -> Printf.sprintf "%02x" (Char.code (Bytes.get b i))))

let mutate r b =
  let b = Bytes.copy b in
  match G.below r 6 with
  | 0 | 1 ->
      for _ = 0 to G.below r 3 do
        if Bytes.length b > 0 then
          Bytes.set b (G.below r (Bytes.length b)) (Char.chr (G.below r 256))
      done;
      b
  | 2 -> Bytes.sub b 0 (Bytes.length b - min (Bytes.length b) (1 + G.below r 8))
  | 3 -> Bytes.cat b (Bytes.init (1 + G.below r 8) (fun _ -> Char.chr (G.below r 256)))
  | 4 -> Bytes.init (G.below r 40) (fun _ -> Char.chr (G.below r 256))
  | _ -> b

let () =
  let r = G.rng seed in
  let accepted = ref 0 and rejected = ref 0 and diff = ref 0 and failures = ref 0 in
  let fail fmt =
    incr failures;
    Printf.ksprintf (fun s -> if !failures <= 10 then prerr_endline ("FAIL " ^ s)) fmt
  in
  for i = 1 to iterations do
    let len = 1 + G.below r (if G.below r 8 = 0 then 100_000 else 600) in
    let plain =
      G.generate
        (match G.below r 3 with 0 -> G.Lit | 1 -> G.Rep | _ -> G.Mix)
        ~seed:(G.next r) len
    in
    let dict =
      if G.below r 3 = 0 then
        Bytes.of_string (G.generate G.Mix ~seed:(G.next r) (1 + G.below r 70_000))
      else Bytes.empty
    in
    let block = Bytes.of_string (ref_compress plain dict (1 + G.below r 8)) in
    let block = if G.below r 3 = 0 then block else mutate r block in
    let n = Bytes.length block in
    let cap =
      match G.below r 4 with
      | 0 -> len
      | 1 -> len + G.below r 100
      | 2 -> max 0 (len - G.below r 100)
      | _ -> G.below r ((2 * len) + 8)
    in
    let dst = Bytes.make (cap + 2) '#' in
    let dictionary =
      if Bytes.length dict = 0 then None else Some (Unlz4.Dictionary.of_bytes dict)
    in
    let mine =
      match
        Unlz4.Block.decompress_into ?dictionary ~src:block ~src_off:0 ~src_len:n ~dst ~dst_off:1
          ~dst_len:cap ()
      with
      | Ok m -> Ok m
      | Error e -> Error (Unlz4.Error.message e)
      | exception e ->
          fail "#%d raised %s on %s" i (Printexc.to_string e) (hex block n);
          Error "raised"
    in
    if Bytes.get dst 0 <> '#' || Bytes.get dst (cap + 1) <> '#' then
      fail "#%d wrote outside [dst]" i;
    let theirs_dst = Bytes.make cap '#' in
    let theirs = ref_decompress block n theirs_dst dict in
    match mine with
    | Ok m ->
        incr accepted;
        if m > cap then fail "#%d produced %d > %d" i m cap
        else if cap = 0 && theirs < 0 then incr diff
        else if theirs <> m then
          fail "#%d unlz4 accepted %d bytes, liblz4 returned %d (cap %d, dict %d): %s" i m theirs
            cap (Bytes.length dict) (hex block n)
        else if Bytes.sub dst 1 m <> Bytes.sub theirs_dst 0 m then
          fail "#%d outputs differ (cap %d): %s" i cap (hex block n)
    | Error why -> (
        incr rejected;
        if theirs >= 0 then
          match shape block n with
          | Some s when allowed ~relaxed:(Bytes.length dict > 0 || cap > theirs) s -> incr diff
          | sh ->
              (match sh with
              | Some s ->
                  Printf.eprintf "  shape: lits=%d mlen=%d tail=%d zero=%b\n" s.final_lits
                    s.last_mlen s.tail s.offset_zero
              | None -> ());
              fail "#%d liblz4 accepted (%d bytes, cap %d, dict %d), unlz4 rejected (%s): %s" i
                theirs cap (Bytes.length dict) why (hex block n))
  done;
  Printf.printf
    "fuzz: %d cases (seed %d): %d accepted, %d rejected, %d allowed differences, %d failures\n"
    iterations seed !accepted !rejected !diff !failures;
  if !failures > 0 then exit 1
