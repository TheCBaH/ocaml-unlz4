[@@@ai_disclosure "ai-generated"]
[@@@ai_provider "Anthropic, OpenAI"]

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
            | Error e -> failwith (Format.asprintf "%a" Unlz4.Error.pp e))
        | C.Block -> (
            match
              Unlz4.Block.decompress ?dictionary ~max_output:(String.length plain) f.C.compressed
            with
            | Ok _ -> ()
            | Error e -> failwith (Format.asprintf "%a" Unlz4.Error.pp e))
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
  (* One-setting-at-a-time pairs over the same literal payload, with bytes allocated per run. *)
  let module B = Unlz4_test_support.Builder in
  let payload = Unlz4_test_support.Gen.generate Unlz4_test_support.Gen.Mix ~seed:5 (60_000 * 20) in
  let blocks =
    List.init 20 (fun i -> B.Compressed (B.literal_block (String.sub payload (i * 60_000) 60_000)))
  in
  let allocs = ref [] in
  let pair name f =
    let src = B.frame ~f ~content:payload blocks in
    let run () =
      match Unlz4.Frame.decompress src with
      | Ok s -> assert (String.length s = String.length payload)
      | Error e -> failwith (Format.asprintf "%a" Unlz4.Error.pp e)
    in
    run ();
    let a0 = Gc.allocated_bytes () in
    run ();
    let alloc = Gc.allocated_bytes () -. a0 in
    allocs := (name, alloc) :: !allocs;
    let n, dt = measure run in
    Printf.printf "%-22s %10d %10d %10.1f  alloc %.0f KiB\n%!" name (String.length src)
      (String.length payload)
      (float_of_int (n * String.length payload) /. dt /. 1e6)
      (alloc /. 1024.)
  in
  let f = B.flags in
  pair "pair-base" { f with B.independent = true; bd_code = 4 };
  pair "pair-linked" { f with B.independent = false };
  pair "pair-block-checksum" { f with B.independent = true; block_checksum = true };
  pair "pair-content-checksum" { f with B.independent = true; content_checksum = true };
  pair "pair-4m-blocks" { f with B.independent = true; bd_code = 7 };
  (* Allocation is deterministic, unlike throughput, so it is the regression gate: a checksum or a
     linked block must not allocate per block. js_of_ocaml reports no allocation. *)
  (let get n = List.assoc n !allocs in
   let base = get "pair-base" in
   let check name limit =
     if get name > limit then
       failwith
         (Printf.sprintf "%s allocates %.0f KiB, over %.0f KiB" name
            (get name /. 1024.)
            (limit /. 1024.))
   in
   check "pair-base" (6. *. 1048576.);
   List.iter
     (fun n -> check n (base +. 262144.))
     [ "pair-linked"; "pair-block-checksum"; "pair-content-checksum" ]);
  (let src, expected = Unlz4_test_support.Builder.tiny_linked 100_000 in
   let n, dt =
     measure (fun () ->
         match Unlz4.Frame.decompress src with
         | Ok s -> assert (String.length s = String.length expected)
         | Error e -> failwith (Format.asprintf "%a" Unlz4.Error.pp e))
   in
   Printf.printf "%-22s %10d %10d %10.1f\n%!" "tiny-linked-blocks" (String.length src)
     (String.length expected)
     (float_of_int (n * String.length expected) /. dt /. 1e6));
  Printf.printf "%-22s %32.1f\n" "overall" (!total_bytes /. !total_time /. 1e6)
