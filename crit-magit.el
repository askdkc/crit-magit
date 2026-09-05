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

(defcustom crit-magit-dsh-command "dsh"
  "Executable name or path of the `dsh' command.
Used to run one-shot review requests through the DSH harness."
  :type 'string
  :group 'crit-magit)

(defcustom crit-magit-dsh-profile "headless"
  "DSH profile used for one-shot review requests.
The `headless' profile runs a single task and prints the final
answer to standard output."
  :type 'string
  :group 'crit-magit)

(defcustom crit-magit-dsh-models
  '(("DeepSeek-V4-Flash" . ("deepseek-official" . "deepseek-v4-flash"))
    ("DeepSeek-V4-Pro" . ("deepseek-official" . "deepseek-v4-pro"))
    ("DeepSeek-V4-Flash-Vision-Exp"
     . ("deepseek-official" . "deepseek-v4-flash-vision-exp")))
  "Alist of DSH model choices for review requests.
Each entry is (LABEL . (PROVIDER . MODEL))."
  :type '(alist :key-type string
                :value-type (cons string string))
  :group 'crit-magit)

(defcustom crit-magit-dsh-default-model "DeepSeek-V4-Flash"
  "Label (key of `crit-magit-dsh-models') of the default model.
When the selected model resolves to the same PROVIDER/MODEL as this
entry, no `--patch' override is generated and the DSH default model
is used."
  :type 'string
  :group 'crit-magit)

(defcustom crit-magit-dsh-inline-size-limit 16000
  "Maximum characters of diff content to inline into a review prompt.
When the content to review exceeds this many characters, the prompt
instructs the DSH agent to run `git diff' instead of inlining."
  :type 'integer
  :group 'crit-magit)

(defcustom crit-magit-dsh-review-buffer-name "*crit-magit-review*"
  "Name of the buffer showing DSH review results."
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

(defun crit-magit--assert-review-buffer ()
  "Signal an error unless the current buffer is a Magit diff or status buffer.
Return non-nil on success."
  (unless (or (derived-mode-p 'magit-diff-mode)
              (derived-mode-p 'magit-status-mode))
    (user-error "Not in a Magit diff or status buffer"))
  t)

(defun crit-magit--working-tree-diff (root)
  "Return the staged and unstaged diff of ROOT as a string.
Uses `git diff HEAD'.  Return an empty string when git fails."
  (let ((default-directory (expand-file-name root))
        (buffer (generate-new-buffer " *crit-magit-git-diff*")))
    (unwind-protect
        (progn
          (call-process "git" nil buffer nil "diff" "HEAD")
          (with-current-buffer buffer (buffer-string)))
      (kill-buffer buffer))))

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

;;;; DSH review transport

(defun crit-magit--dsh-model-entry (label)
  "Return (PROVIDER . MODEL) for LABEL in `crit-magit-dsh-models'.
Signal `user-error' when LABEL is unknown."
  (or (cdr (assoc label crit-magit-dsh-models))
      (user-error "Unknown DSH model: %s" label)))

(defun crit-magit--dsh-model-patch-file (provider model)
  "Return a temporary patch overriding the DSH default model, or nil.
When PROVIDER and MODEL equal the selection of
`crit-magit-dsh-default-model', return nil and write nothing.
Otherwise write a temporary cordis.patch.yml that overrides the
`agent-default-model' row and return its absolute file name."
  (let* ((default-entry (crit-magit--dsh-model-entry
                         crit-magit-dsh-default-model)))
    (when (or (not (equal provider (car default-entry)))
              (not (equal model (cdr default-entry))))
      (let ((file (make-temp-file "crit-magit-dsh-" nil ".yml")))
        (with-temp-file file
          (insert "- id: agent-default-model\n")
          (insert "  name: '@deepseek-ai/dsh-agent-default-model'\n")
          (insert "  config:\n")
          (insert (format "    provider: %s\n" provider))
          (insert (format "    model: %s\n" model)))
        file))))

(defun crit-magit--dsh-argv (prompt model-label)
  "Return (ARGV . PATCH-FILE) for a DSH one-shot review.
PROMPT is the task text passed as the positional argument.
MODEL-LABEL selects the model; a non-default model adds `--patch'
with a temporary override file.  PATCH-FILE is that temporary file
to delete after the run, or nil."
  (let* ((entry (crit-magit--dsh-model-entry model-label))
         (patch-file (crit-magit--dsh-model-patch-file
                      (car entry) (cdr entry))))
    (cons (append (list crit-magit-dsh-command
                        "--profile" crit-magit-dsh-profile)
                  (when patch-file (list "--patch" patch-file))
                  (list prompt))
          patch-file)))

(defun crit-magit--dsh-outcome (exit-status stdout stderr)
  "Translate a DSH process result into (STATUS . TEXT).
STATUS is `success' with STDOUT when EXIT-STATUS is 0; otherwise
STATUS is `error' with STDERR (or STDOUT when STDERR is empty)."
  (if (and (integerp exit-status) (zerop exit-status))
      (cons 'success stdout)
    (cons 'error (if (and stderr (not (string-empty-p stderr)))
                     stderr
                   stdout))))

(defun crit-magit--dsh-sentinel (proc callback patch-file
                                     stdout-buffer stderr-buffer)
  "Handle exit of DSH process PROC.
Call CALLBACK with (STATUS . TEXT) from `crit-magit--dsh-outcome',
then clean up the temporary patch file and output buffers."
  (unwind-protect
      (let ((exit-status (process-exit-status proc))
            (stdout (with-current-buffer stdout-buffer (buffer-string)))
            (stderr (with-current-buffer stderr-buffer (buffer-string))))
        (funcall callback (crit-magit--dsh-outcome
                           exit-status stdout stderr)))
    (when (buffer-live-p stdout-buffer) (kill-buffer stdout-buffer))
    (when (buffer-live-p stderr-buffer) (kill-buffer stderr-buffer))
    (when (and patch-file (file-exists-p patch-file))
      (delete-file patch-file))))

(defun crit-magit--start-dsh (prompt model-label root callback)
  "Start a DSH one-shot review process and return it.
PROMPT is the task text, MODEL-LABEL the selected model, ROOT the
repository root used as working directory, and CALLBACK a function
called with (STATUS . TEXT) when the process exits."
  (let* ((argv-and-patch (crit-magit--dsh-argv prompt model-label))
         (argv (car argv-and-patch))
         (patch-file (cdr argv-and-patch))
         (stdout-buffer (generate-new-buffer " *crit-magit-dsh-stdout*"))
         (stderr-buffer (generate-new-buffer " *crit-magit-dsh-stderr*"))
         (default-directory (expand-file-name root)))
    (make-process
     :name "crit-magit-dsh"
     :buffer stdout-buffer
     :command argv
     :stderr stderr-buffer
     :connection-type 'pipe
     :sentinel (lambda (proc _event)
                 (crit-magit--dsh-sentinel proc callback patch-file
                                           stdout-buffer stderr-buffer)))))

;;;; DSH review prompt

(defun crit-magit--review-content-block (content)
  "Return CONTENT as an inline diff block, bounded by the size limit.
When CONTENT exceeds `crit-magit-dsh-inline-size-limit' characters,
return instead an instruction to run `git diff' in the repository."
  (if (<= (length content) crit-magit-dsh-inline-size-limit)
      (format "```diff\n%s\n```\n" content)
    (concat "The diff is too large to inline; run `git diff' in the "
            "repository root and review the changes.\n")))

(defun crit-magit--build-review-prompt (target &optional whole-content)
  "Build a bounded review prompt for TARGET or WHOLE-CONTENT.
TARGET is a review-target plist from `crit-magit--extract-diff-target'
or `crit-magit--extract-file-target'.  When TARGET is nil, WHOLE-CONTENT
must be a non-empty diff buffer string.  Signal `user-error' when both
yield no content."
  (if target
      (let* ((path (plist-get target :path))
             (start (plist-get target :start-line))
             (end (plist-get target :end-line))
             (side (plist-get target :side))
             (commit (plist-get target :commit))
             (base (plist-get target :base))
             (lines (cond ((null start) "whole file")
                          ((= start end) (format "line %s" start))
                          (t (format "lines %s-%s" start end)))))
        (concat
         "You are reviewing code changes in a Git repository. "
         "The working directory is the repository root.\n\n"
         (format "File: %s\n" path)
         (format "Location: %s\n" lines)
         (format "Side: %s\n" side)
         (format "Commit: %s\n" commit)
         (format "Base: %s\n\n" base)
         (crit-magit--review-content-block
          (or (plist-get target :context) ""))))
    (if (and whole-content (not (string-empty-p whole-content)))
        (concat
         "You are reviewing all changes in the current diff. "
         "The working directory is the repository root.\n\n"
         (crit-magit--review-content-block whole-content))
      (user-error "No review target or diff content"))))

;;;; DSH review commands

(defun crit-magit--show-review (outcome)
  "Display a DSH review OUTCOME (STATUS . TEXT).
STATUS is `success' or `error'.  TEXT is shown in
`crit-magit-dsh-review-buffer-name'."
  (let* ((status (car outcome))
         (text (or (cdr outcome) ""))
         (buffer (get-buffer-create crit-magit-dsh-review-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (if (eq status 'success)
                    text
                  (format "DSH review failed:\n\n%s" text))))
      (special-mode)
      (goto-char (point-min)))
    (display-buffer buffer)
    (if (eq status 'success)
        (message "crit-magit: review complete")
      (message "crit-magit: review failed (see %s)"
               (buffer-name buffer)))))

(defun crit-magit-set-dsh-model (model)
  "Set the DSH review model to MODEL.
Interactively, prompt with completion over `crit-magit-dsh-models'."
  (interactive
   (list (completing-read
          "DSH model: "
          (mapcar #'car crit-magit-dsh-models)
          nil t crit-magit-dsh-default-model)))
  (unless (assoc model crit-magit-dsh-models)
    (user-error "Unknown DSH model: %s" model))
  (setq crit-magit-dsh-default-model model)
  (message "crit-magit: DSH model set to %s" model))

(defun crit-magit-review ()
  "Send the current diff target for DSH AI review.
The model in `crit-magit-dsh-default-model' is used; set it with
`crit-magit-set-dsh-model'.  The result is shown in
`crit-magit-dsh-review-buffer-name'."
  (interactive)
  (crit-magit--assert-diff-buffer)
  (let* ((root (crit-magit--repository-root))
         (target (crit-magit--extract-diff-target))
         (prompt (crit-magit--build-review-prompt target)))
    (message "crit-magit: requesting review (%s)..."
             crit-magit-dsh-default-model)
    (crit-magit--start-dsh prompt crit-magit-dsh-default-model root
                           #'crit-magit--show-review)))

(defun crit-magit-review-whole ()
  "Send the whole current diff for DSH AI review.
In a Magit diff buffer the buffer content is reviewed; in a Magit
status buffer the working-tree diff (staged and unstaged) is
reviewed.  The model in `crit-magit-dsh-default-model' is used."
  (interactive)
  (crit-magit--assert-review-buffer)
  (let* ((root (crit-magit--repository-root))
         (content (if (derived-mode-p 'magit-status-mode)
                      (crit-magit--working-tree-diff root)
                    (buffer-string)))
         (prompt (crit-magit--build-review-prompt nil content)))
    (message "crit-magit: requesting whole-diff review (%s)..."
             crit-magit-dsh-default-model)
    (crit-magit--start-dsh prompt crit-magit-dsh-default-model root
                           #'crit-magit--show-review)))

(provide 'crit-magit)
;;; crit-magit.el ends here
