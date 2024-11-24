;;; khulnasoft.el --- khulnasoft client for emacs         -*- lexical-binding: t; -*-

;; MIT License

;; Copyright (c) 2023 KhulnaSoft

;; Permission is hereby granted, free of charge, to any person obtaining a copy
;; of this software and associated documentation files (the "Software"), to deal
;; in the Software without restriction, including without limitation the rights
;; to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
;; copies of the Software, and to permit persons to whom the Software is
;; furnished to do so, subject to the following conditions:

;; The above copyright notice and this permission notice shall be included in all
;; copies or substantial portions of the Software.

;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
;; IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
;; FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
;; AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
;; LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
;; SOFTWARE.

;;; Commentary:

;; use M-x `khulnasoft-install' to install binaries automatically
;; add `khulnasoft-completion-at-point' to your `completion-at-point-functions'
;; use `khulnasoft-diagnose' to see currently enabled apis and fields

;; anything defined by `khulnasoft-def' a constant or a function that
;; takes 1, 2, or 3 arguments, which are (api state val)
;; api is a symbol such as 'GetCompletions, state is of type `khulnasoft-state'
;; which keeps all the state (including a process, port, and some hash tables)
;; val is only relevant if the field is only sensible given a previous
;; value, such as `khulnasoft/request_id' used in `'CancelRequest'

;; use M-x `customize' see a full list of settings.

;;; Code:

(defvar khulnasoft-latest-local-server-version "1.12.0")

;; (require 'url-parse)
(autoload 'url-parse-make-urlobj "url-parse")

(eval-when-compile
    (require 'url-vars)
    (defvar url-http-end-of-headers)
    (defvar url-http-response-status))

(defgroup khulnasoft nil
    "khulnasoft.el customization -some-doc-str-here-"
    :group 'convenience)
(defvar khulnasoft-log-waiting-text (propertize "waiting for response" 'face '(:weight ultra-bold)))

(defvar khulnasoft-fullpath-alist nil)

(eval-and-compile
    (defun khulnasoft-default-func-name (symbol-name)
        (if (string-prefix-p "khulnasoft" symbol-name)
            (concat "khulnasoft-default" (substring symbol-name (length "khulnasoft")))
            (error "invalid name"))))

(eval-and-compile
    (defun khulnasoft-def-handle-args (args)
        (let ((doc-str nil) (value nil) (arglist nil) (body nil))
            (ignore doc-str value arglist body)
            (pcase-let*
                (
                    (
                        (or
                            `(,value)
                            `(,value ,(and (pred stringp) doc-str))
                            `(,arglist ,(and (pred stringp) doc-str) . ,body)
                            `(,arglist . ,body))
                        args))
                (list doc-str value arglist body)))))

(defmacro khulnasoft-def (name &rest args)
    (declare (doc-string 3))
    (pcase-let*
        (
            (`(,doc-str ,value ,arglist ,body) (khulnasoft-def-handle-args args))
            (funcsymbol (when body (intern (khulnasoft-default-func-name (symbol-name name)))))
            (value (or value `',funcsymbol))

            (fullpath
                (when (string-prefix-p "khulnasoft/" (symbol-name name))
                    (mapcar #'intern (cdr (split-string (symbol-name name) "/")))))
            (funcdefform (when body `((defun ,funcsymbol ,arglist ,@body))))

            (doc-str (or doc-str ""))
            )
        `(progn
             (setf (alist-get ',name khulnasoft-fullpath-alist) ',fullpath)
             (defcustom ,name ,value
                 ;; i can probably process the doc-str
                 ,doc-str
                 :type 'sexp
                 :group 'khulnasoft)
             ,@funcdefform)))

(khulnasoft-def khulnasoft-delay 0.100)

(khulnasoft-def khulnasoft-directory (_api state) (khulnasoft-state-manager-directory state))
(khulnasoft-def khulnasoft-port (_api state) (khulnasoft-state-port state))

(defun khulnasoft-get-language-server-string ()
    (let ((arch
              (unless (eq system-type 'windows-nt)
                  (if (string= (string-trim (shell-command-to-string "uname -m")) "x86_64")
                      "x64" "arm"))))
        (pcase system-type
            ('windows-nt "language_server_windows_x64.exe")
            ('gnu/linux (concat "language_server_linux_" arch))
            ('darwin (concat "language_server_macos_" arch))
            (_ (error "unable to automatically determine your system, or your system is not supported yet. Please file an issue on github.")))))

(khulnasoft-def khulnasoft-local-server-version khulnasoft-latest-local-server-version)

(khulnasoft-def khulnasoft-download-url
    (condition-case err;; don't signal error on loading
        (concat "https://github.com/KhulnaSoft/khulnasoft/releases/download/language-server-v"
            khulnasoft-local-server-version "/" (khulnasoft-get-language-server-string) ".gz")
        (error
            (defvar khulnasoft-download-url (lambda () (signal (car err) (cdr err))))
            nil)))

(defconst khulnasoft-apis
    '(GetCompletions Heartbeat CancelRequest GetAuthToken RegisterUser auth-redirect AcceptCompletion))

(khulnasoft-def khulnasoft-api-enabled () t)

(khulnasoft-def khulnasoft-fields-regexps
    `(
         (GetCompletions .
             ,(rx bol "khulnasoft/" (or "metadata" "document" "editor_options") "/" (* anychar) eol))
         (Heartbeat .
             ,(rx bol "khulnasoft/metadata/" (* anychar) eol))
         (CancelRequest .
             ,(rx bol "khulnasoft/" (or (seq "metadata/" (* anychar)) "request_id")  eol))
         (GetAuthToken)
         (RegisterUser .
             ,(rx bol "khulnasoft/firebase_id_token" eol))
         (AcceptCompletion .
             ,(rx bol "khulnasoft/" (or (seq "metadata/" (* anychar)) "completion_id")  eol))
         ))
(khulnasoft-def khulnasoft-api-fields (api)
    (let ((regexp (alist-get api khulnasoft-fields-regexps)))
        (if (stringp regexp)
            (remq nil
                (mapcar
                    (lambda (el)
                        (when (string-match regexp (symbol-name (car el)))
                            (car el)))
                    khulnasoft-fullpath-alist))
            nil)))

(defvar khulnasoft-special-url-alist '((auth-redirect . "/auth")))
(khulnasoft-def khulnasoft-url (api state)
    (let ((endpoint
              (or (alist-get api khulnasoft-special-url-alist)
                  (concat "/exa.language_server_pb.LanguageServerService/" (symbol-name api)))))
        (url-parse-make-urlobj "http" nil nil "127.0.0.1" (khulnasoft-state-port state)
            endpoint nil nil t)))


(khulnasoft-def khulnasoft/metadata/ide_name "emacs")
(khulnasoft-def khulnasoft/metadata/extension_version khulnasoft-local-server-version)
(khulnasoft-def khulnasoft/metadata/ide_version emacs-version)
;; (khulnasoft-def khulnasoft/metadata/request_id (api)
;; 	(when (eq api 'GetCompletions)
;; 		(random most-positive-fixnum)))

(defvar khulnasoft-global-requestid-counter 0)
(khulnasoft-def khulnasoft/metadata/request_id (api)
    (when (eq api 'GetCompletions)
        (cl-incf khulnasoft-global-requestid-counter)))

;; for CancelRequest
(khulnasoft-def khulnasoft/request_id (_api _state val) val)

;; for AcceptCompletion
(khulnasoft-def khulnasoft/completion_id (_api _state val) val)

(defun khulnasoft-get-saved-api-key ()
  "Retrieve the saved API key for khulnasoft.com from auth-source."
  ;; Ensure the auth-source library is loaded
  (require 'auth-source)
  (auth-source-pick-first-password :host "khulnasoft.com" :user "apikey"))

(khulnasoft-def khulnasoft/metadata/api_key (_api state)
    (if-let ((api-key (or (khulnasoft-state-last-api-key state) (khulnasoft-get-saved-api-key))))
        (setq khulnasoft/metadata/api_key api-key)
        (setq khulnasoft/metadata/api_key
            (lambda (_api state)
                (when-let ((api-key (khulnasoft-state-last-api-key state)))
                    (setq khulnasoft/metadata/api_key api-key))))
        nil))


(khulnasoft-def khulnasoft/document/text ()
    (buffer-string))
(khulnasoft-def khulnasoft/document/cursor_offset ()
    (khulnasoft-utf8-byte-length (buffer-substring-no-properties (point-min) (point))))

(khulnasoft-def khulnasoft/document/editor_language () (symbol-name major-mode))

(defvar khulnasoft-language-alist
    '(
         (nil . 0)
         (c-mode . 1)
         (c-ts-mode . 1)
         (clojure-mode . 2)
         (clojurec-mode . 2)
         (clojurescript-mode . 2)
         (coffee-mode . 3)
         (cc-mode . 4)
         (c++-mode . 4)
         (c++-ts-mode . 4)
         (csharp-mode . 5)
         (csharp-tree-sitter-mode . 5)
         (csharp-ts-mode . 5)
         (css-mode . 6)
         (css-ts-mode . 6)
         (cuda-mode . 7)
         (dockerfile-mode . 8)
         (dockerfile-ts-mode . 8)
         (go-dot-mod-mode . 9)
         (go-mod-ts-mode . 9)
         (go-mode . 9)
         (go-ts-mode . 9)
         (groovy-mode . 10)
         (haskell-mode . 12)
         (terraform-mode . 13)
         (html-mode . 14)
         (sgml-mode . 14)
         (mhtml-mode . 14)
         (java-mode . 16)
         (java-ts-mode . 16)
         (jdee-mode . 16)
         (ecmascript-mode . 17)
         (javascript-mode . 17)
         (js-mode . 17)
         (js2-mode . 17)
         (js-ts-mode . 17)
         (rjsx-mode . 17)
         (json-mode . 18)
         (json-ts-mode . 18)
         (julia-mode . 19)
         (ess-julia-mode . 19)
         (kotlin-mode . 20)
         (kotlin-ts-mode . 20)
         (latex-mode . 21)
         (less-mode . 22)
         (less-css-mode . 22)
         (lua-mode . 23)
         (lsp--render-markdown . 25)
         (markdown-mode . 25)
         (gfm-mode . 25)
         (objc-mode . 26)
         (perl-mode . 28)
         (cperl-mode . 28)
         (php-mode . 29)
         (php-ts-mode . 29)
         (text-mode . 30)
         (python-mode . 33)
         (python-ts-mode . 33)
         (cython-mode . 33)
         (ess-r-mode . 34)
         (ruby-mode . 35)
         (enh-ruby-mode . 35)
         (ruby-ts-mode . 35)
         (rust-mode . 36)
         (rust-ts-mode . 36)
         (rustic-mode . 36)
         (sass-mode . 37)
         (ssass-mode . 37)
         (scala-mode . 38)
         (scss-mode . 39)
         (sh-mode . 40)
         (ebuild-mode . 40)
         (pkgbuild-mode . 40)
         (sql-mode . 41)
         (swift-mode . 43)
         (tsx-mode . 44)
         (tsx-ts-mode . 44)
         (ts-mode . 45)
         (typescript-mode . 45)
         (typescript-ts-mode . 45)
         (nxml-mode . 48)
         (xml-mode . 48)
         (yaml-mode . 50)
         (yaml-ts-mode . 50)
         (conf-toml-mode . 52)
         (toml-ts-mode . 52)
         (dart-mode . 53)
         (caml-mode . 55)
         (tuareg-mode . 55)
         (cmake-mode . 56)
         (cmake-ts-mode . 56)
         (pascal-mode . 57)
         (elixir-mode . 58)
         (elixir-ts-mode . 58)
         (heex-ts-mode . 58)
         (fsharp-mode . 59)
         (lisp-data-mode . 60)))

(khulnasoft-def khulnasoft/document/language ()
    (let ((mode major-mode))
        (while (not (alist-get mode khulnasoft-language-alist))
            (setq mode (get mode 'derived-mode-parent)))
        (alist-get mode khulnasoft-language-alist)))

(khulnasoft-def khulnasoft/document/line_ending "\n"
    "according to https://www.reddit.com/r/emacs/comments/5b7o9r/elisp_how_to_concat_newline_into_string_regarding/
    this can be always \\n")

(khulnasoft-def khulnasoft/document/absolute_path_migrate_me_to_uri ()
    (or buffer-file-name (expand-file-name (buffer-name))))

(khulnasoft-def khulnasoft/editor_options/tab_size ()
    tab-width)
(khulnasoft-def khulnasoft/editor_options/insert_spaces ()
    (if indent-tabs-mode :false t))

(khulnasoft-def khulnasoft/firebase_id_token (_api state) (khulnasoft-state-last-auth-token state))

;;;###autoload
(cl-defstruct
    (khulnasoft-state
        (:constructor khulnasoft-state-make)
        (:copier nil))
    (name "")
    (config nil
        :documentation "state-wise config, access it with `khulnasoft-config'")
    (proc nil
        :documentation "created on a `khulnasoft-init', not created if one specifies `khulnasoft-port'")
    (manager-directory nil
        :documentation "directory which khulnasoft local language server places temp files; created by `khulnasoft-default-command'")
    (port nil
        :documentation "port used by khulnasoft local language server; by default a random port is used.
If you set `khulnasoft-port', it will be used instead and no process will be created")
    (port-ready-hook nil
        :documentation "hook called when the server is ready; use `khulnasoft-on-port-ready' to add to it")

    (alive-tracker nil
        :documentation "a symbol, set to nil on a khulnasoft-reset which ensures that requests on timers made before the request are dropped")

    last-auth-token
    last-api-key

    (last-request-id 0)

    ;; hash tables for khulnasoft-request-synchronously
    ;; these has distinct elements
    (results-table (make-hash-table :test 'eql :weakness nil)) ; results that are ready
    (pending-table (make-hash-table :test 'eql :weakness nil)) ; requestid that we are waiting for
    )

(khulnasoft-def khulnasoft-command-executable
    (expand-file-name
        (pcase system-type
            ('windows-nt "khulnasoft_language_server.exe")
            (_ "khulnasoft_language_server"))
        (expand-file-name "khulnasoft" user-emacs-directory)))

(khulnasoft-def khulnasoft-enterprise nil)
(khulnasoft-def khulnasoft-portal-url "https://www.khulnasoft.com")
(khulnasoft-def khulnasoft-api-url "https://server.khulnasoft.com")
(khulnasoft-def khulnasoft-register-user-url ()
             (if khulnasoft-enterprise
                 (concat khulnasoft-api-url "/exa.seat_management_pb.SeatManagementService/RegisterUser")
               "https://api.khulnasoft.com/register_user/"))

(khulnasoft-def khulnasoft-command (api state)
    (unless (khulnasoft-state-manager-directory state)
        (setf (khulnasoft-state-manager-directory state) (make-temp-file "khulnasoft_" t)))
    `(,(khulnasoft-get-config 'khulnasoft-command-executable api state)
         "--api_server_url" ,(khulnasoft-get-config 'khulnasoft-api-url api state)
         "--manager_dir" ,(khulnasoft-state-manager-directory state)
         "--register_user_url" ,(khulnasoft-get-config 'khulnasoft-register-user-url api state)
         ,@(if (khulnasoft-get-config 'khulnasoft-enterprise api state) '("--enterprise_mode"))
         "--portal_url" ,(khulnasoft-get-config 'khulnasoft-portal-url api state)))

(defvar khulnasoft-state (khulnasoft-state-make :name "default"))

;;;###autoload
(defun khulnasoft-config (field &optional state)
    (setq state (or state khulnasoft-state))
    (if (eq (alist-get field (khulnasoft-state-config state) 'noexist) 'noexist)
        (symbol-value field)
        (alist-get field (khulnasoft-state-config state))))
(defun khulnasoft--set-config (val field &optional state)
    (setq state (or state khulnasoft-state))
    (setf (alist-get field (khulnasoft-state-config state)) val))

;;;###autoload
(gv-define-setter khulnasoft-config (val field &optional state)
    `(khulnasoft--set-config ,val ,field ,state))


(defun khulnasoft-get-config (field api state &optional given-val)
    (let ((val (khulnasoft-config field state)))
        (if (functionp val)
            (cl-case (cdr (func-arity val))
                (0 (funcall val))
                (1 (funcall val api))
                (2 (funcall val api state))
                (t (funcall val api state given-val)))
            val)))

(defun khulnasoft-nested-alist-get-multi (body top &rest rest)
    (if rest
        (apply #'khulnasoft-nested-alist-get-multi (alist-get top body) rest)
        (alist-get top body)))
(defun khulnasoft-nested-alist-set-multi (body val top &rest rest)
    (let ((cur-alist body))
        (setf (alist-get top cur-alist)
            (if rest
                (apply #'khulnasoft-nested-alist-set-multi (alist-get top cur-alist) val rest)
                val))
        cur-alist))
(defun khulnasoft-nested-alist-get (body field)
    (let ((fullpath (alist-get field khulnasoft-fullpath-alist)))
        (unless fullpath (error "field %s is set to path %s which is not valid" field fullpath))
        (apply #'khulnasoft-nested-alist-get-multi body fullpath)))
(defun khulnasoft--nested-alist-set (body field val)
    (let ((fullpath (alist-get field khulnasoft-fullpath-alist)))
        (unless fullpath (error "field %s is set to path %s which is not valid" field fullpath))
        (apply #'khulnasoft-nested-alist-set-multi body val fullpath)))
(gv-define-expander khulnasoft-nested-alist-get
    (lambda (do body field)
        (gv-letplace (getter setter) body
            (macroexp-let2 nil field field
                (funcall do `(khulnasoft-nested-alist-get ,getter ,field)
                    (lambda (v)
                        (macroexp-let2 nil v v
                            `(progn
                                 ,(funcall setter`(khulnasoft--nested-alist-set ,getter ,field ,v))
                                 ,v))))))))


(defun khulnasoft-compute-configs (api state vals-alist)
    (let (ans)
        (mapc
            (lambda (field)
                (setf (alist-get field ans) (khulnasoft-get-config field api state (alist-get field vals-alist))))
            (khulnasoft-get-config 'khulnasoft-api-fields api state))
        ans))

(defun khulnasoft-diagnose (&optional state)
    (interactive)
    (setq state (or state khulnasoft-state))
    (with-output-to-temp-buffer "*khulnasoft-diagnose*"

        (with-current-buffer standard-output
            (insert "khulnasoft state: ")
            (insert (propertize (khulnasoft-state-name state) 'face '(:weight ultra-bold)))
            (terpri)
            (insert "command: ")
            (let ((command
                      (if (khulnasoft-state-proc state)
                          (process-command (khulnasoft-state-proc state))
                          (insert "[will be]")
                          (khulnasoft-get-config 'khulnasoft-command nil state))))
                (terpri)
                (insert
                    (propertize (mapconcat #'shell-quote-argument command " ")
                        'face '(:weight ultra-bold)))
                (terpri)))
        (terpri)
        (mapc
            (lambda (api)
                (if (not (khulnasoft-get-config 'khulnasoft-api-enabled api state))
                    (progn
                        (with-current-buffer standard-output
                            (insert (propertize (symbol-name api) 'face '(:weight ultra-bold :strike-through t))))
                        (terpri)
                        (terpri))
                    (with-current-buffer standard-output
                        (insert (propertize (symbol-name api) 'face '(:weight ultra-bold))))
                    (terpri)
                    (princ (url-recreate-url (khulnasoft-get-config 'khulnasoft-url api state)))
                    (terpri)
                    (mapc
                        (lambda (item)
                            ;; help-insert-xref-button
                            (with-current-buffer standard-output
                                (help-insert-xref-button (symbol-name (car item)) 'help-variable-def (car item))
                                (insert (propertize "\t" 'display '(space :align-to 40))))
                            (let*
                                (
                                    (print-escape-newlines t) (print-length 100)
                                    (obj (cdr item))
                                    (obj (if (stringp obj)
                                             (substring-no-properties obj 0 (length obj)) obj)))
                                (cl-prin1 obj))
                            (terpri))
                        (khulnasoft-compute-configs api state nil))
                    (terpri)))
            khulnasoft-apis)))


(defun khulnasoft-make-body-for-api (api state vals-alist)
    (let (body tmp)
        (mapc
            (lambda (field)
                (setq tmp (khulnasoft-get-config field api state (alist-get field vals-alist)))
                (when tmp
                    (setf (khulnasoft-nested-alist-get body field) tmp)))
            (khulnasoft-get-config 'khulnasoft-api-fields api state))
        body))

(khulnasoft-def khulnasoft-log-buffer ()
    (let ((buf (get-buffer "*khulnasoft-log*")))
        (if buf buf
            (setq buf (generate-new-buffer "*khulnasoft-log*"))
            (with-current-buffer buf
                (special-mode)
                (buffer-disable-undo))
            buf)))

(khulnasoft-def khulnasoft-mode-line-enable nil)
(khulnasoft-def khulnasoft-mode-line-keep-time 3)


;; https://nullprogram.com/blog/2010/05/11/
;; ID: 90aebf38-b33a-314b-1198-c9bffea2f2a2
(defun khulnasoft-uuid-create ()
    "Return a newly generated UUID. This uses a simple hashing of variable data."
    (let ((s (md5 (format "%s%s%s%s%s%s%s%s%s%s"
                      (user-uid)
                      (emacs-pid)
                      (system-name)
                      (user-full-name)
                      user-mail-address
                      (current-time)
                      (emacs-uptime)
                      (garbage-collect)
                      (random)
                      (recent-keys)))))
        (format "%s-%s-3%s-%s-%s"
            (substring s 0 8)
            (substring s 8 12)
            (substring s 13 16)
            (substring s 16 20)
            (substring s 20 32))))

(defvar khulnasoft-last-auth-url nil)

(defun khulnasoft-make-auth-url (state &optional uuid manual)
    (let*
        (
            (uuid (or uuid (khulnasoft-uuid-create)))
            (query-params
                (url-build-query-string
                    `(
                         ("response_type" "token")
                         ("state" ,uuid)
                         ("scope" "openid profile email")
                         ("redirect_uri"
                          ,(if (eq manual 'manual) "vim-show-auth-token"
                            (url-recreate-url (khulnasoft-get-config 'khulnasoft-url 'auth-redirect state))))
                         ("redirect_parameters_type" "query"))))
            (url
             (concat (khulnasoft-get-config 'khulnasoft-portal-url 'auth-redirect state) "/profile?" query-params)))
        (setq khulnasoft-last-auth-url url)))

(defun khulnasoft-kill-last-auth-url ()
    (interactive)
    (when khulnasoft-last-auth-url
        (message "%s sent to kill-ring" khulnasoft-last-auth-url)
        (kill-new khulnasoft-last-auth-url)))

(defun khulnasoft-defer-until-no-input (state tracker func &optional args)
    (when (eq tracker (khulnasoft-state-alive-tracker state))
        (if (input-pending-p)
            (run-with-idle-timer 0.005 nil #'khulnasoft-defer-until-no-input state tracker func args)
            (with-local-quit
                (apply func args)))))
(defun khulnasoft-run-with-timer (state secs func &rest args)
    (unless (khulnasoft-state-alive-tracker state)
        (error "khulnasoft-state is not alive! %s" state))
    (unless (numberp secs)
        (if (eq secs 'default)
            (setq secs (khulnasoft-get-config 'khulnasoft-delay nil state))))
    (run-with-timer secs nil #'khulnasoft-defer-until-no-input
        state (khulnasoft-state-alive-tracker state) func args))
;; (defun khulnasoft-run-with-timer-with-tracker (state tracker secs func &rest args)
;; 	(when (eq tracker (khulnasoft-state-alive-tracker state))
;; 		(apply #'khulnasoft-run-with-timer state secs func args)))

(defun khulnasoft-time-from (start-time)
    (float-time (time-subtract (current-time) start-time)))



;;;###autoload
(defun khulnasoft-install (&optional state noconfirm)
    (interactive)
    (setq state (or state khulnasoft-state))
    (when (khulnasoft-state-alive-tracker state)
        (unless (yes-or-no-p "khulnasoft is already running! are you sure to khulnasoft-install? ") (user-error "aborted")))
    (setf (khulnasoft-state-alive-tracker state)
        (gensym (khulnasoft-state-name khulnasoft-state)))
    (let*
        (
            (filename (khulnasoft-get-config 'khulnasoft-command-executable nil state))
            (url (khulnasoft-get-config 'khulnasoft-download-url nil state)))
        (when (file-exists-p filename)
            (unless (yes-or-no-p (format "%s already exists; overwrite? " filename)) (user-error "aborted")))
        (unless
            (or noconfirm
                (yes-or-no-p
                    (format "you are about to download %s to %s. Proceed? " url filename)))
            (user-error "aborted"))
        (let ((log-callback (khulnasoft-log-request state url)))
            (url-retrieve url
                (lambda (status)
                    (when log-callback
                        (funcall log-callback
                            (let ((inhibit-read-only t) (print-escape-newlines t))
                                (format " status: %s"
                                    (prin1-to-string
                                        (or
                                            (if url-http-response-status
                                                url-http-response-status status)
                                            "no status available"))))))
                    (if (and url-http-response-status (<= 200 url-http-response-status) (<= url-http-response-status 299))
                        (let ((url-buf (current-buffer)))
                            (khulnasoft-run-with-timer state 'default
                                (lambda ()
                                    (khulnasoft-install-process-url-res state url url-buf filename))))
                        (message "khulnasoft cannot fetch local language server: %s %s"
                            status url-http-response-status)))
                nil 'silent 'inhibit-cookies))))

(defun khulnasoft-install-process-url-res (state url url-buf filename)
    (make-directory (file-name-directory filename) t)
    (with-temp-file filename
        (set-buffer-multibyte nil)
        (url-insert-buffer-contents url-buf url)
        (unless (zlib-decompress-region (point-min) (point-max))
            (user-error "zlib is unable to decompress")))
    (chmod filename #o744)
    (kill-buffer url-buf)
    (message "successfully installed khulnasoft local language server")
    (khulnasoft-background-process-start state))


(defun khulnasoft-request-callback (status state tracker callback log-callback)
    (let ((buf (current-buffer)))
        (when (eq tracker (khulnasoft-state-alive-tracker state))
            (khulnasoft-run-with-timer state 'default
                (lambda ()
                    (when (buffer-live-p buf)
                        (with-current-buffer buf
                            (khulnasoft-request-callback-process-res
                                status callback log-callback))))))))
;; should be local to the url retrieve buffer
(defvar-local khulnasoft-kill-url-retrieve-buffer t)
(defun khulnasoft-request-callback-process-res (status callback log-callback)
    (when log-callback
        (let*
            ((print-escape-newlines t)
                (status-str
                    (format " status: %s"
                        (prin1-to-string
                            (or
                                (if url-http-response-status
                                    url-http-response-status status)
                                "no status available")))))
            (funcall log-callback status-str
                (if (and url-http-response-status (= url-http-response-status 200))
                    "" status-str))))
    (funcall callback
        (let ((parsed 'error))
            (when url-http-end-of-headers
                (goto-char url-http-end-of-headers)
                (ignore-error json-parse-error
                    (setq parsed (json-parse-buffer :object-type 'alist))))
            (when khulnasoft-kill-url-retrieve-buffer
                (kill-buffer))
            (when (and parsed (not (eq parsed 'error)) log-callback)
                (funcall log-callback
                    (let* ((print-escape-newlines t))
                        (format " %s"
                            (prin1-to-string
                                (if (listp parsed)
                                    (or
                                        (alist-get 'state parsed)
                                        (alist-get 'message parsed)
                                        parsed)
                                    parsed))))
                    (when-let
                        ((message-str
                             (and (listp parsed)
                                 (or
                                     (alist-get 'message (alist-get 'state parsed))
                                     (alist-get 'message parsed)))))
                        (when (stringp message-str)
                            (concat " " message-str)))))
            parsed)))

(defun khulnasoft-log-request (state str &optional mode-line-str mode-line-ttl)
    "print str on its own line in *khulnasoft-log*, returns a callback function
that can add to that line."
    (let ((modeline-callback (when mode-line-str (khulnasoft-log-mode-line state mode-line-str mode-line-ttl))))
        (when-let ((buf (khulnasoft-get-config 'khulnasoft-log-buffer nil state)))
            (with-current-buffer buf
                (let ((inhibit-read-only t)
                         time-beg-marker time-end-marker insert-marker
                         (start-time (current-time)))
                    (save-excursion
                        (goto-char (point-max))
                        (beginning-of-line)
                        (insert-before-markers "\n")
                        (goto-char (1- (point)))
                        (insert str)
                        (insert " ")
                        (setq time-beg-marker (point-marker))
                        (insert khulnasoft-log-waiting-text)
                        (setq time-end-marker (point-marker))
                        (set-marker-insertion-type time-end-marker t)
                        (setq insert-marker (point-marker))
                        (set-marker-insertion-type insert-marker t)
                        (lambda (newstr &optional newstr-modeline modeline-append)
                            (when (and newstr-modeline modeline-callback)
                                (funcall modeline-callback newstr-modeline modeline-append))
                            (when (buffer-live-p buf)
                                (with-current-buffer buf
                                    (let ((inhibit-read-only t))
                                        (cl--set-buffer-substring time-beg-marker time-end-marker
                                            (format "%.2f secs" (khulnasoft-time-from start-time)))
                                        (set-marker-insertion-type time-end-marker nil)
                                        (cl--set-buffer-substring insert-marker insert-marker
                                            newstr)
                                        (set-marker-insertion-type time-end-marker t)))))))))))

(defvar-local khulnasoft-mode-line nil)
;; requirement for modeline
(put 'khulnasoft-mode-line 'risky-local-variable t)


;; run user code in timers, for efficiency and infinite loop guard
(defvar-local khulnasoft-modeline-refresh-scheduled nil)
(defun khulnasoft-schedule-refresh-modeline-currentbuffer ()
    (unless khulnasoft-modeline-refresh-scheduled
        (run-with-timer 0.005 nil #'khulnasoft-refresh-modeline (current-buffer))
        (setq khulnasoft-modeline-refresh-scheduled t)))
(defun khulnasoft-refresh-modeline (buffer)
    (if (input-pending-p)
        (run-with-idle-timer 0.005 nil #'khulnasoft-refresh-modeline buffer)
        (when (buffer-live-p buffer)
            (with-current-buffer buffer
                (unwind-protect
                    (force-mode-line-update)
                    (setq khulnasoft-modeline-refresh-scheduled nil))))))

(defun khulnasoft-remove-modeline-segment (segment buffer)
    (when (buffer-live-p buffer)
        (with-current-buffer buffer
            (setq khulnasoft-mode-line (delq segment khulnasoft-mode-line))
            (khulnasoft-schedule-refresh-modeline-currentbuffer))))

(defun khulnasoft-log-mode-line (_state str ttl)
    (let*
        (
            (segment `("[" nil (-30 ,str) "]"))
            (buffer (current-buffer))
            (start-time (current-time))
            (timer (run-with-timer ttl nil #'khulnasoft-remove-modeline-segment segment buffer)))
        (push segment khulnasoft-mode-line)
        (khulnasoft-schedule-refresh-modeline-currentbuffer)
        (lambda (newstr &optional append)
            (cancel-timer timer)
            (when (buffer-live-p buffer)
                (with-current-buffer buffer
                    (unless (memq segment khulnasoft-mode-line) (push segment khulnasoft-mode-line))
                    (setq timer (run-with-timer ttl nil #'khulnasoft-remove-modeline-segment segment buffer))
                    (setf (nth 1 segment)
                        (format "%.2fs" (khulnasoft-time-from start-time)))
                    (setf (nth 1 (nth 2 segment))
                        (if append
                            (concat (nth 1 (nth 2 segment)) newstr)
                            newstr))
                    (khulnasoft-schedule-refresh-modeline-currentbuffer))))))

(defun khulnasoft-request-with-body (api state body tracker callback)
    (when (eq tracker (khulnasoft-state-alive-tracker state))
        (if (khulnasoft-get-config 'khulnasoft-port nil state)
            (let*
                (
                    (url (khulnasoft-get-config 'khulnasoft-url api state))
                    (url-request-method "POST")
                    (url-request-extra-headers `(("Content-Type" . "application/json")))
                    (url-request-data (encode-coding-string (json-serialize body) 'utf-8))
                    (log-callback
                        (khulnasoft-log-request state (url-recreate-url url)
                            (when (khulnasoft-get-config 'khulnasoft-mode-line-enable api state)
                                (symbol-name api))
                            (khulnasoft-get-config 'khulnasoft-mode-line-keep-time api state))))
                (when-let
                    (
                        (url-buf
                            (url-retrieve url #'khulnasoft-request-callback
                                (list state (khulnasoft-state-alive-tracker state) callback log-callback)
                                'silent 'inhibit-cookies))
                        (url-proc (get-buffer-process url-buf)))
                    (set-process-query-on-exit-flag url-proc nil)))
            (khulnasoft-on-port-ready state (lambda () (khulnasoft-request-with-body api state body tracker callback))))))

(defun khulnasoft-request (api state vals-alist callback)
    "make an async request to api, calls callback when done.
callback is called with a single argument, the return of
(json-parse-buffer :object-type \\='alist)

returns the body as returned by khulnasoft-make-body-for-api
If `khulnasoft-api-enabled' returns nil, does nothing.

"
    (unless (khulnasoft-state-alive-tracker state)
        (error "khulnasoft-state is not alive! %s" state))
    (when (khulnasoft-get-config 'khulnasoft-api-enabled api state)
        (let ((body (khulnasoft-make-body-for-api api state vals-alist)))
            (khulnasoft-request-with-body api state body (khulnasoft-state-alive-tracker state) callback)
            body)))


(defun khulnasoft-background-process-schedule (state)
    (khulnasoft-run-with-timer state 'default #'khulnasoft-background-process-start state))

(defun khulnasoft-create-process (state)
    (let (buf (executable (car (khulnasoft-get-config 'khulnasoft-command nil state))))
        (unless (executable-find executable)
            (if (and (file-name-absolute-p executable) (not (file-exists-p executable)))
                (user-error "%s does not exist. use M-x khulnasoft-install to install one"
                    executable)
                (user-error "%s is not a valid executable. use M-x khulnasoft-install to install one"
                    executable)))
        (setq buf (khulnasoft-get-config 'khulnasoft-log-buffer nil state))
        (setf (khulnasoft-state-proc state)
            (make-process
                :name "khulnasoft"
                :connection-type 'pipe
                :buffer buf
                :coding 'no-conversion
                :command (khulnasoft-get-config 'khulnasoft-command nil state)
                :noquery t))))

(defun khulnasoft-background-process-start (state)
    ;; entrypoint
    ;; since user calls start, cancel previous stuff
    (unless (khulnasoft-state-alive-tracker state)
        (error "khulnasoft-state is not alive! %s" state))
    (cond
        (;; we created the process but that is now dead for some reason
            (and (khulnasoft-state-proc state)
                (not (process-live-p (khulnasoft-state-proc state))))
            (khulnasoft-reset state))
        ((and
             (not (khulnasoft-get-config 'khulnasoft-port nil state))
             (not (khulnasoft-get-config 'khulnasoft-directory nil state))
             (not (khulnasoft-state-proc state)))
            (setf (khulnasoft-state-port state) nil)
            (when-let ((dir (khulnasoft-state-manager-directory state)))
                (delete-directory dir t)
                (setf (khulnasoft-state-manager-directory state) nil))
            (khulnasoft-create-process state)
            (khulnasoft-background-process-schedule state))
        ((not (khulnasoft-get-config 'khulnasoft-port nil state))
            (unless (khulnasoft-get-config 'khulnasoft-directory nil state)
                (error "no manager directory defined"))
            (let ((files
                      (directory-files (khulnasoft-get-config 'khulnasoft-directory nil state)
                          nil (rx bol (* num) eol))))
                (when files
                    (setf (khulnasoft-state-port state) (string-to-number (car files)))
                    (mapc (lambda (func) (khulnasoft-run-with-timer state 'default func))
                        (khulnasoft-state-port-ready-hook state)))
                (khulnasoft-background-process-schedule state)))
        ((and
             (not (khulnasoft-state-last-auth-token state))
             (not (khulnasoft-state-last-api-key state))
             (not (khulnasoft-get-config 'khulnasoft/metadata/api_key 'GetCompletions state)))
            (let* ((login-method (car (read-multiple-choice
                                    "No Khulnasoft API key found. Authenticate manually or automatically via a browser: "
                                    `((manual "manual")
                                      (auto "auto"))
                                    nil nil t)))
                (authurl (khulnasoft-make-auth-url khulnasoft-state nil login-method)))
            (if (eq login-method 'auto)
                (progn
                    (browse-url authurl)
                    (khulnasoft-request 'GetAuthToken state nil
                                    (lambda (res)
                                    (if-let ((token (and (listp res) (alist-get 'authToken res))))
                                        (setf (khulnasoft-state-last-auth-token state) token)
                                        (error "Cannot get auth_token from res"))
                                    (khulnasoft-background-process-schedule state)))
                    (message "you can also use M-x khulnasoft-kill-last-auth-url to copy the khulnasoft login url"))
                (kill-new authurl)
                (setf (khulnasoft-state-last-auth-token state)
                    (read-string (format "%s has been copied to clipboard.\nAfter you login, paste the token here:\n" authurl)))
                (khulnasoft-background-process-schedule state))))

        ((and
             (not (khulnasoft-state-last-api-key state))
             (not (khulnasoft-get-config 'khulnasoft/metadata/api_key 'GetCompletions state)))
            (khulnasoft-request 'RegisterUser state nil
                (lambda (res)
                    (if-let ((key (and (listp res) (alist-get 'api_key res))))
                        (progn
                            (when (y-or-n-p "save khulnasoft/metadata/api_key using customize?")
                                (customize-save-variable 'khulnasoft/metadata/api_key key))
                            (setf (khulnasoft-state-last-api-key state) key))
                        (error "cannot get api_key from res"))
                    (khulnasoft-background-process-schedule state))))

        (t
            (khulnasoft-request 'Heartbeat state nil
                (lambda (_res)
                    (khulnasoft-run-with-timer state 5 #'khulnasoft-background-process-start state))))))

(defun khulnasoft-reset (&optional state)
    (interactive)
    (setq state (or state khulnasoft-state))
    (setf (khulnasoft-state-alive-tracker state) nil)
    (when-let ((proc (khulnasoft-state-proc state)))
        (delete-process proc)
        (setf (khulnasoft-state-proc state) nil))
    (when-let ((dir (khulnasoft-state-manager-directory state)))
        (delete-directory dir t)
        (setf (khulnasoft-state-manager-directory state) nil))
    (setf (khulnasoft-state-port state) nil)
    (setf (khulnasoft-state-port-ready-hook state) nil)
    (setf (khulnasoft-state-last-api-key state) nil)
    (setf (khulnasoft-state-last-auth-token state) nil)
    (setf (khulnasoft-state-results-table state) (make-hash-table :test 'eql :weakness nil))
    (setf (khulnasoft-state-pending-table state) (make-hash-table :test 'eql :weakness nil)))


(defun khulnasoft-on-port-ready (state callback)
    (if (khulnasoft-state-port state)
        (funcall callback)
        (push callback (khulnasoft-state-port-ready-hook state))))

(defun khulnasoft-request-cancelrequest (state requestid)
    (khulnasoft-request 'CancelRequest state
        `((khulnasoft/request_id . ,requestid))
        #'ignore))

(defun khulnasoft-request-synchronously (api state vals-alist)
    "sends request to khulnasoft, return (reqbody . resbody) or nil
if user input is encountered, schedule a `CancelRequest' and return nil

this uses `sit-for', which means that timers can be ran while this function
waits, but these function called by timers must exit before this function
returns. Prefer using `khulnasoft-request' directly instead.
"
    (when (not (input-pending-p))
        (let*
            (
                (tracker (khulnasoft-state-alive-tracker state))
                (requestid (cl-incf (khulnasoft-state-last-request-id state)))
                (_ (puthash requestid t (khulnasoft-state-pending-table state)))
                (reqbody
                    (khulnasoft-request api state vals-alist
                        (lambda (res)
                            (when (gethash requestid (khulnasoft-state-pending-table state))
                                (remhash requestid (khulnasoft-state-pending-table state))
                                (puthash requestid res (khulnasoft-state-results-table state))))))
                (rst 'noexist))
            (while (and (eq tracker (khulnasoft-state-alive-tracker state)) (eq rst 'noexist) (not (input-pending-p)))
                (sit-for (khulnasoft-get-config 'khulnasoft-delay nil state))
                (setq rst (gethash requestid (khulnasoft-state-results-table state) 'noexist)))
            (if (and (eq rst 'noexist) (eq tracker (khulnasoft-state-alive-tracker state)))
                (when-let
                    (
                        (request-id-sent
                            (khulnasoft-nested-alist-get reqbody 'khulnasoft/metadata/request_id))
                        (buf (current-buffer)))
                    (khulnasoft-run-with-timer state 'default
                        (lambda ()
                            (when (buffer-live-p buf)
                                (with-current-buffer buf
                                    (khulnasoft-request-cancelrequest state request-id-sent))))))
                (remhash requestid (khulnasoft-state-results-table state)))
            (if (or (eq rst 'error) (eq rst 'noexist)) nil (cons reqbody rst)))))

(defun khulnasoft-utf8-byte-length (str)
    (length (encode-coding-string str 'utf-8)))
(defun khulnasoft-make-utf8-offset-table (str offsets)
    (let*
        (
            (str-cur 0)
            (str-len (length str))
            (offset-cur 0)
            (offset-max (apply #'max 0 offsets))
            (table (make-hash-table :test 'eql :weakness nil :size (* 2 (length offsets)))))
        (mapc
            (lambda (offset)
                (puthash offset nil table))
            offsets)
        (while (and (< str-cur str-len) (<= offset-cur offset-max))
            (dotimes (_ (khulnasoft-utf8-byte-length (substring-no-properties str str-cur (1+ str-cur))))
                (unless (eq (gethash offset-cur table 'noexist) 'noexist)
                    (puthash offset-cur str-cur table))
                (cl-incf offset-cur))
            (cl-incf str-cur))
        (while (<= offset-cur offset-max)
            (puthash offset-cur str-len table)
            (cl-incf offset-cur))
        table))
(defmacro khulnasoft-gv-map-table (gv table)
    `(setf ,gv (gethash (khulnasoft-string-to-number-safe ,gv) ,table)))
(defmacro khulnasoft-mapcar-mutate (func seq-gv)
    `(setf ,seq-gv (mapcar ,func ,seq-gv)))

(defun khulnasoft-make-completion-string (completion-item document beg end)
    (let ((cur beg))
        (mapconcat
            (lambda (part)
                (when-let*
                    (
                        ;; should be int since its been processed by khulnasoft-parse-getcompletions-res-process-offsets
                        (offset (alist-get 'offset part))
                        (type (alist-get 'type part))
                        (text (alist-get 'text part)))
                    (when (or (string= type "COMPLETION_PART_TYPE_INLINE") (string= type "COMPLETION_PART_TYPE_BLOCK"))
                        (prog1
                            (concat
                                (substring document cur (min offset (length document)))
                                ;; (substring document (min cur offset (length document)) (min offset (length document)))
                                (when (string= type "COMPLETION_PART_TYPE_BLOCK") "\n")
                                text)
                            (setq cur offset)))))
            (append (alist-get 'completionParts completion-item) `(((offset . ,end))))
            "")))

(defun khulnasoft-string-to-number-safe (str)
    (if (stringp str) (string-to-number str) str))
(defun khulnasoft-parse-getcompletions-res-process-offsets (document cursor res)
    (let*
        (
            (items (alist-get 'completionItems res))
            (offsets-full-list
                (mapcar #'khulnasoft-string-to-number-safe
                    (remove nil
                        (mapcan
                            (lambda (item)
                                (append
                                    (list
                                        (alist-get 'startOffset (alist-get 'range item))
                                        (alist-get 'endOffset (alist-get 'range item)))
                                    (mapcar
                                        (lambda (part) (alist-get 'offset part))
                                        (alist-get 'completionParts item))))
                            items))))
            (offsets-table (khulnasoft-make-utf8-offset-table document (push cursor offsets-full-list)))
            (_
                (khulnasoft-mapcar-mutate
                    (lambda (item)
                        (khulnasoft-gv-map-table (alist-get 'startOffset (alist-get 'range item)) offsets-table)
                        (khulnasoft-gv-map-table (alist-get 'endOffset (alist-get 'range item)) offsets-table)
                        (khulnasoft-mapcar-mutate
                            (lambda (part)
                                (khulnasoft-gv-map-table (alist-get 'offset part) offsets-table)
                                part)
                            (alist-get 'completionParts item))
                        item)
                    items)))
        offsets-table))

;; WARNING: this mutates res
(defun khulnasoft-parse-getcompletions-res (req res)
    "takes req and res"

    ;; (setq res (cdr (khulnasoft-request-synchronously 'GetCompletions khulnasoft-state nil)))
    ;; (mapcar 'car res)
    ;; (state completionItems requestInfo)
    ;; (alist-get 'state res)
    ;; (alist-get 'requestInfo res)

    ;; (setq items (alist-get 'completionItems res))
    ;; (setq item (elt items 0))
    ;; (mapcar 'car item)
    ;; (completion range source completionParts)
    ;; (alist-get 'completion item)
    ;; (alist-get 'range item)
    ;; (alist-get 'source item)
    ;; (alist-get 'completionParts item)
    ;; (alist-get 'endOffset (alist-get 'range item))

    ;; (print (alist-get 'state res))
    ;; (alist-get 'completionId (alist-get 'completion item))
    (when (alist-get 'completionItems res)
        (let*
            (
                (document (khulnasoft-nested-alist-get req 'khulnasoft/document/text))
                (cursor (khulnasoft-nested-alist-get req 'khulnasoft/document/cursor_offset))
                (items (alist-get 'completionItems res))
                (offset-hashtable (khulnasoft-parse-getcompletions-res-process-offsets document cursor res))
                (cursor (gethash cursor offset-hashtable))
                offset-list
                (_
                    (maphash (lambda (_ offset) (if offset (push offset offset-list))) offset-hashtable))
                (range-min (apply #'min cursor offset-list))
                (range-max (apply #'max cursor offset-list))
                (strings-list
                    (mapcar
                        (lambda (item) (khulnasoft-make-completion-string item document range-min range-max))
                        items))
                (completionids
                    (mapcar
                        (lambda (item)
                            (alist-get 'completionId (alist-get 'completion item)))
                        items)))
            ;; (print (elt items 0))
            ;; (print (alist-get 'completionParts (elt items 0)))
            ;; (print strings-list)
            ;; (print (alist-get 'completion (elt items 0)))
            ;; ;; (print (alist-get 'range (elt items 0)))
            ;; ;; (print (alist-get 'source (elt items 0)))
            ;; (print (list (- range-min cursor) (- range-max cursor) (nth 0 strings-list)))
            ;; (print (list range-min cursor range-max))
            (list (- range-min cursor) (- range-max cursor) strings-list completionids))))

;;;###autoload
(defun khulnasoft-init (&optional state)
    (interactive)
    (setq state (or state khulnasoft-state))
    (setf (khulnasoft-state-alive-tracker state)
        (gensym (khulnasoft-state-name khulnasoft-state)))
    (condition-case err
        (khulnasoft-background-process-start state)
        (error (khulnasoft-reset state)
            (signal (car err) (cdr err)))))

;;;###autoload
(defun khulnasoft-completion-at-point (&optional state)
    (setq state (or state khulnasoft-state))
    (when
        (and (khulnasoft-state-proc state)
            (not (process-live-p (khulnasoft-state-proc state))))
        (khulnasoft-reset state))
    (unless (khulnasoft-state-alive-tracker state)
        (khulnasoft-init state))
    ;; (condition-case err
    (when-let*
        (
            (buffer-prev-str (buffer-string))
            (prev-point-offset (- (point) (point-min)))
            (tmp (khulnasoft-request-synchronously 'GetCompletions state nil))
            (req (car tmp))
            (res (cdr tmp))
            (rst (and (not (input-pending-p)) (khulnasoft-parse-getcompletions-res req res)))
            (company-doc-buffer " *khulnasoft-docs*"))
        (cl-destructuring-bind (dmin dmax table completionids) rst
            (let*
                (
                    (rmin (+ dmin (point)))
                    (rmax (+ dmax (point)))
                    (pmin (+ dmin prev-point-offset))
                    (pmax (+ dmax prev-point-offset)))
                (when
                    (and
                        (<= (point-min) rmin)
                        (<= rmax (point-max))
                        (<= 0 pmin)
                        (<= pmax (length buffer-prev-str))
                        (string=
                            (buffer-substring-no-properties rmin rmax)
                            (substring-no-properties buffer-prev-str pmin pmax)))
                    (list rmin rmax table
                          :exit-function
                          `(lambda (string status)
                         (ignore-errors (kill-buffer ,company-doc-buffer))
                         (when-let* ((num (and (eq status 'finished) (cl-position string ',table :test 'string=))))
                           (khulnasoft-request 'AcceptCompletion ,state
                                    `((khulnasoft/completion_id . ,(nth num ',completionids)))
                                    #'ignore)))
                          :annotation-function
                          (lambda (_)
                          (propertize
                           " Khulnasoft"
                           'face font-lock-comment-face))
                          :company-kind
                          (lambda (_) 'magic)
                          :company-doc-buffer
                          `(lambda (string)
                         ;; Soft load of markdown-mode, if no package then will show doc in plain text
                         (unless (featurep 'markdown-mode)
                           (ignore-errors (require 'markdown-mode)))
                         (let* ((derived-lang (or (if (boundp 'markdown-code-lang-modes)
                                          (car (rassoc major-mode
                                               markdown-code-lang-modes)))
                                      (replace-regexp-in-string
                                       "\\(/.*\\|-ts-mode\\|-mode\\)$" ""
                                       (substring-no-properties mode-name))))
                            (markdown-fontify-code-blocks-natively t)
                            (inhibit-read-only t)
                            (non-essential t)
                            (delay-mode-hooks t))
                           (with-current-buffer (get-buffer-create ,company-doc-buffer t)
                             (erase-buffer)
                             (if (fboundp 'gfm-view-mode)
                             (progn
                               (ignore-errors (funcall 'gfm-view-mode))
                               (insert (concat "Khulnasoft: " derived-lang "\n"
                                       "*****\n"
                                       "```" (downcase derived-lang) "\n"
                                       string "\n"
                                       "```")))
                               (insert string))
                             (font-lock-ensure (point-min) (point-max))
                             (current-buffer)))))))))
    ;; (error
    ;; 	(message "an error occurred in khulnasoft-completion-at-point: %s" (error-message-string err))
    ;; 	nil)
    ;; )
    )

;; TODO: put these in separate file

(defun khulnasoft-test ()
    (cl-letf*
        (
            (state (khulnasoft-state-make :name "test"))
            ;; ((khulnasoft-config 'khulnasoft/metadata/api_key state) (khulnasoft-uuid-create))
            ;; ((khulnasoft-config 'khulnasoft/document/text state) "def fibi(n):")
            ;; ((khulnasoft-config 'khulnasoft/document/cursor_offset state) 12)
            ((khulnasoft-config 'khulnasoft-api-enabled state) (lambda (api) (eq api 'GetCompletions))))
        (unwind-protect
            (khulnasoft-completion-at-point state)
            (khulnasoft-reset state))))

(defun khulnasoft-test-cancel ()
    (let ((state (khulnasoft-state-make :name "test")))
        (unwind-protect
            (cl-letf*
                (
                    ((khulnasoft-config 'khulnasoft-api-enabled state) (lambda (api) (memq api '(GetCompletions CancelRequest))))
                    ((khulnasoft-config 'khulnasoft/document/text state) "def fibi(n):")
                    ((khulnasoft-config 'khulnasoft/document/cursor_offset state) 12)
                    (_ (khulnasoft-init state))

                    ((khulnasoft-config 'khulnasoft/metadata/request_id state) 1)
                    (_ (khulnasoft-on-port-ready state
                           (lambda ()
                               (run-with-timer 0.001 nil
                                   (lambda () (khulnasoft-request 'CancelRequest state `((khulnasoft/request_id . 1)) #'ignore)))))))
                (cdr (khulnasoft-request-synchronously 'GetCompletions state nil)))
            (khulnasoft-reset state))))

;; (makunbound 'state)
;; (setq state (khulnasoft-test-cancel))
;; (khulnasoft-reset state)
;; (khulnasoft-state-background-process-cancel-fn state)


(defun khulnasoft-test-multiround (round callback)
    (if (= round 0)
        (funcall callback)
        (khulnasoft-test)
        (run-with-timer 0.005 nil 'khulnasoft-test-multiround (1- round) callback)))

(defun khulnasoft-stresstest ()
    "works by advising `url-retrieve'
so only run this when no other khulnasoft or other code is using that"
    (let*
        (
            (n 50)
            (start-time (current-time))
            url-retrieve-buffer url-retrieve-status
            (url-retrieve-advise
                (lambda (func url callback &optional cbargs &rest args)
                    (if url-retrieve-buffer
                        (let
                            (
                                (callback-wrapped
                                    (lambda ()
                                        (with-current-buffer url-retrieve-buffer
                                            (setq khulnasoft-kill-url-retrieve-buffer nil)
                                            (apply callback url-retrieve-status cbargs)))))
                            (run-with-timer 0.005 nil callback-wrapped)
                            url-retrieve-buffer)
                        (let
                            ((callback-wrapped
                                 (lambda (status)
                                     (setq url-retrieve-buffer (current-buffer))
                                     (setq url-retrieve-status status)
                                     (setq khulnasoft-kill-url-retrieve-buffer nil)
                                     (apply callback status cbargs))))
                            (apply func url callback-wrapped nil args))))))
        (advice-add 'url-retrieve :around url-retrieve-advise)
        (khulnasoft-test-multiround n
            (lambda ()
                (message "average time: %s" (/ (float-time (time-subtract (current-time) start-time)) n))
                (advice-remove 'url-retrieve url-retrieve-advise)))))

;; (setq khulnasoft-mode-line-enable t)
;; (run-with-timer 0.1 nil (lambda () (message "%s" (khulnasoft-test))))
;; (dotimes (_ 10) (run-with-timer 0.1 nil 'khulnasoft-stresstest))



(provide 'khulnasoft)
;;; khulnasoft.el ends here
