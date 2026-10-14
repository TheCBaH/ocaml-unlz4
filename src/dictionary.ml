let window = 65536

type t = { data : bytes; id : int32 option }

let of_sub ?id get_sub n = { data = get_sub (max 0 (n - window)) (min n window); id }
let of_bytes ?id b = of_sub ?id (Bytes.sub b) (Bytes.length b)

let of_string ?id s =
  of_sub ?id (fun off len -> Bytes.of_string (String.sub s off len)) (String.length s)

let empty = { data = Bytes.empty; id = None }
