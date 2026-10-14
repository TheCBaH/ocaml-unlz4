(* createDecoder() returns { push(chunk: Uint8Array): Uint8Array[], finish(): Uint8Array[] }.
   The host awaits its own input and calls push for each chunk; outputs are copies, so they stay
   valid. Errors are thrown as JavaScript Errors. *)

open Js_of_ocaml

let out_size = 65536

let create_decoder () =
  let d = Unlz4.Frame.create () in
  let out = Bytes.create out_size in
  (* Decodes all of [src], collecting the produced slices. *)
  let run src eof =
    let outputs = ref [] in
    let rec go off =
      match
        Unlz4.Frame.decode d ~src ~src_off:off
          ~src_len:(Bytes.length src - off)
          ~eof ~dst:out ~dst_off:0 ~dst_len:out_size ()
      with
      | Error e ->
          Js_error.raise_
            (Js_error.of_error
               (Js.Unsafe.new_obj Js.error_constr
                  [| Js.Unsafe.inject (Js.string (Format.asprintf "%a" Unlz4.Error.pp e)) |]))
      | Ok { consumed; produced; status } -> (
          if produced > 0 then
            outputs := Typed_array.Bytes.to_uint8Array (Bytes.sub out 0 produced) :: !outputs;
          match status with
          | Unlz4.Frame.Stream_end -> ()
          | Need_input when not eof -> ()
          | Need_input | Need_output | Frame_end -> go (off + consumed))
    in
    go 0;
    Js.array (Array.of_list (List.rev !outputs))
  in
  let push chunk = run (Typed_array.Bytes.of_uint8Array chunk) false in
  let finish () = run Bytes.empty true in
  Js.Unsafe.obj
    [|
      ("push", Js.Unsafe.inject (Js.wrap_callback push));
      ("finish", Js.Unsafe.inject (Js.wrap_callback finish));
    |]

let () = Js.export "createDecoder" (Js.wrap_callback create_decoder)
