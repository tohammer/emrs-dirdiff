#!/bin/sh
# Build the module, install it under the name Emacs expects, and run the
# ERT suite with module assertions enabled. emrs.el is taken from the emrs
# checkout that Cargo resolved, so it always matches the Rust crate.
#
# EMRS_MODULE_FILE: test this prebuilt module instead of building one.
#   Nothing is built; the file is installed as emrs-dirdiff-module.<ext>.
# EMRS_EL_DIR: the directory of emrs.el, instead of the Cargo lookup.
# The emrs release workflow sets both to test each released module.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
if [ -n "${EMRS_MODULE_FILE:-}" ]; then
    if [ ! -f "$EMRS_MODULE_FILE" ]; then
        echo "run-ert.sh: EMRS_MODULE_FILE not found: $EMRS_MODULE_FILE" >&2
        exit 1
    fi
else
    cargo build
fi
if [ -n "${EMRS_EL_DIR:-}" ]; then
    emrs_el=$EMRS_EL_DIR
    if [ ! -f "$emrs_el/emrs.el" ]; then
        echo "run-ert.sh: emrs.el not found in EMRS_EL_DIR: $emrs_el" >&2
        exit 1
    fi
else
    emrs_el=$(cargo metadata --format-version 1 |
        sed -n 's|.*"manifest_path":"\([^"]*\)/emrs/Cargo.toml".*|\1/elisp|p' | head -n 1)
    if [ ! -f "$emrs_el/emrs.el" ]; then
        echo "run-ert.sh: emrs.el not found next to the emrs crate" >&2
        exit 1
    fi
fi
out="$root/target/elisp"
mkdir -p "$out"
# Test copies of the Lisp files; the module copied below to the same
# directory is found on `load-path' by the installer, so it is the one
# under test.  Old modules are removed too, so none from an earlier run
# is left over.
rm -f "$out"/*.el "$out"/*.elc "$out"/emrs-dirdiff-module.*
cp lisp/*.el "$out/"
# Test the byte-compiled code, as installed packages run it; the timing of
# the responsiveness test depends on it.
"${EMACS:-emacs}" --batch -L "$out" -L "$emrs_el" -f batch-byte-compile "$out"/*.el
if [ -n "${EMRS_MODULE_FILE:-}" ]; then
    cp "$EMRS_MODULE_FILE" "$out/emrs-dirdiff-module.${EMRS_MODULE_FILE##*.}"
else
    for ext in so dylib dll; do
        for built in "target/debug/libemrs_dirdiff.$ext" "target/debug/emrs_dirdiff.$ext"; do
            if [ -f "$built" ]; then
                cp "$built" "$out/emrs-dirdiff-module.$ext"
            fi
        done
    done
fi
exec "${EMACS:-emacs}" --batch --module-assertions \
    -L "$out" -L "$emrs_el" \
    --eval "(setq emrs-install-directory (file-name-as-directory (make-temp-file \"emrs-install\" t)) emrs-install-download 'never)" \
    -l "$root/tests/emrs-dirdiff-tests.el" \
    --eval "(ert-run-tests-batch-and-exit (or (getenv \"ERT_SELECTOR\") t))"
