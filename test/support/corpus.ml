[@@@ai_disclosure "ai-generated"]
[@@@ai_provider "Anthropic, OpenAI"]

(* The checked-in corpus (test/corpus), embedded at build time by tools/embed.ml. *)

type kind = Block | Frame

type fixture = {
  name : string;
  kind : kind;
  compressed : string;
  plain : string Lazy.t;
  dict : string option Lazy.t;
  opts : string;
}

let fields line =
  List.filter_map
    (fun w ->
      match String.index_opt w '=' with
      | Some i -> Some (String.sub w 0 i, String.sub w (i + 1) (String.length w - i - 1))
      | None -> None)
    (String.split_on_char ' ' line)

let lines prefix =
  List.filter_map
    (fun line ->
      let p = prefix ^ " " in
      if String.length line > String.length p && String.sub line 0 (String.length p) = p then
        Some (fields line)
      else None)
    (String.split_on_char '\n' Corpus_data.manifest)

let fixtures =
  List.map
    (fun f ->
      let get k = List.assoc k f in
      let compressed = List.assoc (get "file") Corpus_data.files in
      if String.length compressed <> int_of_string (get "size") then
        invalid_arg ("corpus size mismatch: " ^ get "name");
      {
        name = get "name";
        kind = (match get "kind" with "block" -> Block | "frame" -> Frame | k -> invalid_arg k);
        compressed;
        plain = lazy (Gen.recipe (get "plain"));
        dict = lazy (match get "dict" with "-" -> None | d -> Some (Gen.recipe d));
        opts = get "opts";
      })
    (lines "fixture")

let xxh32_vectors =
  List.map
    (fun f -> (Gen.recipe (List.assoc "data" f), Int32.of_string (List.assoc "value" f)))
    (lines "xxh32")

let upstream = match lines "upstream" with [ f ] -> List.assoc "version" f | _ -> "?"
let frames = List.filter (fun f -> f.kind = Frame) fixtures
let blocks = List.filter (fun f -> f.kind = Block) fixtures

(* A short summary of the corpus for the runners' report. *)
let summary () =
  let total = List.fold_left (fun n f -> n + String.length f.compressed) 0 fixtures in
  Printf.sprintf
    "%d fixtures (%d blocks, %d frames), %d bytes, %d xxh32 vectors, xxh32 of all 0x%08lx, \
     upstream %s"
    (List.length fixtures) (List.length blocks) (List.length frames) total
    (List.length xxh32_vectors)
    (Unlz4.Private.Xxh32.string (String.concat "" (List.map (fun f -> f.compressed) fixtures)))
    upstream
