Create a bad rule that doesn't allow the sandbox to be deleted.

Note that this rule also fails. We make sure that we see both the error from
the rule and the sandbox cleanup.

  $ cat >dune <<EOF
  > (rule
  >  (target foo)
  >  (action (system "\| touch foo && mkdir bar && touch bar/x && chmod -w bar &&
  >                  "\| echo failed action && exit 1
  >           )))
  > EOF

  $ cat >dune-project <<EOF
  > (lang dune 3.11)
  > EOF

  $ dune build ./foo --sandbox=copy 2>&1 | sed -E 's#.*.sandbox/[^/]+#.sandbox/$SANDBOX#g'
  File "dune", line 1, characters 0-161:
  1 | (rule
  2 |  (target foo)
  3 |  (action (system "\| touch foo && mkdir bar && touch bar/x && chmod -w bar &&
  4 |                  "\| echo failed action && exit 1
  5 |           )))
  failed action
  Error:
  .sandbox/$SANDBOX/default/bar): Directory not empty
  -> required by _build/default/foo

Manual cleaning step so the dune executing the test suite doesn't croak trying
to delete the readonly dir
  $ chmod -R +w _build && rm -rf _build