# Architecture

This document describes the system as it is now. Details are split by
side: [`architecture/module.md`](architecture/module.md) (Rust) and
[`architecture/elisp.md`](architecture/elisp.md) (Elisp).

## Overview

The design for version 1 is in
[`specs/2026-10-14-emrs-dirdiff-v1.md`](specs/2026-10-14-emrs-dirdiff-v1.md):
a Rust module (emrs service `"dirdiff"`) walks and compares two trees on
a thread pool and streams the differences to an Elisp package, which
shows them in one buffer as a tree or as sections (ADR 0001). Copy and
delete act only on what the comparison showed (ADR 0002) and rescans run
one at a time (ADR 0003). Timing against `diff -rq`:
[`benchmark.md`](benchmark.md).

## Components

| Component | Responsibility | Depends on |
|---|---|---|
| `src/lib.rs` | Declares the module `emrs-dirdiff` with its one service | `emrs` |
| `src/service.rs` | `DirdiffService` (`"dirdiff"`): start arguments, the instance's pool, the requests `:compare`, `:same` and `:cancel` | `emrs`, `serde`, `session` |
| `src/session.rs` | One comparison: tasks on the pool, per-directory completion, the stream, the store of identical entries, cancellation | `walk`, `compare`, `rayon`, `emrs` |
| `src/walk.rs` | Lists one directory level of both sides, applies the ignore files, pairs entries by name | `ignore` |
| `src/compare.rs` | Whether two files are the same; line counts | `similar` |
| `lisp/emrs-dirdiff.el` | Module loading, commands, the result model, the buffer with its views, marks, actions, the rescan queue | `emrs.el`, `emrs-install.el` |
| `lisp/emrs-dirdiff-menu.el` | `emrs-dirdiff-menu`, a transient prefix bound to `?`; autoloaded, so transient loads on first use | `transient`, `emrs-dirdiff.el` |
| `tests/run-ert.sh` | Builds the debug module (or takes the file in `EMRS_MODULE_FILE`, as the release workflow does), copies it and the Lisp files to `target/elisp` and byte-compiles them there, finds emrs's `elisp/` directory (`emrs.el`, `emrs-install.el`) through `cargo metadata` (or `EMRS_EL_DIR`), runs ERT with `--module-assertions`, a temporary `emrs-install-directory` and downloads off | `tests/emrs-dirdiff-tests.el` |
| `.github/workflows/ci.yml` | Rust checks, MSRV, and the ERT suite on Emacs 30.1 and 31.1 on Linux and macOS (responsiveness limit 150 ms there) | |

## How it fits together

Elisp calls `emrs-dirdiff--start`, which loads the module through
emrs's installer (`emrs-install-load`: the installed version, else
`emrs-dirdiff-module` on `load-path`, else a download or a cargo build;
ADR 0004) and starts the service with
`(emrs-start 'emrs-dirdiff "dirdiff" (list :a A :b B))`. The start runs on
the module's side: it fails, with a message naming the path, unless both
are existing directories, and the failure reaches Elisp as the instance
state `failed` and through `:on-exit`. `emrs-dirdiff--stop` stops the
instance. The pinned emrs commit (`Cargo.toml`) and the `emrs.el` on
`load-path` must match. The module version is one string in `Cargo.toml`,
`emrs-dirdiff-module-version` and the `;; Version:` header (emrs ADR 0008).

A comparison is an `emrs-call-stream` with `:compare`. The module walks
both trees on the instance's pool and streams one item per difference,
`done` items for finished directories and a final summary; identical
entries are not sent but kept by the module for `:same`. Elisp adds the
items to a buffer-local model and redraws on a throttle, so Emacs stays
responsive while items arrive. Actions and rescans are planned in Elisp
from the model and the instance runs one `:compare` at a time. Item shapes
as Lisp sees them are in the spec, section "The service".

## Lessons

- File name functions such as `file-name-directory` consult
  `file-name-handler-alist` on every call; on relative paths in a hot loop
  they dominated the redraw, so relative paths are split by hand.
- The redraw of about 2,000 visible lines takes about 20 ms byte-compiled
  and more than twice that interpreted, so the ERT runner tests compiled
  code. A garbage collection in the test process takes 15 to 25 ms on its
  own; it is what brings the responsiveness test near its 50 ms limit. The
  test collects garbage before it measures, shows the buffer (hidden
  buffers are not redrawn) and compares three times; its limit is
  `EMRS_DIRDIFF_TEST_MAX_DELAY` milliseconds when set, 150 in CI, where
  shared runners are two to three times slower.
