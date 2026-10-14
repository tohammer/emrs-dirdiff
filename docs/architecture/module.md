# Architecture: the Rust module

Part of [the architecture](../architecture.md). The Elisp side is in
[`elisp.md`](elisp.md).

## Service

`DirdiffService::handle` runs on the instance's emrs worker. The start
checks both roots and builds the instance's rayon pool (one thread per
CPU); stop drops it, and its threads end once the stopped comparison's
tasks have returned. `:compare` sets the stop flag of the previous
comparison, drops the stored results at and below the requested path,
opens the stream (capacity 256) and hands it, with the pool, to
`session::run` on an emrs pool thread, then returns. `:same` answers from
the store; `:cancel` and instance stop set the running comparison's stop
flag. Request paths go through `session::parse_rel`, which refuses `..`,
absolute paths and other components that leave the roots.

## Session

`run` submits the first task to the pool (for a single entry, listing its
parent runs as a task too) and becomes the stream's only writer. Tasks
send items through a bounded channel (256); `run` forwards them with
`try_send`, waiting while Emacs has not drained the stream. Each instance
has its own pool, so tasks blocked on a full stream hold up only their own
comparison.

A directory task lists one level of both sides (`walk::list_level`),
decides one-sided, kind-differing, link and special entries at once, and
submits a task per file pair, per subdirectory and per one-sided directory
to count. Each directory present on both sides is a `DirNode` with a
counter of outstanding work and a link to its parent; the task that
finishes the last unit emits `done` and completes the parent in turn, so
no barrier is needed. Completing the root sends the summary and ends the
stream.

Identical entries are not sent but stored per directory (`Store`) under a
mutex. The store write is checked against the stop flag under the lock, so
a stopped comparison cannot write into a store cleared for its successor.

`Item` carries `kind` and `status` as strings because emrs encodes enum
values as one-element lists (spec "The service").

## Walk

`walk::list_level` lists one directory level of both sides, applies
`.gitignore`, `.ignore` and the global excludes per side (`Rules`, an `Arc`
chain) and pairs entries by name. Special files are told apart
(`Kind::Other(Special)`: fifo, socket, block or character device, through
`std::os::unix::fs::FileTypeExt`; one unknown kind elsewhere). Two of the
same kind are the same, different kinds have status `kind`; Lisp sees
`:kind "other"` for all of them. `count_files` counts the files of a
one-sided directory.

A rescan of a single entry (`:compare :path "x/y"`) walks the parent path
from each root with `symlink_metadata` (`walk::rules_along`). A side where
any component is not a real directory (a symbolic link, a file, missing)
is not read at all, so the entry counts as absent there and its ignore
rules stop at the last real directory. Nothing outside the roots is read
through a symbolic link.

## Compare

`compare_files` compares by content (64 KiB blocks) or by size and time
(nothing read, no line counts). With whitespace ignored, a pair that
differs by bytes is compared again as text without whitespace. Text is
read through `take(4 MiB + 1)`, so a file that grew since the listing is
never read whole.

Line counts are made with `:by content` only, for text files of at most
4 MiB (checked on the listed sizes, then again while reading). The Myers
diff runs with a deadline of 0.5 s (`capture_diff_slices_deadline`); when
the deadline has passed after the call, the pair gets no `:lines`. The
diff cannot be interrupted, so the budget also bounds the cancellation
latency of a file task.

## Listing errors

A side whose directory cannot be listed at all makes the directory one
`error` item (`:kind "dir"`) and no `done`. When only single entries fail
(`read_dir` yields an error for them), the readable entries are compared
as usual, the directory gets one `error` item with the message `some
entries could not be read: …` (the first such error) and still its `done`;
Elisp keeps `done` apart from the items, so both show. A task that panics
sends one `error` item for its path ("internal error in emrs-dirdiff";
`:kind "dir"` for a listing, `"file"` for a file pair) and completes its
parent; a directory whose listing panicked gets no `done`. The panic is
caught with `catch_unwind`, hence `panic = "unwind"` in the profiles.

## Cancellation

The call's `CancelToken` (cancelled by `emrs-cancel` and by instance stop)
and the service's stop flag (`:cancel`, a newer `:compare`, `stop`) are
checked by every task before it starts, by `compare_files` between blocks
and before the line diff, and by `run` every 5 ms; `run` then drops the
channel, which releases tasks blocked on it. A comparison stopped by the
flag ends its stream `failed` with the message `cancelled`, because emrs
gives a module no way to end a stream `cancelled`.
