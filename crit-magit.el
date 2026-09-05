;;; crit-magit.el --- Local AI review comments from Magit diffs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 askdkc

;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1"))
;; Keywords: tools, vc

;; This file is not part of GNU Emacs.

;; This program is free software: you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; crit-magit adds a local AI review path to Magit diff buffers.
;;
;; From a Magit diff buffer you can attach a review comment to the
;; current line, an active region, or a whole file.  Each comment is
;; appended to a per-session Markdown file under the repository root:
;;
;;     <repository-root>/.critmagit/<session-id>.md
;;
;; An AI agent running outside Emacs reads that file (and optionally
;; replies to a separate response file) to receive the comments.  The
;; session directory is added to the repository `.gitignore' once so
;; that transient review state never enters Git history.
;;
;; This package deliberately does NOT start AI processes, call vendor
;; APIs, post to GitHub, or modify existing Magit or Forge behavior.
;; It only provides a stable local file protocol.
;;
;; Magit is a runtime dependency for the interactive commands, but it
;; is never `require'd at load time: Magit functions are referenced
;; through `declare-function' so that this file loads and
;; byte-compiles even when Magit is not installed.
;;
;; Verified against Emacs 30.2 and Magit 4.x (20260808.323).

;;; Code:

(defgroup crit-magit nil
  "Local AI review comments from Magit diff buffers."
  :group 'tools
  :group 'magit
  :prefix "crit-magit-")

(defcustom crit-magit-session-id nil
  "Identifier of the current AI review session.
When nil, commands ask the user to choose a session explicitly; a
shared session is never generated silently."
  :type '(choice (const :tag "Unset (ask on use)" nil)
                 (string :tag "Session ID"))
  :group 'crit-magit)

(defcustom crit-magit-session-file-function 'crit-magit-default-session-file
  "Function returning the session file path for a session ID.
Called with two arguments, the repository root directory and the
session ID, and must return an absolute file name.  The default
builds `<root>/.critmagit/<session-id>.md' and rejects empty IDs
and path traversal."
  :type 'function
  :group 'crit-magit)

(defcustom crit-magit-session-directory-name ".critmagit"
  "Name of the per-repository directory holding session files."
  :type 'string
  :group 'crit-magit)

(defcustom crit-magit-auto-update-gitignore t
  "Whether to add `.critmagit/' to the repository `.gitignore'.
When nil, the session directory is still created, but the user is
warned that session files may be tracked by Git."
  :type 'boolean
  :group 'crit-magit)

(defcustom crit-magit-author "user"
  "Author name recorded on new review comments."
  :type 'string
  :group 'crit-magit)

;; Magit is a runtime dependency only; never require it at load time.
(declare-function magit-toplevel "magit" (&optional directory))
(declare-function magit-file-at-point "magit" (&optional noprompt))
(declare-function magit-current-section "magit-section" ())
(declare-function magit-section-type "magit-section" (section))
(declare-function magit-section-value "magit-section" (section))
(declare-function magit-section-parent "magit-section" (section))

;;;; Position extraction

(defun crit-magit--assert-diff-buffer ()
  "Signal an error unless the current buffer is a Magit diff buffer."
  (unless (derived-mode-p 'magit-diff-mode)
    (user-error "Not in a Magit diff buffer")))

(defun crit-magit--repository-root ()
  "Return the absolute path of the current repository root.
Signal an error if the root cannot be determined."
  (or (and (fboundp 'magit-toplevel) (magit-toplevel))
      (locate-dominating-file default-directory ".git")
      (user-error "Cannot determine repository root")))

(defun crit-magit--diff-range ()
  "Return the diff range string recorded in the current buffer, if any."
  (or (and (boundp 'magit-diff-range) magit-diff-range)
      (and (boundp 'magit-buffer-diff-range) magit-buffer-diff-range)))

(defun crit-magit--commit-and-base (range)
  "Split diff RANGE into (COMMIT . BASE) strings.
Returns (\"unknown\" . \"unknown\") when RANGE is nil, and
(COMMIT . \"unknown\") for a single reference."
  (cond
   ((null range) (cons "unknown" "unknown"))
   ((string-match "^\\(.+\\)\\.\\.\\.\\(.+\\)$" range)
    (cons (match-string 2 range) (match-string 1 range)))
   ((string-match "^\\(.+\\)\\.\\.\\(.+\\)$" range)
    (cons (match-string 2 range) (match-string 1 range)))
   (t (cons range "unknown"))))

(defun crit-magit--normalize-path (path root)
  "Return PATH relative to ROOT.
PATH may be absolute or relative; ROOT must be absolute.
Signal an error if PATH resolves outside ROOT."
  (let* ((root-abs (expand-file-name root))
         (path-abs (expand-file-name path root-abs)))
    (unless (string-prefix-p (file-name-as-directory root-abs) path-abs)
      (user-error "Path %s is outside repository root" path))
    (file-relative-name path-abs root-abs)))

(defun crit-magit--file-at-point ()
  "Return the file path at point in a diff buffer."
  (or (and (fboundp 'magit-file-at-point) (magit-file-at-point))
      (save-excursion
        (beginning-of-line)
        (when (re-search-backward "^+++ b/\\(.+\\)$" nil t)
          (match-string-no-properties 1)))
      (user-error "No file at point")))

(defun crit-magit--current-hunk-header ()
  "Return the hunk header string at point, or nil if none is found."
  (or (and (fboundp 'magit-current-section)
           (let ((section (magit-current-section)))
             (while (and section
                         (not (eq (magit-section-type section) 'hunk)))
               (setq section (magit-section-parent section)))
             (and section (magit-section-value section))))
      (save-excursion
        (beginning-of-line)
        (when (re-search-backward
               "^@@ -[0-9]+\\(?:,[0-9]+\\)? \\+[0-9]+\\(?:,[0-9]+\\)? @@"
               nil t)
          (match-string-no-properties 0)))))

(defun crit-magit--parse-hunk-header (header)
  "Parse hunk HEADER into (OLD-START NEW-START), or nil if invalid."
  (when (string-match
         "^@@ -\\([0-9]+\\(?:,[0-9]+\\)?\\) \\+\\([0-9]+\\(?:,[0-9]+\\)?\\) @@"
         header)
    (list (string-to-number (match-string 1 header))
          (string-to-number (match-string 2 header)))))

(defun crit-magit--hunk-content-start (header)
  "Return the buffer position of the first content line of HEADER.
Returns nil when HEADER is not present before point."
  (save-excursion
    (beginning-of-line)
    (when (re-search-backward (regexp-quote header) nil t)
      (forward-line 1)
      (point))))

(defun crit-magit--hunk-line-info (content-start old-start new-start)
  "Return (SIDE . LINE) for the line containing the entry point.
CONTENT-START is the position of the first content line; OLD-START
and NEW-START are the 1-based line numbers from the hunk header.
SIDE is `added', `removed', or `context'.  Signal an error if the
entry point is not on a hunk content line."
  (let ((target (point)))
    (when (< target content-start)
      (user-error "Point is on the hunk header"))
    (save-excursion
      (let ((old old-start)
            (new new-start))
        (goto-char content-start)
        (while (and (< (point) target) (not (eobp)))
          (pcase (char-after)
            (?+ (setq new (1+ new)))
            (?- (setq old (1+ old)))
            (_ (setq old (1+ old)
                     new (1+ new))))
          (forward-line 1))
        (pcase (char-after)
          ((and c (or ?+ ?- ?\s))
           (cond
            ((eq c ?+) (cons 'added new))
            ((eq c ?-) (cons 'removed old))
            (t (cons 'context new))))
          (_ (user-error "Point is not on a diff hunk content line")))))))

(defun crit-magit--region-line-range (content-start old-start new-start
						    target-side beg end)
  "Return (MIN-LINE . MAX-LINE) of TARGET-SIDE lines between BEG and END.
Returns nil when no line of TARGET-SIDE is present.  Signal an
error if BEG precedes CONTENT-START or the range leaves the hunk."
  (when (< beg content-start)
    (user-error "Region includes the hunk header"))
  (save-excursion
    (let ((old old-start)
          (new new-start)
          (lines nil))
      (goto-char content-start)
      (while (< (point) beg)
        (pcase (char-after)
          (?+ (setq new (1+ new)))
          (?- (setq old (1+ old)))
          (_ (setq old (1+ old)
                   new (1+ new))))
        (forward-line 1))
      (while (< (point) end)
        (pcase (char-after)
          ((and c (or ?+ ?- ?\s))
           (cond
            ((eq c ?+)
             (when (eq target-side 'added) (push new lines))
             (setq new (1+ new)))
            ((eq c ?-)
             (when (eq target-side 'removed) (push old lines))
             (setq old (1+ old)))
            (t
             (when (eq target-side 'context) (push new lines))
             (setq old (1+ old)
                   new (1+ new)))))
          (_ (user-error "Region leaves the diff hunk")))
        (forward-line 1))
      (when lines
        (cons (apply #'min lines) (apply #'max lines))))))

(defun crit-magit--line-context ()
  "Return a short context string for the current line.
The leading diff marker is stripped; strings longer than 80
characters are truncated."
  (let ((line (buffer-substring-no-properties
               (line-beginning-position) (line-end-position))))
    (when (and (string-match-p "^[+\\- ]" line) (> (length line) 0))
      (setq line (substring line 1)))
    (if (> (length line) 80)
        (concat (substring line 0 77) "...")
      line)))

(defun crit-magit--extract-diff-target ()
  "Extract a review target from the current diff buffer.
Uses the active region when present, otherwise the current line.
Returns a plist with :repository, :commit, :base, :path,
:start-line, :end-line, :side, :source, and :context."
  (crit-magit--assert-diff-buffer)
  (let* ((root (crit-magit--repository-root))
         (file (crit-magit--file-at-point))
         (path (crit-magit--normalize-path file root))
         (header (or (crit-magit--current-hunk-header)
                     (user-error "No diff hunk at point")))
         (parsed (or (crit-magit--parse-hunk-header header)
                     (user-error "Malformed hunk header")))
         (content-start (or (crit-magit--hunk-content-start header)
                            (user-error "Hunk header not found in buffer")))
         (old-start (nth 0 parsed))
         (new-start (nth 1 parsed))
         (commit-base (crit-magit--commit-and-base
                       (crit-magit--diff-range))))
    (if (use-region-p)
        (let* ((beg (region-beginning))
               (end (region-end))
               (side-at-region
                (save-excursion
                  (goto-char beg)
                  (car (crit-magit--hunk-line-info
                        content-start old-start new-start))))
               (range-pair (crit-magit--region-line-range
                            content-start old-start new-start
                            side-at-region beg end)))
          (unless range-pair
            (user-error "Selected region contains no commentable lines"))
          (list :repository root
                :commit (car commit-base)
                :base (cdr commit-base)
                :path path
                :start-line (car range-pair)
                :end-line (cdr range-pair)
                :side side-at-region
                :source "diff"
                :context (crit-magit--line-context)))
      (let ((side-line (crit-magit--hunk-line-info
                        content-start old-start new-start)))
        (list :repository root
              :commit (car commit-base)
              :base (cdr commit-base)
              :path path
              :start-line (cdr side-line)
              :end-line (cdr side-line)
              :side (car side-line)
              :source "diff"
              :context (crit-magit--line-context))))))

(defun crit-magit--extract-file-target ()
  "Extract a whole-file review target from the current diff buffer.
Returns a plist without line numbers; :side is `file'."
  (crit-magit--assert-diff-buffer)
  (let* ((root (crit-magit--repository-root))
         (file (crit-magit--file-at-point))
         (path (crit-magit--normalize-path file root))
         (commit-base (crit-magit--commit-and-base
                       (crit-magit--diff-range))))
    (list :repository root
          :commit (car commit-base)
          :base (cdr commit-base)
          :path path
          :side 'file
          :source "diff"
          :context nil)))

(provide 'crit-magit)
;;; crit-magit.el ends here
