
open! Core.Std
open! Async.Std

val init : Config.t -> unit (* just once *)

module Reply : sig
  type t = {
    stdout : string;
    stderr : string;
    outcome : [`success | `error of string];
  }
end

module Request : sig
  type t
  val create :
    (* calls to putenv, to be done in parent, before the fork *)
    putenv:(string * string option) list ->
    dir:Path.t ->
    prog:string ->
    args:string list ->
    t
end

val run : Request.t -> Reply.t Deferred.t
