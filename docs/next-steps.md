# Next steps

Forward-looking only. Remove an item when it is done; move its lessons to
the architecture docs or an ADR.

## Next

1. Finish the manual checks of task 10 in
   [`specs/2026-10-14-emrs-dirdiff-v1.md`](specs/2026-10-14-emrs-dirdiff-v1.md):
   a terminal frame (`emacs -nw`), and the keys typed by hand rather
   than called as commands. The GUI frame, both themes, ediff, the menu
   and the 100,000-file timing are done (README, Status). Then tick task
   10 and set the spec to implemented.
2. Push the branch and watch the first CI run (Linux and macOS, Emacs 30.1
   and 31.1). Emacs 30.1 and macOS have never run. The responsiveness
   limit on CI is 150 ms.
3. Merge the branch.

## Watch out for

- The emrs pin in `Cargo.toml` is a commit hash: bump it deliberately and
  run the full suite (the bump policy the comment in `Cargo.toml` points
  to).
- emrs encodes Rust enums as one-element lists and gives modules no way to
  end a stream `cancelled`, so kinds and statuses are strings and streams
  stopped by the module end `failed` with "cancelled" (spec, "The
  service").
- The mockup shows `C-g` to stop and both `i` and `I` for ignored files;
  the spec supersedes it with `C-c C-k` and `i` alone.
