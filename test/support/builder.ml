[@@@ai_disclosure "ai-generated"]
[@@@ai_provider "Anthropic, OpenAI"]

(* Encoders for handcrafted test inputs: LZ4 sequences, blocks and frames written independently of
   any compressor, so tests can cover patterns a compressor never emits. *)

let xxh32 s = Unlz4.Private.Xxh32.string s

let add_u32 b v =
  for i = 0 to 3 do
    Buffer.add_char b
      (Char.chr (Int32.to_int (Int32.logand (Int32.shift_right_logical v (8 * i)) 0xFFl)))
  done

let add_u64 b v =
  for i = 0 to 7 do
    Buffer.add_char b
      (Char.chr (Int64.to_int (Int64.logand (Int64.shift_right_logical v (8 * i)) 0xFFL)))
  done

let u32 v =
  let b = Buffer.create 4 in
  add_u32 b v;
  Buffer.contents b

let add_ext b n =
  let n = ref n in
  while !n >= 255 do
    Buffer.add_char b '\255';
    n := !n - 255
  done;
  Buffer.add_char b (Char.chr !n)

(* A sequence: literals, then an optional match (offset, length >= 4). *)
type seq = string * (int * int) option

let block (seqs : seq list) =
  let b = Buffer.create 64 in
  List.iter
    (fun (lits, m) ->
      let l = String.length lits in
      let ml = match m with None -> 0 | Some (_, ml) -> ml - 4 in
      Buffer.add_char b (Char.chr ((min l 15 lsl 4) lor min ml 15));
      if l >= 15 then add_ext b (l - 15);
      Buffer.add_string b lits;
      match m with
      | None -> ()
      | Some (off, _) ->
          Buffer.add_char b (Char.chr (off land 0xFF));
          Buffer.add_char b (Char.chr (off lsr 8));
          if ml >= 15 then add_ext b (ml - 15))
    seqs;
  Buffer.contents b

let literal_block s = block [ (s, None) ]

(* The plain text of [seqs] decoded after [history]: a byte-at-a-time reference decoder. *)
let expand ?(history = "") (seqs : seq list) =
  let h = String.length history in
  let n =
    List.fold_left
      (fun n (l, m) -> n + String.length l + match m with None -> 0 | Some (_, ml) -> ml)
      h seqs
  in
  let b = Bytes.create n in
  (* See Gen.generate: switch js_of_ocaml to the array representation before reading back. *)
  if n > 0 then Bytes.set b (n - 1) '\000';
  Bytes.blit_string history 0 b 0 h;
  let pos = ref h in
  List.iter
    (fun (lits, m) ->
      Bytes.blit_string lits 0 b !pos (String.length lits);
      pos := !pos + String.length lits;
      match m with
      | None -> ()
      | Some (off, ml) ->
          for _ = 1 to ml do
            Bytes.set b !pos (Bytes.get b (!pos - off));
            incr pos
          done)
    seqs;
  Bytes.sub_string b h (n - h)

type flags = {
  version : int;
  independent : bool;
  block_checksum : bool;
  content_checksum : bool;
  content_size : int64 option;
  dict_id : int32 option;
  bd_code : int;
  reserved_flg : bool;
  reserved_bd : int;
}

let flags =
  {
    version = 1;
    independent = true;
    block_checksum = false;
    content_checksum = false;
    content_size = None;
    dict_id = None;
    bd_code = 4;
    reserved_flg = false;
    reserved_bd = 0;
  }

let descriptor ?hc f =
  let b = Buffer.create 15 in
  let flg =
    (f.version lsl 6)
    lor (if f.independent then 0x20 else 0)
    lor (if f.block_checksum then 0x10 else 0)
    lor (if f.content_size <> None then 0x08 else 0)
    lor (if f.content_checksum then 0x04 else 0)
    lor (if f.reserved_flg then 0x02 else 0)
    lor if f.dict_id <> None then 0x01 else 0
  in
  Buffer.add_char b (Char.chr flg);
  Buffer.add_char b (Char.chr ((f.bd_code lsl 4) lor f.reserved_bd));
  Option.iter (add_u64 b) f.content_size;
  Option.iter (add_u32 b) f.dict_id;
  let d = Buffer.contents b in
  let hc = match hc with Some h -> h | None -> (Int32.to_int (xxh32 d) lsr 8) land 0xFF in
  d ^ String.make 1 (Char.chr hc)

type data_block =
  | Compressed of string
  | Stored of string
  | Raw of string  (** Written verbatim: header, payload and any checksum. *)

let magic = "\x04\x22\x4d\x18"

(* A modern frame. [content] is what the content checksum covers. *)
let frame ?(f = flags) ?hc ?(content = "") ?content_checksum_value blocks =
  let b = Buffer.create 64 in
  Buffer.add_string b magic;
  Buffer.add_string b (descriptor ?hc f);
  let add_block stored data =
    let size = Int32.of_int (String.length data) in
    add_u32 b (if stored then Int32.logor size 0x80000000l else size);
    Buffer.add_string b data;
    if f.block_checksum then add_u32 b (xxh32 data)
  in
  List.iter
    (function
      | Compressed d -> add_block false d
      | Stored d -> add_block true d
      | Raw r -> Buffer.add_string b r)
    blocks;
  add_u32 b 0l;
  if f.content_checksum then
    add_u32 b (match content_checksum_value with Some v -> v | None -> xxh32 content);
  Buffer.contents b

let skippable ?(nibble = 0) payload =
  let b = Buffer.create 8 in
  add_u32 b (Int32.logor 0x184D2A50l (Int32.of_int nibble));
  add_u32 b (Int32.of_int (String.length payload));
  Buffer.add_string b payload;
  Buffer.contents b
