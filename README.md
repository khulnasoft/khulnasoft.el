# khulnasoft.el

[![Twitter Follow](https://img.shields.io/badge/style--blue?style=social&logo=twitter&label=Follow%20%40khulnasoft)](https://twitter.com/intent/follow?screen_name=khulnasoft)
![License](https://img.shields.io/github/license/KhulnaSoft/khulnasoft.vim)
[![Docs](https://img.shields.io/badge/KhulnaSoft%20Docs-09B6A2)](https://docs.khulnasoft.com)
[![Canny Board](https://img.shields.io/badge/Feature%20Requests-6b69ff)](https://khulnasoft.canny.io/feature-requests/)
[![built with KhulnaSoft](https://khulnasoft.com/badges/main)](https://khulnasoft.com?repo_name=khulnasoft%2Fkhulnasoft.el)

[![Visual Studio](https://img.shields.io/visual-studio-marketplace/i/KhulnaSoft.khulnasoft?label=Visual%20Studio&logo=visualstudio)](https://marketplace.visualstudio.com/items?itemName=KhulnaSoft.khulnasoft)
[![JetBrains](https://img.shields.io/jetbrains/plugin/d/20540?label=JetBrains)](https://plugins.jetbrains.com/plugin/20540-khulnasoft/)
[![Open VSX](https://img.shields.io/open-vsx/dt/KhulnaSoft/khulnasoft?label=Open%20VSX)](https://open-vsx.org/extension/KhulnaSoft/khulnasoft)
[![Google Chrome](https://img.shields.io/chrome-web-store/users/hobjkcpmjhlegmobgonaagepfckjkceh?label=Google%20Chrome&logo=googlechrome&logoColor=FFFFFF)](https://chrome.google.com/webstore/detail/khulnasoft/hobjkcpmjhlegmobgonaagepfckjkceh)

_Free, ultrafast, extensible AI code completion tool for Emacs_

KhulnaSoft autocompletes your code with AI in all major IDEs. We [launched](https://www.khulnasoft.com/blog/khulnasoft-copilot-alternative-in-emacs) this implementation of the KhulnaSoft plugin for Emacs to bring this modern coding superpower to more developers. Check out our [playground](https://www.khulnasoft.com/playground) if you want to quickly try out KhulnaSoft online.

khulnasoft.el provides a `completion-at-point-functions` backend. It is designed to be use with a front-end, such as [company-mode](https://company-mode.github.io/), [corfu](https://github.com/minad/corfu), or the built-in `completion-at-point`.

khulnasoft.el is an open source client and (mostly) written by [Alan Chen](https://github.com/Alan-Chen99). It uses a proprietary language server binary, currently downloaded (automatically, with confirmation) from [here](https://github.com/KhulnaSoft/khulnasoft/releases/). Use `M-x khulnasoft-diagnose` to see apis/fields that would be sent to the local language server, and the command used to run the local language server. Customize `khulnasoft-api-enabled`, `khulnasoft-fields-regexps` and `khulnasoft-command` to change them.

Contributions are welcome! Feel free to submit pull requests and issues related to the package.

<br />

## 🚀 Getting started

1. Install [Emacs](https://www.gnu.org/software/emacs/), ensuring the version of Emacs you are running is compiled with [libxml2](https://www.gnu.org/software/emacs/manual/html_node/elisp/Parsing-HTML_002fXML.html). You can check this by using the `(libxml-available-p)` function within Emacs Lisp. This function returns t (true) if libxml2 is available in your current Emacs session.

2. Install a text-completion frontend of your choice. (We recommend [company-mode](https://company-mode.github.io/) or [corfu](https://github.com/minad/corfu)).

3. Install `KhulnaSoft/khulnasoft.el` using your emacs package manager of
choice, or manually. See [Installation Options](#-installation-options) below.

4. Run `M-x khulnasoft-install` to set up the package.

5. Add `khulnasoft-completion-at-point` to your `completion-at-point-functions`.

6. Start seeing suggestions!

## 🛠️ Configuration

You can see all customization options via `M-x customize`.
(better documentation coming soon!)

Here is an example configuration:
```elisp
;; we recommend using use-package to organize your init.el
(use-package khulnasoft
    ;; if you use straight
    ;; :straight '(:type git :host github :repo "KhulnaSoft/khulnasoft.el")
    ;; otherwise, make sure that the khulnasoft.el file is on load-path

    :init
    ;; use globally
    (add-to-list 'completion-at-point-functions #'khulnasoft-completion-at-point)
    ;; or on a hook
    ;; (add-hook 'python-mode-hook
    ;;     (lambda ()
    ;;         (setq-local completion-at-point-functions '(khulnasoft-completion-at-point))))

    ;; if you want multiple completion backends, use cape (https://github.com/minad/cape):
    ;; (add-hook 'python-mode-hook
    ;;     (lambda ()
    ;;         (setq-local completion-at-point-functions
    ;;             (list (cape-capf-super #'khulnasoft-completion-at-point #'lsp-completion-at-point)))))
    ;; an async company-backend is coming soon!

    ;; khulnasoft-completion-at-point is autoloaded, but you can
    ;; optionally set a timer, which might speed up things as the
    ;; khulnasoft local language server takes ~0.2s to start up
    ;; (add-hook 'emacs-startup-hook
    ;;  (lambda () (run-with-timer 0.1 nil #'khulnasoft-init)))

    ;; :defer t ;; lazy loading, if you want
    :config
    (setq use-dialog-box nil) ;; do not use popup boxes

    ;; if you don't want to use customize to save the api-key
    ;; (setq khulnasoft/metadata/api_key "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx")

    ;; get khulnasoft status in the modeline
    (setq khulnasoft-mode-line-enable
        (lambda (api) (not (memq api '(CancelRequest Heartbeat AcceptCompletion)))))
    (add-to-list 'mode-line-format '(:eval (car-safe khulnasoft-mode-line)) t)
    ;; alternatively for a more extensive mode-line
    ;; (add-to-list 'mode-line-format '(-50 "" khulnasoft-mode-line) t)

    ;; use M-x khulnasoft-diagnose to see apis/fields that would be sent to the local language server
    (setq khulnasoft-api-enabled
        (lambda (api)
            (memq api '(GetCompletions Heartbeat CancelRequest GetAuthToken RegisterUser auth-redirect AcceptCompletion))))
    ;; you can also set a config for a single buffer like this:
    ;; (add-hook 'python-mode-hook
    ;;     (lambda ()
    ;;         (setq-local khulnasoft/editor_options/tab_size 4)))

    ;; You can overwrite all the khulnasoft configs!
    ;; for example, we recommend limiting the string sent to khulnasoft for better performance
    (defun my-khulnasoft/document/text ()
        (buffer-substring-no-properties (max (- (point) 3000) (point-min)) (min (+ (point) 1000) (point-max))))
    ;; if you change the text, you should also change the cursor_offset
    ;; warning: this is measured by UTF-8 encoded bytes
    (defun my-khulnasoft/document/cursor_offset ()
        (khulnasoft-utf8-byte-length
            (buffer-substring-no-properties (max (- (point) 3000) (point-min)) (point))))
    (setq khulnasoft/document/text 'my-khulnasoft/document/text)
    (setq khulnasoft/document/cursor_offset 'my-khulnasoft/document/cursor_offset))
```


Here is an example configuration for company-mode.
```elisp
(use-package company
    :defer 0.1
    :config
    (global-company-mode t)
    (setq-default
        company-idle-delay 0.05
        company-require-match nil
        company-minimum-prefix-length 0

        ;; get only preview
        company-frontends '(company-preview-frontend)
        ;; also get a drop down
        ;; company-frontends '(company-pseudo-tooltip-frontend company-preview-frontend)
        ))
```

You can also access khulnasoft.el from elisp; here is a snippet that returns
the full response of a `GetCompletions` request:
```elisp
(cl-letf*
    (
        ;; making a new khulnasoft-state (thus a new local language server process)
        ;; takes ~0.2 seconds; avoid when possible
        (state (khulnasoft-state-make :name "example"))
        ((khulnasoft-config 'khulnasoft/document/text state) "def fibi(n):")
        ((khulnasoft-config 'khulnasoft/document/cursor_offset state) 12)
        ((khulnasoft-config 'khulnasoft-api-enabled state) (lambda (api) (eq api 'GetCompletions))))
    (unwind-protect
        (progn
            (khulnasoft-init state)
            ;; make async requests using khulnasoft-request
            (cdr (khulnasoft-request-synchronously 'GetCompletions state nil)))
        ;; cleans up temp files, kill process. Scheduled async requests on this state will be dropped.
        (khulnasoft-reset state)))
```
Note that, among other things, you get probabilities for each token!
We would love to see a PR or your own package that uses those!

### 🔓 Authentication
If you want to authenticate automatically, add your khulnasoft api key to one of `auth-sources`. For example

~/.authinfo.gpg:
``` text
machine khulnasoft.com login apikey secret <insert_api_key_here>
```

## 💾 Installation Options

### ➡️ straight.el

```elisp
(straight-use-package '(khulnasoft :type git :host github :repo "KhulnaSoft/khulnasoft.el"))
```

### 💀 Doom Emacs
In `packages.el` add the following:
```elisp
(package! khulnasoft :recipe (:host github :repo "KhulnaSoft/khulnasoft.el"))
```
Add the example configuration to your `config.el` file.


### 💪 Manual

Run the following.

```bash
git clone --depth 1 https://github.com/KhulnaSoft/khulnasoft.el ~/.emacs.d/khulnasoft.el
```

Add the following to your `~/.emacs.d/init.el` file.

```elisp
(add-to-list 'load-path "~/.emacs.d/khulnasoft.el")
```

*Do you have a working installation for another Emacs environment (Spacemacs)? Submit a PR so we can share it with others!*
