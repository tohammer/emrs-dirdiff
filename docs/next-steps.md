# Next steps

Forward-looking only. Remove an item when it is done; move its lessons to
the architecture docs or an ADR.

## Next

1. Merge PR #1 (`feat/emrs-dirdiff-v1`) once its CI is green.

## Watch out for

- The emrs pin in `Cargo.toml` is a commit hash: bump it deliberately and
  run the full suite (the bump policy the comment in `Cargo.toml` points
  to).
- emrs encodes Rust enums as one-element lists and gives modules no way to
  end a stream `cancelled`, so kinds and statuses are strings and streams
  stopped by the module end `failed` with "cancelled" (spec, "The
  service").
- Tests must not assume the temporary directory's spelling: on macOS it
  resolves to `/private/var/...`, and on GitHub runners it lies under
  `$HOME`, so dired shows it as `~/...`. The transient bundled with Emacs
  30 lays out suffixes differently from newer versions. The responsiveness
  limit on CI is 150 ms.
- The mockup shows `C-g` to stop and both `i` and `I` for ignored files;
  the spec supersedes it with `C-c C-k` and `i` alone.
