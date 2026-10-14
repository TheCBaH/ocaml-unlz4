(* Decoding throughput per corpus frame and raw block, in decoded MB/s. Run several rounds of each
   fixture for at least [min_time] seconds of CPU time. *)

module C = Unlz4_test_support.Corpus

let min_time = try float_of_string (Sys.getenv "UNLZ4_BENCH_TIME") with Not_found -> 0.3

let measure f =
  let t0 = Sys.time () in
  let rec go n =
    f ();
    let dt = Sys.time () -. t0 in
    if dt < min_time then go (n + 1) else (n, dt)
  in
  go 1

let () =
  let backend =
    match Sys.backend_type with
    | Sys.Native -> "native"
    | Sys.Bytecode -> "bytecode"
    | Sys.Other s -> s
  in
  Printf.printf "%-22s %10s %10s %10s  (%s)\n" "fixture" "in" "out" "MB/s" backend;
  let total_bytes = ref 0. and total_time = ref 0. in
  List.iter
    (fun f ->
      let plain = Lazy.force f.C.plain in
      let dictionary = Option.map Unlz4.Dictionary.of_string (Lazy.force f.C.dict) in
      let run () =
        match f.C.kind with
        | C.Frame -> (
            let has_id = not (List.mem "dictid=0x00000000" (String.split_on_char ',' f.C.opts)) in
            let resolve_dictionary =
              if has_id then Option.map (fun d _ -> Some d) dictionary else None
            in
            let dictionary = if has_id then None else dictionary in
            match Unlz4.Frame.decompress ?dictionary ?resolve_dictionary f.C.compressed with
            | Ok s -> assert (String.length s = String.length plain)
            | Error e -> failwith (Unlz4.Error.to_string e))
        | C.Block -> (
            match
              Unlz4.Block.decompress ?dictionary ~max_output:(String.length plain) f.C.compressed
            with
            | Ok _ -> ()
            | Error e -> failwith (Unlz4.Error.to_string e))
      in
      if String.length plain >= 50_000 then (
        let n, dt = measure run in
        let bytes = float_of_int n *. float_of_int (String.length plain) in
        total_bytes := !total_bytes +. bytes;
        total_time := !total_time +. dt;
        Printf.printf "%-22s %10d %10d %10.1f\n%!" f.C.name (String.length f.C.compressed)
          (String.length plain)
          (bytes /. dt /. 1e6)))
    C.fixtures;
  Printf.printf "%-22s %32.1f\n" "overall" (!total_bytes /. !total_time /. 1e6)
