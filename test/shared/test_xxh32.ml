open Unlz4_test_support
open Harness
module X = Unlz4.Private.Xxh32

(* Published XXH32 values (seed 0). Upstream-generated vectors at stripe boundaries are checked by
   the corpus suite. *)
let known = [ ("", 0x02CC5D05l); ("a", 0x550D7456l); ("abc", 0x32D153FFl) ]

let chunked s chunks =
  let h = X.create () in
  let b = Bytes.of_string s in
  let pos = ref 0 in
  List.iter
    (fun n ->
      X.update h b !pos n;
      pos := !pos + n)
    chunks;
  X.update h b !pos (String.length s - !pos);
  X.digest h

let cases =
  [
    case "xxh32 known values" (fun () ->
        List.iter
          (fun (s, v) -> check_int32 ~msg:(Printf.sprintf "%S" s) ~expected:v (X.string s))
          known);
    case "xxh32 every split equals one-shot" (fun () ->
        let data = Gen.generate Gen.Lit ~seed:3 70 in
        for len = 0 to 70 do
          let s = String.sub data 0 len in
          let whole = X.string s in
          for k = 0 to len do
            check_int32
              ~msg:(Printf.sprintf "len %d split %d" len k)
              ~expected:whole (chunked s [ k ])
          done;
          check_int32 ~msg:"bytewise" ~expected:whole (chunked s (List.init len (fun _ -> 1)))
        done);
    case "xxh32 reset and continued digest" (fun () ->
        let h = X.create () in
        X.update h (Bytes.of_string "abc") 0 3;
        ignore (X.digest h);
        X.reset h;
        X.update h (Bytes.of_string "a") 0 1;
        check_int32 ~expected:0x550D7456l (X.digest h));
    case "xxh32 sub-range" (fun () ->
        check_int32 ~expected:0x32D153FFl (X.bytes (Bytes.of_string "xxabcxx") 2 3));
  ]
