open Stdune

let _BUILD_PATH_PREFIX_MAP = "BUILD_PATH_PREFIX_MAP"

let extend_build_path_prefix_map env how map =
  let new_rules = Build_path_prefix_map.encode_map map in
  Env.update env ~var:_BUILD_PATH_PREFIX_MAP ~f:(function
    | None -> Some new_rules
    | Some existing_rules ->
      Some
        (match how with
         | `Existing_rules_have_precedence -> new_rules ^ ":" ^ existing_rules
         | `New_rules_have_precedence -> existing_rules ^ ":" ^ new_rules))
;;

(** [inverse ~inverse_rule target] maps a [target] back to the matching source
    in the [inverse_rule]. If [target] is not part of the inverse rule
    then the return value is the unmodified [target]. *)
let inverse ~inverse_rule target =
  let target_file = Path.of_string target |> Path.Expert.try_localize_external in
  match Path.as_in_source_tree target_file with
  | None -> target
  | Some targetfile ->
    let target = Path.Source.to_string targetfile in
    let sourcefile =
      Path.Source.of_string (Build_path_prefix_map.rewrite inverse_rule target)
    in
    Path.to_absolute_filename (Path.source sourcefile)
;;

(** [Build_path_prefix_map.rewrite_opt] does not return back the matching
    {source;target} pair. Find it ourselves and then we can make an
    inverse_mapper function (from target to source). *)
let rewrite_and_inverse prefix_map path =
  let is_prefix = function
    | None -> false
    | Some { Build_path_prefix_map.target = _; source } ->
      String.length source <= String.length path
      && String.equal source (String.sub path ~pos:0 ~len:(String.length source))
  in
  match
    List.find_opt
      ~f:is_prefix
      (* read key/value pairs from right to left, as the spec demands *)
      (List.rev prefix_map)
  with
  | None | Some None -> path, Fun.id
  | Some (Some { source; target }) ->
    let open Build_path_prefix_map in
    let inverse_rule = [ Some { source = target; target = source } ] in
    ( target
      ^ String.sub
          path
          ~pos:(String.length source)
          ~len:(String.length path - String.length source)
    , inverse ~inverse_rule )
;;

(** [source_to_target ~rules source_buildfile] maps the source build file
    to the target build file according to the mapping [rules]. *)
let source_to_target ~rules source_buildfile =
  match Path.Build.extract_build_context_dir source_buildfile with
  | None -> None, Fun.id
  | Some (build_context_dir, sourcefile) ->
    let source = Path.Source.to_string sourcefile in
    let target, inverse = rewrite_and_inverse rules source in
    let targetfile = Path.Source.of_string target in
    Some (Path.Build.append_source build_context_dir targetfile), inverse
;;

let project_target_buildfile source_buildfile =
  match Env.get Env.initial "DUNE_PROJECT_SOURCE_PREFIX_MAP" with
  | None -> None, Fun.id
  | Some map ->
    (match Build_path_prefix_map.decode_map map with
     | Error _ -> None, Fun.id
     | Ok rules -> source_to_target ~rules source_buildfile)
;;
