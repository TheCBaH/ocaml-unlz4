(** XXH32 with seed zero, as used by the LZ4 frame format. *)

type t
(** An incremental hash state. *)

val create : unit -> t
val reset : t -> unit

val update : t -> bytes -> int -> int -> unit
(** [update h b off len] feeds [b.[off .. off + len - 1]]. *)

val digest : t -> int32
(** The hash of the bytes fed so far; [h] can still be updated afterwards. *)

val bytes : bytes -> int -> int -> int32
(** One-shot hash of a byte range. *)

val string : string -> int32
