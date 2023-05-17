(lang dune 3.5)
;          ^^^
; When changing the version, don't forget to regenerate *.opam files
; by running [dune build].
(name fiber)

(generate_opam_files true)

(strict_package_deps false)

; Reserved for Dune itself. This is to help with the bootstrap
(using dune-bootstrap-info 0.1)

(license MIT)
(maintainers "Jane Street Group, LLC <opensource@janestreet.com>")
(authors "Jane Street Group, LLC <opensource@janestreet.com>")
(source (github ocaml/dune))
(documentation "https://dune.readthedocs.io/")

(implicit_transitive_deps false)

(package
 (name fiber)
 (synopsis "Structured concurrency library")
 (depends
  (ocaml (>= 4.08.0))
  (stdune (= :version))
  (dyn (= :version)))
 (description "This library offers no backwards compatibility guarantees. Use at your own risk."))
