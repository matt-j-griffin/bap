open Core_kernel.Std
open Regular.Std
open Bap.Std
open Bap_bml
open Format

include Self()

let grammar = {|
    bml    ::= (<exps> <exps>)
    exps   ::= <exp>  | (<exp>1 .. <exp>N)
    exp    ::= (<id>) | (<id> <arg>)
    arg    ::= <id> | ?quoted string?
    id     ::= ?alphanumeric sequence?
|}

module Scheme = struct
  open Sexp.O

  type pred = bool Term.visitor
  type mark = Term.mapper
  type patt = pred list * mark list
  type t = patt list

  let error fmt = ksprintf (fun s -> Error s) fmt
  let unbound_name name = error "Unbound name: %S" name
  let expect_arg n name = error "Term %s has arity %d" name n

  let lookup arity ns1 ns2 tag = match ns1 tag with
    | Some exp -> Ok exp
    | None -> match ns2 tag with
      | None -> unbound_name tag
      | Some exp -> expect_arg arity tag

  let lookup0 nns uns = lookup 0 nns uns
  let lookup1 nns uns = lookup 1 uns nns

  let parse_exp0 = lookup0
  let parse_exp1 uns nns tag v = match lookup1 uns nns tag with
    | Error err -> Error err
    | Ok parse_arg -> try Ok (parse_arg v) with
      | Parse_error msg -> Error msg

  let rec parse_exp nns uns = function
    | List [Atom tag] -> parse_exp0 nns uns tag
    | List [Atom tag; Atom v] -> parse_exp1 nns uns tag v
    | list -> error "expected <exp> got %s" @@ Sexp.to_string list

  let rec parse_exps nns uns = function
    | List (Atom _ :: _) as exp -> [parse_exp nns uns exp]
    | List exps ->
      List.map exps ~f:(parse_exps nns uns) |> List.concat
    | s -> [error "expected <expr> got %s" @@ Sexp.to_string s]

  let parse_mappers s =
    parse_exps Mappers.Nullary.find Mappers.Unary.find s |>
    Result.all

  let parse_preds s =
    parse_exps Predicates.Nullary.find Predicates.Unary.find s |>
    Result.all

  let parse_marker ps ms = match parse_preds ps, parse_mappers ms with
    | Ok ps, Ok ms -> Ok (ps,ms)
    | Error e,_|_,Error e -> Error e

  let parse : sexp -> (patt,string) Result.t = function
    | Sexp.List [preds; marks] -> parse_marker preds marks
    | _ -> Error {|expect "("<preds> <marks>")"|}

  let sexp_error {Sexp.location; err_msg} =
    Error (sprintf "Syntax error: %s - %s" location err_msg)

  let parse_string s =
    try parse (Sexp.of_string s)
    with Sexp.Parse_error err -> sexp_error err
       | exn -> Error "Malformed sexp"

  let parse_file f =
    try List.map ~f:parse (Sexp.load_sexps f) |> Result.all
    with Sexp.Parse_error err -> sexp_error err
       | Sys_error e -> Error e
       | exn -> Error "Malformed sexp "

  let parse_arg s = match parse_string s with
    | Ok r -> `Ok r
    | Error e -> `Error e

  let arg = parse_arg, (fun ppf _ -> ())
end

class marker (patts : Scheme.t) = object(self)
  inherit Term.mapper as super
  method! map_term cls t =
    List.fold patts ~init:t ~f:(fun t (preds,maps) ->
        if List.for_all preds ~f:(fun p -> p#visit_term cls t false)
        then List.fold maps ~init:t ~f:(fun t m -> m#map_term cls t)
        else t) |>
    super#map_term cls
end

let main patts file proj =
  let patts = match file with
    | None -> patts
    | Some file -> match Scheme.parse_file file with
      | Ok ps -> patts @ ps
      | Error err -> raise (Parse_error err) in
  let marker = new marker patts in
  marker#run (Project.program proj) |>
  Project.with_program proj

module Cmdline = struct
  open Cmdliner

  let scheme : Scheme.t Term.t =
    let doc = "Map terms according the $(docv)" in
    Arg.(value & opt_all Scheme.arg [] &
         info ["with"] ~doc ~docv:"PATTERN")

  let file : string option Term.t =
    let doc = "Read patterns from the $(docv)" in
    Arg.(value & opt (some file) None &
         info ["using"] ~doc ~docv:"FILE")

  let bold = List.map ~f:(sprintf "$(b,%s)")


  let term = ["synthetic"; "live"; "dead"; "visited"]
  let sub = [
    "const"; "pure"; "stub"; "extern"; "leaf"; "malloc";
    "noreturn"; "return_twice"; "nothrow"
  ]
  let arg = ["alloc-size"; "restricted"; "nonnull"]

  let enum xs = Arg.doc_alts ~quoted:false (bold xs)

  let attr attrs name desc =
    `I (sprintf "$(b,(%s))" name,
        sprintf ("%s, where $(i,ATTR) must be one of %s.")
          desc (enum attrs))

  let colors = bold [
      "black"; "red"; "green"; "yellow"; "blue"; "magenta"; "cyan"; "white"
    ]

  module Predicates = struct


    let color attr =
      `I (sprintf "$(b,(has-%s COLOR))" attr,
          sprintf "Is satisfied when a term's
    attribute $(b,%s) has the given value, where $(i,COLOR) must be
    one of %s" attr (enum colors))

    let section = [
      `S "STANDARD PREDICATES";
      `I ("$(b,(true))","Is always satisfied.");
      attr term "is-ATTR"
        "Is satisfied when a term has the given attribute";
      attr sub "is-ATTR-sub"
        "Is satisfied when a term is a subroutine with the given attribute";
      attr arg "is-ATTR-arg"
        "Is satisfied when a term is an argument with the given attribute";
      `I ("$(b,(has-mark))", "Is satisfied when a term has an
      attribute $(b,mark).");
      color "color";
      color "foreground";
      color "background";
      `I ("$(b,(taints))", "Is satisfied if a term is taint source, i.e., has
      $(b,tainted-reg) or $(b,tainted-ptr) attributes.");
      `I ("$(b,(taints-reg))", "Is satisfied if a term is taint source,
      that taints a value stored in a register, i.e., has a
      $(b,tainted-reg) attribute.");
      `I ("$(b,(taints-ptr))", "Is satisfied if a term is taint source,
      that taints a value pointed by a value stored in a register, i.e., has a
      $(b,tainted-ptr) attribute.");
      `I ("$(b,(has-taints))", "Is satisfied if a term is tainted, i.e., has
      $(b,tainted-reg) or $(b,tainted-ptr) attributes.");
      `I ("$(b,(has-tainted-reg))", "Is satisfied if a term uses a
      tainted value stored in a register, i.e., has a
      $(b,tainted-regs) attribute.");
      `I ("$(b,(has-tainted-reg taint))", "Is satisfied if a term uses a
      value tainted with $(i,taint) and stored in a register, where $(i,taint)
      must be a valid taint identifier, e.g., $(b,%12).");
      `I ("$(b,(has-tainted-ptr))", "Is satisfied if a term loads a
      value from a tainted address, i.e., has a $(b,tainted-regs) attribute.");
      `I ("$(b,(has-tainted-reg taint))", "Is satisfied if a term
      loads a value from an address tainted by the give
      $(i,taint). The $(i,taint) must be a valid taint identifier, e.g., $(b,%42).");
    ]
  end

  module Mappers = struct
    let color attr =
      `I (sprintf "$(b,(%s COLOR))" attr,
          sprintf "Set term's attribute $(b,%s) to the given value,
          where $(i,COLOR) must be one of %s" attr (enum colors))

    let section = [
      `S "STANDARD MAPPERS";
      attr term "set-ATTR" "Mark a term with the specified attribute";
      attr sub "set-ATTR-sub" "Mark a term with the specified attribute";
      attr arg "set-ATTR-arg" "Mark a term with the specified attribute";
      `I ("$(b,(set-mark))", "Attch $(b,mark) attribute to a term");
      color "color";
      color "foreground";
      color "background";
      `I ("$(b,(taint-reg TID))", "Mark a term with the given $(b,TID)
      as a taint source for register values.");
      `I ("$(b,(taint-ptr TID))", "Mark a term with the given $(b,TID)
      as a taint source for memory values.")
    ]
  end

  let grammar = [
    `S "LANGUAGE GRAMMAR";
    `Pre grammar;
  ]

  let example = [
    `S "EXAMPLES";
    `P "$(b,bap) exe --$(mname)-pattern='((is-visited) (foreground green))'";
    `P {|$(b,bap) exe --$(mname)-pattern='((taints-ptr %12) (comment "ha ha"))'|};
  ]

  let see_also = [
    `S "SEE ALSO"; `P "$(b,bap-taint)(1), $(b, bap-bml)(3)"
  ]

  let man = [
    `S "SYNOPSIS";
    `P "$(b,bap) [$(b,--$(mname)-with)=$(i,SCHEME)]
                 [$(b,--$(mname)-using)=$(i,FILE)] $(b,--$(mname))";
    `S "DESCRIPTION";
    `P "Transform terms using a domain specific pattern matching language.
    The pass accepts a list of patterns via a command line argument
    $(b,--)$(b,$(mname)-pattern) (that can be specified several times), or
    via file, that contains a list of patterns. Each pattern is
    represented by a pair $(b,(<condition> <action>)). The $(b,<action>) specifies
    a transformation over a term, that is applied if a $(b,<condition>)
    is satisfied. Both $(b,<condition>) and $(b,<action>) can be a
    single $(b,<expression>) or a list of expressions, delimited with
    parentheses. If there is a list of conditions, then all must be
    satisfied. If there is a list of actions, then all actions are
    applied in order. Each expression is either a nullary
    function $(b,(<id>)) or an unary function $(b,(<id>
    <arg>)). Where $(b,<id>) must be a valid predicate or mapper
    name. There is a predefined set of standard functions, but it can
    be extended by adding new mappers or predicates to the BML
    language using $(bap-bml) library. ";
  ] @
    Predicates.section @
    Mappers.section @
    grammar @
    example @
    see_also

  let info  = Term.info ~doc ~man name
  let start = Term.(const main $scheme $file)
  let parse () = Term.eval ~argv ~catch:false (start,info)
end

let () = match Cmdline.parse () with
  | `Ok pass -> Project.register_pass pass
  | `Version | `Help -> exit 0
  | `Error _ -> exit 1
  | exception Parse_error msg ->
    eprintf "Parsing error: %s\n%!" msg;
    exit 2