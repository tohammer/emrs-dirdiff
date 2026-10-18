# Backlog

Open points only. Delete an item when it is done; git keeps the history.
Deferred review findings name their origin, the reason and when to
revisit.

These were left out of version 1 by the spec
([`specs/2026-10-14-emrs-dirdiff-v1.md`](specs/2026-10-14-emrs-dirdiff-v1.md),
section Scope). Revisit after version 1 ships.

## Remote directories (TRAMP)

Compare directories on remote hosts. Version 1 signals a `user-error`
that points to `ztree-diff`.

## Copy and delete in the module, with progress

Version 1 copies and deletes in Elisp, which blocks Emacs for large
directories.

## Three-way comparison and merging

Compare three trees and merge differences.

## Plain directory tree browser

The `ztree-dir` half of ztree.

## Save and reopen a comparison

Keep a comparison's results across sessions.

## Compare archives as directories

Treat zip and tar archives as directory trees.

## Prebuilt module binaries

Partly done. `.github/workflows/release.yml` calls emrs's reusable release
workflow (emrs spec `2026-10-17-release-pipeline`, emrs ADRs 0004–0007): a
tag `v<version>` builds, tests and publishes the module for linux-x86_64,
linux-aarch64 and macos-aarch64 with `SHA256SUMS`. Release v0.1.0 was made
this way on 2026-10-18 from commit 0e523f4, which PR #2 merged into
`master`. Open:

- Users still build with cargo: use emrs's installer `emrs-install.el` once
  it exists (emrs backlog "Installer for prebuilt modules") in place of
  `lisp/emrs-dirdiff-build.el`, and describe it in the README. Until then
  the README could point to the release files for a manual install.
- The release tests only load the module (smoke test). Run the ERT suite
  against the downloaded file: a `test-command` that uses `EMRS_MODULE_DIR`
  and `EMRS_EL_DIR` needs `tests/run-ert.sh` to take a prebuilt module
  instead of building one.
- Windows is left out of `platforms` because it is untested (README,
  Status).

## Large results: show more

If more than 100,000 differences prove slow to show, list the first 10,000
lines of a section with a "show more" line. Origin: spec section "Error
handling". Revisit when measured slow.

## Deferred findings of the version 1 review (2026-10-14)

Origin: the review of the version 1 branch against
[`specs/2026-10-14-emrs-dirdiff-v1.md`](specs/2026-10-14-emrs-dirdiff-v1.md).
Deferred because each is rare in practice or needs a design decision; the
clear defects of that review were fixed.

### File names that are not valid UTF-8

`session.rs` converts names with `to_string_lossy`. Such a name comes back
from Lisp with U+FFFD, so a rescan or `:same` lookup misses it, and two
different names can map to one path. Needs a lossless encoding (bytes or
an escape) in the protocol. Revisit on a report, or before claiming
support for arbitrary file names.

### Ignore rules beyond the root

`.gitignore` files above the roots and `.git/info/exclude` are not
applied, and the global excludes are matched relative to Emacs's current
directory, so their anchored patterns can misfire (spec section
"Comparing" states what is applied). Revisit if comparisons of
subdirectories of a repository show entries git ignores.

### Section view fetches identical entries per directory

Unfolding the Same section sends one `:same` request per finished
directory at once; on a tree with many thousands of directories that is
many thousands of calls. A single request returning all identical entries
(or a paged one) would do. Revisit when the section view is used on large
trees.

### Rescanning an entry in a huge parent directory

A rescan of one entry lists its whole parent directory, and that listing
cannot be interrupted. Revisit if rescans after actions feel slow in
directories with very many entries.

### "Same" counts after a single-path rescan

A rescan of one entry does not update the identical-file counts of its
ancestors; `g` recomputes them. Revisit together with any change to how
rescans report counts.
