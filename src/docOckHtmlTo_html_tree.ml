(*
 * Copyright (c) 2016 Thomas Refis <trefis@janestreet.com>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

open DocOck
open Types
open Paths

open Tyxml.Html

module Documentation = DocOckHtmlDocumentation
module Html_tree = DocOckHtmlHtml_tree
module Markup = DocOckHtmlMarkup

type ('inner, 'outer) text =
  [> `PCDATA | `Span | `A of ([> `PCDATA ] as 'inner) ] as 'outer

let a_href = Html_tree.Relative_link.to_sub_element

let html_dot_magic = List.map ~f:(fun x -> tot @@ toelt x)

let rec list_concat_map ?sep ~f = function
  | [] -> []
  | [x] -> f x
  | x :: xs ->
    let hd = f x in
    let tl = list_concat_map ?sep ~f xs in
    match sep with
    | None -> hd @ tl
    | Some sep -> hd @ sep :: tl

let functor_arg_pos { Types.FunctorArgument.id ; _ } =
  match id with
  | Identifier.Argument (_, nb, _) -> nb
  | _ ->
    let id = string_of_sexp @@ Identifier.sexp_of_t (fun _ -> Atom "") id in
    invalid_arg (Printf.sprintf "functor_arg_pos: %s" id)


let string_of_label = function
  | TypeExpr.Label s -> s
  | Optional s -> "?" ^ s

let rec unit ~get_package (t : _ Types.Unit.t) : Html_tree.t =
  let package =
    match t.id with
    | Paths.Identifier.Root (a, _) -> get_package a
    | _ -> assert false
  in
  Html_tree.enter package;
  Html_tree.enter (Identifier.name t.id);
  let header_doc = Documentation.to_html ~get_package t.doc in
  let html, subtree =
    match t.content with
    | Module sign -> signature ~get_package sign
    | Pack packed -> pack ~get_package packed, []
  in
  Html_tree.make (div [ div ~a:[ a_class ["doc"] ] header_doc; html ], subtree)

and pack
   : 'row. get_package:('a -> string) -> 'a Types.Unit.Packed.t
  -> ([> Html_types.div ] as 'row) elt
= fun ~get_package t ->
  div @@ List.map t ~f:(fun x ->
    let modname = Identifier.name x.Unit.Packed.id in
    let dot_mod = "/" ^ modname in
    let md_def =
      Markup.keyword "module " ::
      pcdata modname ::
      pcdata " = " ::
      Html_tree.Relative_link.of_path ~get_package x.path
    in
    Markup.make_def ~kind:"mod" ~id:dot_mod ~code:md_def ~doc:[]
  )

and signature
   : 'row. get_package:('a -> string) -> 'a Types.Signature.t
  -> ([> Html_types.div ] as 'row) elt * Html_tree.t list
= fun ~get_package t ->
  let html_and_subtrees =
    let recording_doc = ref true in
    List.map t ~f:(function
      | Types.Signature.Module md -> module_ ~get_package md
      | ModuleType mty -> module_type ~get_package mty
      | Type td -> type_decl ~get_package td, []
      | TypExt te -> extension ~get_package te, []
      | Exception e -> exn ~get_package e, []
      | Value v -> value ~get_package v, []
      | External e -> external_ ~get_package e, []
      | Class c -> class_ ~get_package c, []
      | ClassType cty -> class_type ~get_package cty, []
      | Include incl -> include_ ~get_package incl
      | Comment (Documentation doc) ->
        let doc =
          if !recording_doc then
            div ~a:[a_class ["doc"]] (Documentation.to_html ~get_package doc)
          else
            pcdata ""
        in
        doc, []
      | Comment Stop ->
        recording_doc := not !recording_doc;
        pcdata "", []
    )
  in
  let html, subtrees = List.split html_and_subtrees in
  div html, List.concat subtrees

and functor_argument
   : 'row. get_package:('a -> string) -> 'a Types.FunctorArgument.t
  -> ([> Html_types.div ] as 'row) elt * Html_tree.t list
= fun ~get_package arg ->
  let open Types.FunctorArgument in
  let name = Identifier.name arg.id in
  let nb = functor_arg_pos arg in
  let link_name = Printf.sprintf "%s.%d" name nb in
  let dot_a = Printf.sprintf "/%s.moda" link_name in
  let def_div, subtree =
    match arg.expansion with
    | None ->
      (
        pcdata (Identifier.name arg.id) ::
        pcdata " : " ::
        mty ~get_package (Identifier.signature_of_module arg.id) arg.expr
      ), []
    | Some expansion ->
      Html_tree.enter ~kind:(`Arg) link_name;
      let expansion, subpages as node = module_expansion ~get_package expansion in
      let subtree = Html_tree.make node in
      Html_tree.leave ();
      (
        a ~a:[ a_href ~kind:`Arg link_name ] [pcdata name] ::
        pcdata " : " ::
        mty ~get_package (Identifier.signature_of_module arg.id) arg.expr
      ), [subtree]
  in
  let region = Markup.make_def ~kind:"moda" ~id:dot_a ~code:def_div ~doc:[] in
  region, subtree

and module_expansion
   : 'row. get_package:('a -> string) -> 'a Types.Module.expansion
  -> ([> Html_types.div ] as 'row) elt * Html_tree.t list
= fun ~get_package t ->
  match t with
  | Signature sg -> signature ~get_package sg
  | Functor (args, sg) ->
    let sig_html, subpages = signature ~get_package sg in
    let params, params_subpages =
      List.fold_left args ~init:([], []) ~f:(fun (args, subpages as acc) arg ->
        match arg with
        | None -> acc
        | Some arg ->
          let arg, arg_subpages = functor_argument ~get_package arg in
          (arg :: args, arg_subpages @ subpages)
      )
    in
    let html =
      div [
        h3 ~a:[ a_class ["heading"] ] [ pcdata "Parameters" ];
        div params;
        h3 ~a:[ a_class ["heading"] ] [ pcdata "Signature" ];
        sig_html
      ]
    in
    html, params_subpages @ subpages

and module_
   : 'row. get_package:('a -> string) -> 'a Types.Module.t
  -> ([> Html_types.div ] as 'row) elt * Html_tree.t list
= fun ~get_package t ->
  let modname = Identifier.name t.id in
  let dot_mod = "/" ^ modname in
  let doc = Documentation.to_html ~get_package t.doc in
  let md = module_decl ~get_package (Identifier.signature_of_module t.id) t.type_ in
  let modname, subtree =
    match t.expansion with
    | None -> pcdata modname, []
    | Some expansion ->
      Html_tree.enter ~kind:(`Mod) modname;
      let expansion, subpages = module_expansion ~get_package expansion in
      let expansion =
        let md = module_decl ~get_package (Identifier.signature_of_module t.id) t.type_ in
        let md_def_content = Markup.keyword "module " :: pcdata modname :: md in
        let doc =
          match doc with
          | [] -> p []
          | _ -> div ~a:[ a_class ["doc"] ] doc
        in
        div ~a:[ a_class ["mod"] ]
          [Markup.def_div md_def_content; doc; hr (); expansion]
      in
      let subtree = Html_tree.make (expansion, subpages) in
      Html_tree.leave ();
      a ~a:[ a_href ~kind:`Mod modname ] [pcdata modname], [subtree]
  in
  let md_def_content = Markup.keyword "module " :: modname :: md in
  let region =
    Markup.make_def ~id:dot_mod ~kind:"mod" ~code:md_def_content
      ~doc:(Documentation.first_to_html ~get_package t.doc)
  in
  region, subtree

and module_decl ~get_package (base : _ Identifier.signature) md =
  begin match md with
  | Alias _ -> pcdata " = "
  | ModuleType _ -> pcdata " : "
  end ::
  module_decl' ~get_package base md

and extract_path_from_mt ~(default: 'a Identifier.signature) =
  let open ModuleType in
  function
  | Path (Path.Resolved r) ->
    Identifier.signature_of_module_type (Path.Resolved.identifier r)
  | With (mt, _) -> extract_path_from_mt ~default mt
  | TypeOf (Module.Alias (Path.Resolved r)) ->
    Identifier.signature_of_module (Path.Resolved.identifier r)
  | TypeOf (Module.ModuleType mt) -> extract_path_from_mt ~default mt
  | _ -> default

and module_decl'
  : 'inner_row 'outer_row. get_package:('a -> string)
  -> 'a Identifier.signature -> 'a Types.Module.decl
  -> ('inner_row, 'outer_row) text elt list
= fun ~get_package base -> function
  | Alias mod_path -> Html_tree.Relative_link.of_path ~get_package mod_path
  | ModuleType mt -> mty ~get_package (extract_path_from_mt ~default:base mt) mt

and module_type ~get_package (t : _ Types.ModuleType.t) =
  let modname = Identifier.name t.id in
  let dot_modt = "/" ^ modname ^ ".modt" in
  let doc = Documentation.to_html ~get_package t.doc in
  let modname, subtree =
    match t.expansion with
    | None -> pcdata modname, []
    | Some expansion ->
      Html_tree.enter ~kind:(`Mty) modname;
      let expansion, subpages as node = module_expansion ~get_package expansion in
      let subtree = Html_tree.make node in
      Html_tree.leave ();
      a ~a:[ a_href ~kind:`Mty modname ] [pcdata modname], [subtree]
  in
  let mty =
    match t.expr with
    | None -> []
    | Some expr ->
      begin match expr with
      | Path _ -> pcdata " = "
      | _ -> pcdata " : "
      end ::
      mty ~get_package (Identifier.signature_of_module_type t.id) expr
  in
  let mty_def =
    (
      Markup.keyword "module type " ::
      modname ::
      mty
    )
  in
  Markup.make_def ~kind:"modt" ~id:dot_modt ~code:mty_def ~doc, subtree

and mty
  : 'inner_row 'outer_row. get_package:('a -> string)
  -> 'a Identifier.signature -> 'a Types.ModuleType.expr
  -> ('inner_row, 'outer_row) text elt list
= fun ~get_package (base : _ Identifier.signature) -> function
  | Path mty_path -> Html_tree.Relative_link.of_path ~get_package mty_path
  | Signature _ ->
    [ Markup.keyword "sig" ; pcdata " ... " ; Markup.keyword "end" ]
  | Functor (None, expr) ->
    Markup.keyword "functor" :: pcdata " () " ::
    mty ~get_package base expr
  | Functor (Some arg, expr) ->
    let name =
      let open FunctorArgument in
      let to_print = pcdata @@ Identifier.name arg.id in
      match
        Html_tree.Relative_link.Id.href ~get_package
          ~stop_before:(arg.expansion = None) arg.id
      with
      | exception _ -> to_print
      | href -> a ~a:[ Tyxml.Html.a_href href ] [ to_print ]
    in
    Markup.keyword "functor" ::
    pcdata " (" :: name :: pcdata " : " ::
    mty ~get_package base arg.expr @
    pcdata ") -> " ::
    mty ~get_package base expr
  | With (expr, substitutions) ->
    mty ~get_package base expr @
    Markup.keyword " with " ::
    list_concat_map ~sep:(Markup.keyword " and ") substitutions
      ~f:(substitution ~get_package base)
  | TypeOf md ->
    Markup.keyword "module type of " :: module_decl' ~get_package base md

and substitution
  : 'inner_row 'outer_row. get_package:('a -> string)
  -> 'a Identifier.signature -> 'a Types.ModuleType.substitution
  -> ('inner_row, 'outer_row) text elt list
= fun ~get_package base -> function
  | ModuleEq (frag_mod, md) ->
    Markup.keyword "module " ::
    Html_tree.Relative_link.of_fragment ~get_package ~base
      (Fragment.signature_of_module frag_mod)
    @ pcdata " = " ::
    module_decl' ~get_package base md
  | TypeEq (frag_typ, td) ->
    Markup.keyword "type " ::
    format_params td.Types.TypeDecl.Equation.params ::
    Html_tree.Relative_link.of_fragment ~get_package ~base (Fragment.any_sort frag_typ) @
    fst (format_manifest ~get_package td) @
    format_constraints ~get_package td.Types.TypeDecl.Equation.constraints
  | ModuleSubst (frag_mod, mod_path) ->
    Markup.keyword "module " ::
    Html_tree.Relative_link.of_fragment ~get_package ~base (Fragment.signature_of_module frag_mod) @
    pcdata " := " ::
    Html_tree.Relative_link.of_path ~get_package mod_path
  | TypeSubst (frag_typ, vars, typ_path) ->
    let params =
      pcdata begin match vars with
        | [] -> ""
        | [v] -> v ^ "\194\160"
        | _ -> "(" ^ String.concat ~sep:",\194\160" vars ^ ")\194\160"
      end
    in
    Markup.keyword "type " ::
    params ::
    Html_tree.Relative_link.of_fragment ~get_package ~base (Fragment.any_sort frag_typ) @
    pcdata " := " ::
    params ::
    Html_tree.Relative_link.of_path ~get_package typ_path

and constructor
   : 'b. get_package:('a -> string) -> dot_typ:string
  -> ('a, 'b) Identifier.t -> 'a Types.TypeDecl.Constructor.argument
  -> 'a Types.TypeExpr.t option
  -> [> `Code | `PCDATA | `Table ] elt list
= fun ~get_package ~dot_typ id args _ret_type ->
    let name = Identifier.name id in
    let cstr = span ~a:[ a_class [ "constructor" ] ] [ pcdata name ] in
    (* CR trefis: handle GADT style constructors properly. *)
    match args with
    | Tuple [] -> [code [cstr]]
    | Tuple lst ->
      [ code (
          cstr ::
          Markup.keyword " of " ::
          list_concat_map lst ~sep:(Markup.keyword " * ")
            ~f:(type_expr ~get_package)
        )
      ]
    | Record fields ->
      code [ cstr; Markup.keyword " of " ] ::
      record ~get_package dot_typ fields

and format_params
   : 'row. Types.TypeDecl.param list
  -> ([> `PCDATA ] as 'row) elt
= fun params ->
  let format_param (desc, variance_opt) =
    let param_desc = match desc with | Types.TypeDecl.Any -> "_" | Var s -> "'" ^ s in
    match variance_opt with
    | None -> param_desc
    | Some Types.TypeDecl.Pos -> "+" ^ param_desc
    | Some Types.TypeDecl.Neg -> "-" ^ param_desc
  in
  pcdata (
    match params with
    | [] -> ""
    | [x] -> format_param x ^ " "
    | lst ->
      let params = String.concat ", " (List.map lst ~f:format_param) in
      "(" ^ params ^ ") "
  )

and format_constraints
  : 'inner_row 'outer_row. get_package:_ -> (_ * _) list ->
  ([> `PCDATA | `Span
   | `A of ([> `PCDATA ] as 'inner_row) ] as 'outer_row) elt list
  = fun ~get_package -> function
  | [] -> []
  | lst ->
    Markup.keyword " constraint " ::
    list_concat_map lst ~sep:(Markup.keyword " and ") ~f:(fun (t1, t2) ->
      type_expr ~get_package t1 @ pcdata " = " :: type_expr ~get_package t2
    )

and format_manifest
  : 'inner_row 'outer_row. get_package:('a -> string)
  -> 'a Types.TypeDecl.Equation.t
  -> ('inner_row, 'outer_row) text elt list * bool
= fun ~get_package (equation : _ Types.TypeDecl.Equation.t) ->
  let private_ = equation.private_ in
  match equation.manifest with
  | None -> [], private_
  | Some t ->
    let manifest =
      Markup.keyword " = " ::
      (if private_ then Markup.keyword "private " else pcdata "") ::
      type_expr ~get_package t
    in
    manifest, false

and variant ~get_package dot_typ cstrs : [> Html_types.table ] elt =
  let constructor id args res =
    let name = Identifier.name id in
    let dot_cons = Printf.sprintf "%s/%s.cons" dot_typ name in
    Markup.make_spec ~kind:"cons" ~id:dot_cons
      (code [ Markup.keyword "| " ] ::
       constructor ~get_package ~dot_typ id args res)
  in
  let rows =
    List.map cstrs ~f:(fun cstr ->
      let open Types.TypeDecl.Constructor in
      let lhs = constructor cstr.id cstr.args cstr.res in
      let rhs = Documentation.to_html ~get_package cstr.doc in
      tr ~a:[ a_class ["cons"] ] (
        td [ lhs ] ::
        if not (Documentation.has_doc cstr.doc) then [] else [
          td [pcdata "(*"];
          td [ div ~a:[ a_class ["doc"] ] rhs ];
          td [pcdata "*)"];
        ]
      )
    )
  in
  table rows

and record ~get_package dot_typ fields =
  let field mutable_ id =
    let name = Identifier.name id in
    let dot_fld = Printf.sprintf "%s/%s.fld" dot_typ name in
    Markup.make_def ~kind:"fld" ~id:dot_fld ~doc:[] ~code:[
      (if mutable_ then Markup.keyword "mutable " else pcdata "");
      pcdata name
    ]
  in
  let rows =
    List.map fields ~f:(fun fld ->
      let open Types.TypeDecl.Field in
      let lhs = field fld.mutable_ fld.id in
      let rhs = Documentation.to_html ~get_package fld.doc in
      tr ~a:[ a_class ["fld"] ] (
        td [ lhs ] ::
        td [ pcdata " : " ] ::
        td (type_expr ~get_package fld.type_ @ [pcdata ";"]) ::
        if not (Documentation.has_doc fld.doc) then [] else [
          td [pcdata "(*"];
          td [ div ~a:[ a_class ["doc" ]] rhs ];
          td [pcdata "*)"];
        ]
      )
    )
  in
  [pcdata "{"; table rows; pcdata "}"]

and type_decl ~get_package (t : _ Types.TypeDecl.t) =
  let tyname = Identifier.name t.id in
  let dot_typ = "/" ^ tyname ^ ".typ" in
  let params = format_params t.equation.params in
  let constraints = format_constraints ~get_package t.equation.constraints in
  let manifest, need_private = format_manifest ~get_package t.equation in
  let representation =
    match t.representation with
    | None -> []
    | Some repr ->
      code [
        Markup.keyword " = ";
        if need_private then Markup.keyword "private " else pcdata ""
      ] ::
      match repr with
      | Extensible -> [code [Markup.keyword  ".."]]
      | Variant cstrs -> [variant ~get_package dot_typ cstrs]
      | Record fields -> record ~get_package dot_typ fields
  in
  let doc = Documentation.to_html ~get_package t.doc in
  let tdecl_def =
    code (
      Markup.keyword "type " ::
      params ::
      pcdata tyname ::
      manifest
    ) ::
    representation @
    constraints
  in
  Markup.make_spec ~kind:"type" ~id:dot_typ ~doc tdecl_def

and extension ~get_package (t : _ Types.Extension.t) =
  let doc = Documentation.to_html ~get_package t.doc in
  let extension =
    code (
      Markup.keyword "type " ::
      Html_tree.Relative_link.of_path ~get_package t.type_path @
      [ Markup.keyword " += " ]
    ) ::
    list_concat_map t.constructors ~sep:(code [Markup.keyword " | "])
      ~f:(extension_constructor ~get_package)
  in
  (* Inlined [Markup.make_spec] as we don't have an id (which implies we don't
     have an anchor either). *)
  div ~a:[ a_class ["spec"; "ext"] ] [
    div ~a:[ a_class ["def"; "ext"] ] extension;
    div ~a:[ a_class ["doc"] ] doc;
  ]

and extension_constructor ~get_package (t : _ Types.Extension.Constructor.t) =
  (* CR trefis: doc? *)
  let dot_ext = Printf.sprintf "%s.ext" (Identifier.name t.id) in
  constructor ~get_package ~dot_typ:dot_ext t.id t.args t.res

and exn ~get_package (t : _ Types.Exception.t) =
  let dot_exn = Printf.sprintf "%s.exn" (Identifier.name t.id) in
  let cstr = constructor ~get_package ~dot_typ:dot_exn t.id t.args t.res in
  let doc = Documentation.to_html ~get_package t.doc in
  let exn = code [ Markup.keyword "exception " ] :: cstr in
  Markup.make_spec ~kind:"exn" ~id:dot_exn ~doc exn

and te_variant
   : 'inner 'outer. get_package:('a -> string) -> 'a Types.TypeExpr.Variant.t
  -> ('inner, 'outer) text elt list
= fun ~get_package (t : _ Types.TypeExpr.Variant.t) ->
  let elements =
    list_concat_map t.elements ~sep:(pcdata " | ") ~f:(function
      | Types.TypeExpr.Variant.Type te -> type_expr ~get_package te
      | Constructor (name, _bool, args) ->
        let constr = "`" ^ name in
        match args with
        | [] -> [ pcdata constr ]
        | _ ->
          let args =
            list_concat_map args ~sep:(pcdata " * ") ~f:(type_expr ~get_package)
          in
          pcdata (constr ^ " of ") :: args
    )
  in
  match t.kind with
  | Fixed -> pcdata "[ " :: elements @ [pcdata " ]"]
  | Open -> pcdata "[> " :: elements @ [pcdata " ]"]
  | Closed [] -> pcdata "[< " :: elements @ [pcdata " ]"]
  | Closed lst ->
    let constrs = String.concat " " lst in
    pcdata "[< " :: elements @ [pcdata (" " ^ constrs ^ " ]")]

and te_object
   : 'inner 'outer. get_package:('a -> string) -> 'a Types.TypeExpr.Object.t
  -> ('inner, 'outer) text elt list
= fun ~get_package (t : _ Types.TypeExpr.Object.t) ->
  let methods =
    list_concat_map t.methods ~f:(fun { Types.TypeExpr.Object. name; type_ } ->
      pcdata (name ^ " : ") :: type_expr ~get_package type_ @ [pcdata "; "]
    )
  in
  pcdata "< " :: methods @ [pcdata ((if t.open_ then ".. " else "") ^ ">")]

and format_type_path
  : 'inner 'outer. get_package:('a -> string) -> delim:[ `parens | `brackets ]
  -> 'a Types.TypeExpr.t list -> ('inner, 'outer) text elt list
  -> ('inner, 'outer) text elt list
= fun ~get_package ~delim params path ->
  match params with
  | [] -> path
  | [param] ->
    type_expr ~needs_parentheses:true ~get_package param @ pcdata " " :: path
  | params  ->
    let params =
      list_concat_map params ~sep:(pcdata ",\194\160")
        ~f:(type_expr ~get_package)
    in
    match delim with
    | `parens   -> pcdata "(" :: params @ pcdata ")\194\160" :: path
    | `brackets -> pcdata "[" :: params @ pcdata "]\194\160" :: path

and type_expr
   : 'inner 'outer. ?needs_parentheses:bool -> get_package:('a -> string)
  -> 'a Types.TypeExpr.t -> ('inner, 'outer) text elt list
= fun ?(needs_parentheses=false) ~get_package t ->
  match t with
  | Var s -> [Markup.Type.var ("'" ^ s)]
  | Any  -> [Markup.Type.var "_"]
  | Alias (te, alias) ->
    type_expr ~needs_parentheses:true ~get_package te @
    Markup.keyword " as " :: [ pcdata alias ]
  | Arrow (None, src, dst) ->
    let res =
      type_expr ~needs_parentheses:true ~get_package src @
      Markup.keyword " -> " :: type_expr ~get_package dst
    in
    if not needs_parentheses then res else pcdata "(" :: res @ [pcdata ")"]
  | Arrow (Some lbl, src, dst) ->
    let res =
      pcdata (string_of_label lbl ^ ":") ::
      type_expr ~needs_parentheses:true ~get_package src @
      Markup.keyword " -> " :: type_expr ~get_package dst
    in
    if not needs_parentheses then res else pcdata "(" :: res @ [pcdata ")"]
  | Tuple lst ->
    let res =
      list_concat_map lst ~sep:(Markup.keyword " * ")
        ~f:(type_expr ~needs_parentheses:true ~get_package)
    in
    if not needs_parentheses then res else pcdata "(" :: res @ [pcdata ")"]
  | Constr (path, args) ->
    let link = Html_tree.Relative_link.of_path ~get_package path in
    format_type_path ~get_package ~delim:(`parens) args link
  | Variant v -> te_variant ~get_package v
  | Object o -> te_object ~get_package o
  | Class (path, args) ->
    format_type_path ~get_package ~delim:(`brackets) args
      (Html_tree.Relative_link.of_path ~get_package path)
  | Poly (polyvars, t) ->
    pcdata (String.concat " " polyvars ^ ". ") :: type_expr ~get_package t
  | Package pkg ->
    (* CR trefis: TODO substitutions *)
    pcdata "(" :: Markup.keyword "module " ::
    Html_tree.Relative_link.of_path ~get_package pkg.path @ [pcdata ")"]

and value ~get_package (t : _ Types.Value.t) =
  let name = Identifier.name t.id in
  let dot_val = "/" ^ name ^ ".val" in
  let doc = Documentation.to_html ~get_package t.doc in
  let value =
    Markup.keyword "val " ::
    pcdata name ::
    pcdata " : " ::
    type_expr ~get_package t.type_
  in
  Markup.make_def ~kind:"val" ~id:dot_val ~doc ~code:value

and external_ ~get_package (t : _ Types.External.t) =
  let name = Identifier.name t.id in
  let dot_val = "/" ^ name ^ ".val" in
  let doc = Documentation.to_html ~get_package t.doc in
  let external_ =
    Markup.keyword "external " ::
    pcdata name ::
    pcdata " : " ::
    type_expr ~get_package t.type_ @
    pcdata " = " ::
    List.map t.primitives ~f:(fun p -> pcdata ("\"" ^ p ^ "\" "))
  in
  Markup.make_def ~kind:"val" ~id:dot_val ~doc ~code:external_

and class_ ~get_package (t : _ Types.Class.t) =
  let name = Identifier.name t.id in
  let dot_cl = "/" ^ name ^ ".cl" in
  let doc = Documentation.to_html ~get_package t.doc in
  let class_ =
    [
      Markup.keyword "class ";
      pcdata name;
      (* TODO: complete. *)
    ]
  in
  Markup.make_def ~kind:"class" ~id:dot_cl ~doc ~code:class_

and class_type ~get_package (t : _ Types.ClassType.t) =
  let name = Identifier.name t.id in
  let dot_clt = "/" ^ name ^ ".clt" in
  let doc = Documentation.to_html ~get_package t.doc in
  let ctyp =
    [
      Markup.keyword "class type ";
      pcdata name;
      (* TODO: complete. *)
    ]
  in
  Markup.make_def ~kind:"classtype" ~id:dot_clt ~doc ~code:ctyp

and include_ ~get_package (t : _ Types.Include.t) =
  let doc = Documentation.to_html ~get_package t.doc in
  let included_html, tree = signature ~get_package t.expansion.content in
  let should_be_inlined =
    match t.doc with
    | Ok { tags ; _ } -> List.mem Types.Documentation.Inline ~set:tags
    | _ -> false
  in
  let incl =
    if should_be_inlined then included_html else
      let incl =
        Markup.keyword "include " ::
        module_decl' ~get_package t.parent t.decl
      in
      (* TODO: I'd like to add an anchor here, but I don't know what id to give
         it... *)
      details (Markup.def_summary @@ html_dot_magic incl) [included_html]
  in
  div ~a:[ a_class ["include"] ] [incl; div ~a:[ a_class ["doc"] ] doc], tree
