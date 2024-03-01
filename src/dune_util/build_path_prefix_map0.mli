open Stdune

(** The [BUILD_PATH_PREFIX_MAP] variable *)
val _BUILD_PATH_PREFIX_MAP : Env.Var.t

(** [extend_build_path_prefix_map env how map] extends the path rewriting rules
    encoded in the [BUILD_PATH_PREFIX_MAP] variable.

    Note that the rewriting rules are applied from right to left, so the last
    rule of [map] will be tried first.

    If the environment variable is already defined in [env], [how] explains
    whether the rules in [map] should be tried before or after the existing
    ones. *)
val extend_build_path_prefix_map
  :  Env.t
  -> [ `Existing_rules_have_precedence | `New_rules_have_precedence ]
  -> Build_path_prefix_map.map
  -> Env.t

(** [project_target_buildfile source_buildfile] rewrites the location of
    a build file if there is a project source mapping.

    The build file was presumed to be located at [source_buildfile] but because
    of project source mapping the build file is actually located at a
    target location (the return value). For example, a dune rule can
    be used to copy+modify a "source" file to a different "target" directory, and
    a dune stanza could create an executable from that target file.
    If a user hovered over the original source file with Merlin/OCaml-LSP
    the search for Merlin configuration would ... without this function ...
    search around the build file corresponding to the original source
    file. However, the actual build file will correspond to the target file,
    so that search for Merlin configuration must start in the target directory.

    The environment variable ["DUNE_PROJECT_SOURCE_PREFIX_MAP"] has the
    project source mapping.

    If the project source mapping is not present or can't be parsed,
    [None, Fun.id] is returned.
    
    Otherwise [Some target_buildfile, inverse] is returned
    where the inverse is a function that satisfies
    [inverse target_buildfile = source_buildfile]. *)
val project_target_buildfile : Path.Build.t -> Path.Build.t option * (string -> string)
