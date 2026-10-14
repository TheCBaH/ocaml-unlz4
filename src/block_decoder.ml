[@@@ai_disclosure "ai-generated"]
[@@@ai_provider "Anthropic, OpenAI"]

(* The raw-block decoder shared by Unlz4.Block and the frame decoder.

   The history of a block is [ext.[ext_off .. ext_off + ext_len - 1]] followed by
   [dst.[hist .. dp0 - 1]], and the block is decoded into [dst] from [dp0], never past [de]. A match
   may start in [ext] and continue into [dst], including into bytes it is itself producing. *)

type failure =
  | Malformed  (** The block breaks the format. *)
  | Truncated  (** The block ends inside a sequence. *)
  | Overflow  (** The decoded data does not fit in [dst.[dp0 .. de - 1]]. *)

exception Fail of failure * int * int * string
(** [Fail (f, ip, op, msg)]: [ip] indexes [src] at the offending token or field, [op] indexes [dst]
    at the decoded position. *)

let fail f ip op msg = raise (Fail (f, ip, op, msg))

(* Reads the bytes extending a 15 nibble. [cap] is the most the total may reach before the caller
   would fail anyway; stopping there means the sum never needs more than [cap + 255]. *)
let extension src ip se op base cap what =
  let len = ref base in
  let continue = ref true in
  while !continue do
    if !ip >= se then fail Truncated !ip op ("unterminated " ^ what ^ " length");
    let b = Char.code (Bytes.get src !ip) in
    incr ip;
    len := !len + b;
    if b <> 255 then continue := false
    else if !len > cap then fail Overflow !ip op (what ^ " length exceeds the output space")
  done;
  !len

(* dst.[d .. d + n - 1] <- dst.[s .. s + n - 1] with s < d, forward, so bytes produced by the copy
   feed its later bytes. The block [dst.[s .. d - 1]] has period [d - s]; doubling a prefix whose
   length is a multiple of the period keeps that property, so blits can do the work. *)
let overlap_copy dst s d n =
  let period = d - s in
  if period >= n then Bytes.blit dst s dst d n
  else (
    Bytes.blit dst s dst d period;
    let filled = ref period in
    while !filled < n do
      let k = min !filled (n - !filled) in
      Bytes.blit dst d dst (d + !filled) k;
      filled := !filled + k
    done)

let decode ~src ~sp ~se ~dst ~hist ~dp0 ~de ~ext ~ext_off ~ext_len =
  let ip = ref sp and op = ref dp0 in
  let last_match = ref (-1) in
  let result = ref (-1) in
  while !result < 0 do
    let token_at = !ip in
    if token_at >= se then fail Truncated token_at !op "missing token";
    let token = Char.code (Bytes.get src token_at) in
    incr ip;
    let lit = token lsr 4 in
    let lit = if lit = 15 then extension src ip se !op 15 (de - !op) "literal" else lit in
    if lit > de - !op then fail Overflow token_at !op "literals exceed the output space";
    if lit > se - !ip then fail Truncated token_at !op "literals run past the end of the block";
    Bytes.blit src !ip dst !op lit;
    ip := !ip + lit;
    op := !op + lit;
    if !ip = se then (
      (* The last sequence: literals only. The spec's end-of-block conditions apply only when the
         block has a match: the last 5 bytes are literals and the last match starts at least 12
         bytes before the end. *)
      if !last_match >= 0 then (
        if lit < 5 then fail Malformed token_at !op "fewer than 5 literals after the last match";
        if !op - !last_match < 12 then
          fail Malformed token_at !op "last match starts less than 12 bytes before the end");
      result := !op)
    else (
      if se - !ip < 2 then fail Truncated !ip !op "truncated offset";
      let offset = Char.code (Bytes.get src !ip) lor (Char.code (Bytes.get src (!ip + 1)) lsl 8) in
      let offset_at = !ip in
      ip := !ip + 2;
      if offset = 0 then fail Malformed offset_at !op "zero offset";
      if offset > !op - hist + ext_len then fail Malformed offset_at !op "offset before the history";
      let mlen = token land 15 in
      let mlen = if mlen = 15 then extension src ip se !op 15 (de - !op) "match" else mlen in
      let mlen = mlen + 4 in
      if mlen > de - !op then fail Overflow token_at !op "match exceeds the output space";
      last_match := !op;
      let s = !op - offset in
      (if s >= hist then overlap_copy dst s !op mlen
       else
         (* Starts in ext; [hist - s] bytes come from it, the rest from dst.[hist ..]. *)
         let from_ext = min mlen (hist - s) in
         Bytes.blit ext (ext_off + ext_len - (hist - s)) dst !op from_ext;
         if mlen > from_ext then overlap_copy dst hist (!op + from_ext) (mlen - from_ext));
      op := !op + mlen)
  done;
  !result
