# Next steps

Forward-looking only. Remove an item when it is done; move its lessons to
the architecture docs or an ADR.

## Next

1. Do the manual checks of task 10 in
   [`specs/2026-10-14-emrs-dirdiff-v1.md`](specs/2026-10-14-emrs-dirdiff-v1.md):
   - a GUI frame and a terminal frame;
   - a light and a dark theme;
   - ediff from the buffer;
   - the transient menu;
   - a real comparison of two trees of at least 100,000 files, timed
     against `diff -rq`.

   Then tick task 10 and set the spec to implemented.
2. Push the branch and watch the first CI run (Linux and macOS, Emacs 30.1
   and 31.1). Emacs 30.1 and macOS have never run. The responsiveness
   limit on CI is 150 ms.
3. Commit and merge.

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
