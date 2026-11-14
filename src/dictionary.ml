[@@@ai_disclosure "ai-generated"]
[@@@ai_provider "Anthropic, OpenAI"]

let window = 65536

type t = { data : bytes; id : int32 option }

let of_bytes ?id b =
  let n = Bytes.length b in
  { data = Bytes.sub b (max 0 (n - window)) (min n window); id }

let of_string ?id s =
  let n = String.length s in
  let len = min n window in
  let data = Bytes.create len in
  Bytes.blit_string s (n - len) data 0 len;
  { data; id }

let empty = { data = Bytes.empty; id = None }
