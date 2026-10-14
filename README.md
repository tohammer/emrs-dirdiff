# emrs-dirdiff

Compare two directory trees in Emacs and act on the differences, in the
manner of `ztree-diff`. A Rust module built on
[emrs](https://github.com/tohammer/emrs) walks and compares the trees off
the Emacs thread. The buffer opens at once, fills in while the comparison
runs, and the comparison can be stopped.

See the [version 1 spec](docs/specs/2026-10-14-emrs-dirdiff-v1.md) and
[`docs/architecture.md`](docs/architecture.md) for the design.

## Status

Version 1 is implemented: both commands, the tree and section views,
filters, marks, copy, delete, rescans and the transient menu.

Checked automatically:

- `cargo test` (the Rust module) passes.
- The ERT suite (`tests/run-ert.sh`) passes in batch mode in CI on Linux
  and macOS with Emacs 30.1 and 31.1.

Checked on Linux with Emacs 31.1 (2026-10-14). In a GUI frame driven by a
script that exported screenshots of the frame:

- The tree and the section view in the default theme, `modus-operandi`
  and `modus-vivendi`.
- The `?` menu, the diff buffer (`RET`) and ediff (`e`) from the buffer.
- Two trees of 100,000 files: the whole comparison, including Emacs's
  handling of the results, took 0.50 s against 1.00 s for `diff -rq`, and
  Emacs's event loop never paused more than 30 ms.

In a terminal frame (`emacs -nw`, `xterm-256color`), driven by real
keystrokes through a pseudo-terminal: navigation, folding, the section
view, the menu, the name filter, copy with its prompt, delete of a
one-sided file and the diff buffer. All glyphs (`▾ ▸ ↔ → − ·`) display.

Not checked by hand: Emacs 30.1 and macOS (only the automated suite runs
there).

In Emacs's default theme, `diff-changed` has no colour, so changed
entries are marked only by their `M`; themes that colour diff-mode, such
as the modus themes, colour them too.

Windows is untested. Remote directories are not supported.

## Installation

Requirements:

- Emacs 30.1 or later, built with module support (`module-file-suffix` is
  non-nil).
- Rust 1.88 or later and `cargo`.
- The `emrs` Elisp package (`elisp/emrs.el` of the
  [emrs repository](https://github.com/tohammer/emrs)).

The module is built on your machine with cargo and installed as
`lisp/emrs-dirdiff-module` plus `module-file-suffix` inside this
repository, where the package finds it. The package builds it on first use,
after asking, when the file is missing or older than the sources
(`src/**/*.rs`, `Cargo.toml`, `Cargo.lock`; declining a rebuild loads the
old module); you can
also run `M-x emrs-dirdiff-build-module` at any time and restart Emacs to
use a rebuilt module. If cargo is not on `PATH`, set
`emrs-dirdiff-build-cargo-program`.

### Doom Emacs (straight)

In `packages.el`:

```elisp
(package! emrs
  :recipe (:host github :repo "tohammer/emrs" :files ("elisp/emrs.el")))
(package! emrs-dirdiff
  :recipe (:host github :repo "tohammer/emrs-dirdiff" :files ("lisp/*.el")
           :pre-build ((load (expand-file-name "lisp/emrs-dirdiff-build.el") nil t)
                       (emrs-dirdiff-build-module-sync))))
```

`doom sync` clones both repositories and the `:pre-build` form runs
`cargo build --release` in this checkout. `emrs-dirdiff-build-module-sync`
never signals: without a Rust toolchain, or if the build fails, `doom sync`
still completes with a warning, and the first use asks to build.

Update `emrs` together with `emrs-dirdiff`. This recipe has not been tested.

### Manual installation

1. `cargo build --release`, or `M-x emrs-dirdiff-build-module` when
   `emrs-dirdiff.el` is loaded from the checkout.
2. Without the command, copy `target/release/libemrs_dirdiff.so` (macOS:
   `.dylib`) to a directory on `load-path` as `emrs-dirdiff-module` plus
   `module-file-suffix`.
3. Put `lisp/*.el` and `emrs.el` on `load-path` and `(require 'emrs-dirdiff)`.

## Usage

Two commands start a comparison:

- `M-x emrs-dirdiff` asks for directory A, then for directory B. B
  defaults to the directory of the buffer in the other window.
- `M-x emrs-dirdiff-dired`, in a dired buffer, compares the two
  directories marked there. Without exactly two marked directories it
  compares the dired directory with the one shown by the dired buffer in
  the other window.

Both directories must be local, existing, different, and neither inside
the other; otherwise the command signals a `user-error`. The result buffer
is named `*dirdiff: A ↔ B*`, where A and B are the base names of the
directories. Running the command again for the same pair
reuses the buffer and compares again.

### The buffer

The buffer opens at once and fills while the module compares. The header
shows the counts per status, for example
`2 changed · 1 only in A · 1 only in B · 1 kind differs · 3 same (hidden)`.
While the comparison runs it shows the differences found so far, the
elapsed time and the stop key instead (there is no total, so no
percentage):

```
Comparing… 3 differences so far · 2 changed · 1 only in A · 4.2 s   C-c C-k to stop
```

The mode line shows the comparison method, whether ignore files apply and
the time the last comparison of everything took. Identical entries are not
listed unless `s` shows them. A root that cannot be read shows as an
error in the header. While no window shows the buffer it is not redrawn;
it catches up when it is shown again.

The tree view is the default. Each line has a status letter (`M` changed,
`A` only in A, `B` only in B, `T` kind differs, `!` error, `·` still
comparing), the name indented by depth, and on the right the sizes and
the line counts of changed text files. A `*` after the letter marks the
entry. Directories with differences are expanded to the first three
levels.

```
M    changed.txt            6 → 8         +2 −1
M  ▾ deep/                  1 changed
M    ▾ er/                  1 changed
M        n.txt              2 → 2         +1 −1
T    kindy                  kind differs (A: file)
A    only-a.txt             1
B    onlyb/                 2 files
```

The section view (`v` toggles it, `emrs-dirdiff-default-view` sets the
first one) groups the same results into the sections Changed, Only in A,
Only in B, Kind differs, Errors and Same, each a flat list of relative
paths. Empty sections are left out and Same starts folded.

```
▾ Changed (2)
    changed.txt                 6 → 8         +2 −1
    deep/er/n.txt               2 → 2         +1 −1

▾ Only in A (1)
    only-a.txt                  1

▾ Only in B (1)
    onlyb/                      2 files

▾ Kind differs (1)
    kindy                       kind differs (A: file)

▸ Same (3)
```

### Keys

`?` opens a transient menu with every command below and the current
settings of the buffer.

| Key | Command | Action |
|---|---|---|
| **Open** | | |
| `RET` | `emrs-dirdiff-open` | On a changed file: a `diff-mode` buffer of the pair (`diff-no-select`, with `-w` when whitespace is ignored). On a file or directory present on one side: visit it. On a directory present on both sides, or a section header: fold or unfold |
| `e` | `emrs-dirdiff-ediff` | ediff of the pair |
| `o`, `O` | `emrs-dirdiff-visit-a`, `-visit-b` | Visit the entry on side A, on side B |
| `d` | `emrs-dirdiff-dired-entry` | dired at the entry's directory on the side that exists (A if both) |
| **Move** | | |
| `n`, `p` | `emrs-dirdiff-next-difference`, `-previous-difference` | Next, previous difference |
| `N`, `P` | `emrs-dirdiff-next-group`, `-previous-group` | Next, previous directory with differences (section header in the section view) |
| `TAB` | `emrs-dirdiff-toggle-fold` | Fold or unfold the directory or section at point |
| `S-TAB` | `emrs-dirdiff-toggle-fold-all` | Fold every directory (every section in the section view) when any is unfolded, else unfold them all |
| `^` | `emrs-dirdiff-up` | Go to the parent |
| **Show** | | |
| `s` | `emrs-dirdiff-toggle-same` | Show or hide identical entries (section view: unfold or fold the Same section) |
| `i` | `emrs-dirdiff-toggle-ignore-files` | Toggle whether `.gitignore` and similar files apply; compares again |
| `/` | `emrs-dirdiff-filter-name` | Filter by name (substring of the relative path; empty clears; case-insensitive unless it has an uppercase letter) |
| `f` | `emrs-dirdiff-cycle-status-filter` | Cycle the status filter: all, changed, only A, only B |
| `v` | `emrs-dirdiff-toggle-view` | Switch between tree and section view |
| **Act** | | |
| `m`, `u`, `U` | `emrs-dirdiff-mark`, `-unmark`, `-unmark-all` | Mark, unmark (both move down a line), unmark all |
| `>`, `<` | `emrs-dirdiff-copy-a-to-b`, `-copy-b-to-a` | Copy A → B, B → A |
| `D` | `emrs-dirdiff-delete` | Delete |
| `w` | `emrs-dirdiff-copy-path` | Copy the relative path; with a prefix argument, the absolute path on A (on B if the entry is not in A) |
| **Compare by** | | |
| `c`, `t` | `emrs-dirdiff-compare-content`, `-compare-size-time` | Compare by content, by size and time; compares again |
| `W` | `emrs-dirdiff-toggle-whitespace` | Toggle ignoring whitespace; compares again |
| **Comparison** | | |
| `g` | `emrs-dirdiff-rescan` | Compare again; with a prefix argument and point on a directory present on both sides, only that directory (refused while a comparison runs) |
| `x` | `emrs-dirdiff-swap` | Swap A and B; clears the marks |
| `C-c C-k` | `emrs-dirdiff-stop` | Stop the comparison and the rescans waiting behind it |
| `q` | `quit-window` | Quit the window; the buffer and its instance stay until the buffer is killed |

The buffer's settings (compare by, ignore files, whitespace, hidden
files, view) start from the options below and are then local to the
buffer. The menu shows their state. Keys not listed are those of
`special-mode`.

### Copy and delete

`>` and `<` copy and `D` deletes. They act on the marked entries, or on
the entry at point when nothing is marked, and only on what the
comparison showed:

- An entry below another marked entry is covered by it. Marks on paths
  the comparison does not know, and entries still being compared, are
  left out.
- Copying a file overwrites the other side's file. An entry present on
  one side only is copied whole into the other side (`copy-file`, keeping
  times, or `copy-directory`); a symbolic link is copied as a link.
- Copying a directory present on both sides copies the differences listed
  below it, one entry at a time: changed files, entries only on the source
  side, kind differences. Nothing else in it is touched: ignored, hidden
  and identical files stay as they are, and so do entries only on the
  target side. To copy ignored or hidden files, compare with `i` (ignore
  files off) or with hidden files shown first.
- A kind difference (a file on one side, a directory or link on the
  other) is replaced: the target is deleted first, then the source copied.
- Deleting asks which side with `read-char-choice` (A, B or both), once,
  only when an entry is present on both sides; an entry present on one
  side is deleted there. Deleting a directory deletes everything in it.
- Deletions, including those of a replacement, use `delete-file` and
  `delete-directory` with the trash argument, so
  `delete-by-moving-to-trash` decides whether entries go to the trash.
- Entries that cannot be acted on (copying an entry that does not exist
  on the source side, an identical entry, an entry that could not be
  compared, a special file) are left out, and the question or a message
  says so.

Each action asks once for the whole set. The question lists the
operations (ten, then "and N more"), names the direction or the side, and
says separately how many existing files will be overwritten and how many
entries replaced, for example `Copy 4 entries A → B: 2 files overwritten,
1 directory replaced (deleted first)`. It is `yes-or-no-p` whenever
anything is overwritten, replaced or deleted, else `y-or-n-p`.

Before each operation the entry is checked on disk against the
comparison: the same kind on each side involved and, for files, the same
size and modification time (to the second). Every directory between the
root and the entry must be a real directory, not a symbolic link, so an
operation never reaches outside the roots. An entry that fails is skipped
and reported as changed since the comparison; `g` brings the view up to
date. Relative paths are appended to the roots as they are, so an entry
named `~` is not the home directory.

- Copy and delete run in Emacs and block it until they finish, which
  takes a while for large directories.
- An action stops at the first error and shows a warning with the path
  and how many operations were done. `C-g` stops it too and says how many
  were done. What was done stays done.
- Afterwards every path an operation ran on is compared again. A mark is
  cleared when every operation on its path succeeded. These rescans wait
  while another comparison is running, one at a time.

### Stopping and comparing again

`C-c C-k` stops the running comparison and drops the rescans waiting
behind it (`C-g` keeps its usual meaning). The header then reads
"Stopped after …" with what was found so far. Killing the buffer, or
changing its major mode, stops its comparison too. `g` compares everything
again; after an error such as a failed module load it also starts a new
instance. `c`, `t`, `W` and `i` change a setting and compare again.

## Options

Each comparison buffer starts with the value of these options at the time
it was created.

| Option | Default | Meaning |
|---|---|---|
| `emrs-dirdiff-compare-by` | `content` | `content` compares file bytes; `size-time` compares size and modification time to the second and reads nothing |
| `emrs-dirdiff-respect-ignore-files` | `t` | `.gitignore`, `.ignore` and the global git excludes apply, each side under its own rules; `.git` directories are always skipped |
| `emrs-dirdiff-ignore-whitespace` | `nil` | Text files (no NUL byte in the first 8 KiB, at most 4 MiB) that differ only in whitespace count as identical |
| `emrs-dirdiff-show-hidden` | `t` | Names starting with a dot are compared |
| `emrs-dirdiff-default-view` | `tree` | The first view of a buffer: `tree` or `sections` |
| `emrs-dirdiff-build-cargo-program` | see Installation | The cargo executable used to build the module |

Faces:

| Face | Inherits from | Used for |
|---|---|---|
| `emrs-dirdiff-changed` | `diff-changed` | Changed entries |
| `emrs-dirdiff-only-a` | `diff-removed` | Entries only in A |
| `emrs-dirdiff-only-b` | `diff-added` | Entries only in B |
| `emrs-dirdiff-error` | `error` | Entries that could not be compared, and error messages |
| `emrs-dirdiff-mark` | `bold`, `warning` | The `*` of a marked entry |
| `emrs-dirdiff-dim` | `shadow` | Details, identical entries, directories being compared |

## Performance

On a Linux machine with warm caches (tmpfs), two trees of 100,000 files
each with 1,000 changed files took 0.43 s to compare by content and 0.18 s
by size and time. `diff -rq` took 0.82 s on the same trees. These figures
come from the module run in Rust tests; the time Emacs spends handling
the items, and trees on a cold disk cache, were not measured. Setup and
commands are in [`docs/benchmark.md`](docs/benchmark.md).

## Limitations

- Remote (TRAMP) directories are not supported; use `ztree-diff` for them.
- File names that are not valid UTF-8 are converted lossily, so they may
  not name the real file.
- Copy and delete run in Emacs and block it for large trees.
- Copying a directory present on both sides copies only the differences
  the comparison listed; ignored and hidden files in it are never copied.
- An entry changed on disk after the comparison is skipped by copy and
  delete until `g` compares again.
- After an action, rescanning a single path does not always update the
  "same" counts of its parent directories (a file that became identical
  is not counted) until `g` compares everything again.
- `.gitignore` files above the roots and `.git/info/exclude` are not
  applied. The global git excludes are matched relative to Emacs's current
  directory, so their anchored patterns can misfire.
- There is no three-way comparison.

## Development

`cargo fmt --all -- --check`, `cargo clippy --all-targets -- -D warnings`
and `cargo test` check the Rust side; `tests/run-ert.sh` builds the module
and runs the ERT suite in batch mode with the module assertions on.

## Licence

Rust code: MIT OR Apache-2.0 (`LICENSE-MIT`, `LICENSE-APACHE`). Elisp code:
GPL-3.0-or-later (`LICENSE-GPL`).
