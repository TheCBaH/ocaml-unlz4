(* Drives Unlz4.Frame.decode over an input with independent input-chunk and output-capacity
   schedules, checking the progress contract on every call. *)

module F = Unlz4.Frame

type outcome = { output : string; result : (F.status, Unlz4.Error.t) result; consumed : int }

let frames ?(mode = F.Concatenated) ?limits ?dictionary ?resolve_dictionary
    ?(chunk = fun _ -> max_int) ?(out_cap = fun _ -> 65536) input =
  let d = F.create ?limits ~mode ?dictionary ?resolve_dictionary () in
  let n = String.length input in
  let src = Bytes.of_string input in
  let out = Buffer.create 1024 in
  let dst = ref (Bytes.create 0) in
  let pos = ref 0 and delivered = ref 0 and idle = ref 0 in
  let rec loop i =
    if !pos = !delivered && !delivered < n then
      delivered := !delivered + max 1 (min (n - !delivered) (chunk i));
    let eof = !delivered = n in
    let cap = max 0 (out_cap i) in
    if Bytes.length !dst < cap + 3 then dst := Bytes.create (cap + 3);
    let dst = !dst in
    Bytes.fill dst 0 (cap + 2) '#';
    match
      F.decode d ~src ~src_off:!pos ~src_len:(!delivered - !pos) ~eof ~dst ~dst_off:1 ~dst_len:cap
        ()
    with
    | Error e ->
        let produced =
          Int64.to_int (Int64.sub (F.total_out d) (Int64.of_int (Buffer.length out)))
        in
        Buffer.add_subbytes out dst 1 produced;
        { output = Buffer.contents out; result = Error e; consumed = !pos }
    | Ok { consumed; produced; status } -> (
        if consumed < 0 || consumed > !delivered - !pos then Harness.failf "consumed %d" consumed;
        if produced < 0 || produced > cap then Harness.failf "produced %d > %d" produced cap;
        if Bytes.get dst 0 <> '#' || Bytes.get dst (cap + 1) <> '#' then
          Harness.failf "wrote outside the output range";
        Buffer.add_subbytes out dst 1 produced;
        pos := !pos + consumed;
        if consumed = 0 && produced = 0 && cap > 0 then incr idle else idle := 0;
        if !idle > 2 then Harness.failf "no progress (status repeated without input or output)";
        (* Direct self tail calls only: js_of_ocaml and Melange turn those into loops. *)
        match status with
        | F.Stream_end -> { output = Buffer.contents out; result = Ok status; consumed = !pos }
        | F.Frame_end when mode = F.Single ->
            { output = Buffer.contents out; result = Ok status; consumed = !pos }
        | F.Frame_end -> loop (i + 1)
        | F.Need_input ->
            if eof then Harness.failf "Need_input after eof";
            if !pos <> !delivered then Harness.failf "Need_input with unconsumed input";
            loop (i + 1)
        | F.Need_output ->
            if produced <> cap then Harness.failf "Need_output with output space left";
            loop (i + 1))
  in
  loop 0

let ok ?mode ?limits ?dictionary ?resolve_dictionary ?chunk ?out_cap input =
  let o = frames ?mode ?limits ?dictionary ?resolve_dictionary ?chunk ?out_cap input in
  match o.result with
  | Ok _ -> o.output
  | Error e -> Harness.failf "unexpected error: %s" (Unlz4.Error.to_string e)

let error ?mode ?limits ?dictionary ?resolve_dictionary ?chunk ?out_cap input =
  let o = frames ?mode ?limits ?dictionary ?resolve_dictionary ?chunk ?out_cap input in
  match o.result with
  | Ok _ -> Harness.failf "decoded successfully, expected an error"
  | Error e -> e

let fails ?mode ?limits ?dictionary ?resolve_dictionary ?chunk ?out_cap kind input =
  let e = error ?mode ?limits ?dictionary ?resolve_dictionary ?chunk ?out_cap input in
  if Unlz4.Error.kind e <> kind then
    Harness.failf "expected %s, got %s" (Unlz4.Error.kind_to_string kind) (Unlz4.Error.to_string e)

(* Schedules from the repository PRNG, so they are the same on every backend and compiler. *)
let random_schedule seed max =
  let r = Gen.rng seed in
  fun _ -> Gen.below r max
