(lang dune 3.21)

(name unlz4)

(using melange 1.0)

(generate_opam_files true)

(license MIT)

(authors "Vladimir Silyaev")

(maintainers "Vladimir Silyaev")

(source
 (github TheCBaH/ocaml-unlz4))

(package
 (name unlz4)
 (synopsis "Pure OCaml LZ4 decompressor: raw blocks and frames")
 (description
  "Decodes LZ4 raw blocks and the LZ4 frame format (independent and linked blocks, checksums, dictionaries, concatenated and skippable frames) with an incremental, bounded-memory decoder. Depends only on the OCaml standard library and runs unchanged under js_of_ocaml and Melange.")
 (depends
  (ocaml
   (>= 4.14))))

