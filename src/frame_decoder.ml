(* The resumable LZ4 frame decoder. See docs/design.md, "Decoder architecture".

   Fixed-size fields (magic, descriptor, block headers, checksums, skippable sizes) are collected
   into [hdr] across calls. A block payload is decoded straight from the caller's input when it is
   all there, and otherwise collected into [cbuf] first. A decoded block goes into [win], after its
   history, and is drained to the caller before the next block header is read. *)

type mode = Single | Concatenated
type status = Need_input | Need_output | Frame_end | Stream_end
type progress = { consumed : int; produced : int; status : status }

type info = {
  block_max_size : int;
  block_independent : bool;
  block_checksum : bool;
  content_checksum : bool;
  content_size : int64 option;
  dictionary_id : int32 option;
}

type phase =
  | Magic
  | Descriptor
  | Block_header
  | Block_payload
  | Block_checksum
  | Emit
  | Footer
  | Skip_size
  | Skip_payload
  | Finished_single
  | Finished_stream

type t = {
  limits : Limits.t;
  mode : mode;
  dictionary : Dictionary.t option;
  resolve : (int32 -> Dictionary.t option) option;
  mutable phase : phase;
  mutable error : Error.t option;
  hdr : bytes;
  mutable hdr_len : int;
  mutable hdr_need : int;
  mutable field_at : int64;  (** Compressed offset of the field being collected. *)
  mutable total_in : int64;
  mutable total_out : int64;
  mutable decoded : int64;
  mutable frames : int64;  (** Modern and skippable frames started. *)
  mutable modern : int;  (** Modern frames started. *)
  mutable skipped : int64;
  mutable seen_frame : bool;
  mutable eof_seen : bool;
  mutable eof_remaining : int;
  (* The current modern frame. *)
  mutable info : info option;
  mutable desc_at : int64;
  mutable block_max : int;
  mutable independent : bool;
  mutable block_checksum : bool;
  mutable content_checksum : bool;
  mutable content_size : int64 option;
  mutable frame_out : int64;
  mutable block_index : int;
  hash : Xxh32.t;
  (* The current block. *)
  mutable stored : bool;
  mutable bsize : int;
  mutable block_at : int64;
  mutable cbuf : bytes;
  mutable cfill : int;
  mutable win : bytes;
  mutable hist_len : int;
  mutable out_pos : int;
  mutable out_end : int;
  mutable skip_left : int64;
}

let window = Dictionary.window
let magic_modern = 0x184D2204l
let magic_legacy = 0x184C2102l

let create ?(limits = Limits.default) ?(mode = Concatenated) ?dictionary ?resolve_dictionary () =
  {
    limits;
    mode;
    dictionary;
    resolve = resolve_dictionary;
    phase = Magic;
    error = None;
    hdr = Bytes.create 16;
    hdr_len = 0;
    hdr_need = 4;
    field_at = 0L;
    total_in = 0L;
    total_out = 0L;
    decoded = 0L;
    frames = 0L;
    modern = 0;
    skipped = 0L;
    seen_frame = false;
    eof_seen = false;
    eof_remaining = 0;
    info = None;
    desc_at = 0L;
    block_max = 0;
    independent = false;
    block_checksum = false;
    content_checksum = false;
    content_size = None;
    frame_out = 0L;
    block_index = 0;
    hash = Xxh32.create ();
    stored = false;
    bsize = 0;
    block_at = 0L;
    cbuf = Bytes.empty;
    cfill = 0;
    win = Bytes.empty;
    hist_len = 0;
    out_pos = 0;
    out_end = 0;
    skip_left = 0L;
  }

let info t = t.info
let total_in t = t.total_in
let total_out t = t.total_out

exception Stop of Error.t

let in_frame t =
  match t.phase with
  | Descriptor | Block_header | Block_payload | Block_checksum | Emit | Footer -> true
  | Magic | Skip_size | Skip_payload | Finished_single | Finished_stream -> false

let stop ?decoded ?(block = false) t kind at message =
  let frame_index = if in_frame t then Some (t.modern - 1) else None in
  let block_index = if block && frame_index <> None then Some t.block_index else None in
  let decoded_offset = match decoded with Some d -> d | None -> t.decoded in
  raise
    (Stop { Error.kind; compressed_offset = at; decoded_offset; frame_index; block_index; message })

let get32 b i =
  let byte k = Char.code (Bytes.get b (i + k)) in
  Int32.logor
    (Int32.of_int (byte 0 lor (byte 1 lsl 8) lor (byte 2 lsl 16)))
    (Int32.shift_left (Int32.of_int (byte 3)) 24)

let u32_to_int64 v = Int64.logand (Int64.of_int32 v) 0xFFFFFFFFL

let start_field t at need =
  t.hdr_len <- 0;
  t.hdr_need <- need;
  t.field_at <- at

(* Allocates the frame buffers and seeds the history once the descriptor is accepted. *)
let start_blocks t (dict : Dictionary.t) =
  let dlen = Bytes.length dict.data in
  let need = (if t.independent then dlen else window) + t.block_max in
  if Bytes.length t.win < need then t.win <- Buf.create need;
  Bytes.blit dict.data 0 t.win 0 dlen;
  t.hist_len <- dlen;
  t.out_pos <- 0;
  t.out_end <- 0

let resolve_dictionary t id =
  let at = Int64.add t.desc_at (Int64.of_int (if t.content_size = None then 2 else 10)) in
  let check (d : Dictionary.t) =
    match d.id with
    | Some x when not (Int32.equal x id) ->
        stop t Error.Dictionary_id_mismatch at
          (Printf.sprintf "frame needs dictionary 0x%08lx, got 0x%08lx" id x)
    | _ -> d
  in
  match (t.resolve, t.dictionary) with
  | Some resolve, _ -> (
      match resolve id with
      | Some d -> check d
      | None -> stop t Error.Missing_dictionary at (Printf.sprintf "no dictionary 0x%08lx" id))
  | None, Some d -> check d
  | None, None -> stop t Error.Missing_dictionary at (Printf.sprintf "no dictionary 0x%08lx" id)

let parse_flags t =
  let flg = Char.code (Bytes.get t.hdr 0) and bd = Char.code (Bytes.get t.hdr 1) in
  if flg lsr 6 <> 1 then
    stop t Error.Unsupported_feature t.desc_at
      (Printf.sprintf "frame version %d is not supported" (flg lsr 6));
  if flg land 0x02 <> 0 || bd land 0x8F <> 0 then
    stop t Error.Invalid_frame t.desc_at "reserved descriptor bits are set";
  let code = (bd lsr 4) land 7 in
  if code < 4 then
    stop t Error.Invalid_frame (Int64.succ t.desc_at)
      (Printf.sprintf "invalid block maximum size code %d" code);
  2 + (if flg land 0x08 <> 0 then 8 else 0) + (if flg land 0x01 <> 0 then 4 else 0) + 1

let accept_descriptor t =
  let len = t.hdr_len in
  let flg = Char.code (Bytes.get t.hdr 0) and bd = Char.code (Bytes.get t.hdr 1) in
  let hc = (Int32.to_int (Xxh32.bytes t.hdr 0 (len - 1)) lsr 8) land 0xFF in
  if hc <> Char.code (Bytes.get t.hdr (len - 1)) then
    stop t Error.Checksum_mismatch
      (Int64.add t.desc_at (Int64.of_int (len - 1)))
      "frame descriptor checksum mismatch";
  let block_max = 1 lsl (8 + (2 * ((bd lsr 4) land 7))) in
  if block_max > t.limits.max_block_size then
    stop t Error.Limit_exceeded (Int64.succ t.desc_at)
      (Printf.sprintf "block maximum %d exceeds the limit %d" block_max t.limits.max_block_size);
  let content_size =
    if flg land 0x08 = 0 then None
    else
      let lo = u32_to_int64 (get32 t.hdr 2) and hi = get32 t.hdr 6 in
      if Int32.compare hi 0l < 0 then
        stop t Error.Limit_exceeded (Int64.add t.desc_at 2L)
          "declared content size exceeds the supported range";
      Some (Int64.logor lo (Int64.shift_left (Int64.of_int32 hi) 32))
  in
  t.content_size <- content_size;
  let dictionary_id =
    if flg land 0x01 = 0 then None else Some (get32 t.hdr (if content_size = None then 2 else 10))
  in
  t.block_max <- block_max;
  t.independent <- flg land 0x20 <> 0;
  t.block_checksum <- flg land 0x10 <> 0;
  t.content_checksum <- flg land 0x04 <> 0;
  t.info <-
    Some
      {
        block_max_size = block_max;
        block_independent = t.independent;
        block_checksum = t.block_checksum;
        content_checksum = t.content_checksum;
        content_size;
        dictionary_id;
      };
  let dict =
    match dictionary_id with
    | Some id -> resolve_dictionary t id
    | None -> ( match t.dictionary with Some d -> d | None -> Dictionary.empty)
  in
  start_blocks t dict;
  t.frame_out <- 0L;
  t.block_index <- 0;
  Xxh32.reset t.hash

(* Decodes the payload src.[off .. off + bsize - 1] into the window and makes it pending output. *)
let decode_block t src off =
  let base = t.hist_len in
  let decoded_before = t.decoded in
  let n =
    if t.stored then (
      Bytes.blit src off t.win base t.bsize;
      t.bsize)
    else
      match
        Block_decoder.decode ~src ~sp:off ~se:(off + t.bsize) ~dst:t.win ~hist:0 ~dp0:base
          ~de:(base + t.block_max) ~ext:Bytes.empty ~ext_off:0 ~ext_len:0
      with
      | e -> e - base
      | exception Block_decoder.Fail (_, ip, op, msg) ->
          stop
            ~decoded:(Int64.add decoded_before (Int64.of_int (op - base)))
            ~block:true t Error.Invalid_block
            (Int64.add t.block_at (Int64.of_int (ip - off)))
            msg
  in
  let n64 = Int64.of_int n in
  (match t.content_size with
  | Some cs when Int64.compare n64 (Int64.sub cs t.frame_out) > 0 ->
      stop ~block:true t Error.Content_size_mismatch t.block_at
        "decoded data exceeds the declared content size"
  | _ -> ());
  if Int64.compare n64 (Int64.sub t.limits.max_output t.decoded) > 0 then
    stop ~block:true t Error.Limit_exceeded t.block_at "output exceeds max_output";
  if t.content_checksum then Xxh32.update t.hash t.win base n;
  t.frame_out <- Int64.add t.frame_out n64;
  t.decoded <- Int64.add t.decoded n64;
  t.out_pos <- base;
  t.out_end <- base + n;
  t.phase <- Emit

(* After a block is drained: linked frames keep the last 64 KiB as history. *)
let finish_block t =
  (if not t.independent then
     let e = t.out_end in
     if e > window then (
       Bytes.blit t.win (e - window) t.win 0 window;
       t.hist_len <- window)
     else t.hist_len <- e);
  t.block_index <- t.block_index + 1;
  t.phase <- Block_header

let verify_block_checksum t data off expected at =
  if not (Int32.equal (Xxh32.bytes data off t.bsize) expected) then
    stop ~block:true t Error.Checksum_mismatch at "block checksum mismatch"

let frame_done t =
  match t.mode with
  | Single ->
      t.phase <- Finished_single;
      Frame_end
  | Concatenated ->
      t.phase <- Magic;
      start_field t 0L 4;
      Frame_end

let decode t ~src ~src_off ~src_len ~eof ~dst ~dst_off ~dst_len () =
  if src_off < 0 || src_len < 0 || src_off > Bytes.length src - src_len then
    invalid_arg "Unlz4.Frame.decode: invalid source range";
  if dst_off < 0 || dst_len < 0 || dst_off > Bytes.length dst - dst_len then
    invalid_arg "Unlz4.Frame.decode: invalid destination range";
  if src == dst then invalid_arg "Unlz4.Frame.decode: source and destination are the same buffer";
  if t.eof_seen && not eof then invalid_arg "Unlz4.Frame.decode: input already ended (eof:true)";
  if t.eof_seen && src_len <> t.eof_remaining then
    invalid_arg "Unlz4.Frame.decode: after eof:true, pass exactly the unconsumed input";
  match t.error with
  | Some e -> Error e
  | None -> (
      let allowed = Int64.sub t.limits.max_input t.total_in in
      let lim_len =
        if Int64.compare allowed (Int64.of_int src_len) < 0 then Int64.to_int allowed else src_len
      in
      let eof_now = eof && lim_len = src_len in
      let ip = ref src_off and op = ref dst_off in
      let ie = src_off + lim_len and oe = dst_off + dst_len in
      let pos () = Int64.add t.total_in (Int64.of_int (!ip - src_off)) in
      let need_more what =
        if eof_now then stop t Error.Truncated_input t.field_at ("truncated " ^ what)
        else if lim_len < src_len then
          stop t Error.Limit_exceeded (pos ()) "input exceeds max_input"
        else Need_input
      in
      let collect () =
        let n = min (t.hdr_need - t.hdr_len) (ie - !ip) in
        Bytes.blit src !ip t.hdr t.hdr_len n;
        ip := !ip + n;
        t.hdr_len <- t.hdr_len + n;
        t.hdr_len = t.hdr_need
      in
      let start_frame () =
        if Int64.compare t.frames t.limits.max_frames >= 0 then
          stop t Error.Limit_exceeded t.field_at "frame count exceeds max_frames";
        t.frames <- Int64.succ t.frames;
        t.seen_frame <- true
      in
      let rec step () =
        match t.phase with
        | Finished_single -> Frame_end
        | Finished_stream -> Stream_end
        | Magic ->
            if t.hdr_len = 0 then t.field_at <- pos ();
            if t.hdr_len = 0 && !ip = ie && eof_now then
              if t.mode = Concatenated && t.seen_frame then (
                t.phase <- Finished_stream;
                Stream_end)
              else stop t Error.Truncated_input t.field_at "missing frame"
            else if not (collect ()) then need_more "magic number"
            else
              let magic = get32 t.hdr 0 in
              if Int32.equal magic magic_modern then (
                start_frame ();
                t.modern <- t.modern + 1;
                t.desc_at <- pos ();
                t.phase <- Descriptor;
                start_field t t.desc_at 2;
                step ())
              else if Int32.equal (Int32.logand magic 0xFFFFFFF0l) 0x184D2A50l then (
                start_frame ();
                t.phase <- Skip_size;
                start_field t (pos ()) 4;
                step ())
              else if Int32.equal magic magic_legacy then
                stop t Error.Unsupported_feature t.field_at "legacy frame format"
              else stop t Error.Invalid_frame t.field_at "unknown magic number"
        | Descriptor ->
            if not (collect ()) then need_more "frame descriptor"
            else if t.hdr_need = 2 then (
              t.hdr_need <- parse_flags t;
              step ())
            else (
              accept_descriptor t;
              t.phase <- Block_header;
              start_field t (pos ()) 4;
              step ())
        | Block_header ->
            if not (collect ()) then need_more "block header"
            else
              let v = get32 t.hdr 0 in
              if Int32.equal v 0l then (
                (match t.content_size with
                | Some cs when not (Int64.equal cs t.frame_out) ->
                    stop t Error.Content_size_mismatch t.field_at
                      (Printf.sprintf "frame declares %Ld bytes but holds %Ld" cs t.frame_out)
                | _ -> ());
                if t.content_checksum then (
                  t.phase <- Footer;
                  start_field t (pos ()) 4;
                  step ())
                else frame_done t)
              else
                let size = Int32.logand v 0x7FFFFFFFl in
                if Int32.compare size (Int32.of_int t.block_max) > 0 then
                  stop ~block:true t Error.Invalid_frame t.field_at
                    "block size exceeds the frame's block maximum";
                t.stored <- Int32.compare v 0l < 0;
                t.bsize <- Int32.to_int size;
                t.block_at <- pos ();
                let need = t.bsize + if t.block_checksum then 4 else 0 in
                if ie - !ip >= need then (
                  if t.block_checksum then
                    verify_block_checksum t src !ip
                      (get32 src (!ip + t.bsize))
                      (Int64.add t.block_at (Int64.of_int t.bsize));
                  let off = !ip in
                  ip := !ip + need;
                  decode_block t src off;
                  step ())
                else (
                  if Bytes.length t.cbuf < t.block_max then t.cbuf <- Buf.create t.block_max;
                  t.cfill <- 0;
                  t.field_at <- t.block_at;
                  t.phase <- Block_payload;
                  step ())
        | Block_payload ->
            let n = min (t.bsize - t.cfill) (ie - !ip) in
            Bytes.blit src !ip t.cbuf t.cfill n;
            ip := !ip + n;
            t.cfill <- t.cfill + n;
            if t.cfill < t.bsize then need_more "block"
            else if t.block_checksum then (
              t.phase <- Block_checksum;
              start_field t (pos ()) 4;
              step ())
            else (
              decode_block t t.cbuf 0;
              step ())
        | Block_checksum ->
            if not (collect ()) then need_more "block checksum"
            else (
              verify_block_checksum t t.cbuf 0 (get32 t.hdr 0) t.field_at;
              decode_block t t.cbuf 0;
              step ())
        | Emit ->
            let n = min (t.out_end - t.out_pos) (oe - !op) in
            Bytes.blit t.win t.out_pos dst !op n;
            t.out_pos <- t.out_pos + n;
            op := !op + n;
            if t.out_pos < t.out_end then Need_output
            else (
              finish_block t;
              start_field t (pos ()) 4;
              step ())
        | Footer ->
            if not (collect ()) then need_more "content checksum"
            else if not (Int32.equal (get32 t.hdr 0) (Xxh32.digest t.hash)) then
              stop t Error.Checksum_mismatch t.field_at "content checksum mismatch"
            else frame_done t
        | Skip_size ->
            if not (collect ()) then need_more "skippable frame size"
            else
              let size = u32_to_int64 (get32 t.hdr 0) in
              if Int64.compare size (Int64.sub t.limits.max_skipped t.skipped) > 0 then
                stop t Error.Limit_exceeded t.field_at "skipped bytes exceed max_skipped";
              t.skipped <- Int64.add t.skipped size;
              t.skip_left <- size;
              t.field_at <- pos ();
              t.phase <- Skip_payload;
              step ()
        | Skip_payload ->
            let avail = ie - !ip in
            let n =
              if Int64.compare t.skip_left (Int64.of_int avail) < 0 then Int64.to_int t.skip_left
              else avail
            in
            ip := !ip + n;
            t.skip_left <- Int64.sub t.skip_left (Int64.of_int n);
            if Int64.equal t.skip_left 0L then (
              t.phase <- Magic;
              start_field t (pos ()) 4;
              step ())
            else need_more "skippable frame"
      in
      let finish status =
        let consumed = !ip - src_off and produced = !op - dst_off in
        t.total_in <- Int64.add t.total_in (Int64.of_int consumed);
        t.total_out <- Int64.add t.total_out (Int64.of_int produced);
        if eof then (
          t.eof_seen <- true;
          t.eof_remaining <- src_len - consumed);
        { consumed; produced; status }
      in
      match step () with
      | status -> Ok (finish status)
      | exception Stop e ->
          (* Count what this call consumed and wrote, so the caller can find the decoded prefix
             through total_out. *)
          ignore (finish Need_input);
          t.error <- Some e;
          Error e)

let decompress ?(limits = Limits.default) ?dictionary ?resolve_dictionary s =
  let cap = Int64.of_int Sys.max_string_length in
  let limits =
    if Int64.compare limits.Limits.max_output cap > 0 then { limits with max_output = cap }
    else limits
  in
  let t = create ~limits ~mode:Concatenated ?dictionary ?resolve_dictionary () in
  let src = Bytes.of_string s in
  let chunk = Bytes.create 65536 in
  let out = Buffer.create (min ((String.length s * 2) + 16) (1 lsl 20)) in
  let rec go off =
    match
      decode t ~src ~src_off:off
        ~src_len:(String.length s - off)
        ~eof:true ~dst:chunk ~dst_off:0 ~dst_len:(Bytes.length chunk) ()
    with
    | Error e -> Error e
    | Ok { consumed; produced; status } -> (
        Buffer.add_subbytes out chunk 0 produced;
        match status with
        | Stream_end -> Ok (Buffer.contents out)
        | Need_input | Need_output | Frame_end -> go (off + consumed))
  in
  go 0
