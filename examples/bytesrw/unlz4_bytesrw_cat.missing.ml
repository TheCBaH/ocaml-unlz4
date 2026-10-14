(* Built instead of unlz4_bytesrw_cat.bytesrw.ml when bytesrw is not installed. *)

let () =
  prerr_endline "unlz4_bytesrw_cat: built without bytesrw";
  exit 2
