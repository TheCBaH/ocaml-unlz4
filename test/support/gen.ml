[@@@ai_disclosure "ai-generated"]
[@@@ai_provider "Anthropic, OpenAI"]

(* Deterministic data, generated identically by test/reference/unlz4_ref.c: the fixtures' plain
   text and dictionaries are recipes, not files. The generator is xorshift32 on Int32, returning
   30-bit values so they fit in every backend's [int]. Do not change it without regenerating the
   corpus. *)

type rng = { mutable s : int32 }

let rng seed = { s = (if seed = 0 then 0x9E3779B9l else Int32.of_int seed) }

let next r =
  let x = r.s in
  let x = Int32.logxor x (Int32.shift_left x 13) in
  let x = Int32.logxor x (Int32.shift_right_logical x 17) in
  let x = Int32.logxor x (Int32.shift_left x 5) in
  r.s <- x;
  Int32.to_int (Int32.shift_right_logical x 2)

let below r n = next r mod n

type profile = Lit | Rep | Mix

let profile_of_string = function
  | "lit" -> Lit
  | "rep" -> Rep
  | "mix" -> Mix
  | s -> invalid_arg ("Gen.profile_of_string: " ^ s)

let generate_uncached profile ~seed len =
  let r = rng seed in
  let b = Bytes.create len in
  (* Under js_of_ocaml a fresh buffer written in order grows as a string, and reading it back
     between writes is quadratic; writing the last byte first switches it to an array. *)
  if len > 0 then Bytes.set b (len - 1) '\000';
  (match profile with
  | Lit ->
      for i = 0 to len - 1 do
        Bytes.set b i (Char.chr (next r land 0xFF))
      done
  | Rep ->
      let unit = 1 + below r 61 in
      for i = 0 to len - 1 do
        if i < unit then Bytes.set b i (Char.chr (97 + below r 26))
        else if below r 512 = 0 then Bytes.set b i (Char.chr (65 + below r 26))
        else Bytes.set b i (Bytes.get b (i - unit))
      done
  | Mix ->
      let pos = ref 0 in
      while !pos < len do
        let x = next r in
        if !pos >= 8 && x mod 4 <> 0 then
          let window = if x land 64 <> 0 then min !pos 65535 else min !pos 1024 in
          let off = 1 + below r window in
          let ml = 4 + below r 60 in
          let k = ref 0 in
          while !k < ml && !pos < len do
            Bytes.set b !pos (Bytes.get b (!pos - off));
            incr pos;
            incr k
          done
        else
          let n = 1 + below r 16 in
          let k = ref 0 in
          while !k < n && !pos < len do
            Bytes.set b !pos (Char.chr (32 + below r 64));
            incr pos;
            incr k
          done
      done);
  Bytes.unsafe_to_string b

let cache = Hashtbl.create 16

let generate profile ~seed len =
  let key = (profile, seed, len) in
  match Hashtbl.find_opt cache key with
  | Some s -> s
  | None ->
      let s = generate_uncached profile ~seed len in
      Hashtbl.replace cache key s;
      s

(* A recipe segment: "profile:seed:len@from:to", the bytes [from, to) of the generated data. *)
let segment spec =
  match String.split_on_char '@' spec with
  | [ gen; range ] -> (
      match (String.split_on_char ':' gen, String.split_on_char ':' range) with
      | [ p; seed; len ], [ a; b ] ->
          let data =
            generate (profile_of_string p) ~seed:(int_of_string seed) (int_of_string len)
          in
          let a = int_of_string a and b = int_of_string b in
          String.sub data a (b - a)
      | _ -> invalid_arg ("Gen.segment: " ^ spec))
  | _ -> invalid_arg ("Gen.segment: " ^ spec)

(* Segments joined with '+'; "-" is empty. *)
let recipe = function
  | "-" -> ""
  | spec -> String.concat "" (List.map segment (String.split_on_char '+' spec))
