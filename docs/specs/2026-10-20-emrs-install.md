# The module through emrs-install

Status: approved
Date: 2026-10-20

## Purpose

Users without Rust should be able to use emrs-dirdiff. emrs now ships
`elisp/emrs-install.el` (emrs spec `2026-10-19-module-installer`, emrs
ADRs 0006, 0008, 0009): it downloads the release file of a released
version after asking, checked against `SHA256SUMS`, and builds a
`-snapshot` version from the package's checkout. This spec moves
emrs-dirdiff from its own build file to that installer.

Success:

- A user of a release gets the module with one confirmation, without Rust.
- A user of a checkout of `master` (a `-snapshot` version) gets a local
  build, as today.
- `lisp/emrs-dirdiff-build.el` and the build and staleness code in
  `lisp/emrs-dirdiff.el` are gone.

## Scope

In:

- The emrs pin moves to a commit that contains `emrs-install.el`.
- The version convention of emrs ADR 0008: `0.2.0-snapshot` between
  releases, the same string in three places.
- Registration and loading through `emrs-install.el`; removal of the build
  file, its command and its option ([ADR 0004](../decisions/0004-module-comes-from-emrs-install-on-first-use.md)).
- The test runner and the tests.
- README (installation, Doom recipe, options, release steps) and
  architecture docs.

Out:

- A `:pre-build` step for package managers (ADR 0004).
- Running the ERT suite against the released module in the release
  workflow (backlog item "Prebuilt module binaries"; it stays open).
- Windows.

## Design

### emrs pin

`Cargo.toml` pins emrs at `13ba6c9` ("Installer for prebuilt modules
(emrs-install.el) (#11)") or a later `master` commit, following the bump
policy the comment in `Cargo.toml` points to. Between the current pin
`f05b9fa` and `13ba6c9`, emrs changed neither `src/` nor `elisp/emrs.el`,
so the protocol is the same; the full suite still runs after the bump.

### Version

The module version is one string (emrs ADR 0008). It must be identical in:

1. `version` in `Cargo.toml` (the module reports it as `:version`),
2. the `:version` of the registration in `lisp/emrs-dirdiff.el`,
3. the `;; Version:` header of `lisp/emrs-dirdiff.el`.

Between releases it is `X.Y.Z-snapshot`; now `0.2.0-snapshot` (from
`0.2.0-dev` in `Cargo.toml`). The registration names the string once, in a
`defconst emrs-dirdiff-module-version`; an ERT test checks that all three
agree.

Release steps (README, section Development): set the three to `X.Y.Z`,
merge, tag `vX.Y.Z` (the release workflow publishes the files), then set
them to the next `-snapshot` version.

### Registration and loading

At top level of `lisp/emrs-dirdiff.el`, after `(require 'emrs-install)`:

```elisp
(emrs-install-register 'emrs-dirdiff
  :version emrs-dirdiff-module-version
  :url "https://github.com/tohammer/emrs-dirdiff/releases/download"
  :source (or load-file-name buffer-file-name))
```

`emrs-dirdiff--load-module` becomes `(emrs-install-load 'emrs-dirdiff)`.
Everything else about getting the module comes from the installer: lookup
(the installed version, else `emrs-dirdiff-module` on `load-path`),
download consent, the stale-build offer, the build prompt, the error
messages and the version warning.

Removed: `lisp/emrs-dirdiff-build.el` with `emrs-dirdiff-build-module`,
`emrs-dirdiff-build-module-sync` and `emrs-dirdiff-build-cargo-program`;
in `lisp/emrs-dirdiff.el` the functions `emrs-dirdiff--module-file`,
`--source-repo`, `--mtime`, `--newest-source`, `--module-stale-p`,
`--building-p`, `--build-now`, `--offer-rebuild`,
`--not-installed-error` and `--offer-build`, and the
`(require 'emrs-dirdiff-build)`. No aliases (ADR 0004). The Commentary
says where the module comes from.

`.gitignore` keeps `lisp/*-module.*`, so a manually placed module in
`lisp/` stays untracked.

### Package recipe

The Doom recipe in the README becomes:

```elisp
(package! emrs
  :recipe (:host github :repo "tohammer/emrs" :files ("elisp/*.el")))
(package! emrs-dirdiff
  :recipe (:host github :repo "tohammer/emrs-dirdiff" :files ("lisp/*.el")))
```

`:source` resolves through the true name of `emrs-dirdiff.el`, so straight's
symlinked build directory leads to its repository checkout, which has
`Cargo.toml`.

### Test runner

`tests/run-ert.sh` keeps building the debug module and copying it to
`target/elisp/emrs-dirdiff-module<suffix>`, which is on `load-path`, so the
installer's `load-path` lookup finds it. Before loading the tests it sets
`emrs-install-directory` to a new temporary directory and
`emrs-install-download` to `never`, so the suite neither reads nor writes
the user's `~/.emacs.d/emrs/modules/` and never uses the network. The
comment about preferring a module next to `emrs-dirdiff.el` goes.
`emrs-install.el` is found next to `emrs.el` in the emrs checkout Cargo
resolved, as today.

### README

- Requirements: Rust only for a version without a release (a checkout of
  `master`) or a platform without a release file.
- How the module is obtained: a short description of the installer's
  steps for this package, with a link to emrs's README section "Installing
  modules for users" for the details and options (`emrs-install-download`,
  `emrs-install-directory`, `emrs-install-cargo-program`,
  `M-x emrs-install-module`, `M-x emrs-install-build`,
  `M-x emrs-install-clean`).
- The Doom recipe above, and that the first command after an update asks
  to build.
- Manual installation: `lisp/*.el` and emrs's `elisp/*.el` on `load-path`;
  the module comes from the installer, or is placed by hand as
  `emrs-dirdiff-module<suffix>` on `load-path` (the current "Prebuilt
  module" steps, shortened).
- Options table: the row `emrs-dirdiff-build-cargo-program` goes.
- Development: the release steps above.

## Error handling

All failures to get or load the module are the installer's (emrs spec,
section Error handling): `user-error`s naming what was tried, a warning
when the module's `:version` differs from the registered one. emrs-dirdiff
adds no handling of its own; `emrs-dirdiff--start` lets the `user-error`
through, as today.

## Testing

Automated (`cargo test`, `tests/run-ert.sh`, CI on Linux and macOS with
Emacs 30.1 and 31.1):

- The whole existing suite, with the module found through the installer.
- New: the version in `Cargo.toml`, `emrs-dirdiff-module-version` and the
  `;; Version:` header are equal, and the loaded module reports it as
  `:version`.
- New: `emrs-dirdiff` is registered with the installer, with the release
  URL above and a `:source` whose checkout is this repository.
- Removed: `emrs-dirdiff-test-module-staleness` and
  `emrs-dirdiff-test-module-missing-messages`, which tested the removed
  code; emrs's suite covers the same behaviour of the installer.
- Byte compilation without warnings, `checkdoc` clean.

Manual, in `emacs -Q` with a temporary `user-emacs-directory`, from a
checkout of the branch:

- Without an installed module: the first `M-x emrs-dirdiff` asks to build,
  the build runs in `*emrs-install emrs-dirdiff*`, the module lands in
  `<user-emacs-directory>/emrs/modules/emrs-dirdiff/0.2.0-snapshot/`, and
  the command works when run again.
- After touching `src/lib.rs`: a new Emacs offers a rebuild.

Not tested: the download path for emrs-dirdiff itself, because no release
carries the installer yet (emrs tested its download against the v0.1.0
files); it is checked when v0.2.0 is released. The Doom recipe (as
today).

## Tasks

- [ ] 1. Bump the emrs pin to `13ba6c9` (or later `master`) and the
  version to `0.2.0-snapshot` in `Cargo.toml` (and `Cargo.lock`) and the
  `;; Version:` header. *Done when* `cargo test` and `tests/run-ert.sh`
  pass, and `emrs-install.el` is in the emrs checkout Cargo resolved.
- [ ] 2. Register the module, load it with `emrs-install-load`, remove
  `lisp/emrs-dirdiff-build.el` and the functions listed under Design,
  update `tests/run-ert.sh` as described, replace the two build tests with
  the two new tests. *Done when* `tests/run-ert.sh` passes, byte
  compilation of `lisp/*.el` reports no warnings, `checkdoc` reports
  nothing for `lisp/emrs-dirdiff.el`, and `grep -r emrs-dirdiff-build`
  finds nothing outside `docs/specs/` and `docs/decisions/`.
- [ ] 3. Manual checks as described under Testing. *Done when* both pass
  in an Emacs whose `user-emacs-directory` is temporary.
- [ ] 4. Documentation: README as described, `docs/architecture.md`
  (components table, How it fits together), `docs/architecture/elisp.md`
  (Loading, Build), `docs/backlog.md` (the installer bullet of "Prebuilt
  module binaries" removed), `docs/next-steps.md` (the `-dev` watch-out
  replaced by the `-snapshot` rule). *Done when* the doc-checker reports
  nothing stale.
