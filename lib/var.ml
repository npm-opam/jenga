open! Core.Std
open! Int.Replace_polymorphic_compare

module Info = struct

  type t = {
    name    : string;
    default : string option;
    choices : string list;
    value   : string option;
    peeked  : bool;
  } [@@deriving bin_io, sexp_of]

end

(* Wrap [Sys.getenv] to support set/unset within jenga *)
module Var_table : sig

  val get : string -> string option Tenacious.Var.t

end = struct

  let get =
    Memo.general ~hashable:String.hashable
      (fun name -> Tenacious.Var.create (Sys.getenv name))

end

let change_to_peeked_var_var = Tenacious.Var.create ()
let change_to_peeked_var = Tenacious.Var.watch change_to_peeked_var_var

(* [Entry.t] tracks entry information associated with an untyped environment variable *)
module Entry = struct

  type t = {
    name : string;
    default : string option;
    choices : string list;
    mutable peeked : bool;
  } [@@deriving sexp_of]

  let info {name;default;choices;peeked} = {
    Info.name;default;choices;peeked;
    value = Tenacious.Var.get (Var_table.get name);
  }

  let var t = Var_table.get t.name

  let set t ~value =
    let var = var t in
    let old = Tenacious.Var.get var in
    (* Optimize [set] to existing value. <unset> and <set-with-default> are different. *)
    if [%compare.equal: string option] old value
    then ()
    else (
      (if t.peeked then Tenacious.Var.set change_to_peeked_var_var ());
      Tenacious.Var.set var value;
      Message.var_changed ~var:t.name ~old ~new_:value;
    )

  let peek ?dont_trigger t =
    (match dont_trigger with Some () -> () | None -> t.peeked <- true);
    Tenacious.Var.get (var t)

  let watch t = Tenacious.Var.watch (var t)

  let create ?(choices = []) ?default name =
    let peeked = false in
    { name; default; choices; peeked }

end

type table = Entry.t String.Table.t

let the_table : table = String.Table.create ()

let lookup name =
  match Hashtbl.find the_table name with
  | None -> Or_error.errorf "Environment variable `%s' is not registered with jenga" name
  | Some entry -> Ok entry

module Getenv = struct
  type query = { name : string } [@@deriving bin_io]
  type response = Info.t Or_error.t [@@deriving bin_io]
  let query name = { name }
  let run {name} = Or_error.map (lookup name) ~f:Entry.info
end

module Setenv = struct
  type query = { name : string; value : string option } [@@deriving bin_io]
  type response = unit Or_error.t [@@deriving bin_io]
  let query name ~value = { name; value }
  let run {name;value} = Or_error.map (lookup name) ~f:(Entry.set ~value)
end

let clear_all_registrations () = Hashtbl.clear the_table

let unregister name = Hashtbl.remove the_table name

let register_entry ?choices ?default name =
  let entry = Entry.create ?choices ?default name in
  Message.trace !"register: %{sexp:Info.t}" (Entry.info entry);
  Hashtbl.add_exn the_table ~key:name ~data:entry;
  entry

let registered_names () = Hashtbl.keys the_table
let is_registered name = Hashtbl.mem the_table name
let all_registered () = List.map (Hashtbl.data the_table) ~f:Entry.info

(* [T.t] adds a typing layer on [Entry.t] *)

type 'a t = {
  entry : Entry.t;
  parse : (string option -> 'a);
} [@@deriving sexp_of]

let register ?choices name =
  let entry = register_entry ?choices name in
  { entry; parse = Fn.id }

let register_with_default ?choices name ~default =
  let entry = register_entry ?choices name ~default in
  { entry; parse = Option.value ~default }

let map {entry;parse} ~f = {entry; parse = (fun x -> f (parse x))}

let peek ?dont_trigger t = t.parse (Entry.peek ?dont_trigger t.entry)

let watch t =
  Tenacious.map (Entry.watch t.entry) ~f:(fun x -> Or_error.try_with (fun () -> t.parse x))
