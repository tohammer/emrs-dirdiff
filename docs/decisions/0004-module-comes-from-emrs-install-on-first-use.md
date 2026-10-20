# 0004 — The module comes from emrs-install on first use; the Doom recipe has no pre-build step

Date: 2026-10-20
Status: accepted

## Context

emrs-dirdiff built its module with its own `lisp/emrs-dirdiff-build.el`:
on first use after asking, or from the Doom recipe's `:pre-build` step at
`doom sync`. emrs now ships `emrs-install.el` (emrs spec
`2026-10-19-module-installer`, emrs ADRs 0006, 0008, 0009), which downloads
the release file of a released version or builds a `-snapshot` version
from the package's checkout, and installs it per user under
`user-emacs-directory`.

Doom users follow `master`, which always carries a `-snapshot` version, so
for them the installer always builds locally. A pre-build step could do
that at `doom sync` with `emrs-install-build-sync`, but how such a step
finds `emrs-install.el` is open and untried (emrs backlog).

## Decision

- emrs-dirdiff registers its module with `emrs-install-register` and loads
  it with `emrs-install-load`. `lisp/emrs-dirdiff-build.el`, the command
  `emrs-dirdiff-build-module` and the option
  `emrs-dirdiff-build-cargo-program` are removed without aliases; there are
  no other users yet.
- The Doom recipe lists the files only (`elisp/*.el` of emrs,
  `lisp/*.el` of emrs-dirdiff) and has no `:pre-build` step.

The user chose both on 2026-10-20.

## Consequences

- After each update of a Doom installation, the first emrs-dirdiff command
  asks to build the module and has to be run again when the build is done.
- The recipe uses only installer behaviour that emrs tests.
- A pre-build step can be added later, once emrs settles how it finds
  `emrs-install.el`; that would supersede the second point.
