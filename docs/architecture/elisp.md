# Architecture: the Elisp side

Part of [the architecture](../architecture.md). The module is in
[`module.md`](module.md).

## Commands and instance

`emrs-dirdiff` and `emrs-dirdiff-dired` validate the pair
(`emrs-dirdiff--check-dirs`: local, existing, distinct, not nested;
`user-error` otherwise) and call `emrs-dirdiff--open`, which reuses the
buffer comparing the same true names or makes `*dirdiff: A ↔ B*` in
`emrs-dirdiff-mode`, copies the defcustoms into buffer-local settings and
starts a comparison. Each buffer owns one instance, started on demand by
`emrs-dirdiff--ensure-instance` (a load error or a failed instance is kept
in `emrs-dirdiff--instance-error`, shown in the header, and the next `g`
starts a new instance) and stopped, with its stream and timers, from
`kill-buffer-hook` and `change-major-mode-hook` (`emrs-dirdiff--kill`).

Loading (`emrs-dirdiff--load-module`) is `emrs-install-load` of emrs's
`emrs-install.el`. The module is registered at load time with
`emrs-dirdiff-module-version`, the release URL and this file as `:source`
(ADR 0004). The installer finds the installed version under
`emrs-install-directory`, else `emrs-dirdiff-module` on `load-path`, else
downloads the release file (not for `-snapshot` versions) or offers a
cargo build in the checkout; it also offers a rebuild of a local build
older than its sources and warns when the module reports another version.

The other commands (keys in the spec; functions are `emrs-dirdiff-*`):
`open` (RET: a diff-mode buffer from `diff-no-select`, with `-w` when
whitespace is ignored; visit a one-sided entry; fold a directory or
section), `ediff`, `visit-a`/`visit-b`, `dired-entry`, `copy-path`,
movement (`next-difference` over lines whose status is a difference,
`next-group` over directories with differences below them or section
headers), filters, `toggle-view` and the settings toggles, which change
the buffer-local setting and start a full comparison. `swap` stops the
instance, exchanges `--a` and `--b`, renames the buffer and compares with
a new instance; folds and view stay, marks are cleared (a mark went with a
direction).

## Stream handling

`emrs-dirdiff--compare` cancels the buffer's own running stream with
`emrs-cancel` (after forgetting it, so its `cancelled` end is ignored),
clears the model (or, for a subtree, drops the entries at and below it) and
opens `emrs-call-stream` with `:compare`. Callbacks act only while their
call is still `emrs-dirdiff--stream`. `:on-batch` adds each item to the
model and schedules a redraw; `:on-end` records `done`, `stopped`
(`cancelled`, or `failed` with the message `cancelled`) or `failed`. Only
a comparison of everything sets the summary and the elapsed time; a
subtree rescan keeps those of the last full comparison, and the header
says "Comparing PATH…" while it runs.

`rescan` with a prefix argument is refused while a stream runs, since it
would cancel that comparison part way (ADR 0003); plain `g` cancels and
starts over.

## Model

Buffer-local hash tables keyed by relative path:

- `--items`: the difference items.
- `--done`: the finished directories with their `:same` counts.
- `--children`: each directory's known children, filled for every item and
  `done` path and their ancestors, so directories without items of their
  own exist as ancestors.
- `--counts`: per directory, the differences below it by status, updated
  for all ancestors on each item.
- `--same`: the cached `:same` replies, fetched once per comparison for
  each expanded finished directory while `s` is on.
- `--folds`: the user's fold state per path, kept across redraws and
  comparisons.

A directory's displayed status comes from these: its own item, else
changed when anything below differs, else comparing while running and not
`done`.

A subtree rescan rebuilds `--children` and `--counts` from the remaining
items, keeps the rescanned path among its parent's children only when it
is a directory present on both sides, and adjusts the ancestors' `done`
counts by the difference of the subtree's new and old `:same`
(`--rescan`). When it ends, `emrs-dirdiff--rescan-ended` removes a path
that came back with nothing from its parent's children, clears `--rescan`
and forgets the parent's cached `:same` reply. A rescan of a single file
does not adjust the ancestors' `done` counts; see the
[backlog](../backlog.md) ("Same" counts).

## Views and redraw

`emrs-dirdiff--schedule-redraw` sets one timer at most
`emrs-dirdiff--redraw-interval` (0.2 s) after the last redraw; a 1 s
ticker refreshes the elapsed time while running; the end of a stream
redraws in a timer slot of its own. `emrs-dirdiff--redraw` records point
and every window's point and start as (path, line, column) from the
`emrs-dirdiff-path` property every line carries, erases the buffer,
inserts the header and the body from the renderer of `emrs-dirdiff--view`
(`emrs-dirdiff--renderers`), which fills `--line-index` (path to line
start), and puts point back on the same path, else on its nearest visible
ancestor. When the path is missing (after `g` cleared the model), the
wanted position is kept and tried again on later redraws while point has
not moved. The timer-driven redraws skip a buffer no window shows and set
`--dirty`; `emrs-dirdiff--on-shown`, in `window-buffer-change-functions`,
redraws it when a window shows it again.

Header errors: an instance error, a failed comparison, or an `error` item
for the root replace the counts with the message and the key to restart.

The section view (`emrs-dirdiff--render-sections`) lists the sections
Changed, Only in A, Only in B, Kind differs, Errors and Same, each a flat
list sorted by path with the tree's right-hand columns; empty sections are
omitted. It reads `--items` directly, so it fills as items arrive. A
header line carries the path `""` and the property `emrs-dirdiff-section`;
`--line-index` maps section symbols to their header, and the position key
of a redraw is (PATH LINE COLUMN SECTION), so point on a header survives a
redraw. Same is folded unless opened; unfolding it fetches `:same` for
every finished directory. `v` switches the view and moves to the nearest
entry line when the new view does not show the path at point.

Filters: `--name-filter` (a substring of the relative path, smart-case:
the redraw binds `case-fold-search` from `--name-fold`) and
`--status-filter`. `emrs-dirdiff--match-p` tests one entry. The section
view applies it per row; the tree view gets `--keep` for the duration of a
redraw, the matching entries and their ancestors, and
`emrs-dirdiff--children-of` drops everything else. The counts stay totals.

## Marks and actions

Marks (`emrs-dirdiff--marks`) are kept by path, so they survive redraws
and view toggles. Both renderers show a `*` (face `emrs-dirdiff-mark`) in
place of a space, so no alignment changes. When a comparison ends `done`
with no rescan queued, `emrs-dirdiff--prune-marks` drops the marks of
paths the model no longer knows.

Actions (`>` `<` `D`) act only on what the comparison showed (ADR 0002).
`emrs-dirdiff--targets` returns the marked entries, else the entry at
point, leaving out entries below another target and refusing unknown
paths and entries still `comparing`. The action is planned from the model
as a list of operations on single entries: `emrs-dirdiff--plan-copy` turns
a one-sided entry into `new`, a changed file into `overwrite`, a changed
link into `relink`, a kind difference into `replace` (target deleted, then
source copied), and a directory present on both sides into the operations
for the differences listed below it, walking `--children`. Identical
entries, target-only entries, `error` entries and special files are left
out with a reason. `emrs-dirdiff--plan-delete` makes one `delete` per
side, asking which side when an entry is on both. One question covers the
action and names every kind of operation separately; `yes-or-no-p` when
anything is overwritten, replaced or deleted.

Paths are joined to the roots by concatenation (`emrs-dirdiff--file`),
never `expand-file-name`, which turns a top-level `~` into the home
directory. Before each operation `emrs-dirdiff--op-problem` checks the
entry on disk with `file-attributes` (which does not follow links) against
the item, and `emrs-dirdiff--parents-real-p` checks that the root and
every directory down to the entry are real directories. An entry that
fails is skipped and reported "changed since the comparison". Every
deletion passes the TRASH argument, so `delete-by-moving-to-trash`
applies. `emrs-dirdiff--perform` runs the operations in order; on the
first error, or a quit, it stops and reports "N of M done", queues the
rescan of every target an operation ran on and clears the mark of a target
only when all its operations were done.

## Rescan queue

Rescans after an action go through `emrs-dirdiff--rescan-queue`, because
the instance runs one `:compare` at a time (ADR 0003).
`emrs-dirdiff--rescan-paths` queues the paths (a path covered by a queued
ancestor is dropped; a queued descendant is replaced) and forgets the
cached identical entries of their parents. A queued path starts when no
stream is running; `emrs-dirdiff--on-end` starts the next one when a
stream ends `done` or `failed`. A stopped stream, and a full
`emrs-dirdiff--compare ""`, clear the queue. Actions are not refused while
the whole tree is compared; their rescans wait for it.

## Menu

`emrs-dirdiff.el` autoloads `emrs-dirdiff-menu` (`?`). Every key of the
spec's Keys table is a suffix that runs the command the mode binds to the
same key. Toggles use `:description` functions that read the buffer-local
settings of the comparison buffer the menu was opened from
(`transient--original-buffer`); the Act group heading says whether the
marks or the entry at point will be used. The settings, marks and
movement commands carry `:transient t`, so the menu stays open and shows
the new state.
