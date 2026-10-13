(* A minimal test harness that runs unchanged natively, under js_of_ocaml and under Melange. *)

exception Check_failed of string

let failf fmt = Printf.ksprintf (fun s -> raise (Check_failed s)) fmt
let check ?(msg = "check") b = if not b then failf "%s" msg

let hex_prefix s =
  let n = min 32 (String.length s) in
  String.concat "" (List.init n (fun i -> Printf.sprintf "%02x" (Char.code s.[i])))

let first_diff a b =
  let n = min (String.length a) (String.length b) in
  let rec go i = if i < n && a.[i] = b.[i] then go (i + 1) else i in
  go 0

let check_string ?(msg = "string") ~expected actual =
  if not (String.equal expected actual) then
    failf "%s: lengths %d/%d, first difference at %d (expected %s...)" msg (String.length expected)
      (String.length actual) (first_diff expected actual) (hex_prefix expected)

let check_int ?(msg = "int") ~expected actual =
  if expected <> actual then failf "%s: expected %d, got %d" msg expected actual

let check_int64 ?(msg = "int64") ~expected actual =
  if not (Int64.equal expected actual) then failf "%s: expected %Ld, got %Ld" msg expected actual

let check_int32 ?(msg = "int32") ~expected actual =
  if not (Int32.equal expected actual) then
    failf "%s: expected 0x%08lx, got 0x%08lx" msg expected actual

let show_error e = Format.asprintf "%a" Unlz4.Error.pp e
let show_kind k = Format.asprintf "%a" Unlz4.Error.pp_kind k

let raises_invalid_arg ?(msg = "Invalid_argument") f =
  match f () with exception Invalid_argument _ -> () | _ -> failf "%s: no Invalid_argument" msg

type case = { name : string; run : unit -> unit }

let case name run = { name; run }

(* Runs the cases and returns the process exit status. *)
let run ~backend ?(info = []) cases =
  let failures = ref 0 and checks = ref 0 in
  List.iter
    (fun { name; run } ->
      incr checks;
      let t0 = Sys.time () in
      match run () with
      | () ->
          if Sys.time () -. t0 > 1.0 then Printf.printf "SLOW %s: %.1fs\n" name (Sys.time () -. t0)
      | exception Check_failed m ->
          incr failures;
          Printf.printf "FAIL %s: %s\n" name m
      | exception e ->
          incr failures;
          Printf.printf "FAIL %s: exception %s\n" name (Printexc.to_string e))
    cases;
  List.iter (fun (k, v) -> Printf.printf "%s: %s\n" k v) info;
  Printf.printf "backend %s: %d cases, %d failed\n" backend !checks !failures;
  if !failures = 0 then 0 else 1
