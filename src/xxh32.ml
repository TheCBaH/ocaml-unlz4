[@@@ai_disclosure "ai-generated"]
[@@@ai_provider "Anthropic, OpenAI"]

(* All arithmetic is on Int32, so the result is the same with a 63-bit native int, a 31-bit one,
   js_of_ocaml or Melange. Lengths fit in an int; only their low 32 bits enter the hash. *)

let p1 = 0x9E3779B1l
let p2 = 0x85EBCA77l
let p3 = 0xC2B2AE3Dl
let p4 = 0x27D4EB2Fl
let p5 = 0x165667B1l
let rotl x r = Int32.logor (Int32.shift_left x r) (Int32.shift_right_logical x (32 - r))

let get32 b i =
  let byte k = Char.code (Bytes.get b (i + k)) in
  Int32.logor
    (Int32.of_int (byte 0 lor (byte 1 lsl 8) lor (byte 2 lsl 16)))
    (Int32.shift_left (Int32.of_int (byte 3)) 24)

let round acc input = Int32.mul (rotl (Int32.add acc (Int32.mul input p2)) 13) p1

type t = {
  mutable v1 : int32;
  mutable v2 : int32;
  mutable v3 : int32;
  mutable v4 : int32;
  mutable total : int32;  (** Bytes fed, modulo 2^32. *)
  mutable large : bool;  (** At least 16 bytes fed. *)
  mem : bytes;  (** Pending bytes of an incomplete 16-byte stripe. *)
  mutable mem_len : int;
}

let reset h =
  h.v1 <- Int32.add p1 p2;
  h.v2 <- p2;
  h.v3 <- 0l;
  h.v4 <- Int32.neg p1;
  h.total <- 0l;
  h.large <- false;
  h.mem_len <- 0

let create () =
  let h =
    {
      v1 = 0l;
      v2 = 0l;
      v3 = 0l;
      v4 = 0l;
      total = 0l;
      large = false;
      mem = Bytes.create 16;
      mem_len = 0;
    }
  in
  reset h;
  h

(* Consumes the complete stripes of b.[off .. off + len - 1]; returns how many bytes it used. *)
let stripes h b off len =
  let v1 = ref h.v1 and v2 = ref h.v2 and v3 = ref h.v3 and v4 = ref h.v4 in
  let i = ref off in
  let last = off + len - 16 in
  while !i <= last do
    v1 := round !v1 (get32 b !i);
    v2 := round !v2 (get32 b (!i + 4));
    v3 := round !v3 (get32 b (!i + 8));
    v4 := round !v4 (get32 b (!i + 12));
    i := !i + 16
  done;
  h.v1 <- !v1;
  h.v2 <- !v2;
  h.v3 <- !v3;
  h.v4 <- !v4;
  !i - off

let update h b off len =
  if off < 0 || len < 0 || off > Bytes.length b - len then invalid_arg "Xxh32.update";
  h.total <- Int32.add h.total (Int32.of_int len);
  if h.mem_len + len >= 16 then h.large <- true;
  if h.mem_len + len < 16 then (
    Bytes.blit b off h.mem h.mem_len len;
    h.mem_len <- h.mem_len + len)
  else
    let off, len =
      if h.mem_len > 0 then (
        let fill = 16 - h.mem_len in
        Bytes.blit b off h.mem h.mem_len fill;
        ignore (stripes h h.mem 0 16);
        h.mem_len <- 0;
        (off + fill, len - fill))
      else (off, len)
    in
    let used = stripes h b off len in
    let rest = len - used in
    Bytes.blit b (off + used) h.mem 0 rest;
    h.mem_len <- rest

let digest h =
  let acc =
    if h.large then
      Int32.add (Int32.add (rotl h.v1 1) (rotl h.v2 7)) (Int32.add (rotl h.v3 12) (rotl h.v4 18))
    else p5
  in
  let acc = ref (Int32.add acc h.total) in
  let i = ref 0 in
  while !i + 4 <= h.mem_len do
    acc := Int32.mul (rotl (Int32.add !acc (Int32.mul (get32 h.mem !i) p3)) 17) p4;
    i := !i + 4
  done;
  while !i < h.mem_len do
    let byte = Int32.of_int (Char.code (Bytes.get h.mem !i)) in
    acc := Int32.mul (rotl (Int32.add !acc (Int32.mul byte p5)) 11) p1;
    incr i
  done;
  let h = !acc in
  let h = Int32.mul (Int32.logxor h (Int32.shift_right_logical h 15)) p2 in
  let h = Int32.mul (Int32.logxor h (Int32.shift_right_logical h 13)) p3 in
  Int32.logxor h (Int32.shift_right_logical h 16)

let bytes b off len =
  let h = create () in
  update h b off len;
  digest h

let string s = bytes (Bytes.of_string s) 0 (String.length s)
