# emrs-dirdiff version 1: directory comparison

Status: approved
Date: 2026-10-14

## Purpose

Compare two directory trees in Emacs and act on the differences, in the
manner of `ztree-diff`, with a Rust module on
[emrs](https://github.com/tohammer/emrs) doing the walk and the comparison
off the Emacs thread.

ztree-diff compares each pair of files with one synchronous `diff -q`
process on the Emacs thread (`ztree-diff-model-files-equal`), so Emacs is
blocked until the whole comparison is done. Beyond speed, its UX has gaps
this package closes:

| ztree-diff | emrs-dirdiff |
|---|---|
| Blocks until the comparison is done; no progress, no cancel | The buffer opens at once, fills while the module works, shows progress, and can be stopped |
| Two panes; needs a wide window, names get cut | One merged tree with a status column; a toggle groups the differences into sections (ADR 0001) |
| Keys to remember (`h`, `H`, `C`, `D`, `x`, `F5`), no menu | `?` opens a transient menu with every command and the current settings |
| Hides files by a list of regexps | Respects `.gitignore` and similar files, toggled in the buffer |
| Comparison options are global variables | Content or size-and-time comparison and ignoring whitespace are toggles in the buffer |
| No summary, no jump to the next difference | Counts in the header; `n`/`p` move between differences |
| Acts on one entry at a time | Mark several entries, then copy or delete them together |

Users: anyone comparing two copies of a tree in Emacs (two release
checkouts, a backup against its source, a deployed directory against the
repository).

Success:

- The buffer appears within 100 ms of the command, whatever the size of
  the trees.
- During the comparison of two trees of 100,000 files each, typing in
  another buffer shows no noticeable lag.
- Stopping, or killing the buffer, ends the work in the module within
  100 ms.
- Comparing two identical trees of 100,000 files by content completes on a
  warm cache in about the time `diff -rq` takes for the same trees, or
  less. Measured: 0.43 s against 0.82 s for `diff -rq`
  ([`../benchmark.md`](../benchmark.md)).

## Scope

In:

- A new repository `emrs-dirdiff` with a Rust module (crate `emrs-dirdiff`,
  module name `emrs-dirdiff`, one emrs service `"dirdiff"`) and the Elisp
  package `emrs-dirdiff` in `lisp/`.
- The command `emrs-dirdiff` (ask for two directories) and
  `emrs-dirdiff-dired` (compare the two directories marked in dired, or
  the directory at point with the one in the other dired window).
- Comparison by content (default) or by size and modification time.
  Ignoring whitespace differences in text files.
- The tree view and the section view of the same results (ADR 0001),
  with folding, filters and a name filter.
- Opening a changed file pair in a `diff-mode` buffer or in ediff;
  visiting either side; dired at either side.
- Marks; copy A to B and B to A; delete; rescan of an entry after an
  action.
- A transient menu on `?`.
- Building and installing the module locally with cargo, as quarry does
  (quarry ADR 0006 and 0007).

Out (backlog candidates):

- Remote directories (TRAMP). The command signals a `user-error` that
  names `ztree-diff` for them.
- Three-way comparison and merging.
- A plain directory tree browser (the `ztree-dir` half of ztree).
- Copying and deleting in the module, with progress (version 1 does it in
  Elisp; see "Actions").
- Saving a comparison and reopening it.
- Comparing archives (zip, tar) as directories.
- Prebuilt module binaries.

## Design

The mockup of the layouts is
[`2026-10-14-emrs-dirdiff-v1-mockup.html`](2026-10-14-emrs-dirdiff-v1-mockup.html):
variant A is the tree view, variant C the section view, and both shared
parts (progress, menu) apply. Variant B is not built.

### Components

| Component | Responsibility |
|---|---|
| `src/walk.rs` | Lists one directory of each side, applies the ignore rules, pairs the entries by name |
| `src/compare.rs` | Decides whether two files are the same: size, then bytes, or size and time; whitespace-insensitive comparison of text files; line counts of changed text files |
| `src/session.rs` | One comparison: the parallel walk over both trees, the result store, cancellation |
| `src/service.rs` | `DirdiffService`, emrs service `"dirdiff"`: requests, streams |
| `lisp/emrs-dirdiff.el` | Commands, module loading and build offer, the result model, `emrs-dirdiff-mode`, both views, actions |
| `lisp/emrs-dirdiff-menu.el` | The transient menu |
| `lisp/emrs-dirdiff-build.el` | Build and install of the module (`cargo build --release`), loadable on its own |

### The service

One instance per comparison buffer, started with the two root
directories as arguments and stopped when the buffer is killed. The
instance keeps the result of its last comparison, so Elisp receives only
the differences and asks for the identical entries of a directory when it
shows them.

Start arguments: `(:a "/abs/dir/a" :b "/abs/dir/b")`. Both must be
existing directories; otherwise the start fails with a message naming the
path.

Requests:

| Request | Answer |
|---|---|
| `(:compare :path P :by :content\|:size-time :ignore-files BOOL :whitespace BOOL :hidden BOOL)` | A stream of entries (below) for the subtree at relative path `P` (`""` is the whole comparison). A new `:compare` cancels a running one of the same instance. The results of `P` replace those stored for `P` |
| `(:same :dir P)` | The identical entries other than directories directly in directory `P`, as a list of entries with status `"same"` and both `:a` and `:b`, sorted by name; `nil` (the empty list) for an unknown directory. Directories present on both sides are known from their `done` items |
| `(:cancel)` | Answers `nil`. Stops a running comparison; its stream ends with status `failed` and the error `(:kind service :message "cancelled" :data nil)` (emrs gives the module no way to end a stream `cancelled`; a stream cancelled from Elisp with `emrs-cancel` ends `cancelled` as usual). A stream stopped by a newer `:compare` ends the same way |

`:by` takes the keywords `:content` and `:size-time`; the three options
take `t` or `nil` and default to `t`, `nil` and `t` when left out.

Stream items are plists. Keys whose value would be `nil` are left out, so
`plist-get` returns `nil` for them:

```elisp
(:path "src/main.rs"          ; relative to both roots, "/" separated
 :kind "file"                 ; a string: "file", "dir", "link", "other"
 :status "changed"            ; a string: "changed", "only-a", "only-b", "kind", "error", "done"
 :a (:size 4100 :mtime 1760400000.0)   ; left out when absent
 :b (:size 4300 :mtime 1760403600.0)
 :lines (12 4)                ; a list (ADDED REMOVED), for changed text files; left out otherwise
 :files 2                     ; for a directory present on one side: files below it
 :same 37                     ; for done: identical files below this directory
 :message "Permission denied") ; for error
```

`:kind` and `:status` are strings because emrs encodes a Rust enum value
as a one-element list such as `(:changed)`. For status `"kind"`, `:kind`
is the kind on side A. A `done` item has only `:path`, `:kind`,
`:status` and `:same`.

- `changed`: present on both sides with the same kind, contents differ.
- `only-a`, `only-b`: present on one side. A directory present on one side
  is one item with `:files`; the module does not send its contents.
- `kind`: a file on one side, a directory or link on the other.
- `error`: an entry that could not be read on either side.
- `done`: a directory present on both sides whose whole subtree is
  finished, with the number of identical files below it. Elisp uses it to
  replace the "comparing…" marker of that directory. A directory that
  cannot be listed as a whole gets an `error` item instead of `done`. A
  directory where only some entries could not be read gets an `error` item
  ("some entries could not be read: …") and, once finished, a `done`;
  Elisp shows it as a normal directory with `!` and the message.
- The last item is `(:summary t :files N :seconds S)`: N is the number
  of entries examined, S a float.

Items arrive in the order the parallel walk finishes them, not sorted.
Identical files are never sent as items.

### Comparing

- Walk: one directory level of each side at a time, so the two sides are
  paired per directory, with the `ignore` crate's gitignore matcher. With
  `:ignore-files t` (default), the `.gitignore` and `.ignore` files at and
  below each root and the global git excludes apply, also outside a git
  repository; `.gitignore` files above the root and `.git/info/exclude`
  do not. Each side uses its own rules; an entry ignored on both
  sides is skipped, one ignored on one side only is compared as present
  on both. `.git` directories are always skipped. Names starting with `.`
  are compared unless `:hidden` is nil; Elisp sends t by default.
- Directories are processed on a thread pool. Each file pair is compared
  on the pool as well.
- `content`: different sizes mean changed; equal sizes are compared
  byte by byte in 64 KiB blocks, stopping at the first difference.
- `size-time`: changed when size or modification time (to the second)
  differ. Nothing is read.
- `:whitespace t`: a pair that differs by bytes is compared again as text
  with all whitespace removed (Unicode whitespace for files that are valid
  UTF-8, ASCII whitespace otherwise), if both files are text (no NUL byte
  in the first 8 KiB) and at most 4 MiB. Equal then means identical.
- Line counts: for each pair changed by content (not with `size-time`)
  where both files are text and at most 4 MiB, a line diff (the `similar`
  crate) gives the added and removed lines. The diff gets a time budget
  of 0.5 s; a pair that exceeds it gets no line counts.
- Each instance has its own thread pool, so one comparison never delays
  another buffer's: one thread per CPU (4 when the count is unknown).
- Paths in requests are relative to the roots. A request with `..`, an
  absolute path or another component that leaves the roots is refused.
  A rescan never reads through a parent that is not a real directory.
- Symbolic links are not followed; two links are the same when their
  targets are the same string. Other special files are the same when their
  kinds match.

### Commands

| Command | Behaviour |
|---|---|
| `emrs-dirdiff` | Ask for directory A, then B (default: the directory of the other window's buffer). Open or reuse the buffer `*dirdiff: <name A> ↔ <name B>*` and start the comparison |
| `emrs-dirdiff-dired` | Compare the two directories marked in the current dired buffer; without two marks, the dired directory with the one shown in the other window |

### The buffer

`emrs-dirdiff-mode`, derived from `special-mode`. The header shows both
roots, the counts per status (`12 changed · 3 only in A · 5 only in B · 847
same (hidden)`) and, while running, the differences found so far, the
elapsed time and a stop hint (the module sends no total and no running
count of files, so there is no percentage). The mode line shows the comparison method, whether ignore files
apply, and the time taken.

The result model is a hash table from relative path to entry, filled from
the stream batches. A directory's status is computed from its descendants:
changed if any descendant differs, `comparing…` until its `done` item
arrives. The buffer is redrawn at most every 0.2 s while items arrive, and
point stays on the same path.

Tree view (default, variant A): one line per entry, a status letter in the
first column (`M` changed, `A` only in A, `B` only in B, `T` kind differs,
`!` error, `·` comparing), the name indented by depth, and on the right the
sizes (`4.1k → 4.3k`) and line counts (`+12 −4`). Directories are folded
with `TAB`; on open, directories with differences are expanded to the
first three levels. Identical entries are hidden; `s` shows them, fetched
with `:same` for each expanded directory.

Section view (variant C), toggled with `v`: the sections Changed, Only in
A, Only in B, Kind differs, Errors and Same (folded), each a flat list of
relative paths. A directory present on one side appears as one line. The
view setting is kept per buffer; `emrs-dirdiff-default-view` sets the
initial one.

Faces: `emrs-dirdiff-changed`, `-only-a`, `-only-b`, `-error`, `-dim`
and `-mark` (the `*` of a marked entry), inheriting from `diff-changed`,
`diff-removed`, `diff-added`, `error`, `shadow` and, for the mark, `bold`
and `warning`, so themes that style diff-mode style this too.

### Keys

| Key | Command |
|---|---|
| `RET` | On a changed file: a `diff-mode` buffer of the pair (`diff-no-select`). On a one-sided file or directory: visit it. On a directory present on both sides or a section header: fold or unfold |
| `e` | ediff of the pair |
| `o`, `O` | Visit the A side, the B side |
| `d` | dired at the entry's directory on the side that exists (A if both) |
| `n`, `p` | Next, previous difference (skipping identical lines) |
| `N`, `P` | Next, previous directory with differences (section header in the section view) |
| `TAB` (also `<tab>`), `^` | Toggle the fold of the directory or section at point; go to the parent |
| `s` | Toggle showing identical entries (in the section view: fold or unfold the Same section) |
| `i` | Toggle whether `.gitignore` and similar files apply (rescans) |
| `/` | Filter by name (substring, smart-case: case-insensitive unless it has an uppercase letter; empty clears) |
| `f` | Cycle the status filter: all, changed, only A, only B |
| `m`, `u`, `U` | Mark, unmark, unmark all |
| `>`, `<` | Copy A → B, copy B → A (marked entries or the one at point) |
| `D` | Delete (marked entries or the one at point; asks which side when both exist) |
| `w` | Copy the relative path; with a prefix, the absolute path on A |
| `c`, `t`, `W` | Compare by content, by size and time; toggle ignoring whitespace (each rescans) |
| `v` | Toggle tree and section view |
| `x` | Swap A and B |
| `g` | Compare again (cancels a running comparison and starts over); with a prefix argument, only the directory at point, refused while a comparison or rescan runs and when point is not on a directory present on both sides |
| `C-c C-k` | Stop the comparison |
| `?` | The transient menu |
| `q` | Quit the window; the buffer and its instance stay until killed |

The mockup differs in two keys: it shows `C-g to stop`, where the key is
`C-c C-k` because `C-g` must keep its usual meaning, and it lists both `i`
and `I` for ignored files, where `i` alone toggles the ignore files.

### Actions

Copying and deleting run in Elisp with Emacs's file functions
(`copy-file`, `copy-directory`, `delete-file`, `delete-directory`), so
`delete-by-moving-to-trash` applies and nothing needs a second
implementation. A copy of a large directory blocks Emacs while it runs;
moving copies into the module is out of scope for version 1.

An action works only on what the comparison showed (ADR 0002):

- The paths acted on are the marked entries, or the entry at point, that
  the model knows with a difference status. Identical entries are left
  out of actions (reported as "identical"). Entries still being compared, and marks on paths the model does not
  know, are refused with a message.
- Copying an entry present on both sides that is a directory copies the
  differences listed below it, entry by entry (changed files, entries
  only on the source side, kind clashes), never the directory as a whole.
  Ignored, hidden and identical files are not touched.
- A one-sided entry is copied whole to the other side
  (`copy-directory` into a path that does not exist yet). Symbolic links
  are copied as links, never followed.
- A kind clash at the target is replaced: the target is deleted (to the
  trash when `delete-by-moving-to-trash` is set) and the source copied.
- Before each operation, the entry on disk is checked against the
  comparison: same kind on each side involved, and for files the same
  size and modification time. Every component of the target's parent
  directory must be a real directory inside the root, not a symbolic
  link. An entry that fails a check is skipped and reported as changed
  since the comparison.
- Relative paths are joined to the root without `~` expansion.
- The confirmation lists the operations (up to ten, then a count), names
  the direction or side, and states separately how many existing files
  will be overwritten and how many entries replaced (deleted first).
  One question for the whole action.
- An action stops at the first error, reports how many operations were
  done, and rescans every affected path. `C-g` during an action reports
  the same. A mark is cleared only when every operation on its path
  succeeded. Swapping A and B clears all marks.

After an action, each affected path is rescanned with `:compare :path`.
The rescans are queued and run one at a time, because an instance runs one
`:compare` at a time and a new one cancels the running one (ADR 0003).

### Building and loading

As in quarry (`lisp/quarry-build.el`): the package runs
`cargo build --release` in its repository and copies the library to
`lisp/emrs-dirdiff-module` plus `module-file-suffix`, and offers to do so
when the file is missing or older than the sources. This needs no
`cargo-emacs` installation on the user's machine.
`emrs` is a Cargo dependency pinned to a commit and an Elisp dependency
that follows the emrs default branch.

## Error handling

- A or B is not a directory, or is remote: `user-error` before anything
  starts. A and B the same directory, or one inside the other: `user-error`.
- An unreadable directory or file: an `error` item with the OS message;
  the comparison continues. Shown with `!` and the message on the line.
- A file that changes or disappears during the comparison: compared as
  found; a vanished file is an `error` item.
- The module fails to load or the instance fails: the header shows the
  error and `g` restarts the instance.
- A running comparison when its buffer is killed: the instance is stopped
  (`kill-buffer-hook`), which cancels the walk.
- An action fails part way (permission, disk full): the error is shown,
  the paths done so far stay done, and all affected paths are rescanned.
- Very large differences (more than 100,000 differing entries): the
  model keeps them all; the redraw throttle keeps Emacs responsive. If
  this proves too slow, the view will show the first 10,000 lines of a
  section with a "show more" line. Not built; see "Large results: show
  more" in the [backlog](../backlog.md).

## Testing

Rust (`cargo test`), on trees built in temporary directories:

- Pairing and statuses: identical, changed, only-a, only-b, kind, error
  (unreadable directory), symlinks.
- Ignore rules: `.gitignore` on one side only, hidden files, `.git`.
- `content` against `size-time`; same size different bytes; whitespace
  option on text and on binary files; line counts.
- Cancellation: a stream on a large generated tree ends within 100 ms of
  a cancel.
- The service with emrs's test host: `:compare`, `:same`, a second
  `:compare` cancelling the first, subtree rescan replacing stored results.

Elisp (ERT, batch, with the built module):

- A comparison of a fixture tree fills the model with the expected
  statuses; the tree and the section view render the expected lines.
- Folding, filters, `n`/`p`, marks.
- Copy and delete on temporary trees, followed by the rescan result.
- Killing the buffer stops the instance.
- The responsiveness check: during a comparison of a generated tree, a
  timer firing every 10 ms is never delayed by more than 50 ms locally and
  150 ms on CI (`EMRS_DIRDIFF_TEST_MAX_DELAY`; shared runners are two to
  three times slower).

By hand (not covered by the tests): a GUI frame and a terminal frame, a
light and a dark theme, ediff from the buffer, the transient menu, a
comparison of two real trees of at least 100,000 files with the time
compared with `diff -rq`.

CI: Linux and macOS, Emacs 30.1 and 31.1, as in quarry.

## Decisions at approval

The user approved the spec on 2026-10-14 with these six proposals, and all
six are implemented as proposed:

1. Content comparison as the default, not size and time (correct over
   fast; size and time is one key away).
2. The module keeps the results and sends only differences; identical
   entries are fetched per directory on demand.
3. Copy and delete in Elisp for version 1, blocking for large
   directories.
4. `.gitignore` respected by default; hidden files shown by default.
5. The key bindings above, in particular `>`/`<` for copying and
   `C-c C-k` for stopping.
6. Line counts computed for every changed text file up to 4 MiB during
   the comparison, not only when displayed.

## Tasks

- [x] 1. Repository scaffold: Cargo crate (cdylib, emrs pinned), the
  module skeleton with an empty `"dirdiff"` service, `lisp/emrs-dirdiff.el`
  with module loading and the build offer, `tests/run-ert.sh`, CI for
  Linux and macOS, README with installation, devflow docs layout.
  *Done when* CI builds the module and an ERT test starts and stops an
  instance.
  Note: CI has not run yet (nothing is pushed); the module builds and the
  suite passes locally.
- [x] 2. `src/walk.rs`: listing and pairing one directory level of both
  sides with the ignore rules and hidden-file option. *Done when* the
  pairing and ignore tests of section Testing pass. *Parallel with 3.*
- [x] 3. `src/compare.rs`: `content` and `size-time`, whitespace option,
  binary detection, line counts. *Done when* the comparison tests pass.
  *Parallel with 2.*
- [x] 4. `src/session.rs` and `src/service.rs`: the parallel walk, the
  result store, the `:compare`, `:same` and `:cancel` requests and the
  stream items as specified. *Done when* the service and cancellation
  tests pass and a benchmark against `diff -rq` on two 100,000-file trees
  is recorded in `docs/`.
- [x] 5. Elisp model and tree view: the two commands, the result model
  fed from the stream, the throttled redraw, header and mode line, folding,
  identical entries on `s`. *Done when* the model and tree-view ERT tests
  and the responsiveness test pass.
- [x] 6. Section view and the `v` toggle. *Done when* the section-view ERT
  test passes and toggling keeps point on the same path. *Parallel with 7.*
- [x] 7. Navigation and opening: `RET`, `e`, `o`, `O`, `d`, `n`, `p`, `N`,
  `P`, `^`, `/`, `f`, `w`, the comparison toggles and `x`. *Done when* the
  navigation and filter ERT tests pass. *Parallel with 6.*
- [x] 8. Marks and actions: `m`, `u`, `U`, `>`, `<`, `D` with confirmation
  and rescan. *Done when* the copy and delete ERT tests pass.
- [x] 9. The transient menu on `?`, showing the current settings. *Done
  when* every key of section Keys is reachable from it and the menu
  reflects toggled settings.
- [ ] 10. README usage section, faces and options documented, the manual
  checks of section Testing done and their results recorded.
