open Import
open Memo.O

type t =
  { project : Dune_project.t
  ; db : Lib.DB.t
  ; coq_db : Coq_lib.DB.t
  ; root : Path.Build.t
  }

let root t = t.root

let project t = t.project

let libs t = t.db

let coq_libs t = t.coq_db

module DB = struct
  type scope = t

  type t = { by_dir : scope Path.Source.Map.t }

  let find_by_dir_in_map =
    (* This function is linear in the depth of [dir] in the worst case, so if it
       shows up in the profile we should memoize it. *)
    let find_by_dir map (dir : Path.Source.t) =
      let rec loop d =
        match Path.Source.Map.find map d with
        | Some s -> s
        | None -> (
          match Path.Source.parent d with
          | Some d -> loop d
          | None ->
            Code_error.raise "find_by_dir: invalid directory"
              [ ("d", Path.Source.to_dyn d); ("dir", Path.Source.to_dyn dir) ])
      in
      loop dir
    in
    fun map dir ->
      if Path.Build.is_root dir then
        Code_error.raise "Scope.DB.find_by_dir_in_map got an invalid path"
          [ ("dir", Path.Build.to_dyn dir) ];
      find_by_dir map (Path.Build.drop_build_context_exn dir)

  let find_by_dir t dir = find_by_dir_in_map t.by_dir dir

  let find_by_project t project =
    Path.Source.Map.find_exn t.by_dir (Dune_project.root project)

  module Found_or_redirect : sig
    type t = private
      | Found of Lib_info.external_
      | Redirect of (Loc.t * Lib_name.t)

    val redirect : Lib_name.t -> Loc.t * Lib_name.t -> Lib_name.t * t

    val found : Lib_info.external_ -> t
  end = struct
    type t =
      | Found of Lib_info.external_
      | Redirect of (Loc.t * Lib_name.t)

    let redirect from (loc, to_) =
      if Lib_name.equal from to_ then
        Code_error.raise ~loc "Invalid redirect"
          [ ("to_", Lib_name.to_dyn to_) ]
      else (from, Redirect (loc, to_))

    let found x = Found x
  end

  module Library_related_stanza = struct
    type t =
      | Library of Path.Build.t * Dune_file.Library.t
      | Library_redirect of Dune_file.Library_redirect.Local.t
      | Deprecated_library_name of Dune_file.Deprecated_library_name.t
  end

  let create_db_from_stanzas ~parent ~lib_config stanzas =
    let open Memo.O in
    let+ (map : Found_or_redirect.t Lib_name.Map.t) =
      Memo.List.map stanzas ~f:(fun stanza ->
          match (stanza : Library_related_stanza.t) with
          | Library_redirect s ->
            let old_public_name = Lib_name.of_local s.old_name in
            Memo.return
              (Found_or_redirect.redirect old_public_name s.new_public_name)
          | Deprecated_library_name s ->
            let old_public_name =
              Dune_file.Deprecated_library_name.old_public_name s
            in
            Memo.return
              (Found_or_redirect.redirect old_public_name s.new_public_name)
          | Library (dir, (conf : Dune_file.Library.t)) ->
            let+ info =
              Dune_file.Library.to_lib_info conf ~dir ~lib_config
              >>| Lib_info.of_local
            in
            (Dune_file.Library.best_name conf, Found_or_redirect.found info))
      >>| Lib_name.Map.of_list_reducei
            ~f:(fun name (v1 : Found_or_redirect.t) v2 ->
              let res =
                match (v1, v2) with
                | Found info1, Found info2 ->
                  Error (Lib_info.loc info1, Lib_info.loc info2)
                | Found info, Redirect (loc, _) | Redirect (loc, _), Found info
                  -> Error (loc, Lib_info.loc info)
                | Redirect (loc1, lib1), Redirect (loc2, lib2) ->
                  if Lib_name.equal lib1 lib2 then Ok v1 else Error (loc1, loc2)
              in
              match res with
              | Ok x -> x
              | Error (loc1, loc2) ->
                User_error.raise
                  [ Pp.textf "Library %s is defined twice:"
                      (Lib_name.to_string name)
                  ; Pp.textf "- %s" (Loc.to_file_colon_line loc1)
                  ; Pp.textf "- %s" (Loc.to_file_colon_line loc2)
                  ])
    in
    Lib.DB.create () ~parent:(Some parent)
      ~resolve:(fun name ->
        Memo.return
          (match Lib_name.Map.find map name with
          | None -> Lib.DB.Resolve_result.not_found
          | Some (Redirect lib) -> Lib.DB.Resolve_result.redirect None lib
          | Some (Found lib) -> Lib.DB.Resolve_result.found lib))
      ~all:(fun () -> Lib_name.Map.keys map |> Memo.return)
      ~lib_config

  type redirect_to =
    | Project of Dune_project.t
    | Name of (Loc.t * Lib_name.t)

  let resolve t public_libs name : Lib.DB.Resolve_result.t =
    match Lib_name.Map.find public_libs name with
    | None -> Lib.DB.Resolve_result.not_found
    | Some (Project project) ->
      let scope = find_by_project (Fdecl.get t) project in
      Lib.DB.Resolve_result.redirect (Some scope.db) (Loc.none, name)
    | Some (Name name) -> Lib.DB.Resolve_result.redirect None name

  let public_theories ~find_db coq_stanzas =
    List.filter_map coq_stanzas ~f:(fun (dir, (stanza : Coq_stanza.Theory.t)) ->
        if Option.is_some stanza.package then
          Some (stanza, Coq_lib.DB.Theory dir)
        else None)
    |> Coq_lib.DB.create_from_coqlib_stanzas ~find_db ~parent:None

  (* Create a database from the public libraries defined in the stanzas *)
  let public_libs t ~installed_libs ~lib_config stanzas =
    let public_libs =
      List.filter_map stanzas ~f:(fun (stanza : Library_related_stanza.t) ->
          match stanza with
          | Library (_, { project; visibility = Public p; _ }) ->
            Some (Dune_file.Public_lib.name p, Project project)
          | Library _ | Library_redirect _ -> None
          | Deprecated_library_name s ->
            let old_name =
              Dune_file.Deprecated_library_name.old_public_name s
            in
            Some (old_name, Name s.new_public_name))
      |> Lib_name.Map.of_list
      |> function
      | Ok x -> x
      | Error (name, _, _) -> (
        match
          List.filter_map stanzas ~f:(fun stanza ->
              let named p loc = Option.some_if (name = p) loc in
              match stanza with
              | Library (_, { buildable = { loc; _ }; visibility = Public p; _ })
              | Deprecated_library_name
                  { Dune_file.Library_redirect.loc; old_name = p, _; _ } ->
                named (Dune_file.Public_lib.name p) loc
              | _ -> None)
        with
        | [] | [ _ ] -> assert false
        | loc1 :: loc2 :: _ ->
          User_error.raise
            [ Pp.textf "Public library %s is defined twice:"
                (Lib_name.to_string name)
            ; Pp.textf "- %s" (Loc.to_file_colon_line loc1)
            ; Pp.textf "- %s" (Loc.to_file_colon_line loc2)
            ])
    in
    let resolve lib = Memo.return (resolve t public_libs lib) in
    Lib.DB.create ~parent:(Some installed_libs) ~resolve
      ~all:(fun () -> Lib_name.Map.keys public_libs |> Memo.return)
      ~lib_config ()

  module Path_source_map_traversals = Memo.Make_map_traversals (Path.Source.Map)

  let scopes_by_dir context ~projects ~public_libs ~public_theories stanzas
      coq_stanzas =
    let open Memo.O in
    let projects_by_dir =
      List.map projects ~f:(fun (project : Dune_project.t) ->
          (Dune_project.root project, project))
      |> Path.Source.Map.of_list_exn
    in
    let stanzas_by_project_dir =
      List.map stanzas ~f:(fun (stanza : Library_related_stanza.t) ->
          let project =
            match stanza with
            | Library (_, lib) -> lib.project
            | Library_redirect x -> x.project
            | Deprecated_library_name x -> x.project
          in
          (Dune_project.root project, stanza))
      |> Path.Source.Map.of_list_multi
    in
    let coq_stanzas_by_project_dir =
      List.map coq_stanzas ~f:(fun (dir, (stanza : Coq_stanza.Theory.t)) ->
          let project = stanza.project in
          (Dune_project.root project, (dir, stanza)))
      |> Path.Source.Map.of_list_multi
    in
    let lib_config = Context.lib_config context in
    let+ db_by_project_dir =
      Path.Source.Map.merge projects_by_dir stanzas_by_project_dir
        ~f:(fun _dir project stanzas ->
          let project = Option.value_exn project in
          let stanzas = Option.value stanzas ~default:[] in
          Some (project, stanzas))
      |> Path_source_map_traversals.parallel_map
           ~f:(fun _dir (project, stanzas) ->
             let+ db =
               create_db_from_stanzas stanzas ~parent:public_libs ~lib_config
             in
             (project, db))
    in
    let coq_db_by_project_dir =
      let find_db dir = snd (find_by_dir_in_map db_by_project_dir dir) in
      Path.Source.Map.merge projects_by_dir coq_stanzas_by_project_dir
        ~f:(fun _dir project coq_stanzas ->
          assert (Option.is_some project);
          let stanzas = Option.value coq_stanzas ~default:[] in
          let entries =
            List.map stanzas ~f:(fun (dir, (stanza : Coq_stanza.Theory.t)) ->
                let entry =
                  match stanza.package with
                  | None -> Coq_lib.DB.Theory dir
                  | Some _ -> Redirect public_theories
                in
                (stanza, entry))
          in
          Some entries)
      |> Path.Source.Map.map ~f:(fun stanzas ->
             Coq_lib.DB.create_from_coqlib_stanzas
               ~parent:(Some public_theories) ~find_db stanzas)
    in
    Path.Source.Map.merge db_by_project_dir coq_db_by_project_dir
      ~f:(fun _dir project_and_db coq_db ->
        let project, db = Option.value_exn project_and_db in
        let coq_db = Option.value_exn coq_db in
        let root =
          Path.Build.append_source context.build_dir (Dune_project.root project)
        in
        Some { project; db; coq_db; root })

  let create ~context ~projects stanzas coq_stanzas =
    let open Memo.O in
    let t = Fdecl.create Dyn.opaque in
    let* public_libs =
      let lib_config = Context.lib_config context in
      let+ installed_libs = Lib.DB.installed context in
      public_libs t ~lib_config ~installed_libs stanzas
    in
    let public_theories =
      public_theories coq_stanzas ~find_db:(fun _ -> public_libs)
    in
    let+ by_dir =
      scopes_by_dir context ~projects ~public_libs ~public_theories stanzas
        coq_stanzas
    in
    let value = { by_dir } in
    Fdecl.set t value;
    (value, public_libs)

  let create_from_stanzas ~projects ~context stanzas =
    let stanzas, coq_stanzas =
      Dune_file.fold_stanzas stanzas ~init:([], [])
        ~f:(fun dune_file stanza (acc, coq_acc) ->
          match stanza with
          | Dune_file.Library lib ->
            let ctx_dir =
              Path.Build.append_source context.Context.build_dir dune_file.dir
            in
            (Library_related_stanza.Library (ctx_dir, lib) :: acc, coq_acc)
          | Dune_file.Deprecated_library_name d ->
            (Deprecated_library_name d :: acc, coq_acc)
          | Dune_file.Library_redirect d -> (Library_redirect d :: acc, coq_acc)
          | Coq_stanza.Theory.T coq_lib ->
            let ctx_dir =
              Path.Build.append_source context.build_dir dune_file.dir
            in
            (acc, (ctx_dir, coq_lib) :: coq_acc)
          | _ -> (acc, coq_acc))
    in
    create ~projects ~context stanzas coq_stanzas

  let memo =
    let module Input = struct
      type t = Dune_project.t list * Context.t * Dune_file.t list

      let equal =
        Tuple.T3.equal
          (List.equal Dune_project.equal)
          Context.equal
          (List.equal Dune_file.equal)

      let hash =
        Tuple.T3.hash
          (List.hash Dune_project.hash)
          Context.hash (List.hash Dune_file.hash)

      let to_dyn = Dyn.opaque
    end in
    Memo.create "scope-db"
      ~input:(module Input)
      (fun (projects, context, stanzas) ->
        create_from_stanzas ~projects ~context stanzas)

  let create_from_stanzas context =
    let* stanzas = Only_packages.filtered_stanzas context in
    let* { Dune_load.dune_files = _; packages = _; projects } =
      Dune_load.load ()
    in
    Memo.exec memo (projects, context, stanzas)

  let with_all context ~f =
    let+ scopes, _ = create_from_stanzas context in
    let find = find_by_project scopes in
    f find

  let public_libs context =
    let+ _, public_libs = create_from_stanzas context in
    public_libs

  let find_by_dir dir =
    let* context = Context.DB.by_dir dir in
    let+ scopes, _ = create_from_stanzas context in
    find_by_dir scopes dir

  let find_by_project context project =
    let+ scopes, _ = create_from_stanzas context in
    find_by_project scopes project
end
