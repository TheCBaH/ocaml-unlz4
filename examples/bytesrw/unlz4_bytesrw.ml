[@@@ai_disclosure "ai-generated"]
[@@@ai_provider "Anthropic, OpenAI"]

open Bytesrw

type Bytes.Stream.error += Error of Unlz4.Error.t

let format_error =
  let message = function
    | Error e -> Format.asprintf "%a" Unlz4.Error.pp e
    | _ -> "lz4: unknown error"
  in
  Bytes.Stream.make_format_error ~format:"lz4" ~case:(fun e -> Error e) ~message

(* The filter's own position must stay within [max_int]: bound the decoder's output to what is
   left above the starting position. *)
let with_position_cap limits pos =
  let limits = match limits with Some l -> l | None -> Unlz4.Limits.default in
  let room = Int64.of_int (max_int - max 0 pos) in
  if Int64.compare (Unlz4.Limits.max_output limits) room <= 0 then limits
  else Unlz4.Limits.with_max_output limits room

let decompress_reads ?limits ?(mode = Unlz4.Frame.Concatenated) ?dictionary ?resolve_dictionary ()
    ?(pos = 0) ?(slice_length = Bytes.Slice.io_buffer_size) r =
  if slice_length <= 0 then invalid_arg "Unlz4_bytesrw.decompress_reads: slice_length";
  let limits = with_position_cap limits pos in
  let d = Unlz4.Frame.create ~limits ~mode ?dictionary ?resolve_dictionary () in
  let out = Bytes.create slice_length in
  (* The current upstream slice and how much of it is left. *)
  let src = ref Bytes.empty and src_off = ref 0 and src_len = ref 0 in
  let eof = ref false and finished = ref false in
  let rec read () =
    if !finished then Bytes.Slice.eod
    else (
      (if !src_len = 0 && not !eof then
         let s = Bytes.Reader.read r in
         if Bytes.Slice.is_eod s then eof := true
         else (
           src := Bytes.Slice.bytes s;
           src_off := Bytes.Slice.first s;
           src_len := Bytes.Slice.length s));
      match
        Unlz4.Frame.decode d ~src:!src ~src_off:!src_off ~src_len:!src_len ~eof:!eof ~dst:out
          ~dst_off:0 ~dst_len:slice_length ()
      with
      | Error e -> Bytes.Reader.error format_error r e
      | Ok { consumed; produced; status } -> (
          src_off := !src_off + consumed;
          src_len := !src_len - consumed;
          let slice () = Bytes.Slice.make out ~first:0 ~length:produced in
          match status with
          | Need_output -> slice ()
          | Need_input -> if produced > 0 then slice () else read ()
          | Frame_end when mode = Unlz4.Frame.Concatenated ->
              if produced > 0 then slice () else read ()
          | Frame_end | Stream_end ->
              finished := true;
              if !src_len > 0 then
                Bytes.Reader.push_back r (Bytes.Slice.make !src ~first:!src_off ~length:!src_len);
              src_len := 0;
              if produced > 0 then slice () else Bytes.Slice.eod))
  in
  Bytes.Reader.make ~pos ~slice_length read

let decompress_writes ?limits ?dictionary ?resolve_dictionary () ?(pos = 0) ?slice_length ~eod w =
  let limits = with_position_cap limits pos in
  let d =
    Unlz4.Frame.create ~limits ~mode:Unlz4.Frame.Concatenated ?dictionary ?resolve_dictionary ()
  in
  let out_length = Bytes.Writer.slice_length w in
  let out = Bytes.create out_length in
  let slice_length = match slice_length with Some l -> l | None -> out_length in
  let rec drain src off len eof =
    match
      Unlz4.Frame.decode d ~src ~src_off:off ~src_len:len ~eof ~dst:out ~dst_off:0
        ~dst_len:out_length ()
    with
    | Error e -> Bytes.Writer.error format_error w e
    | Ok { consumed; produced; status } -> (
        if produced > 0 then Bytes.Writer.write w (Bytes.Slice.make out ~first:0 ~length:produced);
        match status with
        | Stream_end -> ()
        | Need_input when not eof -> ()
        | Need_input | Need_output | Frame_end -> drain src (off + consumed) (len - consumed) eof)
  in
  let write s =
    if Bytes.Slice.is_eod s then (
      drain Bytes.empty 0 0 true;
      if eod then Bytes.Writer.write_eod w)
    else drain (Bytes.Slice.bytes s) (Bytes.Slice.first s) (Bytes.Slice.length s) false
  in
  Bytes.Writer.make ~pos ~slice_length write
