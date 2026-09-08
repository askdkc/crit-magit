;;; crit-magit-test.el --- Tests for crit-magit -*- lexical-binding: t; -*-

;; Copyright (C) 2026 crit-magit contributors

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

;; ERT tests for crit-magit.  Run the full suite with:
;;
;;     emacs -Q --batch -L . -l crit-magit.el -l crit-magit-test.el \
;;       -f ert-run-tests-batch-and-exit

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'crit-magit)

;;;; Approved-verifier selector compatibility

;; The project's approved per-unit verification commands select tests
;; with the `(:tag SYMBOL)' form (for example `(:tag
;; crit-magit-position)').  Stock ERT only recognizes the standard
;; `(tag SYMBOL)' form, so any such command signals "No clause
;; matching" before running a single test.  Because this file is loaded
;; by those commands before the selector is evaluated, we normalize the
;; exact `(:tag SYMBOL)' shape to `(tag SYMBOL)' here.  This is purely
;; syntactic: every selector stock ERT already accepts passes through
;; unchanged, and `(:tag SYMBOL)' would otherwise always error, so no
;; existing selector can change meaning.
(defun crit-magit-test--normalize-ert-selector (args)
  "Translate `(:tag SYM)' to `(tag SYM)' in `ert-select-tests' ARGS."
  (let ((selector (car args)))
    (if (and (consp selector)
             (eq (car selector) :tag)
             (= (length selector) 2)
             (symbolp (cadr selector)))
        (cons (list 'tag (cadr selector)) (cdr args))
      args)))

(advice-add 'ert-select-tests :filter-args
            #'crit-magit-test--normalize-ert-selector)

(ert-deftest crit-magit-skeleton-customization ()
  "Package skeleton exposes the documented customization variables."
  :tags '(crit-magit-skeleton)
  (should (boundp 'crit-magit-session-id))
  (should (null crit-magit-session-id))
  (should (equal crit-magit-session-directory-name ".critmagit"))
  (should (eq crit-magit-auto-update-gitignore t))
  (should (equal crit-magit-author "user"))
  (should (eq crit-magit-session-file-function
              'crit-magit-default-session-file))
  (should (eq crit-magit-review-after-comment nil))
  (should (equal crit-magit-progress-buffer-name "*crit-magit-progress*")))

;;;; Position extraction tests

(defmacro crit-magit-test-with-diff-buffer (contents &rest body)
  "Evaluate BODY in a temp buffer with CONTENTS and `magit-diff-mode'."
  (declare (indent 1))
  `(with-temp-buffer
     (insert ,contents)
     (setq major-mode 'magit-diff-mode)
     (goto-char (point-min))
     ,@body))

(defun crit-magit-test-set-region (beg end)
  "Set an active region from BEG to END."
  (setq transient-mark-mode t)
  (goto-char beg)
  (set-mark end)
  (activate-mark))

;; Emulate Magit diff buffer-local variables for tests so that the
;; `let' bindings below are dynamic (special) rather than lexical.
(defvar magit-diff-range nil
  "Mock of `magit-diff-range' used only in tests.")
(defvar magit-buffer-diff-range nil
  "Mock of `magit-buffer-diff-range' used only in tests.")

(ert-deftest crit-magit-position-parse-hunk-header ()
  "Parse unified diff hunk headers into old/new start lines."
  :tags '(crit-magit-position)
  (should (equal (crit-magit--parse-hunk-header "@@ -10,3 +20,4 @@")
                 (list 10 20)))
  (should (equal (crit-magit--parse-hunk-header "@@ -1 +1 @@")
                 (list 1 1)))
  (should (null (crit-magit--parse-hunk-header "not a header"))))

(ert-deftest crit-magit-position-commit-and-base ()
  "Split diff ranges into commit and base references."
  :tags '(crit-magit-position)
  (should (equal (crit-magit--commit-and-base "main..HEAD")
                 (cons "HEAD" "main")))
  (should (equal (crit-magit--commit-and-base "main...HEAD")
                 (cons "HEAD" "main")))
  (should (equal (crit-magit--commit-and-base "HEAD")
                 (cons "HEAD" "unknown")))
  (should (equal (crit-magit--commit-and-base nil)
                 (cons "unknown" "unknown"))))

(ert-deftest crit-magit-position-normalize-path ()
  "Normalize file paths relative to the repository root."
  :tags '(crit-magit-position)
  (let ((root "/tmp/repo"))
    (should (equal (crit-magit--normalize-path "src/auth.el" root)
                   "src/auth.el"))
    (should (equal (crit-magit--normalize-path "/tmp/repo/src/auth.el" root)
                   "src/auth.el"))
    (should (equal (crit-magit--normalize-path "path with spaces/file.el" root)
                   "path with spaces/file.el"))
    (should-error (crit-magit--normalize-path "../outside.el" root)
                  :type 'user-error)
    (should-error (crit-magit--normalize-path "/tmp/other/file.el" root)
                  :type 'user-error)))

(ert-deftest crit-magit-position-hunk-line-info ()
  "Compute side and line number for a point inside a hunk."
  :tags '(crit-magit-position)
  (crit-magit-test-with-diff-buffer
      "@@ -10,3 +20,4 @@
 context line
+added line
-removed line
 another context
"
    (forward-line 1) ; first content line (context)
    (let ((content-start (point)))
      (should (equal (crit-magit--hunk-line-info content-start 10 20)
                     (cons 'context 20)))
      (forward-line 1) ; added line
      (should (equal (crit-magit--hunk-line-info content-start 10 20)
                     (cons 'added 21)))
      (forward-line 1) ; removed line
      (should (equal (crit-magit--hunk-line-info content-start 10 20)
                     (cons 'removed 11)))
      (forward-line 1) ; another context
      (should (equal (crit-magit--hunk-line-info content-start 10 20)
                     (cons 'context 22))))))

(ert-deftest crit-magit-position-region-line-range ()
  "Compute line range for a region of added lines."
  :tags '(crit-magit-position)
  (crit-magit-test-with-diff-buffer
      "@@ -10,3 +20,4 @@
 context line
+added line 1
+added line 2
 another context
"
    (forward-line 1) ; first content line (context)
    (let ((content-start (point)))
      (forward-line 1) ; +added line 1
      (let ((beg (point)))
        (forward-line 2) ; after +added line 2 (line start)
        (let ((end (point)))
          (should (equal (crit-magit--region-line-range
                          content-start 10 20 'added beg end)
                         (cons 21 22))))))))

(ert-deftest crit-magit-position-extract-diff-target-current-line ()
  "Extract a target for the current line in a diff buffer."
  :tags '(crit-magit-position)
  (let ((repo (make-temp-file "crit-magit-repo-" t)))
    (make-directory (expand-file-name ".git" repo))
    (unwind-protect
        (crit-magit-test-with-diff-buffer
            (format "diff --git a/src/auth.el b/src/auth.el
--- a/src/auth.el
+++ b/src/auth.el
@@ -10,3 +20,4 @@
 context line
+added line
-removed line
 another context
")
          (let ((default-directory repo)
                (magit-diff-range "main..HEAD"))
            (search-forward "+added line")
            (beginning-of-line)
            (let ((target (crit-magit--extract-diff-target)))
              (should (equal (plist-get target :path) "src/auth.el"))
              (should (equal (plist-get target :start-line) 21))
              (should (equal (plist-get target :end-line) 21))
              (should (eq (plist-get target :side) 'added))
              (should (string= (plist-get target :commit) "HEAD"))
              (should (string= (plist-get target :base) "main"))
              (should (string= (plist-get target :context) "added line")))))
      (delete-directory repo t))))

(ert-deftest crit-magit-position-extract-diff-target-region ()
  "Extract a target for a multi-line region."
  :tags '(crit-magit-position)
  (let ((repo (make-temp-file "crit-magit-repo-" t)))
    (make-directory (expand-file-name ".git" repo))
    (unwind-protect
        (crit-magit-test-with-diff-buffer
            (format "diff --git a/src/auth.el b/src/auth.el
--- a/src/auth.el
+++ b/src/auth.el
@@ -10,3 +20,4 @@
 context line
+added line 1
+added line 2
 another context
")
          (let ((default-directory repo)
                (magit-diff-range "main..HEAD"))
            (search-forward "+added line 1")
            (beginning-of-line)
            (let ((beg (point)))
              (search-forward "+added line 2")
              (end-of-line)
              (crit-magit-test-set-region beg (point))
              (let ((target (crit-magit--extract-diff-target)))
                (should (equal (plist-get target :start-line) 21))
                (should (equal (plist-get target :end-line) 22))
                (should (eq (plist-get target :side) 'added))))))
      (delete-directory repo t))))

(ert-deftest crit-magit-position-extract-diff-target-removed-line ()
  "Extract a target for a removed line."
  :tags '(crit-magit-position)
  (let ((repo (make-temp-file "crit-magit-repo-" t)))
    (make-directory (expand-file-name ".git" repo))
    (unwind-protect
        (crit-magit-test-with-diff-buffer
            (format "diff --git a/src/auth.el b/src/auth.el
--- a/src/auth.el
+++ b/src/auth.el
@@ -10,3 +20,4 @@
 context line
+added line
-removed line
 another context
")
          (let ((default-directory repo)
                (magit-diff-range "main..HEAD"))
            (search-forward "-removed line")
            (beginning-of-line)
            (let ((target (crit-magit--extract-diff-target)))
              (should (eq (plist-get target :side) 'removed))
              (should (equal (plist-get target :start-line) 11))
              (should (equal (plist-get target :end-line) 11)))))
      (delete-directory repo t))))

(ert-deftest crit-magit-position-extract-file-target ()
  "Extract a whole-file target without line numbers."
  :tags '(crit-magit-position)
  (let ((repo (make-temp-file "crit-magit-repo-" t)))
    (make-directory (expand-file-name ".git" repo))
    (unwind-protect
        (crit-magit-test-with-diff-buffer
            (format "diff --git a/src/auth.el b/src/auth.el
--- a/src/auth.el
+++ b/src/auth.el
@@ -10,3 +20,4 @@
 context line
+added line
")
          (let ((default-directory repo)
                (magit-diff-range "main..HEAD"))
            (search-forward "context line")
            (let ((target (crit-magit--extract-file-target)))
              (should (equal (plist-get target :path) "src/auth.el"))
              (should (eq (plist-get target :side) 'file))
              (should (null (plist-get target :start-line)))
              (should (null (plist-get target :end-line))))))
      (delete-directory repo t))))

(ert-deftest crit-magit-position-assert-diff-buffer ()
  "Signal an error outside a Magit diff buffer."
  :tags '(crit-magit-position)
  (with-temp-buffer
    (should-error (crit-magit--assert-diff-buffer) :type 'user-error)))

(ert-deftest crit-magit-position-repository-root-failure ()
  "Signal an error when the repository root cannot be determined."
  :tags '(crit-magit-position)
  (let ((tmp (make-temp-file "crit-magit-nogit-" t)))
    (unwind-protect
        (let ((default-directory tmp))
          (should-error (crit-magit--repository-root) :type 'user-error))
      (delete-directory tmp t))))

;;;; DSH transport tests

(ert-deftest crit-magit-dsh-model-entry ()
  "Resolve DSH model labels to provider/model pairs."
  :tags '(crit-magit-dsh-transport)
  (should (equal (crit-magit--dsh-model-entry "DeepSeek-V4-Flash")
                 (cons "deepseek-official" "deepseek-v4-flash")))
  (should (equal (crit-magit--dsh-model-entry "DeepSeek-V4-Pro")
                 (cons "deepseek-official" "deepseek-v4-pro")))
  (should-error (crit-magit--dsh-model-entry "Not-A-Model")
                :type 'user-error))

(ert-deftest crit-magit-dsh-model-patch-default ()
  "Even a locally default label must override a different DSH profile default."
  :tags '(crit-magit-dsh-transport)
  (let ((file (crit-magit--dsh-model-patch-file
               "deepseek-official" "deepseek-v4-flash")))
    (unwind-protect
        (should (string-match-p "model: 'deepseek-v4-flash'"
                                (crit-magit--read-file file)))
      (delete-file file))))

(ert-deftest crit-magit-dsh-model-patch-nondefault ()
  "Non-default model writes a patch overriding agent-default-model."
  :tags '(crit-magit-dsh-transport)
  (let ((file (crit-magit--dsh-model-patch-file
               "deepseek-official" "deepseek-v4-pro")))
    (unwind-protect
        (progn
          (should (and file (file-exists-p file)))
          (let ((content (with-temp-buffer
                           (insert-file-contents file)
                           (buffer-string))))
            (should (string-match-p "id: agent-default-model" content))
            (should (string-match-p
                     "@deepseek-ai/dsh-agent-default-model" content))
             (should (string-match-p "provider: 'deepseek-official'" content))
             (should (string-match-p "model: 'deepseek-v4-pro'" content))))
      (when (and file (file-exists-p file))
        (delete-file file)))))

(ert-deftest crit-magit-dsh-argv-default ()
  "Default model is passed explicitly using --patch."
  :tags '(crit-magit-dsh-transport)
  (let* ((pair (crit-magit--dsh-argv "review me" "DeepSeek-V4-Flash"))
         (argv (car pair))
         (patch (cdr pair)))
    (unwind-protect
        (progn
          (should patch)
          (should (equal argv
                         (list "dsh" "--profile" "headless"
                               "--patch" patch "review me"))))
      (when (and patch (file-exists-p patch))
        (delete-file patch)))))

(ert-deftest crit-magit-dsh-argv-nondefault ()
  "Non-default model adds --patch with a temp file before the prompt."
  :tags '(crit-magit-dsh-transport)
  (let* ((pair (crit-magit--dsh-argv "review me" "DeepSeek-V4-Pro"))
         (argv (car pair))
         (patch (cdr pair)))
    (unwind-protect
        (progn
          (should patch)
          (should (file-exists-p patch))
          (should (equal (nth 0 argv) "dsh"))
          (should (equal (nth 1 argv) "--profile"))
          (should (equal (nth 2 argv) "headless"))
          (should (equal (nth 3 argv) "--patch"))
          (should (equal (nth 4 argv) patch))
          (should (equal (car (last argv)) "review me")))
      (when (and patch (file-exists-p patch))
        (delete-file patch)))))

(ert-deftest crit-magit-dsh-outcome-success ()
  "Exit 0 maps stdout to a success result."
  :tags '(crit-magit-dsh-transport)
  (should (equal (crit-magit--dsh-outcome 0 "answer" "")
                 (cons 'success "answer"))))

(ert-deftest crit-magit-dsh-outcome-error ()
  "Non-zero exit maps stderr to an error result."
  :tags '(crit-magit-dsh-transport)
  (should (equal (crit-magit--dsh-outcome 1 "" "boom")
                 (cons 'error "boom"))))

;;;; DSH prompt tests

(ert-deftest crit-magit-dsh-prompt-target ()
  "Build a prompt from a review target plist."
  :tags '(crit-magit-dsh-prompt)
  (let ((target '(:path "src/auth.el"
                  :start-line 21 :end-line 22 :side added
                  :commit "HEAD" :base "main"
                  :context "added line")))
    (let ((prompt (crit-magit--build-review-prompt target)))
      (should (stringp prompt))
      (should (not (string-empty-p prompt)))
      (should (string-match-p "review only" prompt))
      (should (string-match-p "must not change" prompt))
      (should (string-match-p "REVIEW comment" prompt))
      (should (string-match-p "File: src/auth.el" prompt))
      (should (string-match-p "lines 21-22" prompt))
      (should (string-match-p "Side: added" prompt))
      (should (string-match-p "Commit: HEAD" prompt))
      (should (string-match-p "Base: main" prompt))
      (should (string-match-p "added line" prompt)))))

(ert-deftest crit-magit-dsh-prompt-target-single-line ()
  "A single-line target renders as \"line N\"."
  :tags '(crit-magit-dsh-prompt)
  (let ((target '(:path "src/auth.el"
                  :start-line 21 :end-line 21 :side removed
                  :commit "HEAD" :base "unknown"
                  :context "removed")))
    (let ((prompt (crit-magit--build-review-prompt target)))
      (should (string-match-p "Location: line 21" prompt)))))

(ert-deftest crit-magit-dsh-prompt-whole ()
  "A whole-buffer prompt embeds the diff content."
  :tags '(crit-magit-dsh-prompt)
  (let ((prompt (crit-magit--build-review-prompt nil "diff --git a/x b/x\n")))
    (should (string-match-p "diff --git a/x b/x" prompt))))

(ert-deftest crit-magit-dsh-prompt-oversize ()
  "Oversized content remains intact for the request-file transport."
  :tags '(crit-magit-dsh-prompt)
  (let ((crit-magit-dsh-inline-size-limit 10))
    (let ((prompt (crit-magit--build-review-prompt
                   nil "this is a long diff that exceeds the limit")))
      (should (string-match-p "this is a long diff that exceeds the limit" prompt))
      (should-not (string-match-p "run `git diff'" prompt)))))

(ert-deftest crit-magit-dsh-prompt-empty ()
  "No target and empty content signal an error."
  :tags '(crit-magit-dsh-prompt)
  (should-error (crit-magit--build-review-prompt nil "")
                :type 'user-error)
  (should-error (crit-magit--build-review-prompt nil nil)
                :type 'user-error))

;;;; DSH command tests

(ert-deftest crit-magit-dsh-command-buffer-name ()
  "The review buffer name defcustom defaults correctly."
  :tags '(crit-magit-dsh-command)
  (should (equal crit-magit-dsh-review-buffer-name "*crit-magit-review*")))

(ert-deftest crit-magit-dsh-command-missing ()
  "A missing DSH executable signals an actionable user error."
  :tags '(crit-magit-dsh-command)
  (let ((crit-magit-dsh-command "/definitely/missing/crit-magit-dsh"))
    (should-error
     (crit-magit--start-dsh "review me" "DeepSeek-V4-Flash"
                             default-directory #'ignore)
     :type 'user-error)))

(ert-deftest crit-magit-dsh-command-set-model ()
  "Setting a known model updates the default; unknown models error."
  :tags '(crit-magit-dsh-command)
  (let ((crit-magit-dsh-default-model "DeepSeek-V4-Flash")
        (crit-magit-dsh-selected-model nil)
        (crit-magit--dsh-model-loaded nil)
        (crit-magit-dsh-model-history-file
         (make-temp-file "crit-magit-model-test-")))
    (unwind-protect
        (progn
          (crit-magit-set-dsh-model "DeepSeek-V4-Pro")
          (should (equal crit-magit-dsh-default-model "DeepSeek-V4-Pro"))
          (should (equal crit-magit-dsh-selected-model
                         '("deepseek-official" . "deepseek-v4-pro")))
          (should-error (crit-magit-set-dsh-model "Not-A-Model")
                        :type 'user-error))
      (when (file-exists-p crit-magit-dsh-model-history-file)
        (delete-file crit-magit-dsh-model-history-file)))))

(ert-deftest crit-magit-dsh-acp-model-options ()
  "Parse grouped ACP model choices and the current selection."
  :tags '(crit-magit-dsh-transport)
  (let* ((options
          (json-parse-string
           "[{\"id\":\"model\",\"currentValue\":\"[\\\"deepseek-official\\\",\\\"deepseek-v4-flash\\\"]\",\"options\":[{\"group\":\"deepseek-official\",\"options\":[{\"name\":\"Flash\",\"value\":\"[\\\"deepseek-official\\\",\\\"deepseek-v4-flash\\\"]\"},{\"name\":\"Pro\",\"value\":\"[\\\"deepseek-official\\\",\\\"deepseek-v4-pro\\\"]\"}]}]}]"
           :object-type 'alist :array-type 'list))
         (choices (crit-magit--dsh-model-options options)))
     (should (equal choices
                    '(("deepseek-official / Flash"
                       . ("deepseek-official" . "deepseek-v4-flash"))
                      ("deepseek-official / Pro"
                       . ("deepseek-official" . "deepseek-v4-pro")))))
    (should (equal (crit-magit--dsh-model-current-selection options)
                   '("deepseek-official" . "deepseek-v4-flash")))))

(ert-deftest crit-magit-dsh-remembered-model-load ()
  "Persist and reload the selected ACP model."
  :tags '(crit-magit-dsh-transport)
  (let ((history (make-temp-file "crit-magit-model-test-"))
        (crit-magit-dsh-selected-model nil)
        (crit-magit--dsh-model-loaded nil)
        (crit-magit-dsh-model-history-file nil))
    (unwind-protect
        (progn
          (setq crit-magit-dsh-model-history-file history)
          (crit-magit--dsh-remember-model
           '("provider" . "model"))
          (setq crit-magit-dsh-selected-model nil
                crit-magit--dsh-model-loaded nil)
          (crit-magit--dsh-load-selected-model)
          (should (equal crit-magit-dsh-selected-model
                         '("provider" . "model"))))
      (when (file-exists-p history)
        (delete-file history)))))

(ert-deftest crit-magit-dsh-remembered-model-is-default ()
  "Offer the persisted ACP model as the next completion default."
  :tags '(crit-magit-dsh-transport)
  (let ((history (make-temp-file "crit-magit-model-test-"))
        (crit-magit-dsh-selected-model nil)
        (crit-magit--dsh-model-loaded nil)
        (crit-magit-dsh-model-history-file nil)
        (initial nil))
    (unwind-protect
        (progn
          (setq crit-magit-dsh-model-history-file history)
          (crit-magit--dsh-remember-model '("provider" . "model"))
          (setq crit-magit-dsh-selected-model nil
                crit-magit--dsh-model-loaded nil)
          (let ((options
                 (json-parse-string
                  "[{\"id\":\"model\",\"currentValue\":\"[\\\"provider\\\",\\\"model\\\"]\",\"options\":[{\"name\":\"Model\",\"value\":\"[\\\"provider\\\",\\\"model\\\"]\"}]}]"
                  :object-type 'alist :array-type 'list)))
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (_prompt _collection _predicate _require-match
                                default)
                         (setq initial default)
                         default))
                      )
              (should (equal (crit-magit--dsh-choose-model options)
                             '("provider" . "model")))))
          (should (equal initial "provider / Model")))
      (when (file-exists-p history)
        (delete-file history)))))

(ert-deftest crit-magit-dsh-review-uses-acp ()
  "Every review uses ACP with the full prompt, including long input."
  (let ((crit-magit--dsh-process nil) captured)
    (cl-letf (((symbol-function 'crit-magit--start-acp-model-discovery)
               (lambda (root callback &optional prompt _on-prompt)
                 (setq captured (list root callback prompt))))
              ((symbol-function 'crit-magit--start-dsh)
               (lambda (&rest _) (ert-fail "Must not start headless"))))
      (crit-magit--request-review "review prompt" "/tmp/repo")
      (should (equal (car captured) "/tmp/repo"))
      (should (functionp (cadr captured)))
      (should (equal (caddr captured) "review prompt")))))

(ert-deftest crit-magit-dsh-command-show-review-success ()
  "A success outcome inserts the answer into the review buffer."
  :tags '(crit-magit-dsh-command)
  (crit-magit--show-review (cons 'success "answer text"))
  (should (get-buffer crit-magit-dsh-review-buffer-name))
  (with-current-buffer crit-magit-dsh-review-buffer-name
    (should (string-match-p "answer text" (buffer-string))))
  (kill-buffer crit-magit-dsh-review-buffer-name))

(ert-deftest crit-magit-dsh-command-show-review-error ()
  "An error outcome marks the review as failed."
  :tags '(crit-magit-dsh-command)
  (crit-magit--show-review (cons 'error "boom"))
  (with-current-buffer crit-magit-dsh-review-buffer-name
    (should (string-match-p "DSH review failed" (buffer-string)))
    (should (string-match-p "boom" (buffer-string))))
  (kill-buffer crit-magit-dsh-review-buffer-name))

(ert-deftest crit-magit-dsh-command-not-diff-buffer ()
  "Reviewing outside a Magit diff buffer signals user-error."
  :tags '(crit-magit-dsh-command)
  (with-temp-buffer
    (should-error (crit-magit-review) :type 'user-error)
    (should-error (crit-magit-review-whole) :type 'user-error)))

;;;; Status buffer support tests

(ert-deftest crit-magit-status-assert-review-buffer ()
  "The review-buffer predicate accepts diff and status modes."
  :tags '(crit-magit-status)
  (with-temp-buffer
    (setq major-mode 'magit-diff-mode)
    (should (crit-magit--assert-review-buffer)))
  (with-temp-buffer
    (setq major-mode 'magit-status-mode)
    (should (crit-magit--assert-review-buffer)))
  (with-temp-buffer
    (should-error (crit-magit--assert-review-buffer) :type 'user-error)))

(ert-deftest crit-magit-status-working-tree-diff ()
  "Return the staged+unstaged diff in a repository."
  :tags '(crit-magit-status)
  (let ((repo (make-temp-file "crit-magit-git-" t)))
    (unwind-protect
        (let ((default-directory repo))
          (call-process "git" nil nil nil "init" "-q")
          (call-process "git" nil nil nil "config" "user.email" "t@t")
          (call-process "git" nil nil nil "config" "user.name" "t")
          (with-temp-file (expand-file-name "a.txt" repo)
            (insert "hello\n"))
          (call-process "git" nil nil nil "add" "a.txt")
          (call-process "git" nil nil nil "commit" "-q" "-m" "init")
          (with-temp-file (expand-file-name "a.txt" repo)
            (insert "hello world\n"))
          (let ((diff (crit-magit--working-tree-diff repo)))
            (should (stringp diff))
            (should (string-match-p "hello world" diff))))
      (delete-directory repo t))))

(ert-deftest crit-magit-status-target-in-status ()
  "Line-target review signals an error in a status buffer."
  :tags '(crit-magit-status)
  (with-temp-buffer
    (setq major-mode 'magit-status-mode)
    (should-error (crit-magit-review) :type 'user-error)))

;;;; Session comment tests

(ert-deftest crit-magit-session-default-file-safe ()
  "Build a session path below the repository and reject traversal."
  :tags '(crit-magit-session)
  (let ((root (make-temp-file "crit-magit-session-root-" t)))
    (unwind-protect
        (progn
          (should (equal
                   (crit-magit-default-session-file root "review-1")
                   (expand-file-name ".critmagit/review-1.md" root)))
          (dolist (invalid '("../outside" "a/b" "a\\b" "." ""))
            (should-error (crit-magit-default-session-file root invalid)
                          :type 'user-error)))
      (delete-directory root t))))

(ert-deftest crit-magit-session-write-comment ()
  "Write two comments with stable anchors and one ignored session directory."
  :tags '(crit-magit-session)
  (let* ((root (make-temp-file "crit-magit-session-root-" t))
         (crit-magit-session-id "review-1")
         (crit-magit-author "tester")
         (crit-magit-review-after-comment nil)
         (target (list :repository root
                       :path "src/auth.el"
                       :start-line 21
                       :end-line 22
                       :side 'added
                       :commit "HEAD"
                       :base "main"
                       :context "added line")))
    (unwind-protect
        (let* ((first (crit-magit--write-comment target "Fix this\ncarefully"))
               (second (crit-magit--write-comment target "Re-check the branch"))
               (file (plist-get first :file))
               (content (crit-magit--read-file file))
               (gitignore (crit-magit--read-file
                           (expand-file-name ".gitignore" root))))
          (should (file-exists-p file))
          (should (equal (plist-get first :count) 1))
          (should (equal (plist-get second :count) 2))
          (should (string-match-p "# crit-magit session: review-1" content))
          (should (string-match-p "- path: `src/auth.el`" content))
          (should (string-match-p "- lines: 21-22" content))
          (should (string-match-p "- side: added" content))
          (should (string-match-p "- author: tester" content))
          (should (string-match-p (concat "> Fix this" "\n> carefully")
                                  content))
          (should (string-match-p "Re-check the branch" content))
          (should (equal gitignore ".critmagit/\n")))
      (delete-directory root t))))

(ert-deftest crit-magit-session-rejects-corrupt-file ()
  "Do not append to a session file with a mismatched header."
  :tags '(crit-magit-session)
  (let* ((root (make-temp-file "crit-magit-session-root-" t))
         (crit-magit-session-id "review-1")
         (crit-magit-review-after-comment nil)
         (target (list :repository root :path "a.el"
                       :start-line 1 :end-line 1 :side 'added
                       :commit "HEAD" :base "unknown" :context "a")))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".critmagit" root))
          (with-temp-file (expand-file-name ".critmagit/review-1.md" root)
            (insert "# another session\n"))
          (should-error (crit-magit--write-comment target "do not append")
                        :type 'user-error))
      (delete-directory root t))))

(ert-deftest crit-magit-progress-log-appends-timestamped-lines ()
  "Progress log appends to the progress buffer and scrolls its window."
  :tags '(crit-magit-progress)
  (let ((crit-magit-progress-buffer-name " *crit-magit-progress-test*"))
    (unwind-protect
        (progn
          (crit-magit--progress-log "first %s" "event")
          (crit-magit--progress-log "second event")
          (with-current-buffer (get-buffer crit-magit-progress-buffer-name)
            (should (string-match-p "\\[..:..:..\\] first event\n" (buffer-string)))
            (should (string-match-p "\\[..:..:..\\] second event\n" (buffer-string)))
            (should (= (point) (point-max)))))
      (when (get-buffer crit-magit-progress-buffer-name)
        (kill-buffer crit-magit-progress-buffer-name)))))

(ert-deftest crit-magit-progress-open-resets-buffer ()
  "Opening the progress buffer resets and displays it as special-mode."
  :tags '(crit-magit-progress)
  (let ((crit-magit-progress-buffer-name " *crit-magit-progress-test*"))
    (unwind-protect
        (progn
          (crit-magit--progress-open)
          (with-current-buffer crit-magit-progress-buffer-name
            (should (derived-mode-p 'special-mode))
            (should (string-match-p "crit-magit DSH progress" (buffer-string))))
          (crit-magit--progress-log "running")
          (with-current-buffer crit-magit-progress-buffer-name
            (should (string-match-p "running" (buffer-string)))))
      (when (get-buffer crit-magit-progress-buffer-name)
        (kill-buffer crit-magit-progress-buffer-name)))))

(ert-deftest crit-magit-dsh-stdout-filter-streams-chunks ()
  "DSH stdout chunks stream into the progress and stdout buffers."
  :tags '(crit-magit-progress)
  (let ((crit-magit-progress-buffer-name " *crit-magit-progress-test*")
        (stdout (generate-new-buffer " *crit-magit-dsh-stdout-test*")))
    (unwind-protect
        (progn
          (crit-magit--dsh-stdout-filter nil "part1\r\npart2\n" stdout)
          (with-current-buffer stdout
            (should (equal (buffer-string) "part1\r\npart2\n")))
          (with-current-buffer crit-magit-progress-buffer-name
            (should (string-match-p "part1" (buffer-string)))
            (should (string-match-p "part2" (buffer-string)))))
      (when (get-buffer crit-magit-progress-buffer-name)
        (kill-buffer crit-magit-progress-buffer-name))
      (when (buffer-live-p stdout) (kill-buffer stdout)))))

(ert-deftest crit-magit-send-session-sends-unresolved-comments ()
  "The confirm command requires a review buffer and dispatches the session."
  :tags '(crit-magit-session)
  (let ((sent nil)
        (file (make-temp-file "crit-magit-send-session-" )))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "# crit-magit session: s\n- status: unresolved\n"))
          (with-temp-buffer
            (setq major-mode 'magit-diff-mode)
            (cl-letf (((symbol-function 'crit-magit--repository-root)
                       (lambda () (file-name-directory file)))
                      ((symbol-function 'crit-magit--session-id) (lambda () "s"))
                      ((symbol-function 'crit-magit--session-file)
                       (lambda (_root _id) file))
                      ((symbol-function 'crit-magit--request-review)
                       (lambda (prompt _root) (setq sent prompt))))
              (crit-magit-send-session)
              (should sent)
              (should (string-match-p "review only" sent))))
          (with-temp-buffer
            (should-error (crit-magit-send-session) :type 'user-error)))
      (when (file-exists-p file) (delete-file file)))))

(ert-deftest crit-magit-comment-no-auto-review-by-default ()
  "Saving a comment never dispatches DSH when review-after-comment is nil."
  :tags '(crit-magit-session)
  (let* ((repo (make-temp-file "crit-magit-accumulate-" t))
         (crit-magit-session-id "accumulate")
         (crit-magit-review-after-comment nil))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "keep local"))
                    ((symbol-function 'crit-magit--review-session-file)
                     (lambda (&rest _) (ert-fail "Must not dispatch by default"))))
            (crit-magit--comment-target (list :repository repo :path "a" :side 'file)))
          (should (string-match-p "keep local"
                                  (crit-magit--read-file
                                   (crit-magit--session-file repo "accumulate")))))
      (delete-directory repo t))))

(ert-deftest crit-magit-session-review-prompt ()
  "Tell DSH where the session is and require review-only REVIEW comments."
  :tags '(crit-magit-session)
  (let ((prompt (crit-magit--build-session-review-prompt
                 "/tmp/repo" "/tmp/repo/.critmagit/review.md"
                 "- status: unresolved\n> comment" "+captured diff")))
    (should (string-match-p "Repository root: /tmp/repo" prompt))
    (should (string-match-p "Session file: /tmp/repo/.critmagit/review.md"
                            prompt))
    (should (string-match-p "review only" prompt))
    (should (string-match-p "must not change" prompt))
    (should (string-match-p "Do not apply any source changes" prompt))
    (should (string-match-p "Do not commit or push" prompt))))

(provide 'crit-magit-test)
;;; crit-magit-test.el ends here
