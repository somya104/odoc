(* Phase 1 - compilation *)

(* First round of resolving only attempts to resolve paths and fragments, and then only those
   that don't contain forward paths *)

open Odoc_model
open Lang
module Id = Paths.Identifier

module Opt = struct
  let map f = function Some x -> Some (f x) | None -> None
end

let type_path : Env.t -> Paths.Path.Type.t -> Paths.Path.Type.t =
 fun env p ->
  match p with
  | `Resolved _ -> p
  | _ -> (
      let cp = Component.Of_Lang.(type_path empty p) in
      match Tools.resolve_type_path env cp with
      | Ok p' -> `Resolved (Cpath.resolved_type_path_of_cpath p')
      | Error _ -> p)

and module_type_path :
    Env.t -> Paths.Path.ModuleType.t -> Paths.Path.ModuleType.t =
 fun env p ->
  match p with
  | `Resolved _ -> p
  | _ -> (
      let cp = Component.Of_Lang.(module_type_path empty p) in
      match Tools.resolve_module_type_path env cp with
      | Ok p' -> `Resolved (Cpath.resolved_module_type_path_of_cpath p')
      | Error _ -> p)

and module_path : Env.t -> Paths.Path.Module.t -> Paths.Path.Module.t =
 fun env p ->
  match p with
  | `Resolved _ -> p
  | _ -> (
      let cp = Component.Of_Lang.(module_path empty p) in
      match Tools.resolve_module_path env cp with
      | Ok p' -> `Resolved (Cpath.resolved_module_path_of_cpath p')
      | Error _ -> p)

and class_type_path : Env.t -> Paths.Path.ClassType.t -> Paths.Path.ClassType.t
    =
 fun env p ->
  match p with
  | `Resolved _ -> p
  | _ -> (
      let cp = Component.Of_Lang.(class_type_path empty p) in
      match Tools.resolve_class_type_path env cp with
      | Ok p' -> `Resolved (Cpath.resolved_class_type_path_of_cpath p')
      | Error _ -> Cpath.class_type_path_of_cpath cp)

let rec unit (resolver : Env.resolver) t =
  let open Compilation_unit in
  let imports, env = Env.initial_env t resolver in
  { t with content = content env t.id t.content; imports }

and content env id =
  let open Compilation_unit in
  function
  | Module m ->
      let sg = Type_of.signature env m in
      Module (signature env (id :> Id.Signature.t) sg)
  | Pack p -> Pack p

and value_ env parent t =
  let open Value in
  let container = (parent :> Id.Parent.t) in
  try { t with type_ = type_expression env container t.type_ }
  with _ ->
    Errors.report ~what:(`Value t.id) `Compile;
    t

and exception_ env parent e =
  let open Exception in
  let container = (parent :> Id.Parent.t) in
  let res = Opt.map (type_expression env container) e.res in
  let args = type_decl_constructor_argument env container e.args in
  { e with res; args }

and extension env parent t =
  let open Extension in
  let container = (parent :> Id.Parent.t) in
  let constructor c =
    let open Constructor in
    {
      c with
      args = type_decl_constructor_argument env container c.args;
      res = Opt.map (type_expression env container) c.res;
    }
  in
  let type_path = type_path env t.type_path in
  let constructors = List.map constructor t.constructors in
  { t with type_path; constructors }

and external_ env parent e =
  let open External in
  let container = (parent :> Id.Parent.t) in
  { e with type_ = type_expression env container e.type_ }

and class_type_expr env parent =
  let open ClassType in
  let container = (parent :> Id.Parent.t) in
  function
  | Constr (path, texps) ->
      Constr
        ( class_type_path env path,
          List.map (type_expression env container) texps )
  | Signature s -> Signature (class_signature env parent s)

and class_type env c =
  let open ClassType in
  let expansion =
    match
      let open Utils.OptionMonad in
      Env.(lookup_by_id s_class_type) c.id env >>= fun (`ClassType (_, c')) ->
      Tools.class_signature_of_class_type env c' >>= fun sg ->
      let cs =
        Lang_of.class_signature Lang_of.empty
          (c.id :> Paths.Identifier.Path.ClassType.t)
          sg
      in
      let compiled = class_signature env (c.id :> Id.ClassSignature.t) cs in
      Some compiled
    with
    | Some _ as exp -> exp
    | None ->
        Errors.report ~what:(`Class_type c.id) `Expand;
        c.expansion
  in
  {
    c with
    expr = class_type_expr env (c.id :> Id.ClassSignature.t) c.expr;
    expansion;
  }

and class_signature env parent c =
  let open ClassSignature in
  let container = (parent : Id.ClassSignature.t :> Id.Parent.t) in
  let env = Env.open_class_signature c env in
  let map_item = function
    | Method m -> Method (method_ env parent m)
    | InstanceVariable i -> InstanceVariable (instance_variable env parent i)
    | Constraint (t1, t2) ->
        Constraint
          (type_expression env container t1, type_expression env container t2)
    | Inherit c -> Inherit (class_type_expr env parent c)
    | Comment c -> Comment c
  in
  {
    c with
    self = Opt.map (type_expression env container) c.self;
    items = List.map map_item c.items;
  }

and method_ env parent m =
  let open Method in
  let container = (parent :> Id.Parent.t) in
  { m with type_ = type_expression env container m.type_ }

and instance_variable env parent i =
  let open InstanceVariable in
  let container = (parent :> Id.Parent.t) in
  { i with type_ = type_expression env container i.type_ }

and class_ env parent c =
  let open Class in
  let container = (parent :> Id.Parent.t) in
  let expansion =
    match
      let open Utils.OptionMonad in
      Env.(lookup_by_id s_class) c.id env >>= fun (`Class (_, c')) ->
      Tools.class_signature_of_class env c' >>= fun sg ->
      let cs =
        Lang_of.class_signature Lang_of.empty
          (c.id :> Paths.Identifier.Path.ClassType.t)
          sg
      in
      Some (class_signature env (c.id :> Id.ClassSignature.t) cs)
    with
    | Some _ as exp -> exp
    | None ->
        Errors.report ~what:(`Class c.id) `Expand;
        c.expansion
  in
  let rec map_decl = function
    | ClassType expr ->
        ClassType (class_type_expr env (c.id :> Id.ClassSignature.t) expr)
    | Arrow (lbl, expr, decl) ->
        Arrow (lbl, type_expression env container expr, map_decl decl)
  in
  { c with type_ = map_decl c.type_; expansion }

and module_substitution env m =
  let open ModuleSubstitution in
  { m with manifest = module_path env m.manifest }

and signature_items : Env.t -> Id.Signature.t -> Signature.item list -> _ =
 fun env id s ->
  let open Signature in
  let items, _ =
    List.fold_left
      (fun (items, env) item ->
        let std i = (i :: items, env) in
        match item with
        | Module (r, m) ->
            let m' = module_ env m in
            if m == m' then (item :: items, env)
            else
              let ty =
                Component.Delayed.(
                  put (fun () -> Component.Of_Lang.(module_ empty m')))
              in
              let docs = [] in
              let env' =
                Env.add_module
                  (m.id :> Paths.Identifier.Path.Module.t)
                  ty docs env
              in
              (Module (r, m') :: items, env')
        | ModuleSubstitution m ->
            std @@ ModuleSubstitution (module_substitution env m)
        | Type (r, t) -> std @@ Type (r, type_decl env t)
        | TypeSubstitution t -> std @@ TypeSubstitution (type_decl env t)
        | ModuleType mt ->
            let m' = module_type env mt in
            let ty = Component.Of_Lang.(module_type empty m') in
            let env' = Env.add_module_type mt.id ty env in
            (ModuleType (module_type env mt) :: items, env')
        | Value v -> std @@ Value (value_ env id v)
        | Comment c -> std @@ Comment c
        | TypExt t -> std @@ TypExt (extension env id t)
        | Exception e -> std @@ Exception (exception_ env id e)
        | External e -> std @@ External (external_ env id e)
        | Class (r, c) -> std @@ Class (r, class_ env id c)
        | ClassType (r, c) -> std @@ ClassType (r, class_type env c)
        | Include i ->
            let i' = include_ env i in
            if i'.expansion == i.expansion then std @@ Include i'
            else
              (* Expansion has changed, let's put the new modules into the environment *)
              let env' =
                List.fold_left
                  (fun env item ->
                    match item with
                    | Module (_, m) ->
                        let ty =
                          Component.Delayed.(
                            put (fun () -> Component.Of_Lang.(module_ empty m)))
                        in
                        let env' =
                          Env.add_module
                            (m.id :> Paths.Identifier.Path.Module.t)
                            ty [] env
                        in
                        env'
                    | _ -> env)
                  env i'.expansion.content.items
              in
              (Include i' :: items, env')
        | Open o -> std @@ Open o)
      ([], env) s
  in
  List.rev items

and signature : Env.t -> Id.Signature.t -> Signature.t -> _ =
 fun env id s ->
  if s.compiled then s
  else
    let env = Env.open_signature s env |> Env.add_docs s.doc in
    let items = signature_items env id s.items in
    {
      items;
      compiled = true;
      doc = s.doc (* comments are ignored while compiling *);
    }

and module_ : Env.t -> Module.t -> Module.t =
 fun env m ->
  let open Module in
  if m.hidden then m
  else { m with type_ = module_decl env (m.id :> Id.Signature.t) m.type_ }

and module_decl : Env.t -> Id.Signature.t -> Module.decl -> Module.decl =
 fun env id decl ->
  let open Module in
  match decl with
  | ModuleType expr -> ModuleType (module_type_expr env id expr)
  | Alias (p, expn) -> Alias (module_path env p, expn)

and include_decl : Env.t -> Id.Signature.t -> Include.decl -> Include.decl =
 fun env id decl ->
  let open Include in
  match decl with
  | ModuleType expr -> ModuleType (u_module_type_expr env id expr)
  | Alias p -> Alias (module_path env p)

and module_type : Env.t -> ModuleType.t -> ModuleType.t =
 fun env m ->
  let open ModuleType in
  let sg_id = (m.id :> Id.Signature.t) in
  (* Format.fprintf Format.err_formatter "Handling module type: %a\n" Component.Fmt.model_identifier (m.id :> Id.t); *)
  let expr =
    match m.expr with
    | None -> None
    | Some e -> Some (module_type_expr env sg_id e)
  in
  { m with expr }

and include_ : Env.t -> Include.t -> Include.t =
 fun env i ->
  let open Include in
  let decl = Component.Of_Lang.(include_decl empty i.decl) in
  let get_expansion () =
    match
      let open Utils.ResultMonad in
      match decl with
      | Alias p ->
          Expand_tools.aux_expansion_of_module_alias env ~strengthen:true p
          >>= Expand_tools.assert_not_functor
      | ModuleType mty ->
          Expand_tools.aux_expansion_of_u_module_type_expr env mty
    with
    | Error e ->
        Errors.report ~what:(`Include decl) ~tools_error:e `Expand;
        i.expansion
    | Ok sg ->
        let map = { Lang_of.empty with shadowed = i.expansion.shadowed } in
        let sg' =
          match i.strengthened with
          | Some p ->
              let cp = Component.Of_Lang.(module_path empty p) in
              Strengthen.signature cp sg
          | None -> sg
        in
        let e = Lang_of.(simple_expansion map i.parent (Signature sg')) in

        let expansion_sg =
          match e with
          | ModuleType.Signature sg -> sg
          | _ ->
              failwith "Expansion shouldn't be anything other than a signature"
        in
        {
          shadowed = i.expansion.shadowed;
          content = signature env i.parent expansion_sg;
        }
  in
  let expansion =
    if i.expansion.content.compiled then i.expansion else get_expansion ()
  in
  { i with decl = include_decl env i.parent i.decl; expansion }

and simple_expansion :
    Env.t ->
    Id.Signature.t ->
    ModuleType.simple_expansion ->
    ModuleType.simple_expansion =
 fun env id e ->
  match e with
  | Signature sg -> Signature (signature env id sg)
  | Functor (param, sg) ->
      let env' = Env.add_functor_parameter param env in
      Functor
        (functor_parameter env param, simple_expansion env' (`Result id) sg)

and functor_parameter : Env.t -> FunctorParameter.t -> FunctorParameter.t =
 fun env param ->
  match param with
  | Unit -> Unit
  | Named arg -> Named (functor_parameter_parameter env arg)

and functor_parameter_parameter :
    Env.t -> FunctorParameter.parameter -> FunctorParameter.parameter =
 fun env a ->
  { a with expr = module_type_expr env (a.id :> Id.Signature.t) a.expr }

and module_type_expr_sub id ~fragment_root (sg_res, env, subs) lsub =
  let open Utils.ResultMonad in
  match sg_res with
  | Error _ -> (sg_res, env, lsub :: subs)
  | Ok sg -> (
      (* Format.eprintf "compile.module_type_expr: sig=%a\n%!" Component.Fmt.signature sg; *)
      let lang_of_map = Lang_of.with_fragment_root fragment_root in
      let env = Env.add_fragment_root sg env in
      let sg_and_sub =
        match lsub with
        | Odoc_model.Lang.ModuleType.ModuleEq (frag, decl) ->
            let cfrag = Component.Of_Lang.(module_fragment empty frag) in
            let cfrag', frag' =
              match
                Tools.resolve_module_fragment env (fragment_root, sg) cfrag
              with
              | Some cfrag' ->
                  ( `Resolved cfrag',
                    `Resolved
                      (Lang_of.Path.resolved_module_fragment lang_of_map cfrag')
                  )
              | None ->
                  Errors.report ~what:(`With_module cfrag) `Resolve;
                  (cfrag, frag)
            in
            let decl' = module_decl env id decl in
            let cdecl' = Component.Of_Lang.(module_decl empty decl') in
            let resolved_csub =
              Component.ModuleType.ModuleEq (cfrag', cdecl')
            in
            Tools.fragmap ~mark_substituted:true env resolved_csub sg
            >>= fun sg' ->
            Ok (sg', Odoc_model.Lang.ModuleType.ModuleEq (frag', decl'))
        | TypeEq (frag, eqn) ->
            let cfrag = Component.Of_Lang.(type_fragment empty frag) in
            let cfrag', frag' =
              match
                Tools.resolve_type_fragment env (fragment_root, sg) cfrag
              with
              | Some cfrag' ->
                  ( `Resolved cfrag',
                    `Resolved
                      (Lang_of.Path.resolved_type_fragment lang_of_map cfrag')
                  )
              | None ->
                  Errors.report ~what:(`With_type cfrag) `Compile;
                  (cfrag, frag)
            in
            let eqn' = type_decl_equation env (id :> Id.Parent.t) eqn in
            let ceqn' = Component.Of_Lang.(type_equation empty eqn') in
            Tools.fragmap ~mark_substituted:true env
              (Component.ModuleType.TypeEq (cfrag', ceqn'))
              sg
            >>= fun sg' ->
            Ok (sg', Odoc_model.Lang.ModuleType.TypeEq (frag', eqn'))
        | ModuleSubst (frag, mpath) ->
            let cfrag = Component.Of_Lang.(module_fragment empty frag) in
            let cfrag', frag' =
              match
                Tools.resolve_module_fragment env (fragment_root, sg) cfrag
              with
              | Some cfrag ->
                  ( `Resolved cfrag,
                    `Resolved
                      (Lang_of.Path.resolved_module_fragment lang_of_map cfrag)
                  )
              | None ->
                  Errors.report ~what:(`With_module cfrag) `Resolve;
                  (cfrag, frag)
            in
            let mpath' = module_path env mpath in
            let cmpath' = Component.Of_Lang.(module_path empty mpath') in
            Tools.fragmap ~mark_substituted:true env
              (Component.ModuleType.ModuleSubst (cfrag', cmpath'))
              sg
            >>= fun sg' ->
            Ok (sg', Odoc_model.Lang.ModuleType.ModuleSubst (frag', mpath'))
        | TypeSubst (frag, eqn) ->
            let cfrag = Component.Of_Lang.(type_fragment empty frag) in
            let cfrag', frag' =
              match
                Tools.resolve_type_fragment env (fragment_root, sg) cfrag
              with
              | Some cfrag ->
                  ( `Resolved cfrag,
                    `Resolved
                      (Lang_of.Path.resolved_type_fragment lang_of_map cfrag) )
              | None ->
                  Errors.report ~what:(`With_type cfrag) `Compile;
                  (cfrag, frag)
            in
            let eqn' = type_decl_equation env (id :> Id.Parent.t) eqn in
            let ceqn' = Component.Of_Lang.(type_equation empty eqn') in
            Tools.fragmap ~mark_substituted:true env
              (Component.ModuleType.TypeSubst (cfrag', ceqn'))
              sg
            >>= fun sg' ->
            Ok (sg', Odoc_model.Lang.ModuleType.TypeSubst (frag', eqn'))
      in
      match sg_and_sub with
      | Ok (sg', sub') -> (Ok sg', env, sub' :: subs)
      | Error _ -> (sg_res, env, lsub :: subs))

and module_type_map_subs env id cexpr subs =
  let rec find_parent : Component.ModuleType.U.expr -> Cfrag.root option =
   fun expr ->
    match expr with
    | Component.ModuleType.U.Signature _ -> None
    | Path (`Resolved p) -> Some (`ModuleType p)
    | Path _ -> None
    | With (_, e) -> find_parent e
    | TypeOf { t_desc = ModPath (`Resolved p); _ }
    | TypeOf { t_desc = StructInclude (`Resolved p); _ } ->
        Some (`Module p)
    | TypeOf _ -> None
  in
  match find_parent cexpr with
  | None -> None
  | Some parent -> (
      match
        Tools.signature_of_u_module_type_expr ~mark_substituted:true env cexpr
      with
      | Error e ->
          Errors.report ~what:(`Module_type id) ~tools_error:e `Lookup;
          None
      | Ok sg ->
          let fragment_root =
            match parent with (`ModuleType _ | `Module _) as x -> x
          in
          let _, _, subs =
            List.fold_left
              (module_type_expr_sub (id :> Id.Signature.t) ~fragment_root)
              (Ok sg, env, []) subs
          in
          let subs = List.rev subs in
          Some subs)

and u_module_type_expr :
    Env.t -> Id.Signature.t -> ModuleType.U.expr -> ModuleType.U.expr =
 fun env id expr ->
  let open ModuleType in
  let rec inner : U.expr -> U.expr = function
    | Signature s -> Signature s
    | Path p -> Path (module_type_path env p)
    | With (subs, expr) -> (
        let expr' = inner expr in
        let cexpr = Component.Of_Lang.(u_module_type_expr empty expr') in
        let subs' =
          match module_type_map_subs env id cexpr subs with
          | Some s -> s
          | None -> subs
        in
        let result : ModuleType.U.expr = With (subs', expr') in
        match expr' with
        | Signature _ -> (
            (* Explicitly handle 'sig ... end with ...' - replace with a plain signature.
               See equivalent in [module_type_expr] *)
            let cu =
              Component.Of_Lang.(u_module_type_expr empty (With (subs, expr')))
            in
            let expansion =
              Expand_tools.aux_expansion_of_u_module_type_expr env cu
            in
            match expansion with
            | Ok sg -> Signature Lang_of.(signature id empty sg)
            | _ -> result)
        | _ -> result)
    | TypeOf { t_desc; t_expansion } ->
        let t_desc =
          match t_desc with
          | ModPath p -> ModPath (module_path env p)
          | StructInclude p -> StructInclude (module_path env p)
        in
        TypeOf { t_desc; t_expansion }
  in
  inner expr

and module_type_expr :
    Env.t -> Id.Signature.t -> ModuleType.expr -> ModuleType.expr =
 fun env id expr ->
  let get_expansion cur e =
    match cur with
    | Some e -> Some (simple_expansion env id e)
    | None -> (
        let ce = Component.Of_Lang.(module_type_expr empty e) in
        match Expand_tools.expansion_of_module_type_expr env id ce with
        | Ok (_, _, ce) ->
            let e = Lang_of.simple_expansion Lang_of.empty id ce in
            Some (simple_expansion env id e)
        | Error e ->
            Errors.report ~what:(`Module_type_expr ce) ~tools_error:e `Expand;
            None)
  in
  match expr with
  | Signature s -> Signature (signature env id s)
  | Path { p_path; p_expansion } as e ->
      let p_expansion = get_expansion p_expansion e in
      Path { p_path = module_type_path env p_path; p_expansion }
  | With { w_substitutions; w_expansion; w_expr } as e -> (
      let w_expansion = get_expansion w_expansion e in
      let w_expr = u_module_type_expr env id w_expr in
      match (w_expr, w_expansion) with
      | Signature _, Some (Signature sg) ->
          (* Explicitly handle 'sig ... end with ...' - replace with a plain signature.
             See equivalent in [u_module_type_expr] *)
          Signature sg
      | _, _ -> (
          let cexpr = Component.Of_Lang.(u_module_type_expr empty w_expr) in
          let subs' = module_type_map_subs env id cexpr w_substitutions in
          match subs' with
          | None -> With { w_substitutions; w_expansion; w_expr }
          | Some s -> With { w_substitutions = s; w_expansion; w_expr }))
  | Functor (param, res) ->
      let param' = functor_parameter env param in
      let env' = Env.add_functor_parameter param env in
      let res' = module_type_expr env' id res in
      Functor (param', res')
  | TypeOf { t_desc; t_expansion } as e ->
      let t_expansion = get_expansion t_expansion e in
      let t_desc =
        match t_desc with
        | ModPath p -> ModuleType.ModPath (module_path env p)
        | StructInclude p -> StructInclude (module_path env p)
      in
      TypeOf { t_desc; t_expansion }

and type_decl : Env.t -> TypeDecl.t -> TypeDecl.t =
 fun env t ->
  let open TypeDecl in
  let container =
    match t.id with
    | `Type (parent, _) -> (parent :> Id.Parent.t)
    | `CoreType _ -> assert false
  in
  let equation = type_decl_equation env container t.equation in
  let representation =
    Opt.map (type_decl_representation env container) t.representation
  in
  { t with equation; representation }

and type_decl_equation :
    Env.t -> Id.Parent.t -> TypeDecl.Equation.t -> TypeDecl.Equation.t =
 fun env parent t ->
  let open TypeDecl.Equation in
  let manifest = Opt.map (type_expression env parent) t.manifest in
  let constraints =
    List.map
      (fun (tex1, tex2) ->
        (type_expression env parent tex1, type_expression env parent tex2))
      t.constraints
  in
  { t with manifest; constraints }

and type_decl_representation :
    Env.t ->
    Id.Parent.t ->
    TypeDecl.Representation.t ->
    TypeDecl.Representation.t =
 fun env parent r ->
  let open TypeDecl.Representation in
  match r with
  | Variant cs -> Variant (List.map (type_decl_constructor env parent) cs)
  | Record fs -> Record (List.map (type_decl_field env parent) fs)
  | Extensible -> Extensible

and type_decl_field env parent f =
  let open TypeDecl.Field in
  { f with type_ = type_expression env parent f.type_ }

and type_decl_constructor_argument env parent c =
  let open TypeDecl.Constructor in
  match c with
  | Tuple ts -> Tuple (List.map (type_expression env parent) ts)
  | Record fs -> Record (List.map (type_decl_field env parent) fs)

and type_decl_constructor :
    Env.t -> Id.Parent.t -> TypeDecl.Constructor.t -> TypeDecl.Constructor.t =
 fun env parent c ->
  let open TypeDecl.Constructor in
  let args = type_decl_constructor_argument env parent c.args in
  let res = Opt.map (type_expression env parent) c.res in
  { c with args; res }

and type_expression_polyvar env parent v =
  let open TypeExpr.Polymorphic_variant in
  let constructor c =
    let open Constructor in
    { c with arguments = List.map (type_expression env parent) c.arguments }
  in
  let element = function
    | Type t -> Type (type_expression env parent t)
    | Constructor c -> Constructor (constructor c)
  in
  { v with elements = List.map element v.elements }

and type_expression_object env parent o =
  let open TypeExpr.Object in
  let method_ m = { m with type_ = type_expression env parent m.type_ } in
  let field = function
    | Method m -> Method (method_ m)
    | Inherit t -> Inherit (type_expression env parent t)
  in
  { o with fields = List.map field o.fields }

and type_expression_package env parent p =
  let open TypeExpr.Package in
  let cp = Component.Of_Lang.(module_type_path empty p.path) in
  match
    Tools.resolve_module_type ~mark_substituted:true ~add_canonical:true env cp
  with
  | Ok (path, mt) -> (
      match Tools.signature_of_module_type env mt with
      | Error e ->
          Errors.report ~what:(`Package cp) ~tools_error:e `Lookup;
          p
      | Ok sg ->
          let substitution (frag, t) =
            let cfrag = Component.Of_Lang.(type_fragment empty frag) in
            let frag' =
              match
                Tools.resolve_type_fragment env (`ModuleType path, sg) cfrag
              with
              | Some cfrag' ->
                  `Resolved (Lang_of.(Path.resolved_type_fragment empty) cfrag')
              | None ->
                  Errors.report ~what:(`Type cfrag) `Compile;
                  frag
            in
            (frag', type_expression env parent t)
          in
          {
            path = module_type_path env p.path;
            substitutions = List.map substitution p.substitutions;
          })
  | Error _ -> { p with path = Cpath.module_type_path_of_cpath cp }

and type_expression : Env.t -> Id.Parent.t -> _ -> _ =
 fun env parent texpr ->
  let open TypeExpr in
  match texpr with
  | Var _ | Any -> texpr
  | Alias (t, str) -> Alias (type_expression env parent t, str)
  | Arrow (lbl, t1, t2) ->
      Arrow (lbl, type_expression env parent t1, type_expression env parent t2)
  | Tuple ts -> Tuple (List.map (type_expression env parent) ts)
  | Constr (path, ts') -> (
      let cp = Component.Of_Lang.(type_path empty path) in
      let ts = List.map (type_expression env parent) ts' in
      match Tools.resolve_type env ~add_canonical:true cp with
      | Ok (cp, (`FType _ | `FClass _ | `FClassType _)) ->
          let p = Cpath.resolved_type_path_of_cpath cp in
          Constr (`Resolved p, ts)
      | Ok (_cp, `FType_removed (_, x, _eq)) ->
          (* Substitute type variables ? *)
          Lang_of.(type_expr empty parent x)
      | Error _ -> Constr (Cpath.type_path_of_cpath cp, ts))
  | Polymorphic_variant v ->
      Polymorphic_variant (type_expression_polyvar env parent v)
  | Object o -> Object (type_expression_object env parent o)
  | Class (path, ts) -> Class (path, List.map (type_expression env parent) ts)
  | Poly (strs, t) -> Poly (strs, type_expression env parent t)
  | Package p -> Package (type_expression_package env parent p)

type msg = [ `Msg of string ]

exception Fetch_failed of msg

let build_resolver :
    ?equal:(Root.t -> Root.t -> bool) ->
    ?hash:(Root.t -> int) ->
    string list ->
    (string -> Env.lookup_unit_result) ->
    (Root.t -> (Compilation_unit.t, _) Result.result) ->
    (string -> Root.t option) ->
    (Root.t -> (Page.t, _) Result.result) ->
    Env.resolver =
 fun ?equal:_ ?hash:_ open_units lookup_unit resolve_unit lookup_page
     resolve_page ->
  let resolve_unit root =
    match resolve_unit root with
    | Ok unit -> unit
    | Error (`Msg s) ->
        Format.eprintf "Fetch_failed: %s\n%!" s;
        raise (Fetch_failed (`Msg s))
  and resolve_page root =
    match resolve_page root with
    | Ok page -> page
    | Error (`Msg s) ->
        Format.eprintf "Fetch_failed (resolving page): %s\n%!" s;
        raise (Fetch_failed (`Msg s))
  in
  { Env.lookup_unit; resolve_unit; lookup_page; resolve_page; open_units }

let compile x y = Lookup_failures.catch_failures (fun () -> unit x y)

let resolve_page _resolver y = y
