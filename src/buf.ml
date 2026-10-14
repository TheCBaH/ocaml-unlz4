[@@@ai_disclosure "ai-generated"]
[@@@ai_provider "Anthropic, OpenAI"]

(* Buffers the decoder both writes and reads back (match copies).

   js_of_ocaml represents a fresh [Bytes.create] buffer as a growing JavaScript string until the
   first [Bytes.set], and appends to it by string concatenation; reading it back between appends
   then flattens the string again and again, which makes decoding quadratic. Rewriting one byte of
   the range with its own value moves the buffer to the array representation once. Elsewhere it
   is a one-byte no-op. *)

let touch b off len =
  if len > 0 then
    let i = off + len - 1 in
    Bytes.set b i (Bytes.get b i)

let create n =
  let b = Bytes.create n in
  touch b 0 n;
  b
