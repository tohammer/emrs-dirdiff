;;; emrs-dirdiff-build.el --- Build the emrs-dirdiff module with cargo  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  The emrs-dirdiff authors

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; Builds the Rust module from the repository that holds this package and
;; installs it as lisp/emrs-dirdiff-module plus `module-file-suffix', next to
;; emrs-dirdiff.el.  This file depends neither on emrs nor on the module, so a
;; package manager can load it standalone from a pre-build step before
;; emrs-dirdiff is built:
;;
;;   (load (expand-file-name "lisp/emrs-dirdiff-build.el") nil t)
;;   (emrs-dirdiff-build-module-sync)
;;
;; `emrs-dirdiff-build-module' is the interactive, asynchronous variant.

;;; Code:

(defgroup emrs-dirdiff nil
  "Compare two directory trees, backed by a Rust module."
  :group 'tools
  :prefix "emrs-dirdiff-")

(defcustom emrs-dirdiff-build-cargo-program "cargo"
  "Program that builds the emrs-dirdiff module (`cargo build --release')."
  :type 'string
  :group 'emrs-dirdiff)

(defconst emrs-dirdiff-build--file (or load-file-name buffer-file-name)
  "File this library was loaded from, or nil.")

(defconst emrs-dirdiff-build--buffer "*emrs-dirdiff-build*"
  "Name of the buffer that receives the build output.")

(defconst emrs-dirdiff-build--hint
  "run M-x emrs-dirdiff-build-module later"
  "What to do after a failed automatic build.")

(defun emrs-dirdiff-build--find-repo ()
  "Return the repository root as a directory name, or nil.
It is the parent of the directory of the true name of this file (its .el
sibling when loaded from a .elc), so the build tree is the one this file
belongs to even when another emrs-dirdiff.el is on `load-path'.  When that is
unknown, it is the parent of the directory of the true name of emrs-dirdiff.el
on `load-path'.  The root need not contain Cargo.toml."
  (let* ((own (and emrs-dirdiff-build--file
                   (if (string-suffix-p ".elc" emrs-dirdiff-build--file)
                       (substring emrs-dirdiff-build--file 0 -1)
                     emrs-dirdiff-build--file)))
         (lib (or (and own (file-exists-p own) (file-truename own))
                  (let ((found (locate-library "emrs-dirdiff.el" t)))
                    (and found (file-truename found))))))
    (and lib
         (file-name-directory
          (directory-file-name (file-name-directory lib))))))

(defun emrs-dirdiff-build--repo ()
  "Return the repository root, which holds Cargo.toml.
Signal a `user-error' when there is none."
  (let ((repo (emrs-dirdiff-build--find-repo)))
    (unless (and repo (file-exists-p (expand-file-name "Cargo.toml" repo)))
      (user-error "emrs-dirdiff source not found (installed without its repository?); install the module by hand, see the README"))
    repo))

(defun emrs-dirdiff-build--module-file (repo)
  "Return the file the module is installed as in REPO."
  (expand-file-name (concat "lisp/emrs-dirdiff-module" module-file-suffix) repo))

(defun emrs-dirdiff-build--library (repo)
  "Return the file `cargo build --release' produces in REPO."
  (expand-file-name
   (concat "target/release/"
           (pcase system-type
             ('darwin "libemrs_dirdiff.dylib")
             ('windows-nt "emrs_dirdiff.dll")
             (_ "libemrs_dirdiff.so")))
   repo))

(defun emrs-dirdiff-build--arguments (repo)
  "Return the arguments of the cargo command that builds REPO.
The target directory is explicit, so neither CARGO_TARGET_DIR nor the
cargo configuration can move the library from `emrs-dirdiff-build--library'."
  (list "build" "--release" "--target-dir"
        (expand-file-name "target" repo)))

(defun emrs-dirdiff-build--install (repo)
  "Install the library built in REPO as its module file.
The copy goes to a temporary file first and replaces the module file by
rename, so an Emacs that has the old module loaded keeps a valid file."
  (let* ((library (emrs-dirdiff-build--library repo))
         (target (emrs-dirdiff-build--module-file repo))
         (temp (progn
                 (unless (file-exists-p library)
                   (user-error "Cargo produced no %s" library))
                 (make-temp-file
                  (expand-file-name "emrs-dirdiff-module.tmp-" (file-name-directory target))
                  nil module-file-suffix))))
    (condition-case err
        (progn (copy-file library temp t)
               (set-file-modes temp #o755)
               (rename-file temp target t))
      (error (ignore-errors (delete-file temp))
             (signal (car err) (cdr err))))
    target))

(defun emrs-dirdiff-build--loaded-p ()
  "Return non-nil when a emrs-dirdiff module is loaded in this Emacs."
  (or (featurep 'emrs-dirdiff-module)
      (and (boundp 'emrs--modules) (hash-table-p emrs--modules)
           (gethash 'emrs-dirdiff emrs--modules)
           t)))

(defun emrs-dirdiff-build--program ()
  "Return the full name of the cargo program, or signal a `user-error'."
  (or (executable-find emrs-dirdiff-build-cargo-program)
      (user-error "Program `%s' not found; install Rust or set `emrs-dirdiff-build-cargo-program'"
                  emrs-dirdiff-build-cargo-program)))

(defun emrs-dirdiff-build--finish (repo success)
  "Install the library of REPO when SUCCESS and report the result."
  (if (not success)
      (message "emrs-dirdiff module build failed (see %s)" emrs-dirdiff-build--buffer)
    (condition-case err
        (progn (emrs-dirdiff-build--install repo)
               (message (if (emrs-dirdiff-build--loaded-p)
                            "emrs-dirdiff module built; restart Emacs to use it"
                          "emrs-dirdiff module built")))
      (error (message "emrs-dirdiff module build failed: %s" (error-message-string err))
             (setq success nil))))
  success)

;;;###autoload
(defun emrs-dirdiff-build-module ()
  "Build the emrs-dirdiff module with cargo, asynchronously.
The output goes to the buffer `*emrs-dirdiff-build*'.  On success the module
is installed next to emrs-dirdiff.el; a running Emacs needs a restart to use
a rebuilt module.  Recompiling in that buffer installs as well.  Return
the build process."
  (interactive)
  (when (get-buffer-process emrs-dirdiff-build--buffer)
    (user-error "The emrs-dirdiff module is being built (see %s)" emrs-dirdiff-build--buffer))
  (let* ((repo (emrs-dirdiff-build--repo))
         (program (emrs-dirdiff-build--program))
         (default-directory repo)
         (buffer (compilation-start
                  (mapconcat #'shell-quote-argument
                             (cons program (emrs-dirdiff-build--arguments repo)) " ")
                  'compilation-mode
                  (lambda (_mode) emrs-dirdiff-build--buffer))))
    (get-buffer-process buffer)))

(defun emrs-dirdiff-build--compilation-finished (buffer message)
  "Install the module when the build in BUFFER ended with MESSAGE.
Meant for `compilation-finish-functions'; it ignores other buffers."
  (when (equal (buffer-name buffer) emrs-dirdiff-build--buffer)
    (emrs-dirdiff-build--finish
     (buffer-local-value 'default-directory buffer)
     (equal message "finished\n"))))

(add-hook 'compilation-finish-functions #'emrs-dirdiff-build--compilation-finished)

(defun emrs-dirdiff-build--output-tail (&optional lines)
  "Return the last LINES (default 30) lines of the build buffer."
  (with-current-buffer emrs-dirdiff-build--buffer
    (save-excursion
      (goto-char (point-max))
      (forward-line (- (or lines 30)))
      (string-trim (buffer-substring-no-properties (point) (point-max))))))

;;;###autoload
(defun emrs-dirdiff-build-module-sync ()
  "Build the emrs-dirdiff module with cargo, waiting for it to finish.
Never signal: a failure becomes a warning.  In batch mode the warning
includes the end of the build output, which is lost with the process.
Return non-nil on success."
  (condition-case err
      (let* ((repo (emrs-dirdiff-build--repo))
             (program (emrs-dirdiff-build--program))
             (default-directory repo)
             (buffer (get-buffer-create emrs-dirdiff-build--buffer))
             status)
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (erase-buffer)))
        (setq status (apply #'call-process program nil buffer nil
                            (emrs-dirdiff-build--arguments repo)))
        (unless (eql status 0)
          (if noninteractive
              (error "The build failed:\n%s" (emrs-dirdiff-build--output-tail))
            (error "The build failed (see %s)" emrs-dirdiff-build--buffer)))
        (emrs-dirdiff-build--install repo)
        (message "emrs-dirdiff module built")
        t)
    (error
     (display-warning
      'emrs-dirdiff (format "Cannot build the module: %s; %s"
                      (error-message-string err) emrs-dirdiff-build--hint))
     nil)))

(provide 'emrs-dirdiff-build)
;;; emrs-dirdiff-build.el ends here
