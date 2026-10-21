#!/bin/sh
# Build the module, install it under the name Emacs expects, and run the
# ERT suite with module assertions enabled. emrs.el is taken from the emrs
# checkout that Cargo resolved, so it always matches the Rust crate.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
cargo build
emrs_el=$(cargo metadata --format-version 1 |
    sed -n 's|.*"manifest_path":"\([^"]*\)/emrs/Cargo.toml".*|\1/elisp|p' | head -n 1)
if [ ! -f "$emrs_el/emrs.el" ]; then
    echo "run-ert.sh: emrs.el not found next to the emrs crate" >&2
    exit 1
fi
out="$root/target/elisp"
mkdir -p "$out"
# Test copies of the Lisp files; the debug module copied below to the same
# directory is found on `load-path' by the installer, so it is the one
# under test.
rm -f "$out"/*.el "$out"/*.elc
cp lisp/*.el "$out/"
# Test the byte-compiled code, as installed packages run it; the timing of
# the responsiveness test depends on it.
"${EMACS:-emacs}" --batch -L "$out" -L "$emrs_el" -f batch-byte-compile "$out"/*.el
for ext in so dylib dll; do
    for built in "target/debug/libemrs_dirdiff.$ext" "target/debug/emrs_dirdiff.$ext"; do
        if [ -f "$built" ]; then
            cp "$built" "$out/emrs-dirdiff-module.$ext"
        fi
    done
done
exec "${EMACS:-emacs}" --batch --module-assertions \
    -L "$out" -L "$emrs_el" \
    --eval "(setq emrs-install-directory (file-name-as-directory (make-temp-file \"emrs-install\" t)) emrs-install-download 'never)" \
    -l "$root/tests/emrs-dirdiff-tests.el" \
    --eval "(ert-run-tests-batch-and-exit (or (getenv \"ERT_SELECTOR\") t))"
