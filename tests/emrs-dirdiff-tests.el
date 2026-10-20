;;; emrs-dirdiff-tests.el --- ERT suite for emrs-dirdiff  -*- lexical-binding: t; -*-

;;; Commentary:

;; Run with tests/run-ert.sh.  The module must be installed as
;; emrs-dirdiff-module on `load-path' (the script does that).

;;; Code:

(require 'ert)
(require 'lisp-mnt)
(require 'emrs-dirdiff)

;; emrs-dirdiff resolves both roots with `file-truename'; resolve the
;; temporary directory too (on macOS /var is a link to /private/var), so
;; paths the tests build compare equal to the buffer's.
(setq temporary-file-directory (file-name-as-directory
                                (file-truename temporary-file-directory)))

(defun emrs-dirdiff-test--wait (pred &optional seconds)
  "Wait up to SECONDS (default 10) until PRED returns non-nil; return it."
  (let ((deadline (+ (float-time) (or seconds 10))))
    (while (and (not (funcall pred)) (< (float-time) deadline))
      (accept-process-output nil 0.05))
    (funcall pred)))

(ert-deftest emrs-dirdiff-test-loads ()
  "emrs-dirdiff.el and emrs.el load."
  (should (featurep 'emrs-dirdiff))
  (should (featurep 'emrs)))

(ert-deftest emrs-dirdiff-test-start-and-stop ()
  "An instance on two directories reaches `running', then stops."
  (let ((a (make-temp-file "emrs-dirdiff-a" t))
        (b (make-temp-file "emrs-dirdiff-b" t))
        (exit nil)
        (inst nil))
    (unwind-protect
        (progn
          (setq inst (emrs-dirdiff--start a b (lambda (_i status _e) (setq exit status))))
          (should (emrs-dirdiff-test--wait
                   (lambda () (eq (emrs-instance-state inst) 'running))))
          (emrs-dirdiff--stop inst)
          (should (emrs-dirdiff-test--wait (lambda () exit)))
          (should (eq exit 'stopped))
          (should (eq (emrs-instance-state inst) 'stopped)))
      (when (and inst (memq (emrs-instance-state inst) '(starting running)))
        (emrs-dirdiff--stop inst))
      (delete-directory a t)
      (delete-directory b t))))

(ert-deftest emrs-dirdiff-test-start-on-missing-directory-fails ()
  "Starting on a missing directory fails with a message naming the path."
  (let* ((a (make-temp-file "emrs-dirdiff-a" t))
         (missing (expand-file-name "missing" a))
         (exit nil)
         (message nil))
    (unwind-protect
        (let ((inst (emrs-dirdiff--start
                     a missing (lambda (_i status err)
                                 (setq message (plist-get err :message)
                                       exit status)))))
          (should (emrs-dirdiff-test--wait (lambda () exit)))
          (should (eq exit 'failed))
          (should (eq (emrs-instance-state inst) 'failed))
          (should (string-match-p (regexp-quote missing) message)))
      (delete-directory a t))))

(defun emrs-dirdiff-test--put (dir rel content)
  "Write CONTENT to REL below DIR, creating directories.
REL is appended as it is, so a name like ~ stays below DIR."
  (let ((file (concat (file-name-as-directory dir) rel)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file (insert content))))

(defun emrs-dirdiff-test--keys (plist)
  "The keys of PLIST, in order."
  (let (keys)
    (while plist
      (push (car plist) keys)
      (setq plist (cddr plist)))
    (nreverse keys)))

(ert-deftest emrs-dirdiff-test-compare-stream-shapes ()
  "A real :compare streams plists in the shapes the spec documents."
  (let* ((root (make-temp-file "emrs-dirdiff-cmp" t))
         (a (expand-file-name "a" root))
         (b (expand-file-name "b" root))
         (items nil) (end nil) (inst nil))
    (unwind-protect
        (progn
          (dolist (dir (list a b))
            (emrs-dirdiff-test--put dir "same.txt" "same\n")
            (emrs-dirdiff-test--put dir "sub/same2" "s"))
          (emrs-dirdiff-test--put a "changed.txt" "a\nb\nc\n")
          (emrs-dirdiff-test--put b "changed.txt" "a\nB\nc\nd\n")
          (emrs-dirdiff-test--put a "only-a.txt" "x")
          (emrs-dirdiff-test--put b "onlyb/f1" "x")
          (emrs-dirdiff-test--put b "onlyb/g/f2" "x")
          (setq inst (emrs-dirdiff--start a b))
          (emrs-call-stream inst '(:compare :path "" :by :content :ignore-files t
                                            :whitespace nil :hidden t)
                            :on-batch (lambda (batch) (setq items (append items batch)))
                            :on-end (lambda (status _err) (setq end status)))
          (should (emrs-dirdiff-test--wait (lambda () end)))
          (should (eq end 'done))
          (let ((summary (car (last items)))
                (by-path (mapcar (lambda (item) (cons (plist-get item :path) item))
                                 (butlast items))))
            (should (equal (emrs-dirdiff-test--keys summary) '(:summary :files :seconds)))
            (should (eq (plist-get summary :summary) t))
            ;; root: changed.txt, only-a.txt, onlyb, same.txt, sub; sub: same2
            (should (eql (plist-get summary :files) 6))
            (should (floatp (plist-get summary :seconds)))
            (should (equal (sort (mapcar #'car by-path) #'string<)
                           '("" "changed.txt" "only-a.txt" "onlyb" "sub")))
            (let ((changed (cdr (assoc "changed.txt" by-path))))
              (should (equal (emrs-dirdiff-test--keys changed)
                             '(:path :kind :status :a :b :lines)))
              (should (equal (plist-get changed :kind) "file"))
              (should (equal (plist-get changed :status) "changed"))
              (should (equal (plist-get changed :lines) '(2 1)))
              (should (equal (emrs-dirdiff-test--keys (plist-get changed :a)) '(:size :mtime)))
              (should (eql (plist-get (plist-get changed :a) :size) 6))
              (should (floatp (plist-get (plist-get changed :b) :mtime))))
            (let ((only-a (cdr (assoc "only-a.txt" by-path))))
              (should (equal (emrs-dirdiff-test--keys only-a) '(:path :kind :status :a)))
              (should (equal (plist-get only-a :status) "only-a")))
            (let ((onlyb (cdr (assoc "onlyb" by-path))))
              (should (equal (emrs-dirdiff-test--keys onlyb) '(:path :kind :status :b :files)))
              (should (equal (plist-get onlyb :kind) "dir"))
              (should (equal (plist-get onlyb :status) "only-b"))
              (should (eql (plist-get onlyb :files) 2)))
            (should (equal (cdr (assoc "sub" by-path))
                           '(:path "sub" :kind "dir" :status "done" :same 1)))
            (should (equal (cdr (assoc "" by-path))
                           '(:path "" :kind "dir" :status "done" :same 2))))
          (let ((same (emrs-call-sync inst '(:same :dir "") 10)))
            (should (equal (mapcar (lambda (i) (plist-get i :path)) same) '("same.txt")))
            (should (equal (emrs-dirdiff-test--keys (car same)) '(:path :kind :status :a :b)))
            (should (equal (plist-get (car same) :status) "same")))
          (should (null (emrs-call-sync inst '(:cancel) 10))))
      (when (and inst (memq (emrs-instance-state inst) '(starting running)))
        (emrs-dirdiff--stop inst))
      (delete-directory root t))))

;;;; The comparison buffer

(defun emrs-dirdiff-test--fixture (root)
  "Create the trees a and b below ROOT; return (A . B)."
  (let ((a (expand-file-name "a" root))
        (b (expand-file-name "b" root)))
    (dolist (dir (list a b))
      (emrs-dirdiff-test--put dir "same.txt" "same\n")
      (emrs-dirdiff-test--put dir "sub/same2" "s")
      (emrs-dirdiff-test--put dir "deep/er/same3" "s"))
    (emrs-dirdiff-test--put a "changed.txt" "a\nb\nc\n")
    (emrs-dirdiff-test--put b "changed.txt" "a\nB\nc\nd\n")
    (emrs-dirdiff-test--put a "only-a.txt" "x")
    (emrs-dirdiff-test--put b "onlyb/f1" "x")
    (emrs-dirdiff-test--put b "onlyb/g/f2" "x")
    (emrs-dirdiff-test--put a "kindy" "file")
    (emrs-dirdiff-test--put b "kindy/inside" "dir")
    (emrs-dirdiff-test--put a "deep/er/n.txt" "1\n")
    (emrs-dirdiff-test--put b "deep/er/n.txt" "2\n")
    (cons a b)))

(defun emrs-dirdiff-test--wait-done (buffer &optional seconds)
  "Wait up to SECONDS (default 20) until the comparison in BUFFER ended
and the buffer was redrawn.  Return its state.
The test buffers are not shown in a window, so their throttled redraws
are skipped; this redraws as showing the buffer would."
  (emrs-dirdiff-test--wait
   (lambda () (and (memq (buffer-local-value 'emrs-dirdiff--state buffer)
                         '(done stopped failed))
                   (null (buffer-local-value 'emrs-dirdiff--rescan-queue buffer))
                   (not (buffer-local-value 'emrs-dirdiff--stream buffer))
                   (not (buffer-local-value 'emrs-dirdiff--redraw-timer buffer))))
   (or seconds 20))
  (with-current-buffer buffer
    (when emrs-dirdiff--dirty
      (emrs-dirdiff--redraw)))
  (buffer-local-value 'emrs-dirdiff--state buffer))

(defun emrs-dirdiff-test--body (buffer)
  "The lines of BUFFER below the header, without trailing whitespace."
  (with-current-buffer buffer
    (emrs-dirdiff--redraw)
    (let ((lines (split-string (buffer-substring-no-properties (point-min) (point-max)) "\n")))
      (mapcar #'string-trim-right (butlast (nthcdr 3 lines))))))

(defun emrs-dirdiff-test--header (buffer)
  "The second header line of BUFFER."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-min))
      (forward-line 1)
      (buffer-substring-no-properties (point) (line-end-position)))))

(defun emrs-dirdiff-test--goto (path)
  "Move point to the line of PATH."
  (goto-char (point-min))
  (while (and (not (equal (get-text-property (point) 'emrs-dirdiff-path) path))
              (zerop (forward-line 1))))
  (should (equal (get-text-property (point) 'emrs-dirdiff-path) path)))

(defmacro emrs-dirdiff-test--with-fixture (vars &rest body)
  "Bind VARS (ROOT A B BUFFER) to a fixture comparison and run BODY.
The comparison has finished when BODY runs; everything is cleaned up."
  (declare (indent 1))
  (pcase-let ((`(,root ,a ,b ,buffer) vars))
    `(let* ((,root (make-temp-file "emrs-dirdiff-fx" t))
            (dirs (emrs-dirdiff-test--fixture ,root))
            (,a (car dirs))
            (,b (cdr dirs))
            (,buffer nil))
       (ignore ,a ,b)
       (unwind-protect
           (progn
             (setq ,buffer (emrs-dirdiff--open ,a ,b))
             (should (eq (emrs-dirdiff-test--wait-done ,buffer) 'done))
             ,@body)
         (when (buffer-live-p ,buffer) (kill-buffer ,buffer))
         (delete-directory ,root t)))))

(defconst emrs-dirdiff-test--tree
  '("M    changed.txt            6 → 8         +2 −1"
    "M  ▾ deep/                  1 changed"
    "M    ▾ er/                  1 changed"
    "M        n.txt              2 → 2         +1 −1"
    "T    kindy                  kind differs (A: file)"
    "A    only-a.txt             1"
    "B    onlyb/                 2 files")
  "The tree view of the fixture.")

(ert-deftest emrs-dirdiff-test-model-and-tree ()
  "A comparison fills the model and renders the tree view."
  (emrs-dirdiff-test--with-fixture (_root _a _b buffer)
    (with-current-buffer buffer
      (should (string-match-p "\\`\\*dirdiff: a ↔ b\\*" (buffer-name)))
      (should (derived-mode-p 'emrs-dirdiff-mode))
      (let ((status (lambda (path) (plist-get (gethash path emrs-dirdiff--items) :status))))
        (should (equal (funcall status "changed.txt") "changed"))
        (should (equal (funcall status "deep/er/n.txt") "changed"))
        (should (equal (funcall status "only-a.txt") "only-a"))
        (should (equal (funcall status "onlyb") "only-b"))
        (should (equal (funcall status "kindy") "kind"))
        (should (eql (plist-get (gethash "onlyb" emrs-dirdiff--items) :files) 2))
        (should (= (hash-table-count emrs-dirdiff--items) 5)))
      (should (eql (gethash "" emrs-dirdiff--done) 3))
      (should (eql (gethash "deep" emrs-dirdiff--done) 1))
      (should (eql (gethash "deep/er" emrs-dirdiff--done) 1))
      (should (eql (gethash "sub" emrs-dirdiff--done) 1))
      (should (eq (emrs-dirdiff--status "deep") 'changed))
      (should (eq (emrs-dirdiff--status "sub") 'same))
      ;; root 7, deep 1, deep/er 2, sub 1; onlyb's contents are counted apart
      (should (eql (plist-get emrs-dirdiff--summary :files) 11))
      (should (string-match-p "\\` content · ignore files on · 11 files in [0-9.]+ s\\'"
                              mode-line-process))
      (should (equal (emrs-dirdiff-test--header buffer)
                     "2 changed · 1 only in A · 1 only in B · 1 kind differs · 3 same (hidden)"))
      (should (equal (emrs-dirdiff-test--body buffer) emrs-dirdiff-test--tree))
      ;; Every line carries its path, also after a redraw.
      (emrs-dirdiff-test--goto "deep/er/n.txt")
      (should (equal (plist-get (emrs-dirdiff--entry-at-point) :status) 'changed))
      (should (equal (emrs-dirdiff--file "deep/er/n.txt" 'b)
                     (expand-file-name "deep/er/n.txt" emrs-dirdiff--b))))))

(ert-deftest emrs-dirdiff-test-fold-and-same ()
  "TAB folds a directory; s shows identical entries after :same answers."
  (emrs-dirdiff-test--with-fixture (_root _a _b buffer)
    (with-current-buffer buffer
      (emrs-dirdiff-test--goto "deep")
      (emrs-dirdiff-toggle-fold)
      (should (equal (emrs-dirdiff--path-at-point) "deep"))
      (should (equal (emrs-dirdiff-test--body buffer)
                     '("M    changed.txt            6 → 8         +2 −1"
                       "M  ▸ deep/                  1 changed"
                       "T    kindy                  kind differs (A: file)"
                       "A    only-a.txt             1"
                       "B    onlyb/                 2 files")))
      (emrs-dirdiff-toggle-fold)
      (should (equal (emrs-dirdiff-test--body buffer) emrs-dirdiff-test--tree))
      ;; The fold state survives a comparison.
      (emrs-dirdiff-test--goto "deep/er")
      (emrs-dirdiff-toggle-fold)
      (emrs-dirdiff-rescan)
      (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
      (should (equal (emrs-dirdiff--path-at-point) "deep/er"))
      (should (equal (nth 2 (emrs-dirdiff-test--body buffer))
                     "M    ▸ er/                  1 changed"))
      (emrs-dirdiff-toggle-fold)
      (emrs-dirdiff-toggle-same)
      (should (emrs-dirdiff-test--wait
               (lambda ()
                 (and (eq (car (gethash "" emrs-dirdiff--same)) 'done)
                      (eq (car (gethash "deep/er" emrs-dirdiff--same)) 'done)))))
      (should (equal (emrs-dirdiff-test--body buffer)
                     '("M    changed.txt            6 → 8         +2 −1"
                       "M  ▾ deep/                  1 changed"
                       "M    ▾ er/                  1 changed"
                       "M        n.txt              2 → 2         +1 −1"
                       "         same3              1"
                       "T    kindy                  kind differs (A: file)"
                       "A    only-a.txt             1"
                       "B    onlyb/                 2 files"
                       "     same.txt               5"
                       "   ▸ sub/                   1 same")))
      (should (string-suffix-p "3 same (shown)" (emrs-dirdiff-test--header buffer)))
      (emrs-dirdiff-toggle-same)
      (should (equal (emrs-dirdiff-test--body buffer) emrs-dirdiff-test--tree)))))

(ert-deftest emrs-dirdiff-test-subtree-rescan ()
  "g with a prefix on a directory compares only that subtree."
  (emrs-dirdiff-test--with-fixture (_root _a b buffer)
    ;; n.txt becomes identical; same.txt changes, outside the subtree.
    (emrs-dirdiff-test--put b "deep/er/n.txt" "1\n")
    (emrs-dirdiff-test--put b "same.txt" "different\n")
    (with-current-buffer buffer
      (let ((summary emrs-dirdiff--summary)
            (started emrs-dirdiff--started)
            (ended emrs-dirdiff--ended))
        (emrs-dirdiff-test--goto "deep")
        (emrs-dirdiff-rescan '(4))
        (should (string-prefix-p "Comparing deep…" (emrs-dirdiff-test--header buffer)))
        (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
        ;; The totals and time of the whole comparison stay.
        (should (eq emrs-dirdiff--summary summary))
        (should (eql emrs-dirdiff--started started))
        (should (eql emrs-dirdiff--ended ended))
        (should (string-match-p " · 11 files in [0-9.]+ s\\'" mode-line-process))
        (should-not emrs-dirdiff--rescan))
      (should-not (gethash "deep/er/n.txt" emrs-dirdiff--items))
      (should-not (gethash "same.txt" emrs-dirdiff--items))
      (should (gethash "changed.txt" emrs-dirdiff--items))
      (should (eql (gethash "deep/er" emrs-dirdiff--done) 2))
      (should (eql (gethash "deep" emrs-dirdiff--done) 2))
      (should (eql (gethash "" emrs-dirdiff--done) 4))
      (should (equal (emrs-dirdiff-test--header buffer)
                     "1 changed · 1 only in A · 1 only in B · 1 kind differs · 4 same (hidden)"))
      (should (equal (emrs-dirdiff-test--body buffer)
                     '("M    changed.txt            6 → 8         +2 −1"
                       "T    kindy                  kind differs (A: file)"
                       "A    only-a.txt             1"
                       "B    onlyb/                 2 files")))
      ;; Only directories present on both sides can be rescanned.
      (emrs-dirdiff-test--goto "onlyb")
      (should-error (emrs-dirdiff-rescan '(4)) :type 'user-error))))

(ert-deftest emrs-dirdiff-test-validation ()
  "Bad directory pairs are refused before anything starts."
  (let* ((root (make-temp-file "emrs-dirdiff-val" t))
         (a (expand-file-name "a" root))
         (b (expand-file-name "b" root))
         (file (expand-file-name "file" root)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "inner" a) t)
          (make-directory b)
          (emrs-dirdiff-test--put root "file" "x")
          (let ((check (lambda (x y regexp)
                         (let ((err (should-error (emrs-dirdiff--open x y)
                                                  :type 'user-error)))
                           (should (string-match-p regexp (cadr err)))))))
            (funcall check a file "Not a directory")
            (funcall check (expand-file-name "missing" root) b "Not a directory")
            (funcall check "/ssh:nohost.invalid:/tmp" b "ztree-diff")
            (funcall check a (concat a "/") "same directory")
            (funcall check a (expand-file-name "inner" a) "inside")
            (funcall check (expand-file-name "inner" a) a "inside"))
          (should (equal (emrs-dirdiff--check-dirs a (concat b "/."))
                         (cons (file-name-as-directory (file-truename a))
                               (file-name-as-directory (file-truename b))))))
      (delete-directory root t))))

(ert-deftest emrs-dirdiff-test-kill-stops-instance ()
  "Killing the buffer stops its instance; the same pair reuses the buffer."
  (let* ((root (make-temp-file "emrs-dirdiff-kill" t))
         (dirs (emrs-dirdiff-test--fixture root))
         (buffer (emrs-dirdiff--open (car dirs) (cdr dirs))))
    (unwind-protect
        (let ((instance (buffer-local-value 'emrs-dirdiff--instance buffer)))
          (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
          (should (eq (emrs-dirdiff--open (car dirs) (cdr dirs)) buffer))
          (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
          (should (eq (emrs-instance-state instance) 'running))
          (kill-buffer buffer)
          (should (memq (emrs-instance-state instance) '(stopping stopped)))
          (should (emrs-dirdiff-test--wait
                   (lambda () (eq (emrs-instance-state instance) 'stopped)))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest emrs-dirdiff-test-start-failure-shown ()
  "A failing instance shows its error in the header; g starts a new one."
  (let* ((root (make-temp-file "emrs-dirdiff-fail" t))
         (dirs (emrs-dirdiff-test--fixture root))
         (buffer (emrs-dirdiff--open (car dirs) (cdr dirs))))
    (unwind-protect
        (with-current-buffer buffer
          (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
          (let ((old emrs-dirdiff--instance))
            ;; Make the next start fail: B no longer exists.
            (emrs-dirdiff--stop old)
            (should (emrs-dirdiff-test--wait
                     (lambda () (eq (emrs-instance-state old) 'stopped))))
            (rename-file (cdr dirs) (concat (directory-file-name (cdr dirs)) "-moved"))
            (emrs-dirdiff-rescan)
            (should (eq (emrs-dirdiff-test--wait-done buffer) 'failed))
            (should (emrs-dirdiff-test--wait (lambda () emrs-dirdiff--instance-error)))
            (emrs-dirdiff--redraw)
            (should (string-prefix-p "Error: " (emrs-dirdiff-test--header buffer)))
            (rename-file (concat (directory-file-name (cdr dirs)) "-moved") (cdr dirs))
            (emrs-dirdiff-rescan)
            (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
            (should-not emrs-dirdiff--instance-error)
            (should-not (eq emrs-dirdiff--instance old))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest emrs-dirdiff-test-stop ()
  "C-c C-k stops a running comparison and the header says so."
  (let* ((root (make-temp-file "emrs-dirdiff-stop" t))
         (dirs (emrs-dirdiff-test--fixture root))
         (buffer (emrs-dirdiff--open (car dirs) (cdr dirs))))
    (unwind-protect
        (with-current-buffer buffer
          (should (eq emrs-dirdiff--state 'running))
          (emrs-dirdiff-stop)
          (should (eq emrs-dirdiff--state 'stopped))
          (should (string-prefix-p "Stopped after" (emrs-dirdiff-test--header buffer))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest emrs-dirdiff-test-dired-marked ()
  "emrs-dirdiff-dired compares the two directories marked in dired."
  (let* ((root (make-temp-file "emrs-dirdiff-dired" t))
         (dirs (emrs-dirdiff-test--fixture root))
         (dired (dired-noselect root))
         (buffer nil))
    (unwind-protect
        (save-window-excursion
          (with-current-buffer dired
            (dired-goto-file (car dirs))
            (dired-mark 1)
            (dired-goto-file (cdr dirs))
            (dired-mark 1)
            (emrs-dirdiff-dired)
            (setq buffer (window-buffer (selected-window))))
          (with-current-buffer buffer
            (should (derived-mode-p 'emrs-dirdiff-mode))
            (should (equal emrs-dirdiff--a (file-name-as-directory (file-truename (car dirs)))))
            (should (equal emrs-dirdiff--b (file-name-as-directory (file-truename (cdr dirs))))))
          (should (eq (emrs-dirdiff-test--wait-done buffer) 'done)))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (kill-buffer dired)
      (delete-directory root t))))

;;;; Section view, navigation, filters, opening and settings

(defconst emrs-dirdiff-test--sections
  '("▾ Changed (2)"
    "    changed.txt                 6 → 8         +2 −1"
    "    deep/er/n.txt               2 → 2         +1 −1"
    ""
    "▾ Only in A (1)"
    "    only-a.txt                  1"
    ""
    "▾ Only in B (1)"
    "    onlyb/                      2 files"
    ""
    "▾ Kind differs (1)"
    "    kindy                       kind differs (A: file)"
    ""
    "▸ Same (3)")
  "The section view of the fixture.")

(defun emrs-dirdiff-test--wait-same (buffer)
  "Wait until BUFFER has fetched `:same' for every finished directory."
  (emrs-dirdiff-test--wait
   (lambda ()
     (with-current-buffer buffer
       (let ((all t))
         (maphash (lambda (dir _)
                    (unless (eq (car (gethash dir emrs-dirdiff--same)) 'done)
                      (setq all nil)))
                  emrs-dirdiff--done)
         all)))))

(defun emrs-dirdiff-test--goto-section (section)
  "Move point to the header of SECTION."
  (goto-char (point-min))
  (while (and (not (eq (get-text-property (point) 'emrs-dirdiff-section) section))
              (zerop (forward-line 1))))
  (should (eq (get-text-property (point) 'emrs-dirdiff-section) section)))

(defun emrs-dirdiff-test--paths (buffer)
  "The paths of the entry lines of BUFFER, in order."
  (with-current-buffer buffer
    (emrs-dirdiff--redraw)
    (let (paths)
      (save-excursion
        (goto-char (point-min))
        (while (not (eobp))
          (when-let* ((path (emrs-dirdiff--path-at-point)))
            (push path paths))
          (forward-line 1)))
      (nreverse paths))))

(defun emrs-dirdiff-test--visit-all (command)
  "Run COMMAND from the top of the buffer until it fails; return the lines it
visited, as paths or section symbols."
  (goto-char (point-min))
  (let (seen)
    (while (condition-case nil
               (progn (funcall command) t)
             (user-error nil))
      (push (or (emrs-dirdiff--section-at-point) (emrs-dirdiff--path-at-point)) seen))
    (nreverse seen)))

(ert-deftest emrs-dirdiff-test-fold-all ()
  "S-TAB folds every directory or section, and unfolds them again."
  (emrs-dirdiff-test--with-fixture (_root _a _b buffer)
    (with-current-buffer buffer
      (emrs-dirdiff-test--goto "deep/er/n.txt")
      (emrs-dirdiff-toggle-fold-all)
      (should (equal (emrs-dirdiff-test--body buffer)
                     '("M    changed.txt            6 → 8         +2 −1"
                       "M  ▸ deep/                  1 changed"
                       "T    kindy                  kind differs (A: file)"
                       "A    only-a.txt             1"
                       "B    onlyb/                 2 files")))
      ;; Point moves to a line that is still shown.
      (should (emrs-dirdiff--path-at-point))
      ;; A directory unfolded inside a folded one is not shown, so the next
      ;; S-TAB still unfolds everything.
      (emrs-dirdiff-test--goto "deep")
      (emrs-dirdiff-toggle-fold)
      (emrs-dirdiff-test--goto "deep/er")
      (emrs-dirdiff-toggle-fold)
      (emrs-dirdiff-test--goto "deep")
      (emrs-dirdiff-toggle-fold)
      (should (equal (gethash "deep/er" emrs-dirdiff--folds) 'open))
      (emrs-dirdiff-toggle-fold-all)
      (should (equal (emrs-dirdiff-test--body buffer) emrs-dirdiff-test--tree))
      ;; Something is unfolded now, so S-TAB folds again.
      (emrs-dirdiff-toggle-fold-all)
      (should (equal (nth 1 (emrs-dirdiff-test--body buffer))
                     "M  ▸ deep/                  1 changed"))
      (emrs-dirdiff-toggle-fold-all)
      (should (equal (emrs-dirdiff-test--body buffer) emrs-dirdiff-test--tree))
      ;; In the section view it applies to the sections.
      (emrs-dirdiff-toggle-view)
      (emrs-dirdiff-toggle-fold-all)
      (should (seq-every-p (lambda (line) (or (equal line "") (string-prefix-p "▸ " line)))
                           (emrs-dirdiff-test--body buffer)))
      (emrs-dirdiff-toggle-fold-all)
      (should (seq-every-p #'emrs-dirdiff--section-open-p
                           (mapcar #'car emrs-dirdiff--sections))))))

(ert-deftest emrs-dirdiff-test-section-view ()
  "The section view renders sections in order; v keeps point; TAB folds."
  (emrs-dirdiff-test--with-fixture (_root _a _b buffer)
    (with-current-buffer buffer
      (emrs-dirdiff-toggle-view)
      (should (eq emrs-dirdiff--view 'sections))
      (should (equal (emrs-dirdiff-test--body buffer) emrs-dirdiff-test--sections))
      ;; Point stays on the same path across the toggle.
      (emrs-dirdiff-test--goto "deep/er/n.txt")
      (emrs-dirdiff-toggle-view)
      (should (eq emrs-dirdiff--view 'tree))
      (should (equal (emrs-dirdiff--path-at-point) "deep/er/n.txt"))
      (emrs-dirdiff-test--goto "kindy")
      (emrs-dirdiff-toggle-view)
      (should (equal (emrs-dirdiff--path-at-point) "kindy"))
      ;; A directory the section view does not list: point lands on an entry.
      (emrs-dirdiff-toggle-view)
      (emrs-dirdiff-test--goto "deep")
      (emrs-dirdiff-toggle-view)
      (should (emrs-dirdiff--path-at-point))
      ;; TAB folds a section; the state survives a redraw and a comparison.
      (emrs-dirdiff-test--goto-section 'changed)
      (emrs-dirdiff-toggle-fold)
      (should (eq (emrs-dirdiff--section-at-point) 'changed))
      (should (equal (nth 0 (emrs-dirdiff-test--body buffer)) "▸ Changed (2)"))
      (should (equal (nth 1 (emrs-dirdiff-test--body buffer)) ""))
      (emrs-dirdiff-rescan)
      (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
      (should (eq (emrs-dirdiff--section-at-point) 'changed))
      (should (equal (nth 0 (emrs-dirdiff-test--body buffer)) "▸ Changed (2)"))
      (emrs-dirdiff-toggle-fold)
      (should (equal (emrs-dirdiff-test--body buffer) emrs-dirdiff-test--sections))
      ;; TAB on an entry does nothing useful.
      (emrs-dirdiff-test--goto "only-a.txt")
      (should-error (emrs-dirdiff-toggle-fold) :type 'user-error)
      ;; Unfolding Same lists the identical files after the :same replies.
      (emrs-dirdiff-test--goto-section 'same)
      (emrs-dirdiff-toggle-fold)
      (should (emrs-dirdiff-test--wait-same buffer))
      (should (equal (nthcdr 13 (emrs-dirdiff-test--body buffer))
                     '("▾ Same (3)"
                       "    deep/er/same3               1"
                       "    same.txt                    5"
                       "    sub/same2                   1")))
      (should (string-suffix-p "3 same (shown)" (emrs-dirdiff-test--header buffer)))
      (emrs-dirdiff-toggle-fold)
      (should (equal (emrs-dirdiff-test--body buffer) emrs-dirdiff-test--sections)))))

(ert-deftest emrs-dirdiff-test-section-view-while-running ()
  "Sections fill as items arrive: a render while the comparison runs shows
the sections found so far.
The items below deep, the root's `done' item, the summary and the end of
the stream are held back until the partial render has been checked."
  (let* ((root (make-temp-file "emrs-dirdiff-run" t))
         (dirs (emrs-dirdiff-test--fixture root))
         (buffer nil)
         (add (symbol-function 'emrs-dirdiff--model-add))
         (on-end (symbol-function 'emrs-dirdiff--on-end))
         (held nil)
         (end nil))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'emrs-dirdiff--model-add)
                     (lambda (item)
                       (let ((path (plist-get item :path)))
                         (if (or (plist-get item :summary)
                                 (equal path "")
                                 (string-prefix-p "deep" path))
                             (push item held)
                           (funcall add item)))))
                    ((symbol-function 'emrs-dirdiff--on-end)
                     (lambda (status err) (setq end (list status err)))))
            (let ((emrs-dirdiff-default-view 'sections))
              (setq buffer (emrs-dirdiff--open (car dirs) (cdr dirs))))
            (should (eq (buffer-local-value 'emrs-dirdiff--view buffer) 'sections))
            (should (emrs-dirdiff-test--wait (lambda () end)))
            (should (eq (buffer-local-value 'emrs-dirdiff--state buffer) 'running))
            (should (equal (emrs-dirdiff-test--body buffer)
                           '("▾ Changed (1)"
                             "    changed.txt                 6 → 8         +2 −1"
                             ""
                             "▾ Only in A (1)"
                             "    only-a.txt                  1"
                             ""
                             "▾ Only in B (1)"
                             "    onlyb/                      2 files"
                             ""
                             "▾ Kind differs (1)"
                             "    kindy                       kind differs (A: file)")))
            (should (string-prefix-p "Comparing… 4 differences so far"
                                     (emrs-dirdiff-test--header buffer))))
          (with-current-buffer buffer
            (dolist (item (nreverse held))
              (funcall add item))
            (funcall on-end (car end) (cadr end)))
          (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
          (should (equal (emrs-dirdiff-test--body buffer) emrs-dirdiff-test--sections)))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(defun emrs-dirdiff-test--stops-mid-stream (stop)
  "Open a comparison, call STOP with its buffer while it runs, and check
that the instance stops, the stream is cancelled and no timer is left."
  (let* ((root (make-temp-file "emrs-dirdiff-mid" t))
         (dirs (emrs-dirdiff-test--fixture root))
         (buffer (emrs-dirdiff--open (car dirs) (cdr dirs))))
    (unwind-protect
        (let ((instance (buffer-local-value 'emrs-dirdiff--instance buffer))
              (call (buffer-local-value 'emrs-dirdiff--stream buffer))
              (tick (buffer-local-value 'emrs-dirdiff--tick-timer buffer))
              (redraw (with-current-buffer buffer
                        (emrs-dirdiff--schedule-redraw)
                        emrs-dirdiff--redraw-timer)))
          (should (eq (buffer-local-value 'emrs-dirdiff--state buffer) 'running))
          (should (and call tick redraw))
          (funcall stop buffer)
          (should-not (memq tick timer-list))
          (should-not (memq redraw timer-list))
          (should (emrs-call-done call))
          (should (memq (emrs-instance-state instance) '(stopping stopped)))
          (should (emrs-dirdiff-test--wait
                   (lambda () (eq (emrs-instance-state instance) 'stopped))))
          ;; Nothing fires later for the buffer.
          (should-not (cl-some (lambda (timer) (memq buffer (timer--args timer)))
                               timer-list)))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest emrs-dirdiff-test-kill-mid-stream ()
  "Killing the buffer while it compares stops the instance and its timers."
  (emrs-dirdiff-test--stops-mid-stream #'kill-buffer))

(ert-deftest emrs-dirdiff-test-change-major-mode-stops ()
  "Changing the major mode stops the instance and its timers, as killing does."
  (emrs-dirdiff-test--stops-mid-stream
   (lambda (buffer) (with-current-buffer buffer (fundamental-mode)))))

(ert-deftest emrs-dirdiff-test-navigation ()
  "n, p, N, P and ^ move between differences in both views."
  (emrs-dirdiff-test--with-fixture (_root _a _b buffer)
    (with-current-buffer buffer
      (emrs-dirdiff--redraw)
      (should (equal (emrs-dirdiff-test--visit-all #'emrs-dirdiff-next-difference)
                     '("changed.txt" "deep" "deep/er" "deep/er/n.txt" "kindy" "only-a.txt" "onlyb")))
      (should (equal (emrs-dirdiff-test--visit-all #'emrs-dirdiff-next-group)
                     '("deep" "deep/er")))
      (goto-char (point-max))
      (let (seen)
        (while (condition-case nil
                   (progn (emrs-dirdiff-previous-difference) t)
                 (user-error nil))
          (push (emrs-dirdiff--path-at-point) seen))
        (should (equal seen '("changed.txt" "deep" "deep/er" "deep/er/n.txt" "kindy"
                              "only-a.txt" "onlyb"))))
      (emrs-dirdiff-test--goto "onlyb")
      (emrs-dirdiff-previous-group)
      (should (equal (emrs-dirdiff--path-at-point) "deep/er"))
      (emrs-dirdiff-previous-group)
      (should (equal (emrs-dirdiff--path-at-point) "deep"))
      (should-error (emrs-dirdiff-previous-group) :type 'user-error)
      (should (equal (emrs-dirdiff--path-at-point) "deep"))
      ;; ^
      (emrs-dirdiff-test--goto "deep/er/n.txt")
      (emrs-dirdiff-up)
      (should (equal (emrs-dirdiff--path-at-point) "deep/er"))
      (emrs-dirdiff-up)
      (should (equal (emrs-dirdiff--path-at-point) "deep"))
      (should-error (emrs-dirdiff-up) :type 'user-error)
      ;; Identical entries are not differences.
      (emrs-dirdiff-toggle-same)
      (should (emrs-dirdiff-test--wait
               (lambda () (eq (car (gethash "" emrs-dirdiff--same)) 'done))))
      (emrs-dirdiff--redraw)
      (should (member "same.txt" (emrs-dirdiff-test--paths buffer)))
      (should (equal (emrs-dirdiff-test--visit-all #'emrs-dirdiff-next-difference)
                     '("changed.txt" "deep" "deep/er" "deep/er/n.txt" "kindy" "only-a.txt" "onlyb")))
      (emrs-dirdiff-toggle-same)
      ;; Section view
      (emrs-dirdiff-toggle-view)
      (should (equal (emrs-dirdiff-test--visit-all #'emrs-dirdiff-next-difference)
                     '("changed.txt" "deep/er/n.txt" "only-a.txt" "onlyb" "kindy")))
      (should (equal (emrs-dirdiff-test--visit-all #'emrs-dirdiff-next-group)
                     '(changed only-a only-b kind same)))
      (goto-char (point-max))
      (emrs-dirdiff-previous-group)
      (should (eq (emrs-dirdiff--section-at-point) 'same))
      (emrs-dirdiff-previous-group)
      (should (eq (emrs-dirdiff--section-at-point) 'kind))
      (emrs-dirdiff-previous-group)
      (should (eq (emrs-dirdiff--section-at-point) 'only-b))
      (emrs-dirdiff-previous-difference)
      (should (equal (emrs-dirdiff--path-at-point) "only-a.txt"))
      (emrs-dirdiff-test--goto "only-a.txt")
      (should-error (emrs-dirdiff-up) :type 'user-error))))

(ert-deftest emrs-dirdiff-test-filters ()
  "/ and f filter both views, the header names the filters, clearing restores."
  (emrs-dirdiff-test--with-fixture (_root a _b buffer)
    (emrs-dirdiff-test--put a "ReadMe.md" "x")
    (with-current-buffer buffer
      (emrs-dirdiff-rescan)
      (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
      (let ((all (emrs-dirdiff-test--paths buffer))
            (counts "2 changed · 2 only in A · 1 only in B · 1 kind differs · 3 same (hidden)"))
        (should (equal all '("ReadMe.md" "changed.txt" "deep" "deep/er" "deep/er/n.txt"
                             "kindy" "only-a.txt" "onlyb")))
        (should (equal (emrs-dirdiff-test--header buffer) counts))
        ;; Name filter, case-insensitive for lowercase input.
        (emrs-dirdiff-filter-name "n.tx")
        (should (equal (emrs-dirdiff-test--paths buffer) '("deep" "deep/er" "deep/er/n.txt")))
        (should (equal (emrs-dirdiff-test--header buffer)
                       (concat counts "   filter: \"n.tx\"")))
        (emrs-dirdiff-filter-name "readme")
        (should (equal (emrs-dirdiff-test--paths buffer) '("ReadMe.md")))
        (emrs-dirdiff-filter-name "README")
        (should (equal (emrs-dirdiff-test--paths buffer) nil))
        (emrs-dirdiff-filter-name "ReadMe")
        (should (equal (emrs-dirdiff-test--paths buffer) '("ReadMe.md")))
        (emrs-dirdiff-filter-name "")
        (should (equal (emrs-dirdiff-test--paths buffer) all))
        (should (equal (emrs-dirdiff-test--header buffer) counts))
        ;; Status filter cycles all -> changed -> only A -> only B -> all.
        (emrs-dirdiff-cycle-status-filter)
        (should (equal (emrs-dirdiff-test--paths buffer)
                       '("changed.txt" "deep" "deep/er" "deep/er/n.txt")))
        (should (string-suffix-p "   filter: only changed" (emrs-dirdiff-test--header buffer)))
        (emrs-dirdiff-cycle-status-filter)
        (should (equal (emrs-dirdiff-test--paths buffer) '("ReadMe.md" "only-a.txt")))
        (emrs-dirdiff-cycle-status-filter)
        (should (equal (emrs-dirdiff-test--paths buffer) '("onlyb")))
        (should (string-suffix-p "   filter: only in B" (emrs-dirdiff-test--header buffer)))
        ;; Both filters, in the section view.
        (emrs-dirdiff-cycle-status-filter)
        (should (equal (emrs-dirdiff-test--paths buffer) all))
        (emrs-dirdiff-toggle-view)
        (emrs-dirdiff-cycle-status-filter)
        (emrs-dirdiff-filter-name "n")
        (should (equal (emrs-dirdiff-test--body buffer)
                       '("▾ Changed (2)"
                         "    changed.txt                 6 → 8         +2 −1"
                         "    deep/er/n.txt               2 → 2         +1 −1")))
        (should (equal (emrs-dirdiff-test--header buffer)
                       (concat counts "   filter: \"n\" · only changed")))
        (emrs-dirdiff-cycle-status-filter)
        (should (equal (emrs-dirdiff-test--body buffer)
                       '("▾ Only in A (1)"
                         "    only-a.txt                  1")))
        (emrs-dirdiff-cycle-status-filter)
        (emrs-dirdiff-cycle-status-filter)
        (emrs-dirdiff-filter-name "")
        (should (equal (emrs-dirdiff-test--paths buffer)
                       '("changed.txt" "deep/er/n.txt" "ReadMe.md" "only-a.txt" "onlyb" "kindy")))
        (should (equal (emrs-dirdiff-test--header buffer) counts))))))

(ert-deftest emrs-dirdiff-test-open-and-visit ()
  "RET, e, o, O and d open the right things; w copies paths."
  (emrs-dirdiff-test--with-fixture (_root a b buffer)
    (let ((created nil))
      (unwind-protect
          (save-window-excursion
            (switch-to-buffer buffer)
            (with-current-buffer buffer
              (dolist (view '(tree sections))
                (setq emrs-dirdiff--view view)
                (emrs-dirdiff--redraw)
                ;; RET on a changed pair: a diff-mode buffer with the hunk.
                (emrs-dirdiff-test--goto "changed.txt")
                (emrs-dirdiff-open)
                (let ((diff (window-buffer (selected-window))))
                  (push diff created)
                  (should (with-current-buffer diff (derived-mode-p 'diff-mode)))
                  (let ((text (with-current-buffer diff (buffer-string))))
                    (should (string-match-p "^-b$" text))
                    (should (string-match-p "^\\+B$" text))
                    (should (string-match-p "^\\+d$" text))))
                (select-window (get-buffer-window buffer))
                ;; RET on a one-sided file visits it.
                (emrs-dirdiff-test--goto "only-a.txt")
                (emrs-dirdiff-open)
                (should (equal (buffer-file-name) (expand-file-name "only-a.txt" a)))
                (push (current-buffer) created)
                (select-window (get-buffer-window buffer))
                ;; o and O
                (emrs-dirdiff-test--goto "changed.txt")
                (emrs-dirdiff-visit-a)
                (should (equal (buffer-file-name) (expand-file-name "changed.txt" a)))
                (push (current-buffer) created)
                (select-window (get-buffer-window buffer))
                (emrs-dirdiff-visit-b)
                (should (equal (buffer-file-name) (expand-file-name "changed.txt" b)))
                (push (current-buffer) created)
                (select-window (get-buffer-window buffer))
                (emrs-dirdiff-test--goto "only-a.txt")
                (should-error (emrs-dirdiff-visit-b) :type 'user-error)
                (emrs-dirdiff-test--goto "onlyb")
                (should-error (emrs-dirdiff-visit-a) :type 'user-error)
                (emrs-dirdiff-visit-b)
                (should (equal (file-name-as-directory (expand-file-name dired-directory))
                               (expand-file-name "onlyb/" b)))
                (push (current-buffer) created)
                (select-window (get-buffer-window buffer))
                ;; d: Dired at the directory of the entry, point on it.
                (emrs-dirdiff-test--goto "deep/er/n.txt")
                (emrs-dirdiff-dired-entry)
                (should (equal (file-name-as-directory (expand-file-name dired-directory)) (expand-file-name "deep/er/" a)))
                (should (equal (dired-get-filename) (expand-file-name "deep/er/n.txt" a)))
                (push (current-buffer) created)
                (select-window (get-buffer-window buffer))
                (emrs-dirdiff-test--goto "onlyb")
                (emrs-dirdiff-dired-entry)
                (should (equal (file-name-as-directory (expand-file-name dired-directory)) (file-name-as-directory b)))
                (should (equal (directory-file-name (dired-get-filename))
                               (expand-file-name "onlyb" b)))
                (push (current-buffer) created)
                (select-window (get-buffer-window buffer))
                ;; RET on a kind difference does nothing useful.
                (emrs-dirdiff-test--goto "kindy")
                (should-error (emrs-dirdiff-open) :type 'user-error)
                (should-error (emrs-dirdiff-ediff) :type 'user-error)
                ;; e: ediff-files with the pair.
                (emrs-dirdiff-test--goto "deep/er/n.txt")
                (let (args)
                  (cl-letf (((symbol-function 'ediff-files)
                             (lambda (x y &rest _) (setq args (list x y)))))
                    (emrs-dirdiff-ediff))
                  (should (equal args (list (expand-file-name "deep/er/n.txt" a)
                                            (expand-file-name "deep/er/n.txt" b)))))
                (emrs-dirdiff-test--goto "only-a.txt")
                (should-error (emrs-dirdiff-ediff) :type 'user-error)
                ;; w
                (emrs-dirdiff-test--goto "deep/er/n.txt")
                (emrs-dirdiff-copy-path)
                (should (equal (car kill-ring) "deep/er/n.txt"))
                (emrs-dirdiff-copy-path '(4))
                (should (equal (car kill-ring) (expand-file-name "deep/er/n.txt" a)))
                (emrs-dirdiff-test--goto "onlyb")
                (emrs-dirdiff-copy-path '(4))
                (should (equal (car kill-ring) (expand-file-name "onlyb" b))))
              ;; RET in the tree on a directory folds it; in sections on a header.
              (setq emrs-dirdiff--view 'tree)
              (emrs-dirdiff--redraw)
              (emrs-dirdiff-test--goto "deep")
              (emrs-dirdiff-open)
              (should (eq (gethash "deep" emrs-dirdiff--folds) 'closed))
              (emrs-dirdiff-open)
              (should (eq (gethash "deep" emrs-dirdiff--folds) 'open))
              (setq emrs-dirdiff--view 'sections)
              (emrs-dirdiff--redraw)
              (emrs-dirdiff-test--goto-section 'changed)
              (emrs-dirdiff-open)
              (should (eq (gethash 'changed emrs-dirdiff--section-folds) 'closed))
              (goto-char (point-min))
              (should-error (emrs-dirdiff-open) :type 'user-error)))
        (dolist (buf created)
          (when (buffer-live-p buf)
            (with-current-buffer buf (set-buffer-modified-p nil))
            (kill-buffer buf)))))))

(ert-deftest emrs-dirdiff-test-diff-honours-whitespace ()
  "The diff switches carry -w when whitespace is ignored."
  (with-temp-buffer
    (let ((diff-switches "-u"))
      (setq-local emrs-dirdiff--whitespace nil)
      (should (equal (emrs-dirdiff--diff-switches) '("-u")))
      (setq-local emrs-dirdiff--whitespace t)
      (should (equal (emrs-dirdiff--diff-switches) '("-u" "-w"))))))

(defun emrs-dirdiff-test--rescan-wait (buffer)
  "Compare again in BUFFER and wait for the end."
  (with-current-buffer buffer (emrs-dirdiff-rescan))
  (should (eq (emrs-dirdiff-test--wait-done buffer) 'done)))

(ert-deftest emrs-dirdiff-test-comparison-toggles ()
  "c, t, W and i change the setting and rescan with it."
  (emrs-dirdiff-test--with-fixture (_root a b buffer)
    (let ((item (lambda (path) (gethash path (buffer-local-value 'emrs-dirdiff--items buffer)))))
      ;; Content differs, size and time are equal.
      (emrs-dirdiff-test--put a "eq.txt" "aaaa")
      (emrs-dirdiff-test--put b "eq.txt" "bbbb")
      (set-file-times (expand-file-name "eq.txt" a) '(1700000000 0))
      (set-file-times (expand-file-name "eq.txt" b) '(1700000000 0))
      ;; Whitespace-only difference.
      (emrs-dirdiff-test--put a "ws.txt" "a b\n")
      (emrs-dirdiff-test--put b "ws.txt" "a  b\n")
      ;; Ignored on both sides.
      (dolist (dir (list a b))
        (emrs-dirdiff-test--put dir ".ignore" "secret.txt\n"))
      (emrs-dirdiff-test--put a "secret.txt" "s")
      (emrs-dirdiff-test--rescan-wait buffer)
      (should (equal (plist-get (funcall item "eq.txt") :status) "changed"))
      (should (equal (plist-get (funcall item "ws.txt") :status) "changed"))
      (should-not (funcall item "secret.txt"))
      (with-current-buffer buffer
        (emrs-dirdiff-compare-size-time)
        (should (eq emrs-dirdiff--by 'size-time))
        (should (string-match-p "size\\+time" (emrs-dirdiff--mode-line))))
      (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
      (should-not (funcall item "eq.txt"))
      (with-current-buffer buffer
        (emrs-dirdiff-compare-content)
        (should (eq emrs-dirdiff--by 'content)))
      (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
      (should (funcall item "eq.txt"))
      ;; W
      (with-current-buffer buffer (emrs-dirdiff-toggle-whitespace))
      (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
      (should (buffer-local-value 'emrs-dirdiff--whitespace buffer))
      (should-not (funcall item "ws.txt"))
      (should (funcall item "eq.txt"))
      (with-current-buffer buffer (emrs-dirdiff-toggle-whitespace))
      (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
      (should (funcall item "ws.txt"))
      ;; i
      (with-current-buffer buffer (emrs-dirdiff-toggle-ignore-files))
      (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
      (should-not (buffer-local-value 'emrs-dirdiff--ignore-files buffer))
      (should (equal (plist-get (funcall item "secret.txt") :status) "only-a"))
      (with-current-buffer buffer (emrs-dirdiff-toggle-ignore-files))
      (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
      (should-not (funcall item "secret.txt")))))

(ert-deftest emrs-dirdiff-test-swap ()
  "x swaps A and B with a new instance, keeping the view and folds."
  (emrs-dirdiff-test--with-fixture (_root a b buffer)
    (with-current-buffer buffer
      (setq emrs-dirdiff--view 'sections)
      (puthash 'changed 'closed emrs-dirdiff--section-folds)
      (puthash "deep" 'closed emrs-dirdiff--folds)
      (puthash "only-a.txt" t emrs-dirdiff--marks)
      (let ((old emrs-dirdiff--instance))
        (emrs-dirdiff-swap)
        ;; A mark chose a direction too; swapping clears them all.
        (should (= (hash-table-count emrs-dirdiff--marks) 0))
        (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
        (should-not (eq emrs-dirdiff--instance old))
        (should (emrs-dirdiff-test--wait (lambda () (eq (emrs-instance-state old) 'stopped))))
        (should (equal emrs-dirdiff--a (file-name-as-directory b)))
        (should (equal emrs-dirdiff--b (file-name-as-directory a)))
        (should (string-match-p "\\`\\*dirdiff: b ↔ a\\*" (buffer-name)))
        (should (eq emrs-dirdiff--view 'sections))
        (should (eq (gethash 'changed emrs-dirdiff--section-folds) 'closed))
        (should (eq (gethash "deep" emrs-dirdiff--folds) 'closed))
        (should (equal (plist-get (gethash "only-a.txt" emrs-dirdiff--items) :status) "only-b"))
        (should (equal (plist-get (gethash "onlyb" emrs-dirdiff--items) :status) "only-a"))
        (should (equal (emrs-dirdiff-test--header buffer)
                       "2 changed · 1 only in A · 1 only in B · 1 kind differs · 3 same (hidden)"))
        (should (equal (nth 0 (emrs-dirdiff-test--body buffer)) "▸ Changed (2)"))))))

(defun emrs-dirdiff-test--generate (dir differ)
  "Create 20 × 10 × 100 files below DIR; DIFFER (a predicate on the
file index) selects files with other contents."
  (dotimes (i 20)
    (dotimes (j 10)
      (let ((sub (expand-file-name (format "d%02d/e%d" i j) dir)))
        (make-directory sub t)
        (dotimes (k 100)
          (let ((n (+ (* 1000 i) (* 100 j) k)))
            (write-region (if (funcall differ n) (format "other %d\n" n) (format "file %d\n" n))
                          nil (expand-file-name (format "f%03d" k) sub) nil 'silent)))))))

(defun emrs-dirdiff-test--max-delay ()
  "The allowed timer delay in seconds: EMRS_DIRDIFF_TEST_MAX_DELAY ms, else 50 ms.
CI sets a higher value: shared runners are two to three times slower."
  (let ((ms (getenv "EMRS_DIRDIFF_TEST_MAX_DELAY")))
    (/ (if (and ms (> (string-to-number ms) 0)) (string-to-number ms) 50) 1000.0)))

(ert-deftest emrs-dirdiff-test-responsiveness ()
  "A 10 ms timer is never delayed by more than 50 ms during a comparison.
The buffer is shown, so the throttled redraws run; the tree is compared
three times to measure several of them.  The limit can be raised with
EMRS_DIRDIFF_TEST_MAX_DELAY (milliseconds)."
  (let* ((root (make-temp-file "emrs-dirdiff-big" t))
         (a (expand-file-name "a" root))
         (b (expand-file-name "b" root))
         (limit (emrs-dirdiff-test--max-delay))
         (redraws 0)
         (count-redraw (lambda (&rest _) (cl-incf redraws)))
         (buffer nil) (timer nil) (last nil) (max-delay 0) (ticks 0))
    (unwind-protect
        (save-window-excursion
          (emrs-dirdiff-test--generate a #'ignore)
          ;; Every tenth file differs: 2,000 changed files, all expanded.
          (emrs-dirdiff-test--generate b (lambda (n) (zerop (% n 10))))
          (advice-add 'emrs-dirdiff--redraw :before count-redraw)
          ;; Start with a clean heap, so that a collection owed to the
          ;; tree generation does not land in the measurement.
          (garbage-collect)
          (setq timer (run-at-time 0.01 0.01
                                   (lambda ()
                                     (let ((now (float-time)))
                                       (when last
                                         (setq max-delay (max max-delay (- now last 0.01))))
                                       (cl-incf ticks)
                                       (setq last now)))))
          (setq buffer (emrs-dirdiff--open a b))
          (set-window-buffer (selected-window) buffer)
          (should (get-buffer-window buffer t))
          (should (eq (emrs-dirdiff-test--wait-done buffer 120) 'done))
          (dotimes (_ 2)
            (with-current-buffer buffer (emrs-dirdiff-rescan))
            (should (eq (emrs-dirdiff-test--wait-done buffer 120) 'done)))
          ;; The final redraw runs in the last callback; let the timer
          ;; fire after it, so that its delay is measured too.
          (let ((ticked ticks))
            (emrs-dirdiff-test--wait (lambda () (> ticks (1+ ticked))) 1))
          (cancel-timer timer)
          (setq timer nil)
          (with-current-buffer buffer
            (should (= (aref (emrs-dirdiff--counts-of "") 0) 2000))
            (should-not emrs-dirdiff--dirty)
            (message "responsiveness: %d files in %.2f s (last of 3), %d redraws, %d ticks, max timer delay %.1f ms (limit %.0f ms)"
                     (plist-get emrs-dirdiff--summary :files)
                     (- emrs-dirdiff--ended emrs-dirdiff--started)
                     redraws ticks (* 1000 max-delay) (* 1000 limit)))
          ;; At least the first and last redraw of each comparison.
          (should (>= redraws 6))
          (should (< max-delay limit)))
      (advice-remove 'emrs-dirdiff--redraw count-redraw)
      (when timer (cancel-timer timer))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

;;;; Marks and actions

(defvar emrs-dirdiff-test--prompts nil "Prompts shown by stubbed confirmations, newest first.")
(defvar emrs-dirdiff-test--messages nil "Messages shown while stubbed, newest first.")
(defvar emrs-dirdiff-test--warnings nil "Warnings shown while stubbed, newest first.")

(defmacro emrs-dirdiff-test--answering (answer choice &rest body)
  "Run BODY with confirmations answered ANSWER and the side prompt CHOICE.
Prompts, messages and warnings are recorded in the variables above;
`delete-by-moving-to-trash' is nil."
  (declare (indent 2))
  `(let ((emrs-dirdiff-test--prompts nil)
         (emrs-dirdiff-test--messages nil)
         (emrs-dirdiff-test--warnings nil)
         (delete-by-moving-to-trash nil))
     (cl-letf (((symbol-function 'yes-or-no-p)
                (lambda (prompt) (push prompt emrs-dirdiff-test--prompts) ,answer))
               ((symbol-function 'y-or-n-p)
                (lambda (prompt) (push prompt emrs-dirdiff-test--prompts) ,answer))
               ((symbol-function 'read-char-choice)
                (lambda (prompt _chars) (push prompt emrs-dirdiff-test--prompts) ,choice))
               ((symbol-function 'display-warning)
                (lambda (&rest args) (push args emrs-dirdiff-test--warnings)))
               ((symbol-function 'message)
                (lambda (fmt &rest args)
                  (when fmt (push (apply #'format fmt args) emrs-dirdiff-test--messages)))))
       ,@body)))

(defun emrs-dirdiff-test--read (file)
  "The contents of FILE."
  (with-temp-buffer (insert-file-contents file) (buffer-string)))

(ert-deftest emrs-dirdiff-test-marks ()
  "m, u and U mark by path; marks show in both views and survive toggles."
  (emrs-dirdiff-test--with-fixture (_root _a _b buffer)
    (with-current-buffer buffer
      (emrs-dirdiff-test--goto "changed.txt")
      (emrs-dirdiff-mark)
      ;; The mark moves to the next line.
      (should (equal (emrs-dirdiff--path-at-point) "deep"))
      (emrs-dirdiff-test--goto "only-a.txt")
      (emrs-dirdiff-mark)
      (should (equal (emrs-dirdiff--path-at-point) "onlyb"))
      (should (equal (emrs-dirdiff-test--body buffer)
                     '("M*   changed.txt            6 → 8         +2 −1"
                       "M  ▾ deep/                  1 changed"
                       "M    ▾ er/                  1 changed"
                       "M        n.txt              2 → 2         +1 −1"
                       "T    kindy                  kind differs (A: file)"
                       "A*   only-a.txt             1"
                       "B    onlyb/                 2 files")))
      (emrs-dirdiff-toggle-view)
      (let ((lines (emrs-dirdiff-test--body buffer)))
        (should (member "  * changed.txt                 6 → 8         +2 −1" lines))
        (should (member "  * only-a.txt                  1" lines)))
      (emrs-dirdiff-toggle-view)
      (should (= (hash-table-count emrs-dirdiff--marks) 2))
      ;; u unmarks and moves on.
      (emrs-dirdiff-test--goto "changed.txt")
      (emrs-dirdiff-unmark)
      (should (equal (emrs-dirdiff--path-at-point) "deep"))
      (should (= (hash-table-count emrs-dirdiff--marks) 1))
      (emrs-dirdiff-unmark-all)
      (should (= (hash-table-count emrs-dirdiff--marks) 0))
      (should (equal (emrs-dirdiff-test--body buffer) emrs-dirdiff-test--tree))
      ;; The header cannot be marked.
      (goto-char (point-min))
      (should-error (emrs-dirdiff-mark) :type 'user-error)
      (emrs-dirdiff-toggle-view)
      (goto-char (point-min))
      (search-forward "Changed (")
      (should-error (emrs-dirdiff-mark) :type 'user-error))))

(ert-deftest emrs-dirdiff-test-marks-dropped-when-gone ()
  "A rescan drops the marks of paths that disappeared, keeps the others."
  (emrs-dirdiff-test--with-fixture (_root a b buffer)
    (with-current-buffer buffer
      (puthash "changed.txt" t emrs-dirdiff--marks)
      (puthash "only-a.txt" t emrs-dirdiff--marks)
      (emrs-dirdiff-test--put b "changed.txt" (emrs-dirdiff-test--read
                                               (expand-file-name "changed.txt" a)))
      (emrs-dirdiff-rescan)
      (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
      (should-not (gethash "changed.txt" emrs-dirdiff--marks))
      (should (gethash "only-a.txt" emrs-dirdiff--marks)))))

(ert-deftest emrs-dirdiff-test-copy-a-to-b ()
  "> copies a changed file and an only-A directory; the rescan finds them identical."
  (emrs-dirdiff-test--with-fixture (_root a b buffer)
    (emrs-dirdiff-test--put a "newdir/x/y.txt" "y\n")
    (emrs-dirdiff-test--put a "newdir/z.txt" "z\n")
    (with-current-buffer buffer
      (emrs-dirdiff-rescan)
      (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
      ;; A changed file: one target exists, so the prompt says so.
      (emrs-dirdiff-test--goto "changed.txt")
      (emrs-dirdiff-test--answering t nil
        (emrs-dirdiff-copy-a-to-b)
        (should (equal emrs-dirdiff-test--prompts
                       '("Copy 1 entry A → B: 1 file overwritten:\n  changed.txt (overwrite)\nProceed? ")))
        (should (member "Copy A → B: 1 of 1 done" emrs-dirdiff-test--messages)))
      (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
      (should (equal (emrs-dirdiff-test--read (expand-file-name "changed.txt" b)) "a\nb\nc\n"))
      (should-not (gethash "changed.txt" emrs-dirdiff--items))
      ;; An only-A directory: created in B with its parents.
      (emrs-dirdiff-test--goto "newdir")
      (should (eq (plist-get (emrs-dirdiff--entry-at-point) :status) 'only-a))
      (emrs-dirdiff-test--answering t nil
        (emrs-dirdiff-copy-a-to-b)
        (should (equal emrs-dirdiff-test--prompts
                       '("Copy 1 entry A → B:\n  newdir (new)\nProceed? "))))
      (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
      (should (equal (emrs-dirdiff-test--read (expand-file-name "newdir/x/y.txt" b)) "y\n"))
      (should (equal (emrs-dirdiff-test--read (expand-file-name "newdir/z.txt" b)) "z\n"))
      (should-not (gethash "newdir" emrs-dirdiff--items))
      (should (eql (gethash "newdir" emrs-dirdiff--done) 2))
      (should-not (string-match-p "newdir" (mapconcat #'identity (emrs-dirdiff-test--body buffer) "\n"))))))

(ert-deftest emrs-dirdiff-test-copy-b-to-a ()
  "< copies B to A for marked entries with one question; marks are cleared."
  (emrs-dirdiff-test--with-fixture (_root a b buffer)
    (with-current-buffer buffer
      (puthash "onlyb" t emrs-dirdiff--marks)
      (puthash "changed.txt" t emrs-dirdiff--marks)
      (emrs-dirdiff-test--answering t nil
        (emrs-dirdiff-copy-b-to-a)
        (should (equal emrs-dirdiff-test--prompts
                       '("Copy 2 entries B → A: 1 file overwritten:\n  changed.txt (overwrite)\n  onlyb (new)\nProceed? "))))
      (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
      (should (equal (emrs-dirdiff-test--read (expand-file-name "changed.txt" a)) "a\nB\nc\nd\n"))
      (should (equal (emrs-dirdiff-test--read (expand-file-name "onlyb/g/f2" a)) "x"))
      (should-not (gethash "changed.txt" emrs-dirdiff--items))
      (should-not (gethash "onlyb" emrs-dirdiff--items))
      (should (= (hash-table-count emrs-dirdiff--marks) 0))
      (should (equal (emrs-dirdiff-test--body buffer)
                     '("M  ▾ deep/                  1 changed"
                       "M    ▾ er/                  1 changed"
                       "M        n.txt              2 → 2         +1 −1"
                       "T    kindy                  kind differs (A: file)"
                       "A    only-a.txt             1")))
      (should (file-exists-p b)))))

(ert-deftest emrs-dirdiff-test-copy-kind-replaces ()
  "Copying over a kind difference replaces what is at the target."
  (emrs-dirdiff-test--with-fixture (_root _a b buffer)
    (with-current-buffer buffer
      (emrs-dirdiff-test--goto "kindy")
      (emrs-dirdiff-test--answering t nil
        (emrs-dirdiff-copy-a-to-b)
        (should (equal emrs-dirdiff-test--prompts
                       '("Copy 1 entry A → B: 1 directory replaced (deleted first):\n  kindy (replace)\nProceed? "))))
      (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
      (should (equal (emrs-dirdiff-test--read (expand-file-name "kindy" b)) "file"))
      (should-not (gethash "kindy" emrs-dirdiff--items)))))

(ert-deftest emrs-dirdiff-test-copy-skips-missing-source ()
  "> on an entry only in B is skipped with a message and asks nothing."
  (emrs-dirdiff-test--with-fixture (_root a _b buffer)
    (with-current-buffer buffer
      (emrs-dirdiff-test--goto "onlyb")
      (emrs-dirdiff-test--answering t nil
        (emrs-dirdiff-copy-a-to-b)
        (should-not emrs-dirdiff-test--prompts)
        (should (member "Nothing to copy A → B: onlyb (not in A)" emrs-dirdiff-test--messages)))
      (should-not (file-exists-p (expand-file-name "onlyb" a)))
      (should-not emrs-dirdiff--rescan-queue))))

(ert-deftest emrs-dirdiff-test-copy-declined ()
  "Declining the question does nothing."
  (emrs-dirdiff-test--with-fixture (_root _a b buffer)
    (with-current-buffer buffer
      (emrs-dirdiff-test--goto "changed.txt")
      (emrs-dirdiff-test--answering nil nil
        (emrs-dirdiff-copy-a-to-b)
        (should (= (length emrs-dirdiff-test--prompts) 1)))
      (should (equal (emrs-dirdiff-test--read (expand-file-name "changed.txt" b))
                     "a\nB\nc\nd\n"))
      (should (gethash "changed.txt" emrs-dirdiff--items))
      (should-not emrs-dirdiff--rescan-queue))))

(ert-deftest emrs-dirdiff-test-prompt-lists-ten-paths ()
  "The prompt lists up to ten paths, then the count of the rest."
  (let ((text (emrs-dirdiff--path-list (mapcar #'number-to-string (number-sequence 1 13)))))
    (should (string-suffix-p "  10\n  and 3 more" text))
    (should-not (string-match-p "11" text)))
  (should (equal (emrs-dirdiff--path-list '("a" "b")) "  a\n  b")))

(ert-deftest emrs-dirdiff-test-delete-one-sided ()
  "D on a one-sided file deletes it without asking for a side."
  (emrs-dirdiff-test--with-fixture (_root a _b buffer)
    (with-current-buffer buffer
      (emrs-dirdiff-test--goto "only-a.txt")
      (emrs-dirdiff-test--answering t ?q
        (emrs-dirdiff-delete)
        (should (equal emrs-dirdiff-test--prompts
                       '("Delete 1 entry (1 in A):\n  only-a.txt (A)\nProceed? "))))
      (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
      (should-not (file-exists-p (expand-file-name "only-a.txt" a)))
      (should-not (gethash "only-a.txt" emrs-dirdiff--items))
      (should-not (string-match-p "only-a" (mapconcat #'identity (emrs-dirdiff-test--body buffer) "\n"))))))

(ert-deftest emrs-dirdiff-test-delete-asks-side ()
  "D on an entry on both sides asks which side once and deletes only that."
  (emrs-dirdiff-test--with-fixture (_root a b buffer)
    (with-current-buffer buffer
      (puthash "changed.txt" t emrs-dirdiff--marks)
      (puthash "onlyb" t emrs-dirdiff--marks)
      (emrs-dirdiff-test--answering t ?a
        (emrs-dirdiff-delete)
        (should (= (length emrs-dirdiff-test--prompts) 2))   ; the side, then the confirmation
        (should (equal (car emrs-dirdiff-test--prompts)
                       "Delete 2 entries (1 in A, 1 in B), 1 directory with everything in it:\n  changed.txt (A)\n  onlyb (B)\nProceed? ")))
      (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
      (should-not (file-exists-p (expand-file-name "changed.txt" a)))
      (should (file-exists-p (expand-file-name "changed.txt" b)))
      (should-not (file-exists-p (expand-file-name "onlyb" b)))
      (should (equal (plist-get (gethash "changed.txt" emrs-dirdiff--items) :status) "only-b"))
      (should-not (gethash "onlyb" emrs-dirdiff--items))
      ;; The other side, and both.
      (emrs-dirdiff-test--goto "deep")
      (emrs-dirdiff-test--answering t ?b
        (puthash "deep/er/n.txt" t emrs-dirdiff--marks)
        (emrs-dirdiff-delete))
      (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
      (should (file-exists-p (expand-file-name "deep/er/n.txt" a)))
      (should-not (file-exists-p (expand-file-name "deep/er/n.txt" b)))
      (should (equal (plist-get (gethash "deep/er/n.txt" emrs-dirdiff--items) :status) "only-a"))
      (emrs-dirdiff-test--answering t ?c
        (puthash "deep/er/n.txt" t emrs-dirdiff--marks)
        (emrs-dirdiff-delete))
      (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
      (should-not (file-exists-p (expand-file-name "deep/er/n.txt" a)))
      (should-not (gethash "deep/er/n.txt" emrs-dirdiff--items))
      ;; Quitting the question deletes nothing.
      (puthash "kindy" t emrs-dirdiff--marks)
      (emrs-dirdiff-test--answering t ?q
        (emrs-dirdiff-delete))
      (should (file-exists-p (expand-file-name "kindy" a)))
      (should (file-exists-p (expand-file-name "kindy" b))))))

(ert-deftest emrs-dirdiff-test-failing-action-rescans ()
  "An error part way is shown, what was done stays, everything is rescanned."
  (skip-unless (not (zerop (user-uid))))
  (emrs-dirdiff-test--with-fixture (_root a b buffer)
    (with-current-buffer buffer
      (puthash "changed.txt" t emrs-dirdiff--marks)
      (puthash "only-a.txt" t emrs-dirdiff--marks)
      (unwind-protect
          (progn
            (set-file-modes b #o555)
            (emrs-dirdiff-test--answering t nil
              (emrs-dirdiff-copy-a-to-b)
              (should (= (length emrs-dirdiff-test--warnings) 1))
              (should (string-match-p "\\`Copy A → B failed on only-a.txt: .*; 1 of 2 done\\'"
                                      (cadr (car emrs-dirdiff-test--warnings))))
              (should (eq (nth 2 (car emrs-dirdiff-test--warnings)) :error)))
            (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
            ;; changed.txt was copied before the failure and rescanned.
            (should (equal (emrs-dirdiff-test--read (expand-file-name "changed.txt" b)) "a\nb\nc\n"))
            (should-not (gethash "changed.txt" emrs-dirdiff--items))
            ;; only-a.txt failed; it stays marked and different.
            (should-not (file-exists-p (expand-file-name "only-a.txt" b)))
            (should (equal (plist-get (gethash "only-a.txt" emrs-dirdiff--items) :status) "only-a"))
            (should (gethash "only-a.txt" emrs-dirdiff--marks))
            (should-not (gethash "changed.txt" emrs-dirdiff--marks))
            (ignore a))
        (set-file-modes b #o755)))))

(ert-deftest emrs-dirdiff-test-rescan-queue ()
  "Rescans queue behind a running stream, covered paths merge, and run in turn."
  (emrs-dirdiff-test--with-fixture (_root _a b buffer)
    (with-current-buffer buffer
      (emrs-dirdiff-test--put b "deep/er/n.txt" "1\n")
      (let ((emrs-dirdiff--stream 'running))
        (emrs-dirdiff--rescan-paths '("deep/er" "only-a.txt"))
        (should (equal emrs-dirdiff--rescan-queue '("deep/er" "only-a.txt")))
        (emrs-dirdiff--rescan-paths '("deep" "deep/er/n.txt"))
        (should (equal emrs-dirdiff--rescan-queue '("only-a.txt" "deep"))))
      (emrs-dirdiff--drain-rescans)
      (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
      (should-not emrs-dirdiff--rescan-queue)
      (should-not (gethash "deep/er/n.txt" emrs-dirdiff--items))
      (should (gethash "only-a.txt" emrs-dirdiff--items)))))

;;;; Actions act only on what the comparison showed (ADR 0002)

(defmacro emrs-dirdiff-test--with-trees (vars setup &rest body)
  "Bind VARS (ROOT A B BUFFER), build the trees with SETUP, compare, run BODY.
A and B exist (empty) when SETUP runs; the comparison has finished when
BODY runs; everything is cleaned up."
  (declare (indent 2))
  (pcase-let ((`(,root ,a ,b ,buffer) vars))
    `(let* ((,root (make-temp-file "emrs-dirdiff-tr" t))
            (,a (concat ,root "/a"))
            (,b (concat ,root "/b"))
            (,buffer nil))
       (ignore ,root ,a ,b)
       (unwind-protect
           (progn
             (make-directory ,a)
             (make-directory ,b)
             ,setup
             (setq ,buffer (emrs-dirdiff--open ,a ,b))
             (should (eq (emrs-dirdiff-test--wait-done ,buffer) 'done))
             ,@body)
         (when (buffer-live-p ,buffer) (kill-buffer ,buffer))
         (delete-directory ,root t)))))

(defun emrs-dirdiff-test--names (dir)
  "The names in DIR other than . and .., sorted."
  (sort (directory-files dir nil directory-files-no-dot-files-regexp) #'string<))

(ert-deftest emrs-dirdiff-test-tilde-names ()
  "Entries named ~ map inside the roots; copy and delete never reach $HOME."
  (let* ((home (make-temp-file "emrs-dirdiff-home" t))
         (process-environment (cons (concat "HOME=" home) process-environment))
         (abbreviated-home-dir nil))
    (unwind-protect
        (progn
          (emrs-dirdiff-test--put home "sentinel" "keep")
          ;; The fake home is the one `expand-file-name' would use.
          (should (equal (expand-file-name "~" "/tmp/") (directory-file-name home)))
          (emrs-dirdiff-test--with-trees (_root a b buffer)
              (progn
                (emrs-dirdiff-test--put a "~/x" "1\n")
                (emrs-dirdiff-test--put b "~/x" "2\n"))
            (with-current-buffer buffer
              (should (equal (emrs-dirdiff--file "~" 'a) (concat a "/~")))
              (should (equal (emrs-dirdiff--file "~/x" 'b) (concat b "/~/x")))
              (should (equal (plist-get (gethash "~/x" emrs-dirdiff--items) :status) "changed"))
              (emrs-dirdiff-test--goto "~")
              (emrs-dirdiff-test--answering t nil
                (emrs-dirdiff-copy-a-to-b)
                (should (equal emrs-dirdiff-test--prompts
                               '("Copy 1 entry A → B: 1 file overwritten:\n  ~/x (overwrite)\nProceed? "))))
              (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
              (should (equal (emrs-dirdiff-test--read (concat b "/~/x")) "1\n"))
              (should (equal (emrs-dirdiff-test--names home) '("sentinel")))
              ;; ~ is identical now; show it and delete it in B.
              (emrs-dirdiff-toggle-same)
              (emrs-dirdiff-test--goto "~")
              (emrs-dirdiff-test--answering t ?b
                (emrs-dirdiff-delete)
                (should (equal (car emrs-dirdiff-test--prompts)
                               "Delete 1 entry (1 in B), 1 directory with everything in it:\n  ~ (B)\nProceed? ")))
              (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
              (should-not (file-exists-p (concat b "/~")))
              (should (file-exists-p (concat a "/~/x")))
              (should (equal (emrs-dirdiff-test--names home) '("sentinel")))
              (should (equal (emrs-dirdiff-test--read (concat home "/sentinel")) "keep")))))
      (delete-directory home t))))

(ert-deftest emrs-dirdiff-test-copy-replaces-symlink-in-target ()
  "A link in the target directory to a directory outside is replaced, not written through."
  (emrs-dirdiff-test--with-trees (root a b buffer)
      (progn
        (emrs-dirdiff-test--put a "sub/same" "s")
        (emrs-dirdiff-test--put b "sub/same" "s")
        (emrs-dirdiff-test--put a "sub/d/f" "from a")
        (emrs-dirdiff-test--put root "outside/keep" "keep")
        (make-symbolic-link (concat root "/outside") (concat b "/sub/d")))
    (with-current-buffer buffer
      (should (equal (plist-get (gethash "sub/d" emrs-dirdiff--items) :status) "kind"))
      (emrs-dirdiff-test--goto "sub")
      (emrs-dirdiff-test--answering t nil
        (emrs-dirdiff-copy-a-to-b)
        (should (equal emrs-dirdiff-test--prompts
                       '("Copy 1 entry A → B: 1 symbolic link replaced (deleted first):\n  sub/d (replace)\nProceed? "))))
      (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
      (should (equal (emrs-dirdiff-test--names (concat root "/outside")) '("keep")))
      (should-not (file-symlink-p (concat b "/sub/d")))
      (should (equal (emrs-dirdiff-test--read (concat b "/sub/d/f")) "from a"))
      (should-not (gethash "sub/d" emrs-dirdiff--items)))))

(ert-deftest emrs-dirdiff-test-copy-refuses-linked-parent ()
  "A directory above the target replaced by a link after the comparison: skipped."
  (emrs-dirdiff-test--with-fixture (root a b buffer)
    ;; The same files, reached through a link: only the parent check stops it.
    (rename-file (concat b "/deep") (concat root "/outside"))
    (make-symbolic-link (concat root "/outside") (concat b "/deep"))
    (with-current-buffer buffer
      (emrs-dirdiff-test--goto "deep/er/n.txt")
      (emrs-dirdiff-test--answering t nil
        (emrs-dirdiff-copy-a-to-b)
        (should (member "Copy A → B: 0 of 1 done; skipped, deep/er/n.txt (changed since the comparison); press g to compare again"
                        emrs-dirdiff-test--messages)))
      (should-not emrs-dirdiff--rescan-queue)
      (should (equal (emrs-dirdiff-test--read (concat root "/outside/er/n.txt")) "2\n"))
      (should (equal (emrs-dirdiff-test--read (concat a "/deep/er/n.txt")) "1\n")))))

(ert-deftest emrs-dirdiff-test-copy-directory-copies-listed-differences ()
  "Copying a directory present on both sides copies the listed differences
entry by entry; ignored files and entries only in the target stay; a
nested kind difference is replaced."
  (emrs-dirdiff-test--with-trees (_root a b buffer)
      (progn
        (dolist (dir (list a b))
          (emrs-dirdiff-test--put dir ".ignore" "*.log\n"))
        (emrs-dirdiff-test--put a "top/a.log" "from a")
        (emrs-dirdiff-test--put b "top/a.log" "from b")
        (emrs-dirdiff-test--put a "top/deep/x" "1\n")
        (emrs-dirdiff-test--put b "top/deep/x" "22\n")
        (emrs-dirdiff-test--put b "top/only-b" "b")
        (emrs-dirdiff-test--put a "top/k" "file")
        (emrs-dirdiff-test--put b "top/k/inner" "dir")
        (emrs-dirdiff-test--put a "top/new/n" "n"))
    (with-current-buffer buffer
      (emrs-dirdiff-test--goto "top")
      (emrs-dirdiff-test--answering t nil
        (emrs-dirdiff-copy-a-to-b)
        (should (equal emrs-dirdiff-test--prompts
                       '("Copy 3 entries A → B: 1 file overwritten, 1 directory replaced (deleted first):\n  top/deep/x (overwrite)\n  top/k (replace)\n  top/new (new)\nProceed? ")))
        (should (member "Copy A → B: 3 of 3 done" emrs-dirdiff-test--messages)))
      (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
      (should (equal (emrs-dirdiff-test--read (concat b "/top/a.log")) "from b"))
      (should (equal (emrs-dirdiff-test--read (concat b "/top/only-b")) "b"))
      (should (equal (emrs-dirdiff-test--read (concat b "/top/deep/x")) "1\n"))
      (should (equal (emrs-dirdiff-test--read (concat b "/top/k")) "file"))
      (should (equal (emrs-dirdiff-test--read (concat b "/top/new/n")) "n"))
      (should (equal (hash-table-keys emrs-dirdiff--items) '("top/only-b"))))))

(ert-deftest emrs-dirdiff-test-actions-skip-entries-changed-on-disk ()
  "An entry that changed on disk after the comparison is skipped and reported."
  (emrs-dirdiff-test--with-fixture (_root a b buffer)
    ;; only-a.txt became a directory; changed.txt in A has another size;
    ;; n.txt in B has another time.
    (delete-file (concat a "/only-a.txt"))
    (emrs-dirdiff-test--put a "only-a.txt/inside" "new")
    (emrs-dirdiff-test--put a "changed.txt" "longer contents\n")
    (set-file-times (concat b "/deep/er/n.txt") '(1600000000 0))
    (with-current-buffer buffer
      (puthash "only-a.txt" t emrs-dirdiff--marks)
      (emrs-dirdiff-test--answering t nil
        (emrs-dirdiff-delete)
        (should (member "Delete: 0 of 1 done; skipped, only-a.txt (changed since the comparison); press g to compare again"
                        emrs-dirdiff-test--messages)))
      (should (file-exists-p (concat a "/only-a.txt/inside")))
      (should (gethash "only-a.txt" emrs-dirdiff--marks))
      (clrhash emrs-dirdiff--marks)
      (puthash "changed.txt" t emrs-dirdiff--marks)
      (puthash "deep/er/n.txt" t emrs-dirdiff--marks)
      (emrs-dirdiff-test--answering t nil
        (emrs-dirdiff-copy-a-to-b)
        (should (member "Copy A → B: 0 of 2 done; skipped, changed.txt (changed since the comparison), deep/er/n.txt (changed since the comparison); press g to compare again"
                        emrs-dirdiff-test--messages)))
      (should (equal (emrs-dirdiff-test--read (concat b "/changed.txt")) "a\nB\nc\nd\n"))
      (should (equal (emrs-dirdiff-test--read (concat b "/deep/er/n.txt")) "2\n"))
      (should (= (hash-table-count emrs-dirdiff--marks) 2)))))

(ert-deftest emrs-dirdiff-test-actions-refuse-unknown-and-comparing ()
  "Marks the model does not know and entries still compared are left out."
  (emrs-dirdiff-test--with-fixture (_root _a b buffer)
    (with-current-buffer buffer
      (puthash "no/such" t emrs-dirdiff--marks)
      (puthash "changed.txt" t emrs-dirdiff--marks)
      (emrs-dirdiff-test--answering t nil
        (emrs-dirdiff-copy-a-to-b)
        (should (equal emrs-dirdiff-test--prompts
                       '("Copy 1 entry A → B: 1 file overwritten:\n  changed.txt (overwrite)\nLeft out: no/such (not in the comparison)\nProceed? "))))
      (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
      (clrhash emrs-dirdiff--marks)
      ;; A directory whose `done' item has not arrived is still compared.
      (let ((emrs-dirdiff--state 'running))
        (remhash "deep" emrs-dirdiff--done)
        (puthash "deep" t emrs-dirdiff--marks)
        (should (eq (emrs-dirdiff--status "deep") 'changed))
        (remhash "deep/er/n.txt" emrs-dirdiff--items)
        (emrs-dirdiff--count '(:path "deep/er/n.txt" :status "changed") -1)
        (should (eq (emrs-dirdiff--status "deep") 'comparing))
        (emrs-dirdiff-test--answering t ?a
          (emrs-dirdiff-copy-a-to-b)
          (emrs-dirdiff-delete)
          (should-not emrs-dirdiff-test--prompts)
          (should (member "Nothing to copy A → B: deep (still being compared)"
                          emrs-dirdiff-test--messages))
          (should (member "Nothing to delete: deep (still being compared)"
                          emrs-dirdiff-test--messages))))
      (should (file-exists-p (concat b "/deep/er/n.txt"))))))

(ert-deftest emrs-dirdiff-test-mark-kept-unless-all-done ()
  "Deleting on both sides: a failure on B keeps the mark although A was done."
  (skip-unless (not (zerop (user-uid))))
  (emrs-dirdiff-test--with-fixture (_root a b buffer)
    (with-current-buffer buffer
      (puthash "changed.txt" t emrs-dirdiff--marks)
      (unwind-protect
          (progn
            (set-file-modes b #o555)
            (emrs-dirdiff-test--answering t ?c
              (emrs-dirdiff-delete)
              (should (string-match-p "\\`Delete failed on changed.txt: .*; 1 of 2 done\\'"
                                      (cadr (car emrs-dirdiff-test--warnings))))))
        (set-file-modes b #o755))
      (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
      (should-not (file-exists-p (concat a "/changed.txt")))
      (should (file-exists-p (concat b "/changed.txt")))
      (should (gethash "changed.txt" emrs-dirdiff--marks))
      (should (equal (plist-get (gethash "changed.txt" emrs-dirdiff--items) :status) "only-b")))))

(ert-deftest emrs-dirdiff-test-quit-during-action ()
  "C-g during an action reports what was done and still compares again."
  (emrs-dirdiff-test--with-fixture (_root _a b buffer)
    (with-current-buffer buffer
      (puthash "changed.txt" t emrs-dirdiff--marks)
      (puthash "deep/er/n.txt" t emrs-dirdiff--marks)
      (let ((copy (symbol-function 'copy-file))
            (calls 0)
            (quitted nil))
        (emrs-dirdiff-test--answering t nil
          (cl-letf (((symbol-function 'copy-file)
                     (lambda (&rest args)
                       (if (= (cl-incf calls) 2)
                           (signal 'quit nil)
                         (apply copy args)))))
            (condition-case nil
                (emrs-dirdiff-copy-a-to-b)
              (quit (setq quitted t))))
          (should quitted)
          (should (member "Copy A → B interrupted: 1 of 2 done" emrs-dirdiff-test--messages))))
      (should (or emrs-dirdiff--stream emrs-dirdiff--rescan-queue))
      (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
      (should (equal (emrs-dirdiff-test--read (concat b "/changed.txt")) "a\nb\nc\n"))
      (should-not (gethash "changed.txt" emrs-dirdiff--items))
      (should (gethash "deep/er/n.txt" emrs-dirdiff--items))
      (should-not (gethash "changed.txt" emrs-dirdiff--marks))
      (should (gethash "deep/er/n.txt" emrs-dirdiff--marks)))))

(ert-deftest emrs-dirdiff-test-partly-readable-directory ()
  "A directory read in part shows ! and its message, expands, and its
differences are copied; one whose listing failed as a whole does not expand."
  (with-temp-buffer
    (emrs-dirdiff-mode)
    (setq emrs-dirdiff--a "/nonexistent/emrs-dirdiff/a/"
          emrs-dirdiff--b "/nonexistent/emrs-dirdiff/b/"
          emrs-dirdiff--state 'done)
    (dolist (item '((:path "sub" :kind "dir" :status "error"
                     :a (:size 0 :mtime 1.0) :b (:size 0 :mtime 1.0)
                     :message "some entries could not be read: Permission denied")
                    (:path "sub/x.txt" :kind "file" :status "changed"
                     :a (:size 1 :mtime 1.0) :b (:size 2 :mtime 1.0))
                    (:path "bad" :kind "dir" :status "error" :message "Permission denied")
                    (:path "sub" :kind "dir" :status "done" :same 0)
                    (:path "" :kind "dir" :status "done" :same 0)))
      (emrs-dirdiff--model-add item))
    (emrs-dirdiff--redraw)
    (should (emrs-dirdiff--expandable-p "sub"))
    (should-not (emrs-dirdiff--expandable-p "bad"))
    (should (equal (emrs-dirdiff-test--body (current-buffer))
                   '("!    bad/                   Permission denied"
                     "!  ▾ sub/                   some entries could not be read: Permission denied"
                     "M      x.txt                1 → 2")))
    ;; Folding and navigation treat it as a directory with differences.
    (emrs-dirdiff-test--goto "sub")
    (should (emrs-dirdiff--directory-difference-p))
    (emrs-dirdiff-toggle-fold)
    (should (equal (cadr (emrs-dirdiff-test--body (current-buffer)))
                   "!  ▸ sub/                   some entries could not be read: Permission denied"))
    (emrs-dirdiff-toggle-fold)
    ;; Copying it plans its listed differences; the error is mentioned.
    (emrs-dirdiff-test--goto "sub")
    (emrs-dirdiff-test--answering nil nil
      (emrs-dirdiff-copy-a-to-b)
      (should (equal emrs-dirdiff-test--prompts
                     '("Copy 1 entry A → B: 1 file overwritten:\n  sub/x.txt (overwrite)\nLeft out: sub (some entries could not be read: Permission denied)\nProceed? "))))
    ;; A directory whose listing failed as a whole is left out.
    (emrs-dirdiff-test--goto "bad")
    (emrs-dirdiff-test--answering nil nil
      (emrs-dirdiff-copy-a-to-b)
      (should-not emrs-dirdiff-test--prompts)
      (should (member "Nothing to copy A → B: bad (could not be compared)"
                      emrs-dirdiff-test--messages)))))

;;;; Rescans, stopping and hidden buffers

(ert-deftest emrs-dirdiff-test-rescan-of-vanished-path ()
  "A path rescanned after it vanished or became identical leaves no line
behind; the parent's identical entries are fetched afresh after it."
  (emrs-dirdiff-test--with-fixture (_root a b buffer)
    (delete-file (concat a "/only-a.txt"))
    (emrs-dirdiff-test--put b "changed.txt" (emrs-dirdiff-test--read (concat a "/changed.txt")))
    (with-current-buffer buffer
      (emrs-dirdiff--rescan-paths '("only-a.txt"))
      (should emrs-dirdiff--stream)
      ;; Identical entries of the parent fetched while the rescan runs are stale.
      (let ((stale (list 'done)))
        (puthash "" stale emrs-dirdiff--same)
        (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
        (should-not (eq (gethash "" emrs-dirdiff--same) stale)))
      (should-not (gethash "only-a.txt" (gethash "" emrs-dirdiff--children)))
      (should-not emrs-dirdiff--rescan)
      (emrs-dirdiff--rescan-paths '("changed.txt"))
      (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
      (should-not (gethash "changed.txt" emrs-dirdiff--items))
      (should-not (gethash "changed.txt" (gethash "" emrs-dirdiff--children)))
      (emrs-dirdiff-toggle-same)
      (should (emrs-dirdiff-test--wait
               (lambda () (eq (car (gethash "" emrs-dirdiff--same)) 'done))))
      (let ((paths (emrs-dirdiff-test--paths buffer)))
        (should-not (member "only-a.txt" paths))
        (should (= (cl-count "changed.txt" paths :test #'equal) 1))))))

(ert-deftest emrs-dirdiff-test-stop-clears-rescans ()
  "C-u g is refused while comparing; stopping drops the queued rescans."
  (let* ((root (make-temp-file "emrs-dirdiff-stopq" t))
         (dirs (emrs-dirdiff-test--fixture root))
         (buffer (emrs-dirdiff--open (car dirs) (cdr dirs))))
    (unwind-protect
        (with-current-buffer buffer
          (should (eq emrs-dirdiff--state 'running))
          (let ((err (should-error (emrs-dirdiff-rescan '(4)) :type 'user-error)))
            (should (string-match-p "C-c C-k" (cadr err))))
          (emrs-dirdiff--rescan-paths '("deep"))
          (should (equal emrs-dirdiff--rescan-queue '("deep")))
          (emrs-dirdiff-stop)
          (should (eq emrs-dirdiff--state 'stopped))
          (should-not emrs-dirdiff--rescan-queue)
          (should-not emrs-dirdiff--stream)
          ;; A stream cancelled otherwise does not start queued rescans either.
          (emrs-dirdiff-rescan)
          (setq emrs-dirdiff--rescan-queue (list "deep"))
          (emrs-cancel emrs-dirdiff--stream)
          (should (eq emrs-dirdiff--state 'stopped))
          (should-not emrs-dirdiff--rescan-queue)
          (should-not emrs-dirdiff--stream))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest emrs-dirdiff-test-hidden-buffer-not-redrawn ()
  "A buffer no window shows is not redrawn; showing it redraws it."
  (let* ((root (make-temp-file "emrs-dirdiff-hide" t))
         (dirs (emrs-dirdiff-test--fixture root))
         (buffer (emrs-dirdiff--open (car dirs) (cdr dirs))))
    (unwind-protect
        (with-current-buffer buffer
          (should-not (get-buffer-window buffer t))
          (should (emrs-dirdiff-test--wait
                   (lambda () (and (eq emrs-dirdiff--state 'done)
                                   (not emrs-dirdiff--redraw-timer)))))
          (should emrs-dirdiff--dirty)
          (should (string-prefix-p "Comparing…" (emrs-dirdiff-test--header buffer)))
          (should (memq #'emrs-dirdiff--on-shown window-buffer-change-functions))
          (save-window-excursion
            (set-window-buffer (selected-window) buffer)
            (emrs-dirdiff--on-shown (selected-window)))
          (should-not emrs-dirdiff--dirty)
          (should (equal (emrs-dirdiff-test--header buffer)
                         "2 changed · 1 only in A · 1 only in B · 1 kind differs · 3 same (hidden)")))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

(ert-deftest emrs-dirdiff-test-unreadable-root ()
  "A root that cannot be read shows as an error in the header."
  (skip-unless (not (zerop (user-uid))))
  (let* ((root (make-temp-file "emrs-dirdiff-unr" t))
         (dirs (emrs-dirdiff-test--fixture root))
         (buffer nil))
    (unwind-protect
        (progn
          (set-file-modes (car dirs) #o000)
          (setq buffer (emrs-dirdiff--open (car dirs) (cdr dirs)))
          (emrs-dirdiff-test--wait-done buffer)
          (let ((header (emrs-dirdiff-test--header buffer)))
            (should (string-prefix-p "Error: " header))
            (should-not (string-match-p "No differences" header))))
      (set-file-modes (car dirs) #o755)
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory root t))))

;;;; Module

(defconst emrs-dirdiff-test--file (or load-file-name buffer-file-name)
  "The file of these tests, from which the repository root is found.")

(defun emrs-dirdiff-test--root ()
  "Return the repository root, the directory above tests/ holding Cargo.toml."
  (file-name-as-directory
   (file-truename (locate-dominating-file emrs-dirdiff-test--file "Cargo.toml"))))

(ert-deftest emrs-dirdiff-test-module-versions-agree ()
  "Cargo.toml, the Version header, the constant and the loaded module agree."
  (let* ((root (emrs-dirdiff-test--root))
         (cargo (with-temp-buffer
                  (insert-file-contents (expand-file-name "Cargo.toml" root))
                  (goto-char (point-min))
                  (re-search-forward "^version *= *\"\\([^\"]+\\)\"")
                  (match-string 1)))
         (header (with-temp-buffer
                   (insert-file-contents (expand-file-name "lisp/emrs-dirdiff.el" root))
                   (lm-version)))
         (loaded (progn (emrs-dirdiff--load-module)
                        (plist-get (emrs-module-info 'emrs-dirdiff) :version))))
    (should (equal cargo header))
    (should (equal cargo emrs-dirdiff-module-version))
    (should (equal cargo loaded))))

(ert-deftest emrs-dirdiff-test-module-registration ()
  "The module is registered with the constant's version, the release URL and this checkout."
  (let ((entry (gethash 'emrs-dirdiff emrs-install--registry)))
    (should (equal (plist-get entry :version) emrs-dirdiff-module-version))
    (should (equal (plist-get entry :url)
                   "https://github.com/tohammer/emrs-dirdiff/releases/download"))
    (should (equal (file-name-as-directory
                    (file-truename (emrs-install--checkout 'emrs-dirdiff)))
                   (emrs-dirdiff-test--root)))))

;;;; The menu

(defconst emrs-dirdiff-test--spec-keys
  '("RET" "e" "o" "O" "d" "n" "p" "N" "P" "TAB" "^" "s" "i" "/" "f" "m" "u" "U"
    ">" "<" "D" "w" "c" "t" "W" "v" "x" "g" "C-c C-k" "q")
  "The keys of the spec's table other than ?, which opens the menu.")

(defun emrs-dirdiff-test--menu-keys ()
  "The keys of the suffixes in the layout of `emrs-dirdiff-menu'."
  (let (keys)
    (named-let walk ((x (get 'emrs-dirdiff-menu 'transient--layout)))
      (cond ((vectorp x) (walk (append x nil)))
            ((consp x)
             ;; A suffix is (CLASS . PLIST) in newer transient versions and
             ;; (LEVEL CLASS PLIST) in older ones (Emacs 30.1's), where
             ;; the walk reaches PLIST itself.
             (let ((plist (cond ((keywordp (car x)) x)
                                ((symbolp (car x)) (cdr x)))))
               (when (and (proper-list-p plist) (stringp (plist-get plist :key)))
                 (push (plist-get plist :key) keys)))
             (when (proper-list-p x)
               (dolist (y x)
                 (when (or (consp y) (vectorp y)) (walk y)))))))
    keys))

(ert-deftest emrs-dirdiff-test-menu ()
  "The menu is a transient prefix with every key and the current settings."
  (require 'emrs-dirdiff-menu)
  (should (commandp 'emrs-dirdiff-menu))
  (should (get 'emrs-dirdiff-menu 'transient--prefix))
  (should (eq (lookup-key emrs-dirdiff-mode-map "?") 'emrs-dirdiff-menu))
  (let ((keys (emrs-dirdiff-test--menu-keys)))
    (dolist (key emrs-dirdiff-test--spec-keys)
      (should (member key keys)))
    (should (= (length keys) (length (delete-dups (copy-sequence keys))))))
  ;; Every suffix runs a command the mode binds to the same key.
  (let ((checked 0))
    (dolist (key emrs-dirdiff-test--spec-keys)
      (let ((suffix (transient-get-suffix 'emrs-dirdiff-menu key)))
        (should suffix)
        (let ((command (plist-get (if (integerp (car suffix)) (nth 2 suffix) (cdr suffix))
                                  :command)))
          (unless (equal key "q")
            (should (eq (lookup-key emrs-dirdiff-mode-map (kbd key)) command)))
          (cl-incf checked))))
    (should (= checked (length emrs-dirdiff-test--spec-keys)))))

(ert-deftest emrs-dirdiff-test-menu-descriptions ()
  "Toggles show the settings of the buffer, and follow them."
  (require 'emrs-dirdiff-menu)
  (emrs-dirdiff-test--with-fixture (_root _a _b buffer)
    (with-current-buffer buffer
      (should (equal (emrs-dirdiff-menu--same) "identical entries [hidden]"))
      (should (equal (emrs-dirdiff-menu--ignore-files) "ignore files [on]"))
      (should (equal (emrs-dirdiff-menu--whitespace) "ignore whitespace [off]"))
      (should (equal (emrs-dirdiff-menu--by 'content "content") "compare by content [on]"))
      (should (equal (emrs-dirdiff-menu--by 'size-time "size and time")
                     "compare by size and time [off]"))
      (should (equal (emrs-dirdiff-menu--view) "view: tree"))
      (should (equal (emrs-dirdiff-menu--filter-status) "status filter [all]"))
      (should (equal (emrs-dirdiff-menu--marks) "Act on the entry at point"))
      (emrs-dirdiff-toggle-same)
      (should (equal (emrs-dirdiff-menu--same) "identical entries [shown]"))
      (emrs-dirdiff-toggle-view)
      (emrs-dirdiff-cycle-status-filter)
      (puthash "changed.txt" t emrs-dirdiff--marks)
      (should (equal (emrs-dirdiff-menu--view) "view: sections"))
      (should (equal (emrs-dirdiff-menu--filter-status) "status filter [changed]"))
      (should (equal (emrs-dirdiff-menu--marks) "Act on the 1 marked entry"))
      (emrs-dirdiff-toggle-whitespace)
      (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
      (should (equal (emrs-dirdiff-menu--whitespace) "ignore whitespace [on]"))
      (emrs-dirdiff-compare-size-time)
      (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
      (should (equal (emrs-dirdiff-menu--by 'size-time "size and time")
                     "compare by size and time [on]"))
      (emrs-dirdiff-toggle-ignore-files)
      (should (eq (emrs-dirdiff-test--wait-done buffer) 'done))
      (should (equal (emrs-dirdiff-menu--ignore-files) "ignore files [off]"))
      ;; From another buffer the menu reads the buffer it was opened from.
      (with-temp-buffer
        (let ((transient--original-buffer buffer))
          (should (equal (emrs-dirdiff-menu--ignore-files) "ignore files [off]")))))))

(provide 'emrs-dirdiff-tests)
;;; emrs-dirdiff-tests.el ends here
