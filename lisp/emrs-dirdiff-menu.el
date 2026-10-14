;;; emrs-dirdiff-menu.el --- Transient menu of emrs-dirdiff  -*- lexical-binding: t; -*-

;; Copyright (C) 2026  The emrs-dirdiff authors

;; SPDX-License-Identifier: GPL-3.0-or-later

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;;; Commentary:

;; `emrs-dirdiff-menu', bound to ? in `emrs-dirdiff-mode', lists every
;; command of the comparison buffer and shows the current settings of the
;; buffer it was opened from.  emrs-dirdiff.el autoloads it, so transient
;; is loaded only when the menu is first used.

;;; Code:

(require 'transient)
(require 'emrs-dirdiff)

(defun emrs-dirdiff-menu--buffer ()
  "Return the comparison buffer the menu works on."
  (cond ((derived-mode-p 'emrs-dirdiff-mode) (current-buffer))
        ((and (bound-and-true-p transient--original-buffer)
              (buffer-live-p transient--original-buffer))
         transient--original-buffer)
        (t (current-buffer))))

(defun emrs-dirdiff-menu--var (symbol)
  "Return the value of SYMBOL in the comparison buffer of the menu."
  (buffer-local-value symbol (emrs-dirdiff-menu--buffer)))

(defun emrs-dirdiff-menu--onoff (text value)
  "Return TEXT followed by [on] or [off] according to VALUE."
  (format "%s [%s]" text (if value "on" "off")))

(defun emrs-dirdiff-menu--same ()
  "Describe whether identical entries are shown."
  (with-current-buffer (emrs-dirdiff-menu--buffer)
    (format "identical entries [%s]"
            (if (emrs-dirdiff--same-shown-p) "shown" "hidden"))))

(defun emrs-dirdiff-menu--ignore-files ()
  "Describe whether ignore files apply."
  (emrs-dirdiff-menu--onoff "ignore files" (emrs-dirdiff-menu--var 'emrs-dirdiff--ignore-files)))

(defun emrs-dirdiff-menu--filter-name ()
  "Describe the name filter."
  (let ((filter (emrs-dirdiff-menu--var 'emrs-dirdiff--name-filter)))
    (if filter (format "filter by name [%s]" filter) "filter by name [none]")))

(defun emrs-dirdiff-menu--filter-status ()
  "Describe the status filter."
  (let ((filter (emrs-dirdiff-menu--var 'emrs-dirdiff--status-filter)))
    (format "status filter [%s]"
            (pcase filter
              ('nil "all") ('changed "changed") ('only-a "only A") ('only-b "only B")
              (_ filter)))))

(defun emrs-dirdiff-menu--view ()
  "Describe the view."
  (format "view: %s" (if (eq (emrs-dirdiff-menu--var 'emrs-dirdiff--view) 'sections)
                         "sections" "tree")))

(defun emrs-dirdiff-menu--by (method text)
  "Describe comparing by METHOD (`content' or `size-time'), shown as TEXT."
  (emrs-dirdiff-menu--onoff (concat "compare by " text)
                            (eq (emrs-dirdiff-menu--var 'emrs-dirdiff--by) method)))

(defun emrs-dirdiff-menu--whitespace ()
  "Describe whether whitespace differences are ignored."
  (emrs-dirdiff-menu--onoff "ignore whitespace" (emrs-dirdiff-menu--var 'emrs-dirdiff--whitespace)))

(defun emrs-dirdiff-menu--marks ()
  "Describe the marks."
  (let* ((marks (emrs-dirdiff-menu--var 'emrs-dirdiff--marks))
         (n (if marks (hash-table-count marks) 0)))
    (if (> n 0) (format "Act on the %d marked %s" n (if (= n 1) "entry" "entries"))
      "Act on the entry at point")))

;;;###autoload (autoload 'emrs-dirdiff-menu "emrs-dirdiff-menu" nil t)
(transient-define-prefix emrs-dirdiff-menu ()
  "Every command of `emrs-dirdiff-mode', with the current settings."
  :refresh-suffixes t
  [["Open"
    ("RET" "open: diff, visit or fold" emrs-dirdiff-open)
    ("e" "ediff" emrs-dirdiff-ediff)
    ("o" "visit A" emrs-dirdiff-visit-a)
    ("O" "visit B" emrs-dirdiff-visit-b)
    ("d" "dired here" emrs-dirdiff-dired-entry)]
   ["Move"
    ("n" "next difference" emrs-dirdiff-next-difference :transient t)
    ("p" "previous difference" emrs-dirdiff-previous-difference :transient t)
    ("N" "next directory" emrs-dirdiff-next-group :transient t)
    ("P" "previous directory" emrs-dirdiff-previous-group :transient t)
    ("TAB" "fold directory" emrs-dirdiff-toggle-fold :transient t)
    ("^" "parent" emrs-dirdiff-up :transient t)]
   ["Show"
    ("s" emrs-dirdiff-toggle-same :description emrs-dirdiff-menu--same :transient t)
    ("i" emrs-dirdiff-toggle-ignore-files :description emrs-dirdiff-menu--ignore-files
     :transient t)
    ("/" emrs-dirdiff-filter-name :description emrs-dirdiff-menu--filter-name)
    ("f" emrs-dirdiff-cycle-status-filter :description emrs-dirdiff-menu--filter-status
     :transient t)
    ("v" emrs-dirdiff-toggle-view :description emrs-dirdiff-menu--view :transient t)]]
  [[
    :description emrs-dirdiff-menu--marks
    ("m" "mark" emrs-dirdiff-mark :transient t)
    ("u" "unmark" emrs-dirdiff-unmark :transient t)
    ("U" "unmark all" emrs-dirdiff-unmark-all :transient t)
    ("D" "delete" emrs-dirdiff-delete)
    (">" "copy A → B" emrs-dirdiff-copy-a-to-b)
    ("<" "copy B → A" emrs-dirdiff-copy-b-to-a)
    ("w" "copy path" emrs-dirdiff-copy-path)]
   ["Compare by"
    ("c" emrs-dirdiff-compare-content
     :description (lambda () (emrs-dirdiff-menu--by 'content "content"))
     :transient t)
    ("t" emrs-dirdiff-compare-size-time
     :description (lambda () (emrs-dirdiff-menu--by 'size-time "size and time"))
     :transient t)
    ("W" emrs-dirdiff-toggle-whitespace :description emrs-dirdiff-menu--whitespace
     :transient t)]
   ["Comparison"
    ("g" "compare again" emrs-dirdiff-rescan)
    ("x" "swap A and B" emrs-dirdiff-swap)
    ("C-c C-k" "stop" emrs-dirdiff-stop)
    ("q" "quit window" quit-window)]])

(provide 'emrs-dirdiff-menu)
;;; emrs-dirdiff-menu.el ends here
