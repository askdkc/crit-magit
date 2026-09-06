;;; crit-magit.el --- Local AI review comments from Magit diffs -*- lexical-binding: t; -*-

;; Copyright (C) 2026 askdkc

;; Version: 0.1.2
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
;; The configured DSH command reads that file to receive the comments and
;; performs the source-change and re-review pass.  The session directory is
;; added to the repository `.gitignore' once so that transient review state
;; never enters Git history.
;;
;; The package starts only the configured local DSH command and does not call
;; vendor APIs, post to GitHub, or modify existing Magit or Forge behavior.
;; ACP model discovery and the comment session file are local protocols.
;;
;; Magit is a runtime dependency for the interactive commands, but it
;; is never `require'd at load time: Magit functions are referenced
;; through `declare-function' so that this file loads and
;; byte-compiles even when Magit is not installed.
;;
;; Verified against Emacs 30.2 and Magit 4.x (20260808.323).

;;; Code:

(require 'json)
(require 'subr-x)
(require 'eieio)

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

(defcustom crit-magit-dsh-acp-profile "acp"
  "DSH profile used to discover model choices over ACP stdio."
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
This label is a fallback for model selection only.  Every request explicitly
passes its chosen provider and model to the headless profile."
  :type 'string
  :group 'crit-magit)

(defcustom crit-magit-dsh-selected-model nil
  "The last ACP-selected model as a (PROVIDER . MODEL) pair.
When nil, `crit-magit' loads the last selection from
`crit-magit-dsh-model-history-file'."
  :type '(choice (const :tag "Unset" nil)
                 (cons (string :tag "Provider")
                       (string :tag "Model")))
  :group 'crit-magit)

(defcustom crit-magit-dsh-model-history-file
  (expand-file-name "crit-magit-dsh-model.json" user-emacs-directory)
  "File used to remember the last ACP-selected provider and model."
  :type 'file
  :group 'crit-magit)

(defcustom crit-magit-dsh-inline-size-limit 16000
  "Maximum UTF-8 bytes of a review prompt passed on the command line.
Larger requests are saved intact in a private temporary file for DSH to read.
The file is removed after completion, failure, or cancellation."
  :type 'integer
  :group 'crit-magit)

(defcustom crit-magit-dsh-review-buffer-name "*crit-magit-review*"
  "Name of the buffer showing DSH review results."
  :type 'string
  :group 'crit-magit)

(defcustom crit-magit-comment-size-limit 8000
  "Maximum number of characters accepted for one review comment."
  :type 'integer
  :group 'crit-magit)

(defcustom crit-magit-review-after-comment t
  "Whether `crit-magit-comment' should start a DSH re-review.
When nil, the comment is only written to the session file and can be
sent later with `crit-magit-review-session'."
  :type 'boolean
  :group 'crit-magit)

(defvar crit-magit--dsh-process nil
  "The currently running DSH review process, or nil.")

(defvar crit-magit--dsh-stage nil
  "Current DSH stage, either `model-discovery', `review', or nil.")

(defvar crit-magit--dsh-model-loaded nil
  "Whether the saved ACP model preference has been loaded.")

(defvar crit-magit--comment-sequence 0
  "Per-Emacs-process sequence used to make comment IDs unique.")

(defvar crit-magit--dsh-mode-line-entry
  '(" " (:eval (crit-magit--dsh-mode-line)))
  "Mode-line entry installed while a DSH review is running.")

;; Magit is a runtime dependency only; never require it at load time.
(declare-function magit-toplevel "magit" (&optional directory))
(declare-function magit-file-at-point "magit" (&optional noprompt))
(declare-function magit-current-section "magit-section" ())
(defcustom crit-magit-dsh-discovery-timeout 30
  "Maximum seconds to wait for ACP model discovery."
  :type 'number
  :group 'crit-magit)

(defun crit-magit--section-slot (section slot)
  "Read SLOT from a Magit SECTION without requiring Magit at compile time."
  (eieio-oref section slot))

(defun crit-magit--section (type)
  "Return the ancestor Magit section of TYPE at point, or nil."
  (let ((section (and (fboundp 'magit-current-section)
                      (magit-current-section))))
    (while (and section (not (eq (crit-magit--section-slot section 'type) type)))
      (setq section (crit-magit--section-slot section 'parent)))
    section))

;;;; DSH status

(defun crit-magit--dsh-mode-line ()
  "Return a mode-line indicator while a DSH review is running."
  (when (and crit-magit--dsh-process
             (process-live-p crit-magit--dsh-process))
    (propertize
     (if (eq crit-magit--dsh-stage 'model-discovery)
         "crit: discovering DSH models"
       "crit: DSH review running")
     'face 'mode-line-emphasis)))

(defun crit-magit--set-dsh-process (process &optional stage)
  "Set the active DSH PROCESS and install its mode-line indicator.
STAGE identifies the visible operation status."
  (setq crit-magit--dsh-process process
        crit-magit--dsh-stage (or stage 'review))
  (unless (boundp 'global-mode-string)
    (setq global-mode-string nil))
  (unless (listp global-mode-string)
    (setq global-mode-string (list global-mode-string)))
  (add-to-list 'global-mode-string crit-magit--dsh-mode-line-entry t)
  (force-mode-line-update t))

(defun crit-magit--clear-dsh-process (process)
  "Clear PROCESS from the active DSH state and refresh the mode line."
  (when (eq process crit-magit--dsh-process)
    (setq crit-magit--dsh-process nil
          crit-magit--dsh-stage nil)
    (when (boundp 'global-mode-string)
      (setq global-mode-string
            (delete crit-magit--dsh-mode-line-entry global-mode-string)))
    (force-mode-line-update t)))

;;;; Position extraction

(defun crit-magit--assert-diff-buffer ()
  "Signal an error unless the current buffer can contain Magit diffs."
  (unless (derived-mode-p 'magit-diff-mode 'magit-status-mode)
    (user-error "Not in a Magit diff or status buffer")))

(defun crit-magit--assert-review-buffer ()
  "Signal an error unless the current buffer is a Magit diff or status buffer.
Return non-nil on success."
  (unless (or (derived-mode-p 'magit-diff-mode)
              (derived-mode-p 'magit-status-mode))
    (user-error "Not in a Magit diff or status buffer"))
  t)

(defun crit-magit--git-output (root &rest args)
  "Run Git ARGS in ROOT, returning output or signaling an error."
  (let ((default-directory (file-name-as-directory (expand-file-name root))))
    (with-temp-buffer
      (let ((status (apply #'call-process "git" nil t nil args)))
        (unless (equal status 0)
          (user-error "Git %s failed (%s): %s"
                      (car args) status (string-trim (buffer-string))))
        (buffer-string)))))

(defun crit-magit--working-tree-diff (root)
  "Return separate staged and unstaged patches in ROOT.
Keep both layers even when they cancel out relative to HEAD.  This also
works before the first commit.  Untracked files are not included."
  (let ((staged (crit-magit--git-output
                 root "diff" "--cached" "--no-ext-diff" "--no-textconv"
                 "--no-color" "--binary" "--"))
        (unstaged (crit-magit--git-output
                   root "diff" "--no-ext-diff" "--no-textconv"
                   "--no-color" "--binary" "--")))
    (concat (unless (string-empty-p staged)
              (concat "Staged changes (HEAD to index):\n" staged))
            (unless (string-empty-p unstaged)
              (concat "\nUnstaged changes (index to worktree):\n" unstaged)))))

(defun crit-magit--buffer-diff ()
  "Return the full displayed diff, including folded and narrowed text."
  (save-restriction
    (widen)
    (buffer-substring-no-properties (point-min) (point-max))))

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
  "Return the file at point without falling back to a previous Magit section."
  (or (and (fboundp 'magit-file-at-point) (magit-file-at-point t))
      (unless (and (fboundp 'magit-current-section) (magit-current-section))
        (save-excursion
          (beginning-of-line)
          (let ((limit (save-excursion
                         (if (re-search-backward "^diff --git " nil t)
                             (point) (point-min)))))
            (when (or (looking-at "^[+][+][+] ")
                      (re-search-backward "^[+][+][+] " limit t))
              (cond
               ((looking-at "[+][+][+] b/\\(.+\\)$")
                (match-string-no-properties 1))
               ((looking-at "[+][+][+] /dev/null$")
                (when (re-search-backward "^--- a/\\(.+\\)$" limit t)
                  (match-string-no-properties 1))))))))
      (user-error "No file at point")))

(defun crit-magit--current-hunk-header ()
  "Return the actual hunk header at point, without crossing file sections."
  (let ((section (crit-magit--section 'hunk)))
    (cond
     (section
      (save-excursion
        (goto-char (crit-magit--section-slot section 'start))
        (buffer-substring-no-properties (line-beginning-position)
                                        (line-end-position))))
     ((and (fboundp 'magit-current-section) (magit-current-section)) nil)
     (t
      (save-excursion
        (beginning-of-line)
        (when (or (looking-at "^@@ ")
                  (re-search-backward "^\\(?:@@ \\|diff --git \\|[+][+][+] \\|--- \\)" nil t))
          (when (looking-at "^@@ ")
            (buffer-substring-no-properties (line-beginning-position)
                                            (line-end-position)))))))))

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
    (when (or (looking-at (regexp-quote header))
              (re-search-backward (concat "^" (regexp-quote header) "$") nil t))
      (forward-line 1)
      (point))))

(defun crit-magit--hunk-line-info (content-start old-start new-start)
  "Return (SIDE . LINE) for the line containing the entry point.
CONTENT-START is the position of the first content line; OLD-START
and NEW-START are the 1-based line numbers from the hunk header.
SIDE is `added', `removed', or `context'.  Signal an error if the
entry point is not on a hunk content line."
  (let ((target (line-beginning-position)))
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
            (?\s (setq old (1+ old) new (1+ new)))
            (?\\ nil)
            (_ (user-error "Point leaves the diff hunk")))
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
  (setq beg (save-excursion (goto-char beg) (line-beginning-position)))
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
          (?\s (setq old (1+ old) new (1+ new)))
          (?\\ nil)
          (_ (user-error "Region leaves the diff hunk")))
        (forward-line 1))
      (while (< (point) end)
        (pcase (char-after)
          ((and c (or ?+ ?- ?\s))
           (cond
            ((eq c ?+)
             (when (eq target-side 'removed)
               (user-error "Select old or new lines separately"))
             (unless (eq target-side 'removed) (push new lines))
             (setq new (1+ new)))
            ((eq c ?-)
             (unless (eq target-side 'removed)
               (user-error "Select old or new lines separately"))
             (when (eq target-side 'removed) (push old lines))
             (setq old (1+ old)))
            (t
             (when (eq target-side 'removed)
               (user-error "Select removed lines separately from context"))
             (push new lines)
             (setq old (1+ old)
                   new (1+ new)))))
          (?\\ nil)
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
  "Extract a target at the start of the selection, independent of its direction."
  (let ((bounds (and (use-region-p)
                     (cons (region-beginning) (region-end)))))
    (save-mark-and-excursion
      (when bounds
        (goto-char (car bounds))
        (set-mark (cdr bounds))
        (activate-mark))
      (crit-magit--extract-diff-target-at-point))))

(defun crit-magit--extract-diff-target-at-point ()
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

;;;; Session comments

(defun crit-magit--validate-path-component (value description)
  "Return VALUE when it is a safe single path component.
DESCRIPTION is used in the user-facing error when VALUE is invalid."
  (unless (and (stringp value)
               (not (string-empty-p value))
               (<= (length value) 128)
               (not (string-match-p "[\r\n\0]" value))
               (not (string-match-p "/" value))
               (not (string-match-p "\\\\" value))
               (not (member value '("." ".."))))
    (user-error "Invalid %s: %s" description value))
  value)

(defun crit-magit--validate-session-id (session-id)
  "Return SESSION-ID after validating it as a safe session name."
  (crit-magit--validate-path-component session-id "session ID"))

(defun crit-magit-default-session-file (root session-id)
  "Return the default session file for ROOT and SESSION-ID.
The result is always below ROOT's configured session directory."
  (let* ((root-abs (file-name-as-directory (expand-file-name root)))
         (directory-name
          (crit-magit--validate-path-component
           crit-magit-session-directory-name "session directory name"))
         (directory (expand-file-name directory-name root-abs))
         (id (crit-magit--validate-session-id session-id))
         (file (expand-file-name (concat id ".md") directory)))
    (unless (string-prefix-p (file-name-as-directory directory) file)
      (user-error "Session file leaves the session directory: %s" file))
    file))

(defcustom crit-magit-session-id-function 'crit-magit-default-session-id
  "Function returning a default session ID for the prompt.
Called with no arguments and must return a string or nil.  The
default returns a timestamp-based random ID, so pressing RET at
the prompt starts a fresh session instead of erroring."
  :type 'function
  :group 'crit-magit)

(defun crit-magit-default-session-id ()
  "Return a timestamp-based default session ID.
The result is a safe single path component suitable for
`crit-magit-default-session-file'."
  (format "session-%s"
          (format-time-string "%Y%m%d-%H%M%S" nil t)))

(defun crit-magit--session-id ()
  "Return the configured session ID, prompting when it is unset.
The explicitly selected ID is retained for subsequent commands in this
Emacs session.  When prompted, RET accepts the default from
`crit-magit-session-id-function'."
  (let ((id (or crit-magit-session-id
                (read-string "crit-magit session ID: "
                             (funcall crit-magit-session-id-function)))))
    (setq id (crit-magit--validate-session-id id))
    (setq crit-magit-session-id id)
    id))

(defun crit-magit-set-session (session-id)
  "Set the current AI review SESSION-ID.
Interactively, prompt for a safe single-component session name; RET
accepts the default from `crit-magit-session-id-function'."
  (interactive
   (list (read-string "crit-magit session ID: "
                      (or crit-magit-session-id
                          (funcall crit-magit-session-id-function)))))
  (setq crit-magit-session-id (crit-magit--validate-session-id session-id))
  (message "crit-magit: session set to %s" crit-magit-session-id))

(defun crit-magit--session-file (root session-id)
  "Return a validated session file inside ROOT's session directory."
  (crit-magit--validate-session-id session-id)
  (let* ((directory (expand-file-name
                     (crit-magit--validate-path-component
                      crit-magit-session-directory-name "session directory name")
                     root))
         (file (funcall crit-magit-session-file-function root session-id)))
    (unless (and (stringp file) (file-name-absolute-p file)
                 (equal (file-name-directory (expand-file-name file))
                        (file-name-as-directory directory)))
      (user-error "Session file must be directly inside %s" directory))
    (when (or (file-symlink-p directory) (file-symlink-p file)
              (file-directory-p file))
      (user-error "Refusing symlink or directory session path: %s" file))
    (expand-file-name file)))

(defun crit-magit--read-file (file)
  "Return the UTF-8 text in FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun crit-magit--atomic-write (file content &optional coding)
  "Atomically write CONTENT as UTF-8 to FILE.
Reject symlinks and directories; preserve optional CODING when supplied."
  (when (file-symlink-p file)
    (user-error "Refusing to replace symlink: %s" file))
  (when (file-directory-p file)
    (user-error "Refusing to replace directory: %s" file))
  (when (and (file-exists-p file) (not (file-writable-p file)))
    (user-error "Cannot write file: %s" file))
  (when-let ((buffer (find-buffer-visiting file)))
    (when (buffer-modified-p buffer)
      (user-error "Save or revert the modified session buffer first: %s" file)))
  (let* ((directory (file-name-directory file))
         (temporary (make-temp-file
                     (expand-file-name ".crit-magit-write-" directory))))
    (unwind-protect
        (progn
          (with-temp-file temporary
            (set-buffer-file-coding-system (or coding 'utf-8-unix))
            (insert content))
          (when (file-exists-p file)
            (set-file-modes temporary (file-modes file)))
          (rename-file temporary file t)
          (setq temporary nil))
      (when (and temporary (file-exists-p temporary))
        (delete-file temporary)))))

(defun crit-magit--gitignore-entry ()
  "Return the exact gitignore entry for the session directory."
  (concat (crit-magit--validate-path-component
           crit-magit-session-directory-name "session directory name")
          "/"))

(defun crit-magit--ensure-gitignore (root)
  "Ensure ROOT's gitignore protects the session directory, preserving coding."
  (let* ((file (expand-file-name ".gitignore" root))
         (entry (crit-magit--gitignore-entry))
         (content "")
         (coding 'utf-8-unix))
    (when (or (file-symlink-p file) (file-directory-p file))
      (user-error "Refusing symlink or directory .gitignore: %s" file))
    (when (file-exists-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (setq content (buffer-string) coding buffer-file-coding-system)))
    (unless (member entry (split-string content "\n" t))
      (if crit-magit-auto-update-gitignore
          (progn
            (crit-magit--atomic-write
             file (concat content
                          (unless (or (string-empty-p content)
                                      (string-suffix-p "\n" content)) "\n")
                          entry "\n")
             coding)
            (message "crit-magit: added %s to %s" entry file))
        (display-warning
         'crit-magit
         (format "%s is not ignored; session files may be tracked by Git" entry)
         :warning)))))

(defun crit-magit--prepare-session-file (root session-id)
  "Return (FILE . CONTENT) for a validated session under ROOT.
Create the session directory and header content when FILE is new."
  (let* ((directory (expand-file-name
                     (crit-magit--validate-path-component
                      crit-magit-session-directory-name
                      "session directory name")
                     root))
         (file (crit-magit--session-file root session-id)))
    (crit-magit--ensure-gitignore root)
    (when (file-symlink-p directory)
      (user-error "Refusing to use symlink session directory: %s" directory))
    (cond
     ((file-exists-p directory)
      (unless (file-directory-p directory)
        (user-error "Session directory is not a directory: %s" directory)))
     (t (make-directory directory t)))
    (when (file-symlink-p file)
      (user-error "Refusing to use symlink session file: %s" file))
    (when (file-directory-p file)
      (user-error "Session file is a directory: %s" file))
    (if (file-exists-p file)
        (let ((content (crit-magit--read-file file)))
          (unless (crit-magit--session-header-p content session-id)
            (user-error "Session file belongs to another session or is corrupt: %s"
                        file))
          (cons file content))
      (cons file
            (format
             "# crit-magit session: %s\n\n- protocol: 1\n- repository: `%s`\n- created: %s\n\n"
             session-id
             (replace-regexp-in-string "`" "'" (expand-file-name root) t t)
             (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t))))))

(defun crit-magit--markdown-value (value)
  "Return VALUE safe for one Markdown metadata line."
  (replace-regexp-in-string
   "`" "'"
   (replace-regexp-in-string "[\r\n]" " " (format "%s" value) t t)
   t t))

(defun crit-magit--session-header-p (content session-id)
  "Return non-nil when CONTENT starts with SESSION-ID's valid header."
  (let ((header (format "# crit-magit session: %s" session-id)))
    (and (string-prefix-p header content)
         (> (length content) (length header))
         (= (aref content (length header)) ?\n))))

(defun crit-magit--comment-id ()
  "Return a process-local unique review comment ID."
  (setq crit-magit--comment-sequence
        (1+ crit-magit--comment-sequence))
  (format "c_%s_%x_%06d"
          (format-time-string "%Y%m%d%H%M%S" nil t)
          (emacs-pid)
          crit-magit--comment-sequence))

(defun crit-magit--comment-lines (target)
  "Return the Markdown line description for TARGET."
  (let ((start (plist-get target :start-line))
        (end (plist-get target :end-line)))
    (cond
     ((null start) "whole file")
     ((equal start end) (format "%s" start))
     (t (format "%s-%s" start end)))))

(defun crit-magit--blockquote (body)
  "Return BODY formatted as a Markdown block quote without changing its text."
  (concat "> " (replace-regexp-in-string "\n" "\n> " body t t)))

(defun crit-magit--format-comment (target session-id body comment-id)
  "Return a Markdown block for BODY attached to TARGET.
SESSION-ID and COMMENT-ID identify the persisted review comment."
  (format
   "\n## Comment %s\n\n- session-id: `%s`\n- repository: `%s`\n- path: `%s`\n- lines: %s\n- side: %s\n- source: diff\n- commit: `%s`\n- base: `%s`\n- author: %s\n- status: unresolved\n- created: %s\n\n%s\n\n<!-- context: %s -->\n"
   comment-id
   (crit-magit--markdown-value session-id)
   (crit-magit--markdown-value (plist-get target :repository))
   (crit-magit--markdown-value (plist-get target :path))
   (crit-magit--comment-lines target)
   (crit-magit--markdown-value (plist-get target :side))
   (crit-magit--markdown-value (plist-get target :commit))
   (crit-magit--markdown-value (plist-get target :base))
   (crit-magit--markdown-value crit-magit-author)
   (format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t)
   (crit-magit--blockquote body)
   (crit-magit--markdown-value (or (plist-get target :context) ""))))

(defun crit-magit--unresolved-comment-count (content)
  "Return the number of unresolved comments in session CONTENT."
  (let ((start 0)
        (count 0))
    (while (string-match "^- status: unresolved[ \t]*$" content start)
      (setq count (1+ count)
            start (match-end 0)))
    count))

(defun crit-magit--write-comment (target body)
  "Persist BODY for TARGET and return (:file :id :count).
The target must already have been extracted from the current diff buffer."
  (unless (and (stringp body) (not (string-empty-p body)))
    (user-error "Review comment must not be empty"))
  (when (> (length body) crit-magit-comment-size-limit)
    (user-error "Review comment exceeds %s characters"
                crit-magit-comment-size-limit))
  (let* ((root (plist-get target :repository))
         (session-id (crit-magit--session-id))
         (file (crit-magit--session-file root session-id))
         (lock (concat file ".lock")))
    (make-directory (file-name-directory file) t)
    ;; Atomic directory creation serializes the entire read/append/replace cycle.
    (condition-case nil
        (make-directory lock)
      (file-already-exists
       (user-error "Session is locked by another writer: %s" lock)))
    (unwind-protect
        (let* ((prepared (crit-magit--prepare-session-file root session-id))
               (comment-id (crit-magit--comment-id))
               (new-content (concat (cdr prepared)
                                    (crit-magit--format-comment
                                     target session-id body comment-id))))
          (crit-magit--atomic-write file new-content)
          (list :file file :id comment-id
                :count (crit-magit--unresolved-comment-count new-content)
                :session-id session-id))
      (delete-directory lock))))

(defun crit-magit--dsh-running-p ()
  "Return non-nil when a DSH process is currently running."
  (and crit-magit--dsh-process
       (process-live-p crit-magit--dsh-process)))

;;;; DSH review transport

(defun crit-magit--valid-model-selection-p (selection)
  "Return non-nil when SELECTION is a valid (PROVIDER . MODEL) pair."
  (and (consp selection)
       (stringp (car selection))
       (stringp (cdr selection))
       (not (string-empty-p (car selection)))
       (not (string-empty-p (cdr selection)))
       (<= (length (car selection)) 256)
       (<= (length (cdr selection)) 256)
       (not (string-match-p "[\r\n]" (car selection)))
       (not (string-match-p "[\r\n]" (cdr selection)))))

(defun crit-magit--dsh-selection-label (selection)
  "Return a readable label for the PROVIDER/MODEL SELECTION."
  (format "%s / %s" (car selection) (cdr selection)))

(defun crit-magit--dsh-selection-from-value (value)
  "Decode an ACP model option VALUE into a provider/model pair."
  (when (stringp value)
    (condition-case nil
        (let ((parts (json-parse-string value :array-type 'list)))
          (when (and (listp parts)
                     (= (length parts) 2)
                     (stringp (nth 0 parts))
                     (stringp (nth 1 parts)))
            (let ((selection (cons (nth 0 parts) (nth 1 parts))))
              (when (crit-magit--valid-model-selection-p selection)
                selection))))
      (error nil))))

(defun crit-magit--json-object-value (object key)
  "Return KEY from JSON alist OBJECT.
`json-parse-string' uses symbols for alist keys by default, while
callers and test fixtures may use strings, so accept both forms."
  (or (alist-get key object nil nil #'equal)
      (alist-get (intern key) object nil nil #'eq)))

(defun crit-magit--dsh-model-options (config-options)
  "Return an alist of completion labels and selections from ACP CONFIG-OPTIONS.
Only the standard select option whose id is `model' is accepted."
  (let ((model-option nil))
    (dolist (option config-options)
      (when (and (listp option)
                 (equal (crit-magit--json-object-value option "id") "model"))
        (setq model-option option)))
    (unless model-option
      (user-error "DSH ACP did not return a model selection"))
    (let ((choices nil))
      (dolist (entry (crit-magit--json-object-value model-option "options"))
        (let* ((group (crit-magit--json-object-value entry "group"))
               (values (if (stringp group)
                           (crit-magit--json-object-value entry "options")
                         (list entry))))
          (dolist (value values)
            (let* ((selection
                    (crit-magit--dsh-selection-from-value
                     (crit-magit--json-object-value value "value")))
                   (name (crit-magit--json-object-value value "name")))
              (when (and selection (stringp name) (not (string-empty-p name)))
                (let ((label (format "%s / %s"
                                     (or group (car selection)) name)))
                  (unless (assoc label choices)
                    (push (cons label selection) choices))))))))
      (nreverse choices))))

(defun crit-magit--dsh-model-current-selection (config-options)
  "Return the current ACP model selection in CONFIG-OPTIONS, or nil."
  (let ((model-option nil))
    (dolist (option config-options)
      (when (and (listp option)
                 (equal (crit-magit--json-object-value option "id") "model"))
        (setq model-option option)))
    (and model-option
         (crit-magit--dsh-selection-from-value
          (crit-magit--json-object-value model-option "currentValue")))))

(defun crit-magit--dsh-load-selected-model ()
  "Load the remembered ACP model selection once."
  (unless crit-magit--dsh-model-loaded
    (setq crit-magit--dsh-model-loaded t)
    (when (and (null crit-magit-dsh-selected-model)
               (file-regular-p crit-magit-dsh-model-history-file)
               (not (file-symlink-p crit-magit-dsh-model-history-file)))
      (condition-case nil
          (let* ((data (json-parse-string
                        (crit-magit--read-file crit-magit-dsh-model-history-file)
                        :object-type 'alist))
                 (selection
                  (cons (crit-magit--json-object-value data "provider")
                        (crit-magit--json-object-value data "model"))))
            (when (crit-magit--valid-model-selection-p selection)
              (setq crit-magit-dsh-selected-model selection)))
        (error nil)))))

(defun crit-magit--dsh-remember-model (selection)
  "Remember the ACP model SELECTION for this and future Emacs sessions."
  (unless (crit-magit--valid-model-selection-p selection)
    (user-error "Invalid DSH model selection"))
  (setq crit-magit-dsh-selected-model (cons (car selection) (cdr selection)))
  (condition-case error-data
      (let ((directory (file-name-directory
                        (expand-file-name crit-magit-dsh-model-history-file))))
        (unless (file-directory-p directory)
          (make-directory directory t))
        (crit-magit--atomic-write
         crit-magit-dsh-model-history-file
         (json-encode `(("provider" . ,(car selection))
                        ("model" . ,(cdr selection)))))
        (message "crit-magit: remembered DSH model %s"
                 (crit-magit--dsh-selection-label selection)))
    (error
     (display-warning
      'crit-magit
      (format "Could not remember DSH model: %s" (error-message-string error-data))
      :warning))))

(defun crit-magit--dsh-choose-model (config-options)
  "Prompt for a model from ACP CONFIG-OPTIONS and remember the choice."
  (let* ((choices (crit-magit--dsh-model-options config-options))
         (current (crit-magit--dsh-model-current-selection config-options)))
    (unless choices
      (user-error "DSH ACP returned no usable models"))
    (crit-magit--dsh-load-selected-model)
    (let* ((saved crit-magit-dsh-selected-model)
           (default-selection
            (or saved
                current
                (cdr (assoc crit-magit-dsh-default-model
                            crit-magit-dsh-models))
                (cdar choices)))
           (default-label
            (or (car (rassoc default-selection choices))
                (caar choices)))
           (label (completing-read "DSH model: " choices nil t default-label))
           (selection (cdr (assoc label choices))))
      (unless selection
        (user-error "Unknown DSH model choice: %s" label))
      (crit-magit--dsh-remember-model selection)
      selection)))

(defun crit-magit--dsh-assert-command ()
  "Signal an actionable error when the configured DSH executable is unavailable."
  (unless (and (stringp crit-magit-dsh-command)
               (or (file-executable-p crit-magit-dsh-command)
                   (executable-find crit-magit-dsh-command)))
    (user-error "DSH command not found or not executable: %s"
                crit-magit-dsh-command)))

(defun crit-magit--acp-send (process id method params)
  "Send an ACP JSON-RPC request to PROCESS."
  (process-send-string
   process
   (concat
    (json-encode
     `(("jsonrpc" . "2.0")
       ("id" . ,id)
       ("method" . ,method)
       ("params" . ,params)))
    "\n")))

(defun crit-magit--acp-finish (process state callback outcome)
  "Finish ACP discovery STATE with OUTCOME and clean up PROCESS."
  (unless (plist-get state :finished)
    (setf (plist-get state :finished) t)
    (when-let ((timer (plist-get state :timer))) (cancel-timer timer))
    (crit-magit--clear-dsh-process process)
    (set-process-query-on-exit-flag process nil)
    (when (process-live-p process)
      (delete-process process))
    (let ((stderr-buffer (plist-get state :stderr-buffer)))
      (when (buffer-live-p stderr-buffer)
        (let ((kill-buffer-query-functions nil))
          (kill-buffer stderr-buffer))))
    ;; Never enter a minibuffer or start another process from a process filter.
    (run-at-time 0 nil callback outcome)))

(defun crit-magit--acp-failure (process state callback message)
  "Finish ACP discovery with an error MESSAGE and stderr context."
  (let* ((stderr-buffer (plist-get state :stderr-buffer))
         (stderr (and (buffer-live-p stderr-buffer)
                      (with-current-buffer stderr-buffer (buffer-string))))
         (detail (if (and stderr (not (string-empty-p stderr)))
                     (format "%s\n\n%s" message stderr)
                   message)))
    (crit-magit--acp-finish process state callback (cons 'error detail))))

(defun crit-magit--acp-handle-message (process state callback message)
  "Handle one parsed ACP MESSAGE during model discovery."
  (let ((id (crit-magit--json-object-value message "id")))
    (cond
     ((plist-get state :finished) nil)
     ((crit-magit--json-object-value message "method")
      (when id
        (process-send-string
         process
         (concat (json-encode
                  `((jsonrpc . "2.0") (id . ,id)
                    (error . ((code . -32601)
                              (message . "Unsupported client method")))))
                 "\n"))))
     (id
      (if (crit-magit--json-object-value message "error")
          (if (and (eq (plist-get state :phase) 'close-session)
                   (equal id (plist-get state :expected-id))
                   (equal (crit-magit--json-object-value
                           (crit-magit--json-object-value message "error") "code")
                          -32601))
              ;; Closing is optional; the captured model list is already complete.
              (crit-magit--acp-finish
               process state callback (cons 'success (plist-get state :options)))
            (crit-magit--acp-failure
             process state callback
             (or (crit-magit--json-object-value
                  (crit-magit--json-object-value message "error") "message")
                 "DSH ACP request failed")))
        (pcase (plist-get state :phase)
          ('initialize
           (if (not (equal id (plist-get state :expected-id)))
               (crit-magit--acp-failure
                process state callback "Unexpected DSH ACP initialize response")
             (setf (plist-get state :phase) 'new-session
                   (plist-get state :expected-id) 2)
             (condition-case error-data
                 (crit-magit--acp-send
                  process 2 "session/new"
                  `(("cwd" . ,(plist-get state :root))
                    ("mcpServers" . [])))
               (error
                (crit-magit--acp-failure
                 process state callback (error-message-string error-data))))))
          ('new-session
           (if (not (equal id (plist-get state :expected-id)))
               (crit-magit--acp-failure
                process state callback "Unexpected DSH ACP session response")
             (let* ((result (crit-magit--json-object-value message "result"))
                    (session-id (and (listp result)
                                     (crit-magit--json-object-value
                                      result "sessionId")))
                    (options (and (listp result)
                                  (crit-magit--json-object-value
                                   result "configOptions"))))
               (if (not (and (stringp session-id) (listp options)))
                   (crit-magit--acp-failure
                    process state callback
                    "DSH ACP returned no session or model options")
                 (setf (plist-get state :phase) 'close-session
                       (plist-get state :expected-id) 3
                       (plist-get state :session-id) session-id
                       (plist-get state :options) options)
                 (condition-case error-data
                     (crit-magit--acp-send
                      process 3 "session/close"
                      `(("sessionId" . ,session-id)))
                   (error
                    (crit-magit--acp-failure
                     process state callback (error-message-string error-data))))))))
          ('close-session
           (if (not (equal id (plist-get state :expected-id)))
               (crit-magit--acp-failure
                process state callback "Unexpected DSH ACP close response")
             (crit-magit--acp-finish
              process state callback
              (cons 'success (plist-get state :options)))))
          (_ nil)))))))

(defun crit-magit--acp-filter (process state callback chunk)
  "Parse newline-delimited ACP JSON CHUNK for PROCESS."
  (setf (plist-get state :input)
        (concat (plist-get state :input) chunk))
  (let ((input (plist-get state :input))
        (start 0))
    (while (and (not (plist-get state :finished))
                (string-match "\n" input start))
      (let ((line (substring input start (match-beginning 0))))
        (setq start (match-end 0))
        (unless (string-empty-p line)
          (condition-case error-data
              (crit-magit--acp-handle-message
               process state callback
               (json-parse-string line :object-type 'alist :array-type 'list))
            (error
             (crit-magit--acp-failure
              process state callback
              (format "Invalid DSH ACP response: %s"
                      (error-message-string error-data))))))))
    (setf (plist-get state :input) (substring input start))))

(defun crit-magit--acp-sentinel (process state callback _event)
  "Report an ACP PROCESS that exits before discovery completes."
  (when (and (memq (process-status process) '(exit signal))
             (not (plist-get state :finished)))
    (crit-magit--acp-failure
     process state callback
     "DSH ACP server stopped before returning model choices")))

(defun crit-magit--start-acp-model-discovery (root callback)
  "Start ACP model discovery for ROOT and call CALLBACK with its outcome."
  (crit-magit--dsh-assert-command)
  (let* ((stderr-buffer (generate-new-buffer " *crit-magit-acp-stderr*"))
         (state (list :phase 'initialize
                      :expected-id 1
                      :root (expand-file-name root)
                      :input ""
                      :options nil
                      :session-id nil
                      :stderr-buffer stderr-buffer
                      :finished nil :timer nil))
         (default-directory (expand-file-name root)))
    (condition-case error-data
        (let ((process
               (make-process
                :name "crit-magit-acp"
                :buffer nil
                :command (list crit-magit-dsh-command
                               "--profile" crit-magit-dsh-acp-profile)
                :stderr stderr-buffer
                :coding 'utf-8-unix
                :noquery t
                :connection-type 'pipe
                :filter (lambda (proc chunk)
                          (crit-magit--acp-filter proc state callback chunk))
                :sentinel (lambda (proc event)
                            (crit-magit--acp-sentinel
                             proc state callback event)))))
          (crit-magit--set-dsh-process process 'model-discovery)
          (setf (plist-get state :timer)
                (run-at-time crit-magit-dsh-discovery-timeout nil
                             #'crit-magit--acp-failure process state callback
                             "DSH ACP model discovery timed out"))
          (condition-case send-error
              (crit-magit--acp-send
               process 1 "initialize"
               `(("protocolVersion" . 1)
                 ("clientCapabilities" . ,(make-hash-table))))
            (error
             (crit-magit--acp-failure
              process state callback (error-message-string send-error))))
          process)
      (error
       (when (buffer-live-p stderr-buffer) (kill-buffer stderr-buffer))
       (signal (car error-data) (cdr error-data))))))

(defun crit-magit--dsh-model-entry (label)
  "Return (PROVIDER . MODEL) for LABEL in `crit-magit-dsh-models'.
Signal `user-error' when LABEL is unknown."
  (or (cdr (assoc label crit-magit-dsh-models))
      (user-error "Unknown DSH model: %s" label)))

(defun crit-magit--dsh-selection (model)
  "Normalize MODEL to a (PROVIDER . MODEL) pair.
Accept an ACP selection pair or a legacy label from
`crit-magit-dsh-models'."
  (cond
   ((crit-magit--valid-model-selection-p model)
    (cons (car model) (cdr model)))
   ((stringp model) (crit-magit--dsh-model-entry model))
   (t (user-error "Invalid DSH model selection"))))

(defun crit-magit--yaml-string (value)
  "Return VALUE as a single-quoted YAML scalar."
  (concat "'" (replace-regexp-in-string "'" "''" value t t) "'"))

(defun crit-magit--dsh-model-patch-file (provider model)
  "Write an explicit PROVIDER and MODEL override for every selection.
The headless profile default cannot be inferred from a local label or ACP."
  (let ((file (make-temp-file "crit-magit-dsh-" nil ".yml")))
    (condition-case err
        (progn
          (with-temp-file file
            (set-buffer-file-coding-system 'utf-8-unix)
            (insert "- id: agent-default-model\n"
                    "  name: '@deepseek-ai/dsh-agent-default-model'\n"
                    "  config:\n"
                    (format "    provider: %s\n" (crit-magit--yaml-string provider))
                    (format "    model: %s\n" (crit-magit--yaml-string model))))
          file)
      (error (delete-file file) (signal (car err) (cdr err))))))

(defun crit-magit--dsh-argv (prompt model)
  "Return (ARGV . PATCH-FILE) for a DSH one-shot review.
PROMPT is the task text passed as the positional argument.
MODEL is a provider/model pair or a legacy model label.  Every selection
adds `--patch' with a temporary override file.  PATCH-FILE is deleted after
the run."
  (let* ((entry (crit-magit--dsh-selection model))
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
      (if (string-empty-p (string-trim (or stdout "")))
          (cons 'error (concat "DSH exited without a review response.\n" stderr))
        (cons 'success stdout))
    (cons 'error (if (and stderr (not (string-empty-p stderr)))
                     stderr
                   stdout))))

(defun crit-magit--dsh-sentinel (proc callback patch-file
                                      stdout-buffer stderr-buffer)
  "Handle exit of DSH process PROC.
Call CALLBACK with (STATUS . TEXT) from `crit-magit--dsh-outcome',
then clean up the temporary patch file and output buffers."
  (when (and (memq (process-status proc) '(exit signal))
             (not (process-get proc 'crit-magit-finished)))
    (process-put proc 'crit-magit-finished t)
    (unwind-protect
        (let ((exit-status (process-exit-status proc))
              (stdout (if (buffer-live-p stdout-buffer)
                          (with-current-buffer stdout-buffer (buffer-string)) ""))
              (stderr (if (buffer-live-p stderr-buffer)
                          (with-current-buffer stderr-buffer (buffer-string)) "")))
          (crit-magit--clear-dsh-process proc)
          (funcall callback (crit-magit--dsh-outcome
                             exit-status stdout stderr)))
      (when (buffer-live-p stdout-buffer) (kill-buffer stdout-buffer))
      (when (buffer-live-p stderr-buffer) (kill-buffer stderr-buffer))
      (when (and patch-file (file-exists-p patch-file))
        (delete-file patch-file)))))

(defun crit-magit--start-dsh (prompt model root callback)
  "Start a DSH one-shot review process and return it.
PROMPT is the task text, MODEL the selected model, ROOT the
repository root used as working directory, and CALLBACK a function
called with (STATUS . TEXT) when the process exits."
  (when (crit-magit--dsh-running-p)
    (user-error "A DSH review is already running"))
  (crit-magit--dsh-assert-command)
  (let* ((argv-and-patch (crit-magit--dsh-argv prompt model))
         (argv (car argv-and-patch))
         (patch-file (cdr argv-and-patch))
         (stdout-buffer (generate-new-buffer " *crit-magit-dsh-stdout*"))
         (stderr-buffer (generate-new-buffer " *crit-magit-dsh-stderr*"))
         (default-directory (expand-file-name root)))
    (condition-case error-data
        (let ((process
               (make-process
                :name "crit-magit-dsh"
                :buffer stdout-buffer
                :command argv
                :stderr stderr-buffer
                :coding 'utf-8-unix
                :noquery t
                :connection-type 'pipe
                :sentinel (lambda (proc _event)
                            (crit-magit--dsh-sentinel
                             proc callback patch-file
                             stdout-buffer stderr-buffer)))))
          (crit-magit--set-dsh-process process 'review)
          process)
      (error
       (when (buffer-live-p stdout-buffer) (kill-buffer stdout-buffer))
       (when (buffer-live-p stderr-buffer) (kill-buffer stderr-buffer))
       (when (and patch-file (file-exists-p patch-file))
         (delete-file patch-file))
       (signal (car error-data) (cdr error-data))))))

(defun crit-magit-cancel-review ()
  "Cancel active ACP discovery or DSH review and release request resources."
  (interactive)
  (unless (crit-magit--dsh-running-p)
    (user-error "No DSH request is running"))
  (delete-process crit-magit--dsh-process))

;;;; DSH review prompt

(defun crit-magit--review-content-block (content)
  "Return CONTENT intact as review evidence."
  (concat "BEGIN CAPTURED DIFF\n" content "\nEND CAPTURED DIFF\n"))

(defun crit-magit--build-review-prompt (target &optional whole-content)
  "Build a complete review prompt for TARGET or WHOLE-CONTENT.
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
         "The working directory is the repository root.\n"
         "Review only; do not modify files, commit, or push.\n\n"
         (format "File: %s\n" path)
         (format "Location: %s\n" lines)
         (format "Side: %s\n" side)
         (format "Commit: %s\n" commit)
         (format "Base: %s\n\n" base)
         (crit-magit--review-content-block
          (or whole-content (plist-get target :context) ""))))
    (if (and whole-content (not (string-empty-p whole-content)))
        (concat
         "You are reviewing all changes in the current diff. "
         "The working directory is the repository root.\n"
         "Review only; do not modify files, commit, or push.\n\n"
         (crit-magit--review-content-block whole-content))
      (user-error "No review target or diff content"))))

(defun crit-magit--build-session-review-prompt (root session-file &optional content diff)
  "Build a DSH prompt to process unresolved comments in SESSION-FILE.
ROOT is the repository working directory; CONTENT and DIFF are snapshots."
  (format
   (concat
    "You are addressing source-review comments in a Git repository.\n\n"
    "Repository root: %s\n"
    "Session file: %s\n\n"
    "Process every unresolved comment in the captured session below. "
    "For each comment, inspect the current source and diff, make the requested "
    "source changes when appropriate, and do not edit the session file itself. "
    "After applying changes, review the resulting git diff again and run the "
    "relevant tests or checks. Report each comment ID, the action taken, tests "
    "run, and any remaining concern. Do not commit or push changes.\n\n"
    "BEGIN CAPTURED SESSION\n%s\nEND CAPTURED SESSION\n\n%s")
   (expand-file-name root)
   (expand-file-name session-file)
   (or content (crit-magit--read-file session-file))
   (crit-magit--review-content-block
    (or diff (crit-magit--working-tree-diff root)))))

(defun crit-magit--current-session-context (root)
  "Return captured comments for ROOT's selected session, when it exists."
  (when crit-magit-session-id
    (let ((file (crit-magit--session-file root crit-magit-session-id)))
      (when (file-exists-p file)
        (let ((content (crit-magit--read-file file)))
          (unless (crit-magit--session-header-p content crit-magit-session-id)
            (user-error "Invalid session file: %s" file))
          (concat "\nConsider the unresolved comments below in this review.\n"
                  "BEGIN CAPTURED SESSION\n" content "\nEND CAPTURED SESSION\n"))))))

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

(defun crit-magit--show-review-error (format-string &rest args)
  "Display a review error made from FORMAT-STRING and ARGS."
  (let ((message-text (apply #'format format-string args)))
    (display-warning 'crit-magit message-text :warning)
    (crit-magit--show-review (cons 'error message-text))))

(defun crit-magit--request-review (prompt root)
  "Send a complete captured PROMPT to DSH under ROOT.
Use a private UTF-8 request file when command-line transport is too large."
  (when (crit-magit--dsh-running-p)
    (user-error "A DSH review is already running"))
  (let ((file nil))
    (condition-case err
        (progn
          (when (> (string-bytes (encode-coding-string prompt 'utf-8-unix))
                   crit-magit-dsh-inline-size-limit)
            (setq file (make-temp-file "crit-magit-request-" nil ".md"))
            (with-temp-file file
              (set-buffer-file-coding-system 'utf-8-unix)
              (insert prompt))
            (setq prompt
                  (format "Read the complete review request in %s. Follow its instructions and review all captured diff and comments; do not substitute a fresh git diff for the captured evidence."
                          (json-encode-string file))))
          (crit-magit--request-review-dispatch
           prompt root
           (lambda ()
             (when (and file (file-exists-p file)) (delete-file file)))))
      ((error quit)
       (when (and file (file-exists-p file)) (delete-file file))
       (signal (car err) (cdr err))))))

(defun crit-magit--request-review-dispatch (prompt root cleanup)
  "Discover a model, send PROMPT under ROOT, and call CLEANUP when finished."
  (when (crit-magit--dsh-running-p)
    (user-error "A DSH review is already running"))
  (message "crit-magit: discovering models through DSH ACP...")
  (condition-case error-data
      (crit-magit--start-acp-model-discovery
       root
       (lambda (outcome)
         (if (eq (car outcome) 'success)
             (condition-case selection-error
                 (let ((selection
                        (crit-magit--dsh-choose-model (cdr outcome))))
                   (message "crit-magit: requesting review (%s)..."
                            (crit-magit--dsh-selection-label selection))
                   (crit-magit--start-dsh
                    prompt selection root
                    (lambda (result)
                      (unwind-protect (crit-magit--show-review result)
                        (funcall cleanup)))))
               (quit
                (funcall cleanup)
                (message "crit-magit: model selection canceled"))
               (error
                (funcall cleanup)
                (crit-magit--show-review-error
                 "Model selection or review startup failed:\n\n%s"
                 (error-message-string selection-error))))
           (funcall cleanup)
           (crit-magit--show-review-error
            "DSH ACP model discovery failed:\n\n%s"
            (cdr outcome)))))
    (error
     (funcall cleanup)
     (crit-magit--show-review-error
      "DSH ACP model discovery failed:\n\n%s"
      (error-message-string error-data)))))

(defun crit-magit--review-session-file (root session-id session-file)
  "Start a DSH re-review for SESSION-FILE under ROOT.
SESSION-ID is used to validate the session header before dispatch."
  (let ((content (if (file-exists-p session-file)
                     (crit-magit--read-file session-file)
                   (user-error "Session file does not exist: %s" session-file))))
    (unless (crit-magit--session-header-p content session-id)
      (user-error "Session file belongs to another session or is corrupt: %s"
                  session-file))
    (when (zerop (crit-magit--unresolved-comment-count content))
      (user-error "Session has no unresolved comments: %s" session-file))
    (crit-magit--request-review
     (crit-magit--build-session-review-prompt
      root session-file content
      (if (derived-mode-p 'magit-diff-mode)
          (crit-magit--buffer-diff)
        (crit-magit--working-tree-diff root)))
     root)))

(defun crit-magit-review-session ()
  "Send unresolved comments from the current repository session to DSH."
  (interactive)
  (let* ((root (crit-magit--repository-root))
         (session-id (crit-magit--session-id))
         (session-file (crit-magit--session-file root session-id)))
    (crit-magit--review-session-file root session-id session-file)))

(defun crit-magit--comment-target (target)
  "Prompt for and save a comment attached to TARGET.
When `crit-magit-review-after-comment' is non-nil, start a DSH re-review
after the comment has been durably written."
  (let* ((root (plist-get target :repository))
         (path (plist-get target :path))
         (body (read-string (format "Comment on %s: " path)))
         (result (crit-magit--write-comment target body))
         (session-file (plist-get result :file))
         (session-id (plist-get result :session-id)))
    (message
     "crit-magit: comment %s saved for %s; %s unresolved comment%s. AIへ伝達: %s を読んでください。"
     (plist-get result :id)
     path
     (plist-get result :count)
     (if (= (plist-get result :count) 1) "" "s")
     session-file)
    (when crit-magit-review-after-comment
      (if (crit-magit--dsh-running-p)
          (message "crit-magit: comment saved; DSH is busy. Send it later with crit-magit-review-session")
        (crit-magit--review-session-file root session-id session-file)))))

(defun crit-magit-comment ()
  "Attach a review comment to the current diff line or active region.
The comment is stored in the current session and, by default, sent to DSH
for a source-change and re-review pass."
  (interactive)
  (crit-magit--comment-target (crit-magit--extract-diff-target)))

(defun crit-magit-comment-file ()
  "Attach a review comment to the file at point in the current diff."
  (interactive)
  (crit-magit--comment-target (crit-magit--extract-file-target)))

(defun crit-magit-open-session ()
  "Open the current repository's crit-magit session file."
  (interactive)
  (let* ((root (crit-magit--repository-root))
         (session-id (crit-magit--session-id))
         (session-file (crit-magit--session-file root session-id)))
    (unless (file-exists-p session-file)
      (user-error "Session file does not exist: %s" session-file))
    (find-file session-file)))

(defun crit-magit-copy-session-file ()
  "Copy an instruction for the current session to the kill ring."
  (interactive)
  (let* ((root (crit-magit--repository-root))
         (session-id (crit-magit--session-id))
         (session-file (crit-magit--session-file root session-id))
         (text (format
                "AIへ伝達: %s を読んで、未解決コメントに対応してください。"
                session-file)))
    (kill-new text)
    (message "%s" text)))

(defun crit-magit-set-dsh-model (&optional model)
  "Set the DSH review MODEL and remember it.
When called interactively without MODEL, discover choices through ACP.
Programmatic callers may pass a legacy label from `crit-magit-dsh-models'."
  (interactive)
  (if (null model)
      (crit-magit-select-dsh-model)
    (let ((selection (crit-magit--dsh-selection model)))
      (when (stringp model)
        (setq crit-magit-dsh-default-model model))
      (crit-magit--dsh-remember-model selection)
      (message "crit-magit: DSH model set to %s"
               (crit-magit--dsh-selection-label selection)))))

(defun crit-magit-select-dsh-model ()
  "Discover DSH models through ACP and remember an interactive selection."
  (interactive)
  (when (crit-magit--dsh-running-p)
    (user-error "A DSH review is already running"))
  (let ((root (crit-magit--repository-root)))
    (message "crit-magit: discovering models through DSH ACP...")
    (condition-case error-data
        (crit-magit--start-acp-model-discovery
         root
         (lambda (outcome)
           (if (eq (car outcome) 'success)
               (condition-case selection-error
                   (let ((selection
                          (crit-magit--dsh-choose-model (cdr outcome))))
                     (message "crit-magit: DSH model set to %s"
                              (crit-magit--dsh-selection-label selection)))
                 (quit (message "crit-magit: model selection canceled"))
                 (error
                  (display-warning
                   'crit-magit
                   (format "DSH model selection failed: %s"
                           (error-message-string selection-error))
                   :warning)))
             (display-warning
              'crit-magit
              (format "DSH ACP model discovery failed: %s" (cdr outcome))
              :warning))))
      (error
       (display-warning
        'crit-magit
        (format "DSH ACP model discovery failed: %s"
                (error-message-string error-data))
        :warning)))))

(defun crit-magit-review ()
  "Send the current diff target for DSH AI review.
Before sending, discover available models through DSH ACP and prompt for
one.  The last selection is offered first next time."
  (interactive)
  (crit-magit--assert-diff-buffer)
  (let* ((root (crit-magit--repository-root))
         (target (if (and (crit-magit--section 'file)
                          (not (crit-magit--section 'hunk))
                          (not (use-region-p)))
                     (crit-magit--extract-file-target)
                   (crit-magit--extract-diff-target)))
         (prompt (crit-magit--build-review-prompt
                  target (crit-magit--buffer-diff))))
    (crit-magit--request-review prompt root)))

(defun crit-magit-review-whole ()
  "Send the whole current diff for DSH AI review.
In a Magit diff buffer the buffer content is reviewed; in a Magit
status buffer the working-tree diff (staged and unstaged) is
  reviewed.  Before sending, discover available models through DSH ACP and
  prompt for one."
  (interactive)
  (crit-magit--assert-review-buffer)
  (let* ((root (crit-magit--repository-root))
         (content (if (derived-mode-p 'magit-status-mode)
                      (crit-magit--working-tree-diff root)
                    (crit-magit--buffer-diff)))
         (prompt (concat (crit-magit--build-review-prompt nil content)
                         (crit-magit--current-session-context root))))
    (crit-magit--request-review prompt root)))

(provide 'crit-magit)
;;; crit-magit.el ends here
