;;; emrs-dirdiff.el --- Compare two directory trees, backed by a Rust module  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  The emrs-dirdiff authors

;; Version: 0.2.0
;; Package-Requires: ((emacs "30.1") (emrs "0.2.0"))
;; Keywords: files, tools
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; emrs-dirdiff compares two directory trees with a Rust module (built
;; with emrs) that walks and compares them off the Emacs thread.
;;
;; M-x emrs-dirdiff asks for two directories; M-x emrs-dirdiff-dired
;; compares the two directories marked in dired, or the dired directory
;; with the one in the other window.  The buffer opens at once and fills
;; while the module streams the differences.
;;
;; The module comes from emrs-install.el: a download of the release file
;; for a released version, else a cargo build from the checkout, or
;; `emrs-dirdiff-module' plus `module-file-suffix' on `load-path'.

;;; Code:

(require 'cl-lib)
(require 'diff)
;; The faces inherit from diff-mode's, which are defined there.
(require 'diff-mode)
(require 'seq)
(require 'subr-x)
(require 'emrs)
(require 'emrs-install)

(declare-function dired-get-marked-files "dired")
(declare-function dired-marker-regexp "dired")
(declare-function dired-goto-file "dired")
(declare-function dired-other-window "dired")
(declare-function ediff-files "ediff")

;;;###autoload
(autoload 'emrs-dirdiff-menu "emrs-dirdiff-menu" "Show the menu of `emrs-dirdiff-mode'." t)

(defgroup emrs-dirdiff nil
  "Compare two directory trees, backed by a Rust module."
  :group 'tools
  :prefix "emrs-dirdiff-")

;;;; Options

(defcustom emrs-dirdiff-compare-by 'content
  "How files are compared: by `content' or by `size-time'.
Each comparison buffer starts with this value."
  :type '(choice (const :tag "Content" content)
                 (const :tag "Size and modification time" size-time)))

(defcustom emrs-dirdiff-respect-ignore-files t
  "Non-nil means `.gitignore', `.ignore' and the global git excludes apply.
Each comparison buffer starts with this value."
  :type 'boolean)

(defcustom emrs-dirdiff-ignore-whitespace nil
  "Non-nil means text files that differ only in whitespace are the same.
Each comparison buffer starts with this value."
  :type 'boolean)

(defcustom emrs-dirdiff-show-hidden t
  "Non-nil means names starting with a dot are compared.
Each comparison buffer starts with this value."
  :type 'boolean)

(defcustom emrs-dirdiff-default-view 'tree
  "The view a comparison buffer starts with: `tree' or `sections'."
  :type '(choice (const :tag "Tree" tree)
                 (const :tag "Sections" sections)))

(defface emrs-dirdiff-changed '((t :inherit diff-changed))
  "Face of changed entries.")

(defface emrs-dirdiff-only-a '((t :inherit diff-removed))
  "Face of entries present only in A.")

(defface emrs-dirdiff-only-b '((t :inherit diff-added))
  "Face of entries present only in B.")

(defface emrs-dirdiff-error '((t :inherit error))
  "Face of entries that could not be compared.")

(defface emrs-dirdiff-mark '((t :inherit (bold warning)))
  "Face of the mark `*' of a marked entry.")

(defface emrs-dirdiff-dim '((t :inherit shadow))
  "Face of details, identical entries and directories being compared.")

;;;; Module

(defconst emrs-dirdiff-module-version "0.2.0"
  "The version of the emrs-dirdiff module this Lisp code needs.
It equals `version' in Cargo.toml and the Version header of this file.")

(emrs-install-register 'emrs-dirdiff
  :version emrs-dirdiff-module-version
  :url "https://github.com/tohammer/emrs-dirdiff/releases/download"
  :source (or load-file-name buffer-file-name))

(defun emrs-dirdiff--load-module ()
  "Load the emrs-dirdiff module and return its handle.
`emrs-install-load' finds, downloads or builds it, and signals a
`user-error' that says what to do when it cannot."
  (emrs-install-load 'emrs-dirdiff))

;;;; Instances

(defun emrs-dirdiff--start (a b &optional on-exit)
  "Start a \"dirdiff\" instance for the directories A and B; return it.
The instance starts asynchronously: a bad directory makes it fail, and
ON-EXIT, if given, is called as (ON-EXIT INSTANCE STATUS ERR) then."
  (emrs-dirdiff--load-module)
  (emrs-start 'emrs-dirdiff "dirdiff" (list :a a :b b) :on-exit on-exit))

(defun emrs-dirdiff--stop (instance)
  "Stop INSTANCE, which `emrs-dirdiff--start' returned."
  (emrs-stop instance))

;;;; Buffer-local state

(defvar-local emrs-dirdiff--a nil
  "Root A of this buffer: an absolute true directory name.")

(defvar-local emrs-dirdiff--b nil
  "Root B of this buffer: an absolute true directory name.")

(defvar-local emrs-dirdiff--by 'content
  "Comparison method of this buffer: `content' or `size-time'.")

(defvar-local emrs-dirdiff--ignore-files t
  "Whether ignore files apply in this buffer.")

(defvar-local emrs-dirdiff--whitespace nil
  "Whether whitespace differences are ignored in this buffer.")

(defvar-local emrs-dirdiff--hidden t
  "Whether names starting with a dot are compared in this buffer.")

(defvar-local emrs-dirdiff--view 'tree
  "The view of this buffer, a key of `emrs-dirdiff--renderers'.")

(defvar-local emrs-dirdiff--show-same nil
  "Non-nil when identical entries are shown in the tree view.")

(defvar-local emrs-dirdiff--name-filter nil
  "The substring entries must contain in their relative path, or nil.")

(defvar-local emrs-dirdiff--name-regexp nil
  "The regexp for `emrs-dirdiff--name-filter', or nil.")

(defvar-local emrs-dirdiff--name-fold nil
  "Non-nil when the name filter ignores case (it has no uppercase letter).")

(defvar-local emrs-dirdiff--status-filter nil
  "Show only entries of this status: nil, `changed', `only-a' or `only-b'.")

(defvar-local emrs-dirdiff--keep nil
  "During a redraw with a filter, the hash table of paths to keep, else nil.
It holds the entries that pass the filters and their ancestors.")

(defvar-local emrs-dirdiff--instance nil
  "The emrs instance of this buffer, or nil.")

(defvar-local emrs-dirdiff--instance-error nil
  "Message of the last failure to start or run the instance, or nil.")

(defvar-local emrs-dirdiff--stream nil
  "The call object of the running comparison, or nil.")

(defvar-local emrs-dirdiff--stream-path ""
  "The relative path of the running or last comparison; \"\" for all.")

(defvar-local emrs-dirdiff--dirty nil
  "Non-nil when a redraw was skipped because no window shows the buffer.")

(defvar-local emrs-dirdiff--state nil
  "State of the last comparison: nil, `running', `done', `stopped' or `failed'.")

(defvar-local emrs-dirdiff--error nil
  "Message of the failed comparison, or nil.")

(defvar-local emrs-dirdiff--started nil
  "`float-time' when the last comparison started.")

(defvar-local emrs-dirdiff--ended nil
  "`float-time' when the last comparison ended, or nil.")

(defvar-local emrs-dirdiff--items nil
  "Hash table: relative path -> stream item of a difference.")

(defvar-local emrs-dirdiff--done nil
  "Hash table: relative path of a finished directory -> its identical files.")

(defvar-local emrs-dirdiff--children nil
  "Hash table: directory path -> hash table of child paths (values t).
Holds every path of `emrs-dirdiff--items' and `emrs-dirdiff--done' and
their ancestors.")

(defvar-local emrs-dirdiff--counts nil
  "Hash table: directory path -> vector of difference counts below it.
The slots are those of `emrs-dirdiff--statuses'.")

(defvar-local emrs-dirdiff--summary nil
  "The summary item of the last finished comparison of everything, or nil.
A subtree rescan keeps it.")

(defvar-local emrs-dirdiff--rescan nil
  "During a subtree rescan, (PATH . OLD-SAME): the identical files that
the `done' item of PATH had before.  The ancestors' counts are adjusted
by the difference when the new one arrives.")

(defvar-local emrs-dirdiff--same nil
  "Hash table: directory path -> (pending) or (done . ITEMS) from `:same'.
The cons cell of a pending request is unique, so a stale reply is dropped.")

(defvar-local emrs-dirdiff--folds nil
  "Hash table: directory path -> `open' or `closed', set by the user.
Kept across redraws and comparisons.")

(defvar-local emrs-dirdiff--section-folds nil
  "Hash table: section symbol -> `open' or `closed', set by the user.
Kept across redraws and comparisons.")

(defvar-local emrs-dirdiff--line-index nil
  "Hash table: path -> position of its line, from the last redraw.
In the section view it also maps each section symbol to its header.")

(defvar-local emrs-dirdiff--redraw-timer nil
  "Timer of the pending throttled redraw, or nil.")

(defvar-local emrs-dirdiff--tick-timer nil
  "Timer that refreshes the elapsed time while comparing, or nil.")

(defvar-local emrs-dirdiff--last-redraw 0
  "`float-time' of the last redraw.")

(defvar-local emrs-dirdiff--marks nil
  "Hash table: relative path of a marked entry -> t.")

(defvar-local emrs-dirdiff--rescan-queue nil
  "Relative paths waiting to be compared again after an action.
They run one at a time, each when the previous stream has ended.")

(defconst emrs-dirdiff--statuses [changed only-a only-b kind error]
  "Difference statuses in the order of the slots of a count vector.")

(defconst emrs-dirdiff--redraw-interval 0.2
  "Minimum seconds between redraws while items arrive.")

(defconst emrs-dirdiff--expand-depth 3
  "Directories with differences at this depth or less start expanded.")

;;;; Paths

;; Relative paths are split by hand: the file name functions consult
;; `file-name-handler-alist' on every call, which dominates a redraw.

(defun emrs-dirdiff--slash (path)
  "Return the index of the last slash in PATH, or nil."
  (let ((i (1- (length path))))
    (while (and (>= i 0) (/= (aref path i) ?/))
      (setq i (1- i)))
    (and (>= i 0) i)))

(defun emrs-dirdiff--parent (path)
  "Return the parent of the relative PATH; \"\" for a top-level entry."
  (let ((i (emrs-dirdiff--slash path)))
    (if i (substring path 0 i) "")))

(defun emrs-dirdiff--name (path)
  "Return the last component of the relative PATH."
  (let ((i (emrs-dirdiff--slash path)))
    (if i (substring path (1+ i)) path)))

(defun emrs-dirdiff--depth (path)
  "Return the depth of PATH: 1 for a top-level entry, 0 for the root."
  (if (equal path "")
      0
    (let ((depth 1))
      (dotimes (i (length path))
        (when (eq (aref path i) ?/) (setq depth (1+ depth))))
      depth)))

(defun emrs-dirdiff--root (side)
  "Return the root directory of SIDE, `a' or `b'."
  (pcase side
    ('a emrs-dirdiff--a)
    ('b emrs-dirdiff--b)
    (_ (error "Unknown side %S" side))))

(defun emrs-dirdiff--file (path side)
  "Return the absolute file name of the relative PATH on SIDE (`a' or `b').
PATH is appended to the root as it is: `expand-file-name' would turn a
top-level entry named ~ into the home directory."
  (let ((root (emrs-dirdiff--root side)))
    (if (equal path "") root (concat (file-name-as-directory root) path))))

;;;; Model

(defun emrs-dirdiff--model-clear ()
  "Forget every result of this buffer (not the fold state)."
  (setq emrs-dirdiff--items (make-hash-table :test 'equal)
        emrs-dirdiff--done (make-hash-table :test 'equal)
        emrs-dirdiff--children (make-hash-table :test 'equal)
        emrs-dirdiff--counts (make-hash-table :test 'equal)
        emrs-dirdiff--same (make-hash-table :test 'equal)
        emrs-dirdiff--summary nil
        emrs-dirdiff--rescan nil))

(defun emrs-dirdiff--index (path)
  "Record PATH and its ancestors in `emrs-dirdiff--children'."
  (unless (equal path "")
    (let* ((parent (emrs-dirdiff--parent path))
           (set (or (gethash parent emrs-dirdiff--children)
                    (puthash parent (make-hash-table :test 'equal)
                             emrs-dirdiff--children))))
      (unless (gethash path set)
        (puthash path t set)
        (emrs-dirdiff--index parent)))))

(defun emrs-dirdiff--count (item delta)
  "Add DELTA to the counts of the status of ITEM in all its ancestors."
  (let ((slot (cl-position (intern (plist-get item :status)) emrs-dirdiff--statuses))
        (path (plist-get item :path)))
    (when slot
      (while (not (equal path ""))
        (setq path (emrs-dirdiff--parent path))
        (let ((counts (or (gethash path emrs-dirdiff--counts)
                          (puthash path (make-vector (length emrs-dirdiff--statuses) 0)
                                   emrs-dirdiff--counts))))
          (cl-incf (aref counts slot) delta))))))

(defun emrs-dirdiff--add-done (path same)
  "Record that directory PATH is finished with SAME identical files below."
  (when (and emrs-dirdiff--rescan (equal path (car emrs-dirdiff--rescan)))
    (let ((delta (- same (cdr emrs-dirdiff--rescan)))
          (p path))
      (setq emrs-dirdiff--rescan nil)
      (while (not (equal p ""))
        (setq p (emrs-dirdiff--parent p))
        (when-let* ((old (gethash p emrs-dirdiff--done)))
          (puthash p (+ old delta) emrs-dirdiff--done)))))
  (puthash path same emrs-dirdiff--done)
  (emrs-dirdiff--index path))

(defun emrs-dirdiff--model-add (item)
  "Add the stream ITEM to the model."
  (let ((path (plist-get item :path))
        (status (plist-get item :status)))
    (cond
     ((plist-get item :summary)
      ;; The summary of a subtree rescan would replace the totals of the
      ;; whole comparison.
      (when (equal emrs-dirdiff--stream-path "")
        (setq emrs-dirdiff--summary item)))
     ((equal status "done")
      (emrs-dirdiff--add-done path (or (plist-get item :same) 0)))
     (path
      (when-let* ((old (gethash path emrs-dirdiff--items)))
        (emrs-dirdiff--count old -1))
      (puthash path item emrs-dirdiff--items)
      (emrs-dirdiff--count item 1)
      (emrs-dirdiff--index path)))))

(defun emrs-dirdiff--at-or-below-p (path dir)
  "Non-nil when PATH is DIR or below it."
  (or (equal dir "")
      (equal path dir)
      (string-prefix-p (concat dir "/") path)))

(defun emrs-dirdiff--model-drop (dir)
  "Forget the results at and below DIR before it is compared again."
  (let ((old-same (gethash dir emrs-dirdiff--done 0))
        (both-sides (emrs-dirdiff--expandable-p dir))
        (items emrs-dirdiff--items)
        (done emrs-dirdiff--done)
        (same emrs-dirdiff--same))
    (dolist (table (list items done same))
      (let (gone)
        (maphash (lambda (path _v)
                   (when (emrs-dirdiff--at-or-below-p path dir) (push path gone)))
                 table)
        (dolist (path gone) (remhash path table))))
    (setq emrs-dirdiff--children (make-hash-table :test 'equal)
          emrs-dirdiff--counts (make-hash-table :test 'equal)
          emrs-dirdiff--rescan (cons dir old-same))
    (maphash (lambda (_path item)
               (emrs-dirdiff--count item 1)
               (emrs-dirdiff--index (plist-get item :path)))
             items)
    (maphash (lambda (path _same) (emrs-dirdiff--index path)) done)
    ;; A directory present on both sides stays listed (comparing…) while
    ;; it is compared again; any other path comes back with its item, if
    ;; it still differs.
    (when both-sides
      (emrs-dirdiff--index dir))))

(defun emrs-dirdiff--rescan-ended (path ok)
  "Tidy the model after the rescan of PATH ended; OK when it finished.
A path that came back with no item, no `done' item and nothing below it
is gone from the comparison: it leaves its parent's children.  A
directory that did not come back takes its identical files from the
counts of its ancestors.  The parent's cached identical entries may
have been fetched during the rescan and are forgotten."
  (unless (or (gethash path emrs-dirdiff--items)
              (gethash path emrs-dirdiff--done)
              (gethash path emrs-dirdiff--children))
    (when (and ok emrs-dirdiff--rescan (equal (car emrs-dirdiff--rescan) path))
      ;; Adjusts the ancestors by the difference to the old count.
      (emrs-dirdiff--add-done path 0)
      (remhash path emrs-dirdiff--done))
    (when-let* ((set (gethash (emrs-dirdiff--parent path) emrs-dirdiff--children)))
      (remhash path set)))
  (setq emrs-dirdiff--rescan nil)
  (remhash (emrs-dirdiff--parent path) emrs-dirdiff--same))

(defun emrs-dirdiff--counts-of (path)
  "Return the count vector of the differences below PATH."
  (or (gethash path emrs-dirdiff--counts)
      (make-vector (length emrs-dirdiff--statuses) 0)))

(defun emrs-dirdiff--differences (path)
  "Return the number of differences below PATH."
  (let ((counts (gethash path emrs-dirdiff--counts))
        (sum 0))
    (when counts
      (dotimes (i (length counts))
        (setq sum (+ sum (aref counts i)))))
    sum))

(defun emrs-dirdiff--status (path)
  "Return the displayed status of PATH.
One of `changed', `only-a', `only-b', `kind', `error', `comparing' and
`same'.  A directory without an item of its own is changed when anything
below it differs, and comparing until its `done' item arrives."
  (let ((item (gethash path emrs-dirdiff--items)))
    (cond
     (item (intern (plist-get item :status)))
     ((> (emrs-dirdiff--differences path) 0) 'changed)
     ;; Every path without an item is a directory present on both sides.
     ((and (eq emrs-dirdiff--state 'running)
           (not (gethash path emrs-dirdiff--done)))
      'comparing)
     (t 'same))))

(defun emrs-dirdiff--dir-error-p (item)
  "Non-nil when ITEM is an `error' item of a directory."
  (and item
       (equal (plist-get item :status) "error")
       (equal (plist-get item :kind) "dir")))

(defun emrs-dirdiff--expandable-p (path)
  "Non-nil when PATH is a directory present on both sides.
Such a directory has no item of its own; the module reports it through
its descendants and its `done' item.  A directory that could be read
only in part has an `error' item as well, and its descendants and
`done' item; it is expandable too.  One whose listing failed as a whole
has neither."
  (let ((item (gethash path emrs-dirdiff--items)))
    (and (or (not item) (emrs-dirdiff--dir-error-p item))
         (or (gethash path emrs-dirdiff--children)
             (gethash path emrs-dirdiff--done))
         t)))

(defun emrs-dirdiff--partial-dir-p (path item)
  "Non-nil when PATH with ITEM is a directory that could be read in part."
  (and (emrs-dirdiff--dir-error-p item)
       (emrs-dirdiff--expandable-p path)))

(defun emrs-dirdiff--comparing-p (path)
  "Non-nil when PATH is a directory whose comparison has not finished."
  (and (eq emrs-dirdiff--state 'running)
       (emrs-dirdiff--expandable-p path)
       (not (gethash path emrs-dirdiff--done))))

(defun emrs-dirdiff--dir-p (path &optional item)
  "Non-nil when PATH (with its ITEM, if known) is a directory on side A or B."
  (let ((item (or item (gethash path emrs-dirdiff--items))))
    (if item
        (and (equal (plist-get item :kind) "dir")
             (not (equal (plist-get item :status) "kind")))
      (emrs-dirdiff--expandable-p path))))

(defun emrs-dirdiff--expanded-p (path)
  "Non-nil when the directory PATH is shown expanded."
  (pcase (gethash path emrs-dirdiff--folds)
    ('open t)
    ('closed nil)
    (_ (and (<= (emrs-dirdiff--depth path) emrs-dirdiff--expand-depth)
            (> (emrs-dirdiff--differences path) 0)))))

(defun emrs-dirdiff--same-items (dir)
  "Return the identical non-directory entries of DIR fetched so far."
  (let ((cached (gethash dir emrs-dirdiff--same)))
    (and (eq (car cached) 'done) (cdr cached))))

(defun emrs-dirdiff--fetch-same (dir)
  "Ask the instance once for the identical entries of DIR.
Only for a finished directory; the reply triggers a redraw."
  (when (and emrs-dirdiff--instance
             (gethash dir emrs-dirdiff--done)
             (not (gethash dir emrs-dirdiff--same))
             (memq (emrs-instance-state emrs-dirdiff--instance) '(starting running)))
    (let ((token (list 'pending))
          (buffer (current-buffer)))
      (puthash dir token emrs-dirdiff--same)
      (condition-case nil
          (emrs-call emrs-dirdiff--instance (list :same :dir dir)
                     (lambda (reply err)
                       (when (buffer-live-p buffer)
                         (with-current-buffer buffer
                           (when (eq (gethash dir emrs-dirdiff--same) token)
                             (puthash dir (cons 'done (and (not err) reply))
                                      emrs-dirdiff--same)
                             (emrs-dirdiff--schedule-redraw))))))
        (emrs-error (puthash dir (list 'done) emrs-dirdiff--same))))))

;;;; Filters

(defun emrs-dirdiff--filter-active-p ()
  "Non-nil when a name or status filter is set."
  (or emrs-dirdiff--name-regexp emrs-dirdiff--status-filter))

(defun emrs-dirdiff--match-p (path status)
  "Non-nil when the entry PATH with STATUS passes both filters.
Call it with `case-fold-search' bound as the name filter wants."
  (and (or (not emrs-dirdiff--status-filter)
           (eq status emrs-dirdiff--status-filter))
       (or (not emrs-dirdiff--name-regexp)
           (string-match-p emrs-dirdiff--name-regexp path))))

(defun emrs-dirdiff--build-keep ()
  "Return the hash table of paths the tree shows under the filters, or nil.
These are the entries that pass the filters and their ancestors."
  (when (emrs-dirdiff--filter-active-p)
    (let ((keep (make-hash-table :test 'equal)))
      (cl-flet ((mark (path)
                  (while (and (not (equal path "")) (not (gethash path keep)))
                    (puthash path t keep)
                    (setq path (emrs-dirdiff--parent path)))))
        (maphash (lambda (path item)
                   (when (emrs-dirdiff--match-p path (intern (plist-get item :status)))
                     (mark path)))
                 emrs-dirdiff--items)
        (when emrs-dirdiff--show-same
          (maphash (lambda (_dir cached)
                     (dolist (item (cdr cached))
                       (let ((path (plist-get item :path)))
                         (when (emrs-dirdiff--match-p path 'same) (mark path)))))
                   emrs-dirdiff--same)))
      keep)))

(defun emrs-dirdiff--children-of (dir)
  "Return the visible children of DIR as (PATH . ITEM) pairs, sorted by name.
ITEM is the difference or identical entry, or nil for a directory known
only from its descendants or its `done' item."
  (let (children)
    (when-let* ((set (gethash dir emrs-dirdiff--children)))
      (maphash (lambda (path _)
                 (when (and (or emrs-dirdiff--show-same
                                (not (eq (emrs-dirdiff--status path) 'same)))
                            (or (not emrs-dirdiff--keep) (gethash path emrs-dirdiff--keep)))
                   (push (cons path (gethash path emrs-dirdiff--items)) children)))
               set))
    (when emrs-dirdiff--show-same
      (emrs-dirdiff--fetch-same dir)
      (dolist (item (emrs-dirdiff--same-items dir))
        (unless (or (gethash (plist-get item :path) emrs-dirdiff--items)
                    (and emrs-dirdiff--keep
                         (not (gethash (plist-get item :path) emrs-dirdiff--keep))))
          (push (cons (plist-get item :path) item) children))))
    (sort children (lambda (x y) (string< (car x) (car y))))))

;;;; Entries at point

(defun emrs-dirdiff--path-at-point ()
  "Return the relative path of the entry at point, or nil on other lines."
  (let ((path (get-text-property (line-beginning-position) 'emrs-dirdiff-path)))
    (and path (not (equal path "")) path)))

(defun emrs-dirdiff--entry (path)
  "Return the entry of PATH as a plist (:path :status :item :dir).
ITEM is the stream item or identical entry, or nil."
  (let ((item (or (gethash path emrs-dirdiff--items)
                  (cl-find path (emrs-dirdiff--same-items (emrs-dirdiff--parent path))
                           :key (lambda (i) (plist-get i :path)) :test #'equal))))
    (list :path path
          :status (if (and item (equal (plist-get item :status) "same"))
                      'same
                    (emrs-dirdiff--status path))
          :item item
          :dir (emrs-dirdiff--dir-p path item))))

(defun emrs-dirdiff--entry-at-point ()
  "Return the entry at point (see `emrs-dirdiff--entry'), or nil."
  (when-let* ((path (emrs-dirdiff--path-at-point)))
    (emrs-dirdiff--entry path)))

;;;; Rendering

(defvar emrs-dirdiff--renderers
  '((tree . emrs-dirdiff--render-tree)
    (sections . emrs-dirdiff--render-sections))
  "Alist: view -> function inserting the body of the buffer.
A view without a renderer shows the tree.")

(defun emrs-dirdiff--status-face (status)
  "Return the face of STATUS, or nil."
  (pcase status
    ((or 'changed 'kind) 'emrs-dirdiff-changed)
    ('only-a 'emrs-dirdiff-only-a)
    ('only-b 'emrs-dirdiff-only-b)
    ('error 'emrs-dirdiff-error)
    ((or 'comparing 'same) 'emrs-dirdiff-dim)))

(defun emrs-dirdiff--letter (status)
  "Return the status letter of STATUS."
  (pcase status
    ('changed "M") ('only-a "A") ('only-b "B") ('kind "T")
    ('error "!") ('comparing "·") (_ " ")))

(defun emrs-dirdiff--human-size (n)
  "Format the byte count N in powers of 1000: 900, 4.1k, 12k, 1.4M."
  (if (< n 1000)
      (number-to-string n)
    (let ((units '("k" "M" "G" "T" "P" "E"))
          (x (/ n 1000.0)))
      (while (and (>= x 999.5) (cdr units))
        (setq x (/ x 1000.0)
              units (cdr units)))
      (if (< x 9.95)
          (format "%.1f%s" x (car units))
        (format "%d%s" (round x) (car units))))))

(defun emrs-dirdiff--size (side)
  "Format the size in the side plist SIDE, or nil."
  (when-let* ((size (plist-get side :size)))
    (emrs-dirdiff--human-size size)))

(defun emrs-dirdiff--plural (n word)
  "Return N followed by WORD, with an s when N is not 1."
  (format "%d %s%s" n word (if (= n 1) "" "s")))

(defun emrs-dirdiff--count-labels (counts labels)
  "Return the nonzero COUNTS labelled with LABELS, a list of strings."
  (let (parts)
    (dotimes (i (length counts))
      (let ((n (aref counts i)))
        (when (> n 0)
          (push (if (eq (aref emrs-dirdiff--statuses i) 'error)
                    (emrs-dirdiff--plural n "error")
                  (format "%d %s" n (nth i labels)))
                parts))))
    (nreverse parts)))

(defun emrs-dirdiff--dir-summary (path)
  "Return the summary of the differences below the directory PATH."
  (let* ((parts (emrs-dirdiff--count-labels
                 (emrs-dirdiff--counts-of path)
                 '("changed" "only A" "only B" "kind" "error")))
         (comparing (and (eq emrs-dirdiff--state 'running)
                         (not (gethash path emrs-dirdiff--done)))))
    (cond
     (parts (concat (mapconcat #'identity parts ", ")
                    (if comparing ", comparing…" "")))
     (comparing "comparing…")
     ((gethash path emrs-dirdiff--done)
      (format "%d same" (gethash path emrs-dirdiff--done)))
     (t ""))))

(defun emrs-dirdiff--details (path status item dir)
  "Return the right-hand text of the line of PATH (STATUS, ITEM, DIR).
It is a fresh string: rendering adds properties to it in place."
  (pcase status
    ('error (propertize (or (plist-get item :message) "error") 'face 'emrs-dirdiff-error))
    (_
     (let ((text
            (cond
             ((and dir (not item)) (emrs-dirdiff--dir-summary path))
             ((eq status 'changed)
              ;; concat, not format: this runs for every changed file.
              (let ((sizes (concat (or (emrs-dirdiff--size (plist-get item :a)) "?")
                                   " → "
                                   (or (emrs-dirdiff--size (plist-get item :b)) "?")))
                    (lines (plist-get item :lines)))
                (if lines
                    (concat sizes (make-string (max 1 (- 14 (length sizes))) ?\s)
                            "+" (number-to-string (car lines))
                            " −" (number-to-string (cadr lines)))
                  sizes)))
             ((eq status 'kind)
              (format "kind differs (A: %s)" (or (plist-get item :kind) "?")))
             ((plist-get item :files)
              (emrs-dirdiff--plural (plist-get item :files) "file"))
             (t (or (emrs-dirdiff--size (or (plist-get item :a) (plist-get item :b))) "")))))
       (if (equal text "")
           text
         (propertize text 'face 'emrs-dirdiff-dim))))))

(defun emrs-dirdiff--mark-text (path)
  "Return the one-column mark text of PATH: `*' when marked, else a space."
  (if (and emrs-dirdiff--marks (gethash path emrs-dirdiff--marks))
      (propertize "*" 'face 'emrs-dirdiff-mark)
    " "))

(defun emrs-dirdiff--tree-rows (dir depth rows)
  "Push the rows of the visible entries of DIR (at DEPTH) onto ROWS.
Return ROWS.  A row is a vector [PATH DEPTH STATUS ITEM DIR MARKER NAME
WIDTH], where NAME is the displayed name and WIDTH the width of the
text left of the details."
  (let ((prefix (if (equal dir "") 0 (1+ (length dir)))))
    (dolist (child (emrs-dirdiff--children-of dir))
      (let* ((path (car child))
             (item (cdr child))
             (status (if (and item (equal (plist-get item :status) "same"))
                         'same
                       (emrs-dirdiff--status path)))
             (is-dir (emrs-dirdiff--dir-p path item))
             (expandable (and (or (not item) (emrs-dirdiff--dir-error-p item))
                              (emrs-dirdiff--expandable-p path)))
             (open (and expandable (emrs-dirdiff--expanded-p path)))
             (name (if is-dir
                       (concat (substring path prefix) "/")
                     (substring path prefix))))
        (push (vector path depth status item is-dir
                      (cond (open "▾ ") (expandable "▸ ") (t "  "))
                      name
                      (+ 5 (* 2 (1- depth)) (string-width name)))
              rows)
        (when open
          (setq rows (emrs-dirdiff--tree-rows path (1+ depth) rows))))))
  rows)

(defconst emrs-dirdiff--indents
  (let ((v (make-vector 32 nil)))
    (dotimes (i 32) (aset v i (make-string (* 2 i) ?\s)))
    v)
  "Indentation strings by depth, to save allocating them per line.")

(defun emrs-dirdiff--indent (n)
  "Return a string of 2 × N spaces."
  (if (< n 32) (aref emrs-dirdiff--indents n) (make-string (* 2 n) ?\s)))

(defun emrs-dirdiff--render-tree ()
  "Insert the tree view of the model."
  (let* ((rows (nreverse (emrs-dirdiff--tree-rows "" 1 nil)))
         (width 0)
         (index emrs-dirdiff--line-index))
    (dolist (row rows)
      (setq width (max width (aref row 7))))
    (setq width (min 60 (max 28 (+ width 2))))
    (dolist (row rows)
      (let* ((path (aref row 0))
             (status (aref row 2))
             (face (emrs-dirdiff--status-face status))
             (dim (memq status '(comparing same)))
             (details (emrs-dirdiff--details path status (aref row 3) (aref row 4)))
             (line (concat (propertize (emrs-dirdiff--letter status) 'face face)
                           (emrs-dirdiff--mark-text path) " "
                           (emrs-dirdiff--indent (1- (aref row 1)))
                           (if dim (propertize (aref row 5) 'face face) (aref row 5))
                           (if (or dim (memq status '(only-a only-b)))
                               (propertize (aref row 6) 'face face)
                             (aref row 6))
                           (if (equal details "")
                               ""
                             (make-string (max 2 (- width (aref row 7))) ?\s))
                           details
                           "\n")))
        (puthash path (point) index)
        (put-text-property 0 (length line) 'emrs-dirdiff-path path line)
        (insert line)))))

;;;; Section view

(defconst emrs-dirdiff--sections
  '((changed "Changed") (only-a "Only in A") (only-b "Only in B")
    (kind "Kind differs") (error "Errors") (same "Same"))
  "The sections of the section view, in order: (SYMBOL TITLE).")

(defun emrs-dirdiff--section-open-p (section)
  "Non-nil when SECTION is shown unfolded.  Same starts folded."
  (pcase (gethash section emrs-dirdiff--section-folds)
    ('open t)
    ('closed nil)
    (_ (not (eq section 'same)))))

(defun emrs-dirdiff--same-shown-p ()
  "Non-nil when identical entries are shown in the current view."
  (if (eq emrs-dirdiff--view 'sections)
      (emrs-dirdiff--section-open-p 'same)
    emrs-dirdiff--show-same))

(defun emrs-dirdiff--section-same-rows ()
  "Return the identical files of all finished directories as (PATH . ITEM).
Ask for the `:same' entries of every finished directory not yet fetched;
replies arrive later and redraw."
  (let (dirs rows)
    (maphash (lambda (dir _same) (push dir dirs)) emrs-dirdiff--done)
    (dolist (dir dirs)
      (emrs-dirdiff--fetch-same dir))
    (maphash (lambda (_dir cached)
               (dolist (item (cdr cached))
                 (let ((path (plist-get item :path)))
                   (when (and (not (gethash path emrs-dirdiff--items))
                              (emrs-dirdiff--match-p path 'same))
                     (push (cons path item) rows)))))
             emrs-dirdiff--same)
    rows))

(defun emrs-dirdiff--section-rows ()
  "Return an alist from section symbol to its rows (PATH . ITEM), sorted by path.
Applies the filters.  The rows of `same' exist only when it is unfolded."
  (let (groups)
    (maphash (lambda (path item)
               (let ((status (intern (plist-get item :status))))
                 (when (and (not (equal path ""))
                            (emrs-dirdiff--match-p path status))
                   (push (cons path item) (alist-get status groups)))))
             emrs-dirdiff--items)
    (when (and (not emrs-dirdiff--status-filter)
               (emrs-dirdiff--section-open-p 'same))
      (when-let* ((rows (emrs-dirdiff--section-same-rows)))
        (setf (alist-get 'same groups) rows)))
    (dolist (group groups)
      (setcdr group (sort (cdr group) (lambda (x y) (string< (car x) (car y))))))
    groups))

(defun emrs-dirdiff--section-line (row width status)
  "Return the line of ROW (PATH . ITEM) with STATUS, details at WIDTH."
  (let* ((path (car row))
         (item (cdr row))
         (dir (emrs-dirdiff--dir-p path item))
         (name (if dir (concat path "/") path))
         (face (emrs-dirdiff--status-face status))
         (details (emrs-dirdiff--details path status item dir))
         (line (concat "  " (emrs-dirdiff--mark-text path) " "
                       (if (memq status '(only-a only-b same))
                           (propertize name 'face face)
                         name)
                       (if (equal details "")
                           ""
                         (make-string (max 2 (- width 4 (string-width name))) ?\s))
                       details
                       "\n")))
    (put-text-property 0 (length line) 'emrs-dirdiff-path path line)
    line))

(defun emrs-dirdiff--render-sections ()
  "Insert the section view of the model."
  (let* ((groups (emrs-dirdiff--section-rows))
         (same-total (gethash "" emrs-dirdiff--done))
         (width 0)
         (first t)
         (index emrs-dirdiff--line-index))
    (dolist (group groups)
      (dolist (row (cdr group))
        (setq width (max width (+ 4 (string-width (car row)) 1)))))
    (setq width (min 70 (max 32 (+ width 2))))
    (dolist (entry emrs-dirdiff--sections)
      (let* ((section (car entry))
             (rows (cdr (assq section groups)))
             (same (eq section 'same))
             (count (if same (or same-total 0) (length rows))))
        (when (and (> count 0)
                   (or rows (not same) (not emrs-dirdiff--status-filter)))
          (unless first (insert "\n"))
          (setq first nil)
          (let* ((open (emrs-dirdiff--section-open-p section))
                 (face (emrs-dirdiff--status-face section))
                 (head (concat (if open "▾ " "▸ ")
                               (propertize (format "%s (%d)" (cadr entry) count)
                                           'face (list face 'bold))
                               "\n")))
            (puthash section (point) index)
            (put-text-property 0 (length head) 'emrs-dirdiff-path "" head)
            (put-text-property 0 (length head) 'emrs-dirdiff-section section head)
            (insert head)
            (when open
              (dolist (row rows)
                (let ((line (emrs-dirdiff--section-line row width section)))
                  (puthash (car row) (point) index)
                  (insert line))))))))))

(defun emrs-dirdiff--root-label (dir)
  "Return the abbreviated DIR with its last component in bold."
  (let* ((name (directory-file-name (abbreviate-file-name dir)))
         (base (file-name-nondirectory name)))
    (concat (propertize (substring name 0 (- (length name) (length base)))
                        'face 'emrs-dirdiff-dim)
            (propertize base 'face 'bold))))

(defun emrs-dirdiff--elapsed ()
  "Return the seconds the last comparison took or has taken so far."
  (cond
   (emrs-dirdiff--summary (plist-get emrs-dirdiff--summary :seconds))
   (emrs-dirdiff--started
    (- (or emrs-dirdiff--ended (float-time)) emrs-dirdiff--started))
   (t 0)))

(defun emrs-dirdiff--status-line ()
  "Return the second header line: progress and counts."
  (let* ((counts (emrs-dirdiff--counts-of ""))
         (total (apply #'+ (append counts nil)))
         (faces '(emrs-dirdiff-changed emrs-dirdiff-only-a emrs-dirdiff-only-b
                                       emrs-dirdiff-changed emrs-dirdiff-error))
         (labels (emrs-dirdiff--count-labels
                  counts '("changed" "only in A" "only in B" "kind differs" "error")))
         (parts (let ((i -1) out)
                  ;; Pair each label with the face of its slot.
                  (dotimes (slot (length counts))
                    (when (> (aref counts slot) 0)
                      (push (propertize (nth (cl-incf i) labels) 'face (nth slot faces)) out)))
                  (nreverse out)))
         (same (gethash "" emrs-dirdiff--done))
         (same-part (and same (propertize (format "%d same (%s)" same
                                                  (if (emrs-dirdiff--same-shown-p) "shown" "hidden"))
                                          'face 'emrs-dirdiff-dim)))
         (root-error (let ((item (gethash "" emrs-dirdiff--items)))
                       (and item (or (plist-get item :message) "cannot be read"))))
         (subtree (and (not (equal emrs-dirdiff--stream-path ""))
                       emrs-dirdiff--stream-path))
         (counts-text (mapconcat #'identity (delq nil (append parts (list same-part))) " · ")))
    (cond
     (emrs-dirdiff--instance-error
      (concat (propertize (format "Error: %s" emrs-dirdiff--instance-error)
                          'face 'emrs-dirdiff-error)
              (propertize "   g to restart" 'face 'emrs-dirdiff-dim)))
     ((eq emrs-dirdiff--state 'running)
      (concat (propertize (if subtree (format "Comparing %s…" subtree) "Comparing…")
                          'face 'bold)
              (format " %s so far" (emrs-dirdiff--plural total "difference"))
              (if parts (concat " · " (mapconcat #'identity parts " · ")) "")
              ;; The elapsed time is that of the whole comparison.
              (if subtree "" (format " · %.1f s" (emrs-dirdiff--elapsed)))
              (propertize "   C-c C-k to stop" 'face 'emrs-dirdiff-dim)))
     ((eq emrs-dirdiff--state 'failed)
      (concat (propertize (format "Comparison failed: %s" emrs-dirdiff--error)
                          'face 'emrs-dirdiff-error)
              (propertize "   g to compare again" 'face 'emrs-dirdiff-dim)))
     (root-error
      (concat (propertize (format "Error: the roots cannot be compared: %s" root-error)
                          'face 'emrs-dirdiff-error)
              (propertize "   g to compare again" 'face 'emrs-dirdiff-dim)))
     ((eq emrs-dirdiff--state 'stopped)
      (concat (if subtree
                  (format "Stopped comparing %s" subtree)
                (format "Stopped after %.1f s" (emrs-dirdiff--elapsed)))
              (format " · %s so far" (emrs-dirdiff--plural total "difference"))
              (if parts (concat " · " (mapconcat #'identity parts " · ")) "")))
     (t
      (concat (if (and (= total 0) (eq emrs-dirdiff--state 'done))
                  (concat "No differences" (if same-part " · " ""))
                "")
              counts-text)))))

(defun emrs-dirdiff--filter-text ()
  "Return the header text naming the active filters, or an empty string."
  (if (not (emrs-dirdiff--filter-active-p))
      ""
    (propertize
     (concat "   filter: "
             (mapconcat
              #'identity
              (delq nil
                    (list (and emrs-dirdiff--name-filter
                               (format "%S" emrs-dirdiff--name-filter))
                          (pcase emrs-dirdiff--status-filter
                            ('changed "only changed")
                            ('only-a "only in A")
                            ('only-b "only in B"))))
              " · "))
     'face 'bold)))

(defun emrs-dirdiff--insert-header ()
  "Insert the header: both roots, then progress and counts."
  (let ((start (point)))
    (insert (propertize "A" 'face 'bold) " " (emrs-dirdiff--root-label emrs-dirdiff--a)
            "    " (propertize "B" 'face 'bold) " " (emrs-dirdiff--root-label emrs-dirdiff--b)
            "\n" (emrs-dirdiff--status-line) (emrs-dirdiff--filter-text) "\n\n")
    (put-text-property start (point) 'emrs-dirdiff-path "")))

(defun emrs-dirdiff--mode-line ()
  "Return the `mode-line-process' text: method, ignore files and timing."
  (concat " "
          (if (eq emrs-dirdiff--by 'size-time) "size+time" "content")
          " · ignore files " (if emrs-dirdiff--ignore-files "on" "off")
          (if emrs-dirdiff--whitespace " · whitespace ignored" "")
          (cond
           ((eq emrs-dirdiff--state 'running) " · running")
           ((and (eq emrs-dirdiff--state 'done) emrs-dirdiff--summary)
            (format " · %d files in %.1f s"
                    (plist-get emrs-dirdiff--summary :files)
                    (plist-get emrs-dirdiff--summary :seconds)))
           ((eq emrs-dirdiff--state 'stopped) " · stopped")
           (t ""))))

(defun emrs-dirdiff--position-key (pos)
  "Return (PATH LINE COLUMN SECTION) describing POS, to find it after a redraw.
SECTION is the section whose header is at POS, or nil."
  (save-excursion
    (goto-char pos)
    (list (get-text-property (line-beginning-position) 'emrs-dirdiff-path)
          (line-number-at-pos)
          (current-column)
          (get-text-property (line-beginning-position) 'emrs-dirdiff-section))))

(defun emrs-dirdiff--position-find (key &optional exact)
  "Return the position KEY describes in the redrawn buffer.
The line of the same path, else of its nearest visible ancestor, else
the same line number.  With EXACT, return nil unless the path's own
line exists."
  (pcase-let ((`(,path ,line ,column ,section) key))
    (let ((pos nil))
      (when (and path (not (equal path "")))
        (setq pos (gethash path emrs-dirdiff--line-index))
        (unless exact
          (while (and (not pos) (not (equal path "")))
            (setq path (emrs-dirdiff--parent path)
                  pos (gethash path emrs-dirdiff--line-index)))))
      (when (and section (not pos))
        (setq pos (gethash section emrs-dirdiff--line-index)))
      (unless (and exact (not pos))
        (save-excursion
          (if pos
              (goto-char pos)
            (goto-char (point-min))
            (forward-line (1- line)))
          (move-to-column column)
          (point))))))

(defvar-local emrs-dirdiff--wanted nil
  "(POS . KEY): the redraw put point at POS because the line of KEY's
path was missing.  While point stays at POS, later redraws look for KEY
again, so point returns to its entry once it reappears (after `g').")

(defun emrs-dirdiff--point-key ()
  "Return the position key of point, preferring a pending wanted one."
  (if (and emrs-dirdiff--wanted (eql (point) (car emrs-dirdiff--wanted)))
      (cdr emrs-dirdiff--wanted)
    (emrs-dirdiff--position-key (point))))

(defun emrs-dirdiff--redraw ()
  "Redraw the buffer now, keeping point and window starts on their paths."
  (when emrs-dirdiff--redraw-timer
    (cancel-timer emrs-dirdiff--redraw-timer)
    (setq emrs-dirdiff--redraw-timer nil))
  (let* ((inhibit-read-only t)
         (old-point (point))
         (point-key (emrs-dirdiff--point-key))
         (windows (mapcar (lambda (w)
                            (list w
                                  (if (eql (window-point w) old-point)
                                      point-key
                                    (emrs-dirdiff--position-key (window-point w)))
                                  (emrs-dirdiff--position-key (window-start w))))
                          (get-buffer-window-list nil nil t))))
    (setq emrs-dirdiff--line-index (make-hash-table :test 'equal))
    (erase-buffer)
    (emrs-dirdiff--insert-header)
    (let ((case-fold-search emrs-dirdiff--name-fold))
      (setq emrs-dirdiff--keep (emrs-dirdiff--build-keep))
      (unwind-protect
          (funcall (alist-get emrs-dirdiff--view emrs-dirdiff--renderers
                              #'emrs-dirdiff--render-tree))
        (setq emrs-dirdiff--keep nil)))
    (goto-char (emrs-dirdiff--position-find point-key))
    (setq emrs-dirdiff--wanted
          (and (nth 0 point-key)
               (or (not (equal (nth 0 point-key) "")) (nth 3 point-key))
               (not (emrs-dirdiff--position-find point-key t))
               (cons (point) point-key)))
    (dolist (w windows)
      (set-window-start (nth 0 w) (emrs-dirdiff--position-find (nth 2 w)) t)
      (set-window-point (nth 0 w) (emrs-dirdiff--position-find (nth 1 w)))))
  (setq mode-line-process (emrs-dirdiff--mode-line)
        emrs-dirdiff--last-redraw (float-time)
        emrs-dirdiff--dirty nil)
  (force-mode-line-update))

(defun emrs-dirdiff--shown-p (buffer)
  "Non-nil when a window on any frame shows BUFFER."
  (get-buffer-window buffer t))

(defun emrs-dirdiff--redraw-buffer (buffer)
  "Redraw BUFFER if it is live and shown; else note that it needs one.
`emrs-dirdiff--on-shown' redraws it when a window shows it again."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq emrs-dirdiff--redraw-timer nil)
      (if (emrs-dirdiff--shown-p buffer)
          (emrs-dirdiff--redraw)
        (setq emrs-dirdiff--dirty t)))))

(defun emrs-dirdiff--on-shown (window)
  "Redraw the buffer of WINDOW if a redraw was skipped while it was hidden.
In the buffer-local `window-buffer-change-functions'."
  (let ((buffer (window-buffer window)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when emrs-dirdiff--dirty
          (emrs-dirdiff--redraw))))))

(defun emrs-dirdiff--schedule-redraw (&optional soon)
  "Redraw within `emrs-dirdiff--redraw-interval' of the last redraw.
With SOON, redraw as soon as Emacs is idle from the current callback, so
the redraw does not add to the time spent in it."
  (when (and soon emrs-dirdiff--redraw-timer)
    (cancel-timer emrs-dirdiff--redraw-timer)
    (setq emrs-dirdiff--redraw-timer nil))
  (unless emrs-dirdiff--redraw-timer
    (setq emrs-dirdiff--redraw-timer
          (run-at-time (if soon
                           0
                         (max 0 (- (+ emrs-dirdiff--last-redraw emrs-dirdiff--redraw-interval)
                                   (float-time))))
                       nil #'emrs-dirdiff--redraw-buffer (current-buffer)))))

;;;; Comparing

(defun emrs-dirdiff--cancel-timers ()
  "Cancel the redraw and tick timers."
  (dolist (timer (list emrs-dirdiff--redraw-timer emrs-dirdiff--tick-timer))
    (when timer (cancel-timer timer)))
  (setq emrs-dirdiff--redraw-timer nil
        emrs-dirdiff--tick-timer nil))

(defun emrs-dirdiff--cancel-stream ()
  "Cancel the running comparison without reporting it as stopped."
  (when-let* ((call emrs-dirdiff--stream))
    (setq emrs-dirdiff--stream nil)
    (emrs-cancel call))
  (when emrs-dirdiff--tick-timer
    (cancel-timer emrs-dirdiff--tick-timer)
    (setq emrs-dirdiff--tick-timer nil)))

(defun emrs-dirdiff--ensure-instance ()
  "Start an instance for this buffer unless one is starting or running.
On failure, record the message in `emrs-dirdiff--instance-error'."
  (unless (and emrs-dirdiff--instance
               (memq (emrs-instance-state emrs-dirdiff--instance) '(starting running)))
    (setq emrs-dirdiff--instance nil
          emrs-dirdiff--instance-error nil)
    (let ((buffer (current-buffer)))
      (condition-case err
          (setq emrs-dirdiff--instance
                (emrs-dirdiff--start
                 (directory-file-name emrs-dirdiff--a)
                 (directory-file-name emrs-dirdiff--b)
                 (lambda (instance status err)
                   (when (buffer-live-p buffer)
                     (with-current-buffer buffer
                       (when (eq instance emrs-dirdiff--instance)
                         (setq emrs-dirdiff--instance-error
                               (if (eq status 'failed)
                                   (or (plist-get err :message) "The instance failed")
                                 "The instance stopped"))
                         (emrs-dirdiff--schedule-redraw)))))))
        (error (setq emrs-dirdiff--instance-error (error-message-string err)))))))

(defun emrs-dirdiff--request (path)
  "Return the `:compare' request for PATH with this buffer's settings."
  (list :compare :path path
        :by (if (eq emrs-dirdiff--by 'size-time) :size-time :content)
        :ignore-files (and emrs-dirdiff--ignore-files t)
        :whitespace (and emrs-dirdiff--whitespace t)
        :hidden (and emrs-dirdiff--hidden t)))

(defun emrs-dirdiff--on-end (status err)
  "Record that the comparison ended with STATUS and ERR, and redraw."
  (let ((path emrs-dirdiff--stream-path))
    (setq emrs-dirdiff--stream nil)
    (when (equal path "")
      (setq emrs-dirdiff--ended (float-time)))
    (pcase status
      ('done (setq emrs-dirdiff--state 'done))
      ('cancelled (setq emrs-dirdiff--state 'stopped))
      (_ (if (equal (plist-get err :message) "cancelled")
             (setq emrs-dirdiff--state 'stopped)
           (setq emrs-dirdiff--state 'failed
                 emrs-dirdiff--error (or (plist-get err :message) "unknown error")))))
    (emrs-dirdiff--cancel-timers)
    (unless (equal path "")
      (emrs-dirdiff--rescan-ended path (eq status 'done)))
    ;; A stopped comparison stops the rescans waiting behind it too.
    (when (eq emrs-dirdiff--state 'stopped)
      (setq emrs-dirdiff--rescan-queue nil))
    (when (and (eq emrs-dirdiff--state 'done) (null emrs-dirdiff--rescan-queue))
      (emrs-dirdiff--prune-marks))
    (cond
     ;; Rescans queued by an action run one after the other; the next one
     ;; redraws.
     (emrs-dirdiff--rescan-queue (emrs-dirdiff--drain-rescans))
     ;; A stop from `emrs-dirdiff-stop' shows at once; the end of a stream
     ;; arrives with its last batch, so redraw in a timer slot of its own.
     ((eq status 'cancelled) (emrs-dirdiff--redraw))
     (t (emrs-dirdiff--schedule-redraw t)))))

(defun emrs-dirdiff--compare (&optional path)
  "Compare the subtree at PATH again (default \"\": everything).
Cancels a running comparison, drops the results at and below PATH and
starts the instance first if it is not running."
  (let ((path (or path ""))
        (buffer (current-buffer)))
    (emrs-dirdiff--cancel-stream)
    (if (equal path "")
        (progn (setq emrs-dirdiff--rescan-queue nil)
               (emrs-dirdiff--model-clear))
      (emrs-dirdiff--model-drop path))
    (emrs-dirdiff--ensure-instance)
    (setq emrs-dirdiff--state nil
          emrs-dirdiff--error nil
          emrs-dirdiff--stream-path path)
    ;; The elapsed time is that of the last comparison of everything.
    (when (equal path "")
      (setq emrs-dirdiff--started (float-time)
            emrs-dirdiff--ended nil))
    (when emrs-dirdiff--instance
      (condition-case err
          (let (call)
            (setq call (emrs-call-stream
                        emrs-dirdiff--instance (emrs-dirdiff--request path)
                        :on-batch (lambda (items)
                                    (when (buffer-live-p buffer)
                                      (with-current-buffer buffer
                                        (when (eq call emrs-dirdiff--stream)
                                          (dolist (item items)
                                            (emrs-dirdiff--model-add item))
                                          (emrs-dirdiff--schedule-redraw)))))
                        :on-end (lambda (status err)
                                  (when (buffer-live-p buffer)
                                    (with-current-buffer buffer
                                      (when (eq call emrs-dirdiff--stream)
                                        (emrs-dirdiff--on-end status err)))))))
            (setq emrs-dirdiff--stream call
                  emrs-dirdiff--state 'running
                  emrs-dirdiff--tick-timer
                  (run-at-time 1 1 (lambda ()
                                     (when (buffer-live-p buffer)
                                       (with-current-buffer buffer
                                         (if (emrs-dirdiff--shown-p buffer)
                                             (emrs-dirdiff--schedule-redraw)
                                           (setq emrs-dirdiff--dirty t))))))))
        (emrs-error
         (setq emrs-dirdiff--state 'failed
               emrs-dirdiff--error (nth 2 err)))))
    (emrs-dirdiff--redraw)))

(defun emrs-dirdiff--kill ()
  "Stop the comparison and the instance of this buffer.
In `kill-buffer-hook' and `change-major-mode-hook'."
  (emrs-dirdiff--cancel-timers)
  (ignore-errors (emrs-dirdiff--cancel-stream))
  (when emrs-dirdiff--instance
    (let ((instance emrs-dirdiff--instance))
      (setq emrs-dirdiff--instance nil)
      (emrs-dirdiff--stop instance))))

;;;; Commands in the buffer

(defun emrs-dirdiff--section-at-point ()
  "Return the section whose header is on this line, or nil."
  (get-text-property (line-beginning-position) 'emrs-dirdiff-section))

(defun emrs-dirdiff--toggle-section (section)
  "Fold SECTION if it is open, else unfold it."
  (puthash section (if (emrs-dirdiff--section-open-p section) 'closed 'open)
           emrs-dirdiff--section-folds)
  (emrs-dirdiff--redraw))

(defun emrs-dirdiff-toggle-fold ()
  "Fold or unfold the directory (tree view) or section (section view) at point."
  (interactive nil emrs-dirdiff-mode)
  (if-let* ((section (emrs-dirdiff--section-at-point)))
      (emrs-dirdiff--toggle-section section)
    (when (eq emrs-dirdiff--view 'sections)
      (user-error "Nothing to fold here; TAB folds a section header"))
    (let ((path (emrs-dirdiff--path-at-point)))
      (unless (and path (emrs-dirdiff--expandable-p path))
        (user-error "No directory present on both sides at point"))
      (puthash path (if (emrs-dirdiff--expanded-p path) 'closed 'open) emrs-dirdiff--folds)
      (emrs-dirdiff--redraw))))

(defun emrs-dirdiff--fold-directories ()
  "Return every directory below the root that can be folded."
  (let (dirs)
    (maphash (lambda (path _)
               (when (and (not (equal path ""))
                          (emrs-dirdiff--expandable-p path))
                 (push path dirs)))
             emrs-dirdiff--children)
    dirs))

(defun emrs-dirdiff--visibly-expanded-p (path)
  "Non-nil when PATH and every directory above it are expanded."
  (and (emrs-dirdiff--expanded-p path)
       (let ((parent (emrs-dirdiff--parent path)))
         (or (equal parent "") (emrs-dirdiff--visibly-expanded-p parent)))))

(defun emrs-dirdiff-toggle-fold-all ()
  "Fold everything when anything shown is unfolded, else unfold everything.
In the tree view this applies to every directory, in the section view to
every section.  A directory unfolded inside a folded one does not count."
  (interactive nil emrs-dirdiff-mode)
  (if (eq emrs-dirdiff--view 'sections)
      (let* ((sections (mapcar #'car emrs-dirdiff--sections))
             (state (if (seq-some #'emrs-dirdiff--section-open-p sections)
                        'closed
                      'open)))
        (dolist (section sections)
          (puthash section state emrs-dirdiff--section-folds))
        (message "All sections %s" (if (eq state 'open) "unfolded" "folded")))
    (let* ((dirs (emrs-dirdiff--fold-directories))
           (state (if (seq-some #'emrs-dirdiff--visibly-expanded-p dirs)
                      'closed
                    'open)))
      (dolist (dir dirs)
        (puthash dir state emrs-dirdiff--folds))
      (message "All directories %s" (if (eq state 'open) "expanded" "collapsed"))))
  (emrs-dirdiff--redraw))

(defun emrs-dirdiff-toggle-same ()
  "Toggle showing the identical entries.
In the section view this folds or unfolds the Same section."
  (interactive nil emrs-dirdiff-mode)
  (if (eq emrs-dirdiff--view 'sections)
      (emrs-dirdiff--toggle-section 'same)
    (setq emrs-dirdiff--show-same (not emrs-dirdiff--show-same))
    (emrs-dirdiff--redraw))
  (message "Identical entries %s" (if (emrs-dirdiff--same-shown-p) "shown" "hidden")))

(defun emrs-dirdiff-toggle-view ()
  "Switch between the tree view and the section view.
Point stays on the same path; when the new view does not show it, on the
nearest entry line."
  (interactive nil emrs-dirdiff-mode)
  (setq emrs-dirdiff--view (if (eq emrs-dirdiff--view 'sections) 'tree 'sections))
  (emrs-dirdiff--redraw)
  (unless (emrs-dirdiff--path-at-point)
    (unless (emrs-dirdiff--next-line-where #'emrs-dirdiff--path-at-point 1)
      (emrs-dirdiff--next-line-where #'emrs-dirdiff--path-at-point -1)))
  (message "%s view" (if (eq emrs-dirdiff--view 'sections) "Section" "Tree")))

;;;; Navigation

(defun emrs-dirdiff--next-line-where (predicate direction)
  "Move to the next line (DIRECTION 1) or previous one (-1) where PREDICATE holds.
PREDICATE is called with point at the start of the line.  Return the
new position, or nil and leave point where it was."
  (let ((start (point)) found)
    (while (and (not found) (zerop (forward-line direction)))
      (when (and (not (eobp)) (funcall predicate))
        (setq found (point))))
    (unless found (goto-char start))
    found))

(defun emrs-dirdiff--difference-p ()
  "Non-nil when the entry on this line is a difference.
A directory counts when differences are below it; a line being compared
or identical does not."
  (when-let* ((path (emrs-dirdiff--path-at-point)))
    (let ((item (gethash path emrs-dirdiff--items)))
      (memq (if item (intern (plist-get item :status)) (emrs-dirdiff--status path))
            '(changed only-a only-b kind error)))))

(defun emrs-dirdiff--directory-difference-p ()
  "Non-nil on the line of a directory present on both sides with differences."
  (when-let* ((path (emrs-dirdiff--path-at-point)))
    (and (emrs-dirdiff--expandable-p path)
         (> (emrs-dirdiff--differences path) 0))))

(defun emrs-dirdiff--move (predicate direction what)
  "Move to the next line in DIRECTION where PREDICATE holds.
Signal a `user-error' naming WHAT when there is none."
  (beginning-of-line)
  (unless (emrs-dirdiff--next-line-where predicate direction)
    (user-error "No %s %s" (if (> direction 0) "next" "previous") what)))

(defun emrs-dirdiff-next-difference ()
  "Move to the next entry that is a difference."
  (interactive nil emrs-dirdiff-mode)
  (emrs-dirdiff--move #'emrs-dirdiff--difference-p 1 "difference"))

(defun emrs-dirdiff-previous-difference ()
  "Move to the previous entry that is a difference."
  (interactive nil emrs-dirdiff-mode)
  (emrs-dirdiff--move #'emrs-dirdiff--difference-p -1 "difference"))

(defun emrs-dirdiff-next-group ()
  "Move to the next directory with differences or section header.
In the tree view it goes to directories, in the section view to headers."
  (interactive nil emrs-dirdiff-mode)
  (if (eq emrs-dirdiff--view 'sections)
      (emrs-dirdiff--move #'emrs-dirdiff--section-at-point 1 "section")
    (emrs-dirdiff--move #'emrs-dirdiff--directory-difference-p 1 "directory with differences")))

(defun emrs-dirdiff-previous-group ()
  "Move to the previous directory with differences or section header."
  (interactive nil emrs-dirdiff-mode)
  (if (eq emrs-dirdiff--view 'sections)
      (emrs-dirdiff--move #'emrs-dirdiff--section-at-point -1 "section")
    (emrs-dirdiff--move #'emrs-dirdiff--directory-difference-p -1 "directory with differences")))

(defun emrs-dirdiff-up ()
  "Move to the line of the parent directory (tree view)."
  (interactive nil emrs-dirdiff-mode)
  (when (eq emrs-dirdiff--view 'sections)
    (user-error "The section view has no parent directories"))
  (let ((path (emrs-dirdiff--path-at-point)))
    (unless path (user-error "No entry at point"))
    (let* ((parent (emrs-dirdiff--parent path))
           (pos (and (not (equal parent "")) (gethash parent emrs-dirdiff--line-index))))
      (unless pos (user-error "%s is at the top level" path))
      (goto-char pos))))

;;;; Filters

(defun emrs-dirdiff-filter-name (substring)
  "Show only entries whose relative path contains SUBSTRING; \"\" clears.
The match ignores case unless SUBSTRING has an uppercase letter.  The
tree keeps the ancestors of matching entries."
  (interactive (list (read-string
                      (if emrs-dirdiff--name-filter
                          (format "Filter by name (now \"%s\"; empty clears): "
                                  emrs-dirdiff--name-filter)
                        "Filter by name: ")
                      nil nil nil))
               emrs-dirdiff-mode)
  (if (equal substring "")
      (setq emrs-dirdiff--name-filter nil
            emrs-dirdiff--name-regexp nil
            emrs-dirdiff--name-fold nil)
    (setq emrs-dirdiff--name-filter substring
          emrs-dirdiff--name-regexp (regexp-quote substring)
          emrs-dirdiff--name-fold (let ((case-fold-search nil))
                                    (not (string-match-p "[[:upper:]]" substring)))))
  (emrs-dirdiff--redraw))

(defun emrs-dirdiff-cycle-status-filter ()
  "Cycle the status filter: all, changed, only in A, only in B, all."
  (interactive nil emrs-dirdiff-mode)
  (setq emrs-dirdiff--status-filter
        (pcase emrs-dirdiff--status-filter
          ('nil 'changed) ('changed 'only-a) ('only-a 'only-b) (_ nil)))
  (emrs-dirdiff--redraw)
  (message "Showing %s" (pcase emrs-dirdiff--status-filter
                          ('changed "changed entries") ('only-a "entries only in A")
                          ('only-b "entries only in B") (_ "all differences"))))

;;;; Opening

(defun emrs-dirdiff--sides (entry)
  "Return the sides, `a' and `b', on which the ENTRY exists."
  (let* ((item (plist-get entry :item))
         (a (and item (plist-get item :a)))
         (b (and item (plist-get item :b))))
    (pcase (plist-get entry :status)
      ('only-a '(a))
      ('only-b '(b))
      ('error (cond ((and a (not b)) '(a)) ((and b (not a)) '(b)) (t '(a b))))
      (_ '(a b)))))

(defun emrs-dirdiff--require-entry ()
  "Return the entry at point or signal a `user-error'."
  (or (emrs-dirdiff--entry-at-point)
      (user-error "No entry at point")))

(defun emrs-dirdiff--file-pair-p (entry)
  "Non-nil when ENTRY is a changed pair of regular files."
  (and (eq (plist-get entry :status) 'changed)
       (not (plist-get entry :dir))
       (equal (plist-get (plist-get entry :item) :kind) "file")))

(defun emrs-dirdiff--diff-switches ()
  "Return the diff switches: `diff-switches', plus -w to ignore whitespace."
  (let ((switches (if (listp diff-switches) diff-switches (split-string diff-switches))))
    (if emrs-dirdiff--whitespace (append switches '("-w")) switches)))

(defun emrs-dirdiff-open ()
  "Open the entry at point.
A changed file pair opens as a `diff-mode' buffer, a file on one side is
visited, a directory or section header folds."
  (interactive nil emrs-dirdiff-mode)
  (if (emrs-dirdiff--section-at-point)
      (emrs-dirdiff-toggle-fold)
    (let ((entry (emrs-dirdiff--require-entry)))
      (cond
       ((emrs-dirdiff--file-pair-p entry)
        (let ((path (plist-get entry :path)))
          (pop-to-buffer
           (diff-no-select (emrs-dirdiff--file path 'a) (emrs-dirdiff--file path 'b)
                           (emrs-dirdiff--diff-switches) t))))
       ((and (eq emrs-dirdiff--view 'tree) (emrs-dirdiff--expandable-p (plist-get entry :path)))
        (emrs-dirdiff-toggle-fold))
       ((memq (plist-get entry :status) '(only-a only-b))
        (find-file-other-window
         (emrs-dirdiff--file (plist-get entry :path)
                             (if (eq (plist-get entry :status) 'only-a) 'a 'b))))
       (t (user-error "Nothing to open for this entry"))))))

(defun emrs-dirdiff-ediff ()
  "Compare the changed file pair at point with ediff."
  (interactive nil emrs-dirdiff-mode)
  (let ((entry (emrs-dirdiff--require-entry)))
    (unless (emrs-dirdiff--file-pair-p entry)
      (user-error "Not a changed file pair"))
    (let ((path (plist-get entry :path)))
      (ediff-files (emrs-dirdiff--file path 'a) (emrs-dirdiff--file path 'b)))))

(defun emrs-dirdiff--visit (side)
  "Visit the entry at point on SIDE (`a' or `b') in another window."
  (let* ((entry (emrs-dirdiff--require-entry))
         (name (upcase (symbol-name side))))
    (unless (memq side (emrs-dirdiff--sides entry))
      (user-error "%s does not exist in %s" (plist-get entry :path) name))
    (find-file-other-window (emrs-dirdiff--file (plist-get entry :path) side))))

(defun emrs-dirdiff-visit-a ()
  "Visit the entry at point on side A."
  (interactive nil emrs-dirdiff-mode)
  (emrs-dirdiff--visit 'a))

(defun emrs-dirdiff-visit-b ()
  "Visit the entry at point on side B."
  (interactive nil emrs-dirdiff-mode)
  (emrs-dirdiff--visit 'b))

(defun emrs-dirdiff-dired-entry ()
  "Open Dired at the directory of the entry at point, with point on the entry.
Uses side A when the entry exists there, else side B."
  (interactive nil emrs-dirdiff-mode)
  (let* ((entry (emrs-dirdiff--require-entry))
         (file (emrs-dirdiff--file (plist-get entry :path)
                                   (car (emrs-dirdiff--sides entry)))))
    (dired-other-window (file-name-directory file))
    (dired-goto-file file)))

(defun emrs-dirdiff-copy-path (&optional absolute)
  "Copy the relative path of the entry at point to the kill ring.
With prefix argument ABSOLUTE, copy the absolute path on side A (B if the
entry is not in A)."
  (interactive "P" emrs-dirdiff-mode)
  (let* ((entry (emrs-dirdiff--require-entry))
         (path (plist-get entry :path))
         (text (if absolute
                   (emrs-dirdiff--file path (car (emrs-dirdiff--sides entry)))
                 path)))
    (kill-new text)
    (message "Copied %s" text)))

;;;; Marks

(defun emrs-dirdiff--path-known-p (path)
  "Non-nil when the model knows PATH.
That is an item, a directory or a cached identical file."
  (or (gethash path emrs-dirdiff--items)
      (gethash path emrs-dirdiff--done)
      (gethash path emrs-dirdiff--children)
      (cl-find path (emrs-dirdiff--same-items (emrs-dirdiff--parent path))
               :key (lambda (i) (plist-get i :path)) :test #'equal)))

(defun emrs-dirdiff--prune-marks ()
  "Drop the marks of paths that are no longer in the results."
  (let (gone)
    (maphash (lambda (path _v)
               (unless (emrs-dirdiff--path-known-p path) (push path gone)))
             emrs-dirdiff--marks)
    (dolist (path gone) (remhash path emrs-dirdiff--marks))))

(defun emrs-dirdiff--set-mark (marked)
  "Mark (MARKED non-nil) or unmark the entry at point and move to the next line."
  (let ((path (or (emrs-dirdiff--path-at-point)
                  (user-error "Nothing to mark here; point is not on an entry"))))
    (if marked
        (puthash path t emrs-dirdiff--marks)
      (remhash path emrs-dirdiff--marks))
    (emrs-dirdiff--redraw)
    (forward-line 1)))

(defun emrs-dirdiff-mark ()
  "Mark the entry at point and move to the next line."
  (interactive nil emrs-dirdiff-mode)
  (emrs-dirdiff--set-mark t))

(defun emrs-dirdiff-unmark ()
  "Unmark the entry at point and move to the next line."
  (interactive nil emrs-dirdiff-mode)
  (emrs-dirdiff--set-mark nil))

(defun emrs-dirdiff-unmark-all ()
  "Remove all marks."
  (interactive nil emrs-dirdiff-mode)
  (clrhash emrs-dirdiff--marks)
  (emrs-dirdiff--redraw))

;;;; Actions

;; An action works only on what the comparison showed (ADR 0002): the
;; marked entries, else the entry at point, that the model knows with a
;; finished status.  It is planned from the model as a list of
;; operations on single entries, asks once, and runs them in Elisp.
;; Before each operation the entry on disk is checked against the model
;; and the directories above it against symbolic links; an entry that
;; fails is skipped.  Then every affected path is compared again with
;; `:compare :path'.  A running comparison of the whole tree is not
;; refused: the rescans wait in `--rescan-queue' until its stream has
;; ended, and run one at a time (a `:compare' cancels the previous one of
;; the instance).
;;
;; An operation is a plist (:op OP :path PATH :target TARGET :item ITEM
;; :from SIDE :to SIDE) for a copy, OP one of `new' (the target does not
;; exist), `overwrite' (a file), `relink' (a symbolic link) and `replace'
;; (a kind difference: delete the target, then copy), or (:op delete
;; :path PATH :target TARGET :item ITEM :side SIDE).  TARGET is the
;; marked entry or entry at point the operation belongs to; ITEM is nil
;; for a directory present on both sides.

(defun emrs-dirdiff--targets ()
  "Return (ENTRIES . REFUSED): what an action works on.
ENTRIES are the marked entries, else the entry at point, without those
below another one.  REFUSED lists (PATH . REASON) for marks on paths the
model does not know and for entries still being compared."
  (let ((paths (if (> (hash-table-count emrs-dirdiff--marks) 0)
                   (sort (hash-table-keys emrs-dirdiff--marks) #'string<)
                 (list (or (emrs-dirdiff--path-at-point)
                           (user-error "No entry at point")))))
        kept refused)
    (dolist (path paths)
      (cond
       ((cl-some (lambda (k) (string-prefix-p (concat (plist-get k :path) "/") path)) kept))
       ((not (emrs-dirdiff--path-known-p path))
        (push (cons path "not in the comparison") refused))
       (t
        (let ((entry (emrs-dirdiff--entry path)))
          (if (or (eq (plist-get entry :status) 'comparing)
                  (emrs-dirdiff--comparing-p path))
              (push (cons path "still being compared") refused)
            (push entry kept))))))
    (cons (nreverse kept) (nreverse refused))))

(defun emrs-dirdiff--count-noun (n singular plural)
  "Return N followed by SINGULAR when N is 1, else by PLURAL."
  (format "%d %s" n (if (= n 1) singular plural)))

(defun emrs-dirdiff--path-list (paths)
  "Return PATHS one per line, indented; the first ten, then \"and N more\"."
  (concat (mapconcat (lambda (p) (concat "  " p)) (seq-take paths 10) "\n")
          (if (> (length paths) 10)
              (format "\n  and %d more" (- (length paths) 10))
            "")))

(defun emrs-dirdiff--left-out-text (left-out)
  "Return LEFT-OUT, a list of (PATH . REASON), as \"PATH (REASON), …\"."
  (mapconcat (lambda (x) (format "%s (%s)" (car x) (cdr x))) left-out ", "))

;;;;; Checks on disk

(defun emrs-dirdiff--disk (file)
  "Return (KIND SIZE MTIME) of FILE without following a symbolic link, or nil.
KIND is a string as in stream items, MTIME in whole seconds."
  (when-let* ((attrs (file-attributes file)))
    (list (pcase (aref (file-attribute-modes attrs) 0)
            (?- "file") (?d "dir") (?l "link") (_ "other"))
          (file-attribute-size attrs)
          (floor (float-time (file-attribute-modification-time attrs))))))

(defun emrs-dirdiff--expected (item side)
  "Return what the comparison saw on SIDE (`a' or `b') of ITEM.
A kind string, (not KIND) on the B side of a kind difference, or nil
when the entry was absent there.  A nil ITEM is a directory present on
both sides."
  (if (null item)
      "dir"
    (let ((kind (plist-get item :kind)))
      (pcase (plist-get item :status)
        ("only-a" (and (eq side 'a) kind))
        ("only-b" (and (eq side 'b) kind))
        ("kind" (if (eq side 'a) kind (list 'not kind)))
        (_ kind)))))

(defun emrs-dirdiff--meta-matches-p (disk meta)
  "Non-nil unless DISK is a file whose size or time differ from META.
META is the side plist (:size :mtime) of the stream item; times are
compared to the second."
  (or (not (equal (car disk) "file"))
      (and (numberp (plist-get meta :size))
           (numberp (plist-get meta :mtime))
           (= (nth 1 disk) (plist-get meta :size))
           (= (nth 2 disk) (floor (plist-get meta :mtime))))))

(defun emrs-dirdiff--side-matches-p (path side item)
  "Non-nil when PATH on SIDE is on disk what ITEM says it was."
  (let ((expected (emrs-dirdiff--expected item side))
        (disk (emrs-dirdiff--disk (emrs-dirdiff--file path side)))
        (meta (and item (plist-get item (if (eq side 'a) :a :b)))))
    (cond
     ((null expected) (null disk))
     ((null disk) nil)
     ((consp expected)
      (and (not (equal (car disk) (cadr expected)))
           (emrs-dirdiff--meta-matches-p disk meta)))
     (t
      (and (equal (car disk) expected)
           (emrs-dirdiff--meta-matches-p disk meta))))))

(defun emrs-dirdiff--parents-real-p (path side)
  "Non-nil when the root of SIDE and each directory above PATH are real.
Real means a directory, not a symbolic link: a link would take the
operation out of the root."
  (let* ((root (emrs-dirdiff--root side))
         (ok (eq (car (file-attributes (directory-file-name root))) t))
         (start 0)
         i)
    (while (and ok (setq i (string-search "/" path start)))
      (setq ok (eq (car (file-attributes (concat root (substring path 0 i)))) t)
            start (1+ i)))
    ok))

(defun emrs-dirdiff--op-problem (op)
  "Return why OP cannot run now, or nil when it can."
  (let* ((path (plist-get op :path))
         (item (plist-get op :item))
         (kind (plist-get op :op))
         (sides (if (eq kind 'delete) (list (plist-get op :side)) '(a b))))
    (cond
     ((not (cl-every (lambda (side)
                       (and (emrs-dirdiff--parents-real-p path side)
                            (emrs-dirdiff--side-matches-p path side item)))
                     sides))
      "changed since the comparison")
     ((and (memq kind '(new replace))
           (not (member (car (emrs-dirdiff--disk
                              (emrs-dirdiff--file path (plist-get op :from))))
                        '("file" "dir" "link"))))
      "a special file"))))

;;;;; Running

(defun emrs-dirdiff--delete-file (file)
  "Delete FILE, a directory with its contents; honour `delete-by-moving-to-trash'.
A symbolic link is deleted, not what it points to."
  (if (eq (car (file-attributes file)) t)
      (delete-directory file t t)
    (delete-file file t)))

(defun emrs-dirdiff--copy-new (src dst)
  "Copy SRC to DST, which does not exist; a link as a link, times kept."
  (pcase (car (emrs-dirdiff--disk src))
    ("dir" (copy-directory src dst t nil nil))
    ("file" (copy-file src dst nil t nil t))
    ("link" (make-symbolic-link (file-symlink-p src) dst nil))
    (_ (error "Cannot copy %s" src))))

(defun emrs-dirdiff--op-run (op)
  "Run the operation OP (see the commentary of this section)."
  (let ((path (plist-get op :path)))
    (if (eq (plist-get op :op) 'delete)
        (emrs-dirdiff--delete-file (emrs-dirdiff--file path (plist-get op :side)))
      (let ((src (emrs-dirdiff--file path (plist-get op :from)))
            (dst (emrs-dirdiff--file path (plist-get op :to))))
        (pcase (plist-get op :op)
          ('new (emrs-dirdiff--copy-new src dst))
          ('overwrite (copy-file src dst t t nil t))
          ('relink (make-symbolic-link (file-symlink-p src) dst t))
          ('replace
           (emrs-dirdiff--delete-file dst)
           (emrs-dirdiff--copy-new src dst)))))))

(defun emrs-dirdiff--rescan-paths (paths)
  "Compare PATHS again, one after the other, once no stream is running."
  (dolist (path paths)
    (remhash (emrs-dirdiff--parent path) emrs-dirdiff--same)
    (unless (or (member path emrs-dirdiff--rescan-queue)
                (cl-some (lambda (q) (emrs-dirdiff--at-or-below-p path q))
                         emrs-dirdiff--rescan-queue))
      (setq emrs-dirdiff--rescan-queue
            (append (cl-remove-if (lambda (q) (emrs-dirdiff--at-or-below-p q path))
                                  emrs-dirdiff--rescan-queue)
                    (list path)))))
  (emrs-dirdiff--drain-rescans))

(defun emrs-dirdiff--drain-rescans ()
  "Start the next queued rescan unless a stream is running."
  (when (and emrs-dirdiff--rescan-queue (not emrs-dirdiff--stream))
    (emrs-dirdiff--compare (pop emrs-dirdiff--rescan-queue))))

(defun emrs-dirdiff--perform (what ops)
  "Run OPS in order, then compare the affected paths again.
WHAT names the action in messages.  An operation whose entry fails the
checks on disk is skipped.  The first error stops the action and is
shown with how many operations were done; so is a quit.  Every target
an operation ran on is compared again either way, and the mark of a
target is cleared when all its operations were done."
  (let ((done 0)
        (total (length ops))
        (counts (make-hash-table :test 'equal)) ; target -> (OPS . DONE)
        (touched nil)
        (skipped nil)
        (failure nil)
        (finished nil))
    (dolist (op ops)
      (let ((cell (or (gethash (plist-get op :target) counts)
                      (puthash (plist-get op :target) (cons 0 0) counts))))
        (cl-incf (car cell))))
    (unwind-protect
        (progn
          (catch 'stop
            (dolist (op ops)
              (let ((target (plist-get op :target))
                    (problem (emrs-dirdiff--op-problem op)))
                (if problem
                    (push (cons (plist-get op :path) problem) skipped)
                  (cl-pushnew target touched :test #'equal)
                  (condition-case err
                      (progn
                        (emrs-dirdiff--op-run op)
                        (cl-incf done)
                        (cl-incf (cdr (gethash target counts))))
                    (error
                     (setq failure (cons op err))
                     (throw 'stop nil)))))))
          (setq finished t))
      (setq skipped (nreverse skipped))
      (let ((skipped-text
             (if skipped
                 (format "; skipped, %s; press g to compare again"
                         (emrs-dirdiff--left-out-text skipped))
               "")))
        (cond
         (failure
          (display-warning 'emrs-dirdiff
                           (format "%s failed on %s: %s; %d of %d done%s"
                                   what (plist-get (car failure) :path)
                                   (error-message-string (cdr failure))
                                   done total skipped-text)
                           :error))
         ((not finished)
          (message "%s interrupted: %d of %d done%s" what done total skipped-text))
         (t
          (message "%s: %d of %d done%s" what done total skipped-text))))
      (maphash (lambda (target cell)
                 (when (= (car cell) (cdr cell))
                   (remhash target emrs-dirdiff--marks)))
               counts)
      (emrs-dirdiff--rescan-paths (sort touched #'string<)))))

(defun emrs-dirdiff--confirm (ask prompt)
  "Ask PROMPT with `yes-or-no-p' when ASK is `yes', else with `y-or-n-p'."
  (funcall (if (eq ask 'yes) #'yes-or-no-p #'y-or-n-p) prompt))

;;;;; Copy

(defun emrs-dirdiff--sorted-children (dir)
  "Return the known children of DIR, sorted."
  (when-let* ((set (gethash dir emrs-dirdiff--children)))
    (sort (hash-table-keys set) #'string<)))

(defun emrs-dirdiff--plan-copy (entries from)
  "Return (OPS . LEFT-OUT) to copy ENTRIES from side FROM to the other side.
A directory present on both sides contributes the differences listed
below it, entry by entry; entries only on the other side stay.
LEFT-OUT lists (PATH . REASON) for the entries that are not copied."
  (let* ((to (if (eq from 'a) 'b 'a))
         (only-from (if (eq from 'a) "only-a" "only-b"))
         (from-name (upcase (symbol-name from)))
         ops left-out)
    (cl-labels
        ((op (kind target path item)
           (push (list :op kind :path path :target target :item item :from from :to to)
                 ops))
         (item-ops (target path item top)
           (let ((status (plist-get item :status))
                 (kind (plist-get item :kind)))
             (cond
              ((equal status only-from)
               (if (member kind '("file" "dir" "link"))
                   (op 'new target path item)
                 (push (cons path "a special file") left-out)))
              ((and (equal status "changed") (equal kind "file"))
               (op 'overwrite target path item))
              ((and (equal status "changed") (equal kind "link"))
               (op 'relink target path item))
              ((equal status "kind")
               (if (and (eq from 'a) (not (member kind '("file" "dir" "link"))))
                   (push (cons path "a special file") left-out)
                 (op 'replace target path item)))
              ((emrs-dirdiff--partial-dir-p path item)
               ;; Read in part: its listed differences are copied; the
               ;; error is mentioned for information.
               (push (cons path (or (plist-get item :message) "could not be read in part"))
                     left-out)
               (dir-ops target path))
              ((equal status "error")
               (push (cons path "could not be compared") left-out))
              (top
               (push (cons path (if (equal status "same")
                                    "identical"
                                  (format "not in %s" from-name)))
                     left-out)))))
         (dir-ops (target dir)
           (dolist (child (emrs-dirdiff--sorted-children dir))
             (let ((item (gethash child emrs-dirdiff--items)))
               (cond
                (item (item-ops target child item nil))
                ((emrs-dirdiff--expandable-p child) (dir-ops target child)))))))
      (dolist (entry entries)
        (let ((path (plist-get entry :path))
              (item (plist-get entry :item)))
          (cond
           ((eq (plist-get entry :status) 'same)
            (push (cons path "identical") left-out))
           (item (item-ops path path item t))
           (t
            (let ((before (length ops)))
              (dir-ops path path)
              (when (= before (length ops))
                (push (cons path (format "nothing below it to copy from %s" from-name))
                      left-out))))))))
    (cons (nreverse ops) (nreverse left-out))))

(defun emrs-dirdiff--kind-noun (kinds)
  "Return the noun pair (SINGULAR PLURAL) for entries of KINDS on disk."
  (pcase (delete-dups (copy-sequence kinds))
    ('("dir") '("directory" "directories"))
    ('("file") '("file" "files"))
    ('("link") '("symbolic link" "symbolic links"))
    (_ '("entry" "entries"))))

(defun emrs-dirdiff--copy-prompt (label ops left-out)
  "Return the question for copying OPS in direction LABEL; LEFT-OUT as text."
  (let* ((overwritten (cl-count-if (lambda (op) (memq (plist-get op :op) '(overwrite relink)))
                                   ops))
         (replaced (cl-remove-if-not (lambda (op) (eq (plist-get op :op) 'replace)) ops))
         (noun (emrs-dirdiff--kind-noun
                (mapcar (lambda (op)
                          (car (emrs-dirdiff--disk
                                (emrs-dirdiff--file (plist-get op :path) (plist-get op :to)))))
                        replaced)))
         (effects (delq nil
                        (list (and (> overwritten 0)
                                   (format "%s overwritten"
                                           (emrs-dirdiff--count-noun overwritten "file" "files")))
                              (and replaced
                                   (format "%s replaced (deleted first)"
                                           (emrs-dirdiff--count-noun (length replaced)
                                                                     (car noun) (cadr noun))))))))
    (format "Copy %s %s%s:\n%s%s\nProceed? "
            (emrs-dirdiff--count-noun (length ops) "entry" "entries")
            label
            (if effects (concat ": " (mapconcat #'identity effects ", ")) "")
            (emrs-dirdiff--path-list
             (mapcar (lambda (op)
                       (format "%s (%s)" (plist-get op :path)
                               (pcase (plist-get op :op)
                                 ('new "new") ('overwrite "overwrite")
                                 ('relink "overwrite") ('replace "replace"))))
                     ops))
            (if left-out
                (concat "\nLeft out: " (emrs-dirdiff--left-out-text left-out))
              ""))))

(defun emrs-dirdiff--copy (from)
  "Copy the targets from side FROM (`a' or `b') to the other side."
  (pcase-let* ((label (if (eq from 'a) "A → B" "B → A"))
               (`(,entries . ,refused) (emrs-dirdiff--targets))
               (`(,ops . ,left-out) (emrs-dirdiff--plan-copy entries from))
               (left-out (append refused left-out)))
    (if (null ops)
        (message "Nothing to copy %s%s" label
                 (if left-out (concat ": " (emrs-dirdiff--left-out-text left-out)) ""))
      (when (emrs-dirdiff--confirm
             (if (cl-some (lambda (op) (memq (plist-get op :op) '(overwrite relink replace))) ops)
                 'yes 'y)
             (emrs-dirdiff--copy-prompt label ops left-out))
        (emrs-dirdiff--perform (concat "Copy " label) ops)))))

(defun emrs-dirdiff-copy-a-to-b ()
  "Copy the marked entries, or the one at point, from A to B.
Copies what the comparison showed: a directory present on both sides
contributes the differences below it, entry by entry.  Asks once for
the whole action and says what will be overwritten or replaced."
  (interactive nil emrs-dirdiff-mode)
  (emrs-dirdiff--copy 'a))

(defun emrs-dirdiff-copy-b-to-a ()
  "Copy the marked entries, or the one at point, from B to A.
See `emrs-dirdiff-copy-a-to-b'."
  (interactive nil emrs-dirdiff-mode)
  (emrs-dirdiff--copy 'b))

;;;;; Delete

(defun emrs-dirdiff--plan-delete (entries choice)
  "Return (OPS . LEFT-OUT) to delete ENTRIES.
CHOICE (?a, ?b or ?c for both) picks the side of entries present on both."
  (let (ops left-out)
    (dolist (entry entries)
      (let* ((path (plist-get entry :path))
             (item (plist-get entry :item))
             (sides (emrs-dirdiff--sides entry)))
        (if (and (eq (plist-get entry :status) 'error)
                 (not (emrs-dirdiff--partial-dir-p path item)))
            (push (cons path "could not be compared") left-out)
          (when (cdr sides)
            (setq sides (pcase choice (?a '(a)) (?b '(b)) (_ '(a b)))))
          (dolist (side sides)
            (push (list :op 'delete :path path :target path :item item :side side) ops)))))
    (cons (nreverse ops) (nreverse left-out))))

(defun emrs-dirdiff--delete-prompt (ops left-out)
  "Return the question for deleting OPS; LEFT-OUT as text."
  (let ((in-a (cl-count 'a ops :key (lambda (op) (plist-get op :side))))
        (in-b (cl-count 'b ops :key (lambda (op) (plist-get op :side))))
        (dirs (cl-count-if (lambda (op)
                             (equal (car (emrs-dirdiff--disk
                                          (emrs-dirdiff--file (plist-get op :path)
                                                              (plist-get op :side))))
                                    "dir"))
                           ops)))
    (format "Delete %s (%s)%s:\n%s%s\nProceed? "
            (emrs-dirdiff--count-noun (length ops) "entry" "entries")
            (mapconcat #'identity
                       (delq nil (list (and (> in-a 0) (format "%d in A" in-a))
                                       (and (> in-b 0) (format "%d in B" in-b))))
                       ", ")
            (if (> dirs 0)
                (format ", %s with everything in it"
                        (emrs-dirdiff--count-noun dirs "directory" "directories"))
              "")
            (emrs-dirdiff--path-list
             (mapcar (lambda (op)
                       (format "%s (%s)" (plist-get op :path)
                               (upcase (symbol-name (plist-get op :side)))))
                     ops))
            (if left-out
                (concat "\nLeft out: " (emrs-dirdiff--left-out-text left-out))
              ""))))

(defun emrs-dirdiff-delete ()
  "Delete the marked entries, or the one at point.
An entry present on both sides is deleted from the side asked for once
for the whole action: A, B or both.  Entries on one side are deleted from
it.  Each entry is checked on disk against the comparison first.
`delete-by-moving-to-trash' applies."
  (interactive nil emrs-dirdiff-mode)
  (pcase-let* ((`(,entries . ,refused) (emrs-dirdiff--targets))
               (choice (when (cl-some (lambda (e)
                                        (and (or (not (eq (plist-get e :status) 'error))
                                                 (emrs-dirdiff--partial-dir-p
                                                  (plist-get e :path) (plist-get e :item)))
                                             (cdr (emrs-dirdiff--sides e))))
                                      entries)
                         (read-char-choice
                          "Delete entries present on both sides from (a) A, (b) B, (c) both, (q) nothing: "
                          '(?a ?b ?c ?q)))))
    (unless (eq choice ?q)
      (pcase-let* ((`(,ops . ,left-out) (emrs-dirdiff--plan-delete entries choice))
                   (left-out (append refused left-out)))
        (if (null ops)
            (message "Nothing to delete%s"
                     (if left-out (concat ": " (emrs-dirdiff--left-out-text left-out)) ""))
          (when (yes-or-no-p (emrs-dirdiff--delete-prompt ops left-out))
            (emrs-dirdiff--perform "Delete" ops)))))))

;;;; Settings

(defun emrs-dirdiff-compare-content ()
  "Compare by content and compare again."
  (interactive nil emrs-dirdiff-mode)
  (setq emrs-dirdiff--by 'content)
  (emrs-dirdiff--compare ""))

(defun emrs-dirdiff-compare-size-time ()
  "Compare by size and modification time and compare again."
  (interactive nil emrs-dirdiff-mode)
  (setq emrs-dirdiff--by 'size-time)
  (emrs-dirdiff--compare ""))

(defun emrs-dirdiff-toggle-whitespace ()
  "Toggle ignoring whitespace differences and compare again."
  (interactive nil emrs-dirdiff-mode)
  (setq emrs-dirdiff--whitespace (not emrs-dirdiff--whitespace))
  (emrs-dirdiff--compare "")
  (message "Whitespace differences %s" (if emrs-dirdiff--whitespace "ignored" "count")))

(defun emrs-dirdiff-toggle-ignore-files ()
  "Toggle whether ignore files apply and compare again."
  (interactive nil emrs-dirdiff-mode)
  (setq emrs-dirdiff--ignore-files (not emrs-dirdiff--ignore-files))
  (emrs-dirdiff--compare "")
  (message "Ignore files %s" (if emrs-dirdiff--ignore-files "apply" "do not apply")))

(defun emrs-dirdiff-swap ()
  "Swap A and B: a new instance compares the swapped roots.
The buffer is renamed; folds and the view stay, marks are cleared."
  (interactive nil emrs-dirdiff-mode)
  (emrs-dirdiff--cancel-stream)
  ;; A mark chose an entry and a direction together; after the swap the
  ;; same keys would act the other way round.
  (clrhash emrs-dirdiff--marks)
  (when-let* ((instance emrs-dirdiff--instance))
    (setq emrs-dirdiff--instance nil)
    (emrs-dirdiff--stop instance))
  (cl-rotatef emrs-dirdiff--a emrs-dirdiff--b)
  (setq default-directory emrs-dirdiff--a)
  (rename-buffer (emrs-dirdiff--buffer-name emrs-dirdiff--a emrs-dirdiff--b) t)
  (emrs-dirdiff--compare ""))

(defun emrs-dirdiff-rescan (&optional subtree)
  "Compare again.
With a prefix argument SUBTREE and point on a directory present on both
sides, compare only that directory."
  (interactive "P" emrs-dirdiff-mode)
  (if (not subtree)
      (emrs-dirdiff--compare "")
    ;; A subtree rescan would cancel the running comparison and leave the
    ;; rest of the tree half compared.
    (when emrs-dirdiff--stream
      (user-error "A comparison is running; wait for it to finish or stop it with C-c C-k"))
    (let ((path (emrs-dirdiff--path-at-point)))
      (unless (and path (emrs-dirdiff--expandable-p path))
        (user-error "No directory present on both sides at point"))
      (emrs-dirdiff--compare path))))

(defun emrs-dirdiff-stop ()
  "Stop the running comparison and the rescans waiting behind it."
  (interactive nil emrs-dirdiff-mode)
  (setq emrs-dirdiff--rescan-queue nil)
  (if-let* ((call emrs-dirdiff--stream))
      (emrs-cancel call)
    (message "No comparison is running")))

(defvar-keymap emrs-dirdiff-mode-map
  :doc "Keymap of `emrs-dirdiff-mode'."
  :parent special-mode-map
  "TAB" #'emrs-dirdiff-toggle-fold
  "<tab>" #'emrs-dirdiff-toggle-fold
  "S-TAB" #'emrs-dirdiff-toggle-fold-all
  "<backtab>" #'emrs-dirdiff-toggle-fold-all
  "s" #'emrs-dirdiff-toggle-same
  "v" #'emrs-dirdiff-toggle-view
  "RET" #'emrs-dirdiff-open
  "e" #'emrs-dirdiff-ediff
  "o" #'emrs-dirdiff-visit-a
  "O" #'emrs-dirdiff-visit-b
  "d" #'emrs-dirdiff-dired-entry
  "n" #'emrs-dirdiff-next-difference
  "p" #'emrs-dirdiff-previous-difference
  "N" #'emrs-dirdiff-next-group
  "P" #'emrs-dirdiff-previous-group
  "^" #'emrs-dirdiff-up
  "/" #'emrs-dirdiff-filter-name
  "f" #'emrs-dirdiff-cycle-status-filter
  "w" #'emrs-dirdiff-copy-path
  "c" #'emrs-dirdiff-compare-content
  "t" #'emrs-dirdiff-compare-size-time
  "W" #'emrs-dirdiff-toggle-whitespace
  "i" #'emrs-dirdiff-toggle-ignore-files
  "x" #'emrs-dirdiff-swap
  "g" #'emrs-dirdiff-rescan
  "m" #'emrs-dirdiff-mark
  "u" #'emrs-dirdiff-unmark
  "U" #'emrs-dirdiff-unmark-all
  ">" #'emrs-dirdiff-copy-a-to-b
  "<" #'emrs-dirdiff-copy-b-to-a
  "D" #'emrs-dirdiff-delete
  "?" #'emrs-dirdiff-menu
  "C-c C-k" #'emrs-dirdiff-stop)

(define-derived-mode emrs-dirdiff-mode special-mode "Dirdiff"
  "Major mode of a directory comparison buffer.

\\{emrs-dirdiff-mode-map}"
  (setq truncate-lines t
        buffer-undo-list t)
  (setq-local revert-buffer-function
              (lambda (_ignore-auto _noconfirm) (emrs-dirdiff-rescan)))
  (setq emrs-dirdiff--folds (make-hash-table :test 'equal)
        emrs-dirdiff--section-folds (make-hash-table :test 'eq)
        emrs-dirdiff--marks (make-hash-table :test 'equal)
        emrs-dirdiff--line-index (make-hash-table :test 'equal))
  (emrs-dirdiff--model-clear)
  (add-hook 'kill-buffer-hook #'emrs-dirdiff--kill nil t)
  (add-hook 'change-major-mode-hook #'emrs-dirdiff--kill nil t)
  (add-hook 'window-buffer-change-functions #'emrs-dirdiff--on-shown nil t))

;;;; Commands

(defun emrs-dirdiff--check-dirs (a b)
  "Return (A . B) as absolute true directory names, or signal a `user-error'.
A and B must be local directories, not the same and not one inside the other."
  (dolist (dir (list a b))
    (when (file-remote-p dir)
      (user-error "Remote directories are not supported (%s); use ztree-diff for them" dir)))
  (dolist (dir (list a b))
    (unless (file-directory-p dir)
      (user-error "Not a directory: %s" dir)))
  (let ((a (file-name-as-directory (file-truename (expand-file-name a))))
        (b (file-name-as-directory (file-truename (expand-file-name b)))))
    (cond
     ((equal a b) (user-error "A and B are the same directory: %s" a))
     ((string-prefix-p a b) (user-error "%s is inside %s" b a))
     ((string-prefix-p b a) (user-error "%s is inside %s" a b)))
    (cons a b)))

(defun emrs-dirdiff--buffer-name (a b)
  "Return the name of the buffer comparing A with B."
  (format "*dirdiff: %s ↔ %s*"
          (file-name-nondirectory (directory-file-name a))
          (file-name-nondirectory (directory-file-name b))))

(defun emrs-dirdiff--open (a b)
  "Compare the directories A and B in their buffer and return it.
Validate A and B (see `emrs-dirdiff--check-dirs'), reuse the buffer that
compares the same pair, else make one, and start the comparison.  The
buffer is not displayed."
  (pcase-let ((`(,a . ,b) (emrs-dirdiff--check-dirs a b)))
    (let ((buffer (cl-find-if (lambda (buf)
                                (with-current-buffer buf
                                  (and (derived-mode-p 'emrs-dirdiff-mode)
                                       (equal emrs-dirdiff--a a)
                                       (equal emrs-dirdiff--b b))))
                              (buffer-list))))
      (if buffer
          (with-current-buffer buffer
            (emrs-dirdiff--compare ""))
        (setq buffer (generate-new-buffer (emrs-dirdiff--buffer-name a b)))
        (with-current-buffer buffer
          (emrs-dirdiff-mode)
          (setq default-directory a
                emrs-dirdiff--a a
                emrs-dirdiff--b b
                emrs-dirdiff--by emrs-dirdiff-compare-by
                emrs-dirdiff--ignore-files emrs-dirdiff-respect-ignore-files
                emrs-dirdiff--whitespace emrs-dirdiff-ignore-whitespace
                emrs-dirdiff--hidden emrs-dirdiff-show-hidden
                emrs-dirdiff--view emrs-dirdiff-default-view)
          (emrs-dirdiff--compare "")
          ;; Below the header, so point lands on the first entry to arrive.
          (goto-char (point-max))))
      buffer)))

(defun emrs-dirdiff--other-window-dir (&optional dired-only)
  "Return the directory of the buffer in the next window, or nil.
With DIRED-ONLY, only when that buffer is in Dired mode."
  (let ((window (next-window)))
    (unless (eq window (selected-window))
      (with-current-buffer (window-buffer window)
        (and (or (not dired-only) (derived-mode-p 'dired-mode))
             default-directory)))))

;;;###autoload
(defun emrs-dirdiff (a b)
  "Compare the directories A and B and show the result.
Interactively, ask for A, then for B; B defaults to the directory of the
buffer in the other window."
  (interactive
   (let* ((a (read-directory-name "Compare directory A: " nil nil t))
          (other (emrs-dirdiff--other-window-dir))
          (b (read-directory-name (format "Compare %s with directory B: "
                                          (abbreviate-file-name a))
                                  other other t)))
     (list a b)))
  (pop-to-buffer-same-window (emrs-dirdiff--open a b)))

;;;###autoload
(defun emrs-dirdiff-dired ()
  "Compare the two directories marked in this Dired buffer.
Without exactly two marked directories, compare the Dired directory with
the one shown by the Dired buffer in the other window."
  (interactive nil dired-mode)
  (unless (derived-mode-p 'dired-mode)
    (user-error "Not in a Dired buffer"))
  (let* ((marked (and (save-excursion
                        (goto-char (point-min))
                        (re-search-forward (dired-marker-regexp) nil t))
                      (dired-get-marked-files nil nil #'file-directory-p))))
    (if (= (length marked) 2)
        (emrs-dirdiff (car marked) (cadr marked))
      (let ((other (emrs-dirdiff--other-window-dir t)))
        (unless other
          (user-error "Mark two directories, or show another directory in Dired in the other window"))
        (emrs-dirdiff default-directory other)))))

(provide 'emrs-dirdiff)
;;; emrs-dirdiff.el ends here
