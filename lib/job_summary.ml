open Core.Std

module Q : sig

  val shell_escape : string -> string
  val shell_escape_list : string list -> string

end = struct

  let is_special_char_to_bash = function
    | '\\' | '\'' | '"' | '`' | '<' | '>' | '|' | ';' | ' ' | '\t' | '\n'
    | '(' | ')' | '[' | ']' | '?' | '#' | '$' | '^' | '&' | '*' | '=' | '!' | '~'
      -> true
    | _
      -> false

  let vanilla_shell_escape s =
    "'" ^ String.concat_map s ~f:(function
    | '\'' -> "'\\''"
    | c -> String.make 1 c
    ) ^ "'"

  let needs_quoting = function
    | "" -> true
    | s -> String.exists s ~f:is_special_char_to_bash

  let shell_escape s =
    (* quote a string (if necessary) to prevent interpretation of any chars which have a
       special meaning to bash *)
    if needs_quoting s
    then
      if String.contains s '\''
      (* already contains single-quotes; quote using backslash escaping *)
      then vanilla_shell_escape s
      else
        (* no embedded single quotes; just wrap with single quotes;
           same behavior as [shell_escape], but perhaps more efficient *)
        sprintf "'%s'" s
    else
      (* does not need quoting *)
      s

  let shell_escape_list l =
    String.concat ~sep:" " (List.map l ~f:(fun x -> shell_escape x))

end

let pretty_span span =
  let { Time.Span.Parts.sign = _; hr; min; sec; ms; us = _ } = Time.Span.to_parts span in
  let mins = 60 * hr + min in
  if mins > 0     then sprintf "%dm %02ds" mins sec
  else if sec > 0 then sprintf "%d.%03ds"  sec ms
  else                 sprintf "%dms"      ms
;;

let parse_pretty_span span =
  match String.lsplit2 ~on:' ' span with
  | None -> Time.Span.of_string span
  | Some (minutes, seconds) -> Time.Span.(of_string minutes + of_string seconds)
;;

let%test_unit _ =
  List.iter ~f:(fun str -> [%test_result: string] ~expect:str
                             (pretty_span (parse_pretty_span str)))
    [ "1m 44s"
    ; "23.123s"
    ; "55ms"
    ]
;;

module Start = struct

  type t = {
    uid : int; (* to line up commands in .jenga/debug *)
    need : string;
    where : string;
    prog : string;
    args : string list;
  } [@@deriving bin_io, fields, sexp_of]

  let create =
    let genU = (let r = ref 1 in fun () -> let u = !r in r:=1+u; u) in
    fun ~need ~where ~prog ~args ->
      let uid = genU() in
      { uid; need; where; prog; args }

end

module Finish = struct
  type t = {
    outcome : [`success | `error of string];
    duration : Time.Span.t;
  } [@@deriving bin_io, fields, sexp_of]
end

module Output = struct
  type t = {
    stdout : string list;
    stderr : string list;
  } [@@deriving bin_io, fields, sexp_of]
end

type t = Start.t * Finish.t * Output.t
[@@deriving bin_io, sexp_of]

let split_string_into_lines s =
  match s with
  | "" -> []
  | "\n" -> [""]
  | _ ->
    let s =
      match String.chop_suffix s ~suffix:"\n" with
      | None -> s
      | Some s -> s
    in
    String.split s ~on:'\n'

let create start ~outcome ~duration ~stdout ~stderr =
  let finish = { Finish. outcome; duration } in
  let stdout = split_string_into_lines stdout in
  let stderr = split_string_into_lines stderr in
  let output = { Output. stdout; stderr } in
  (start,finish,output)

let outcome (_,f,_) = f.Finish.outcome

let iter_lines (
  {Start. where; need; prog; args; uid=_},
  {Finish. outcome; duration},
  {Output. stdout; stderr}
) ~f:put =
  put (sprintf "- build %s %s" where need);
    (* print out the command in a format suitable for cut&pasting into bash
       (except for the leading "+")
    *)
  let args = List.map args ~f:(fun arg -> Q.shell_escape arg) in
  put (sprintf "+ %s %s" prog (String.concat ~sep:" " args));
  List.iter stdout ~f:put;
  List.iter stderr ~f:put;
  let duration_string = pretty_span duration in
  let status_string =
    match outcome with
    | `success -> "code 0"
    | `error status_string -> status_string
  in
  put (sprintf "- exit %s %s, %s, %s" where need duration_string status_string)

let to_lines t =
  let collected = ref [] in
  iter_lines t ~f:(fun s -> collected := s :: !collected);
  List.rev !collected
