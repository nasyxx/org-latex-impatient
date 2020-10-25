;;; org-latex-instant-preview.el --- Preview org-latex Fragments Instantly via MathJax -*- lexical-binding: t; -*-
;;
;; Copyright (C) 2020 Sheng Yang
;;
;; Author:  Sheng Yang <styang@fastmail.com>
;; Created: June 03, 2020
;; Modified: October 04, 2020
;; Version: 0.1.0
;; Keywords: tex,tools
;; Homepage: https://github.com/yangsheng6810/org-latex-instant-preview
;; Package-Requires: ((emacs "26") (names "0.5.2") (s "1.8.0") (posframe "0.8.0") (org "9.3") (dash "2.17.0"))
;;
;; This file is not part of GNU Emacs.
;;
;;; Commentary:
;;
;;  This package provides instant preview of LaTeX snippets via MathJax outputed
;;  SVG.
;;
;;; Code:
;;;

(eval-when-compile (require 'names))
(require 'image-mode)
(require 's)
(require 'dash)
(require 'org)
(require 'posframe)
(require 'org-element)

;; Workaround for defvar-local problem in names.el
(eval-when-compile
  (unless (fboundp 'names--convert-defvar-local)
    (defalias 'names--convert-defvar-local 'names--convert-defvar
      "Special treatment for `defvar-local' FORM.")))

;; Additional posframe poshandler
(unless (fboundp 'posframe-poshandler-point-window-center)
  (defun posframe-poshandler-point-window-center (info)
    "Posframe's position handler.

Get a position which let posframe stay right below current
position, centered in the current window. The structure of INFO
can be found in docstring of `posframe-show'."
    (let* ((window-left (plist-get info :parent-window-left))
           (window-top (plist-get info :parent-window-top))
           (window-width (plist-get info :parent-window-width))
           (window-height (plist-get info :parent-window-height))
           (posframe-width (plist-get info :posframe-width))
           (posframe-height (plist-get info :posframe-height))
           (mode-line-height (plist-get info :mode-line-height))
           (y-pixel-offset (plist-get info :y-pixel-offset))
           (posframe-height (plist-get info :posframe-height))
           (ymax (plist-get info :parent-frame-height))
           (window (plist-get info :parent-window))
           (position-info (plist-get info :position-info))
           (header-line-height (plist-get info :header-line-height))
           (tab-line-height (plist-get info :tab-line-height))
           (y-top (+ (cadr (window-pixel-edges window))
                     tab-line-height
                     header-line-height
                     (- (or (cdr (posn-x-y position-info)) 0)
                        ;; Fix the conflict with flycheck
                        ;; http://lists.gnu.org/archive/html/emacs-devel/2018-01/msg00537.html
                        (or (cdr (posn-object-x-y position-info)) 0))
                     y-pixel-offset))
           (font-height (plist-get info :font-height))
           (y-bottom (+ y-top font-height)))
      (cons (+ window-left (/ (- window-width posframe-width) 2))
            (max 0 (if (> (+ y-bottom (or posframe-height 0)) ymax)
                       (- y-top (or posframe-height 0))
                     y-bottom))))))

;;;###autoload
(define-namespace org-latex-instant-preview-
;; (defgroup org-latex-instant-preview nil
;;   "Instant preview for org LaTeX snippets.")

(defcustom tex2svg-bin ""
  "Location of tex2svg executable."
  :group 'org-latex-instant-preview
  :type '(string))

(defcustom delay 0.1
  "Number of seconds to wait before a re-compilation."
  :group 'org-latex-instant-preview
  :type '(number))

(defcustom scale 1.0
  "Scale of preview."
  :group 'org-latex-instant-preview
  :type '(float))

(defcustom border-color "black"
  "Color of preview border."
  :group 'org-latex-instant-preview
  :type '(color))

(defcustom border-width 1
  "Width of preview border."
  :group 'org-latex-instant-preview
  :type '(integer))

(defcustom user-latex-definitions
  '("\\newcommand{\\ensuremath}[1]{#1}")
  "Custom LaTeX definitions used in preview."
  :group 'org-latex-instant-preview
  :type '(repeat string))

(defcustom posframe-position-handler
  #'poshandler
  "The handler for posframe position."
  :group 'org-latex-instant-preview
  :type '(function))

(defconst -output-buffer-prefix "*org-latex-instant-preview*"
  "Prefix for buffer to hold the output.")

(defconst -posframe-buffer "*org-latex-instant-preview*"
  "Buffer to hold the preview.")

(defvar keymap
  (let ((map (make-sparse-keymap)))
    (define-key map "\C-g" #'abort-preview)
    map)
  "Keymap for reading input.")

(defvar -process nil)
(defvar -timer nil)
(defvar-local -last-tex-string nil)
(defvar-local -last-position nil)
(defvar-local -position nil)
(defvar-local -last-preview nil)
(defvar-local -current-window nil)
(defvar-local -output-buffer nil)
(defvar-local -is-inline nil)
(defvar-local -force-hidden nil)


(defun poshandler (info)
  "Default position handler for posframe.

Uses the end point of the current LaTeX fragment for inline math,
and centering right below the end point otherwise. Position are
calculated from INFO."
  (if -is-inline
      (posframe-poshandler-point-bottom-left-corner info)
    (posframe-poshandler-point-window-center info)))

(defun -clean-up ()
  "Clean up timer, process, and variables."
  (-hide)
  (when -process
    (kill-process -process))
  (when (get-buffer -output-buffer)
    (kill-buffer -output-buffer))
  (setq -process nil
        -last-tex-string nil
        -last-position nil
        -current-window nil))

:autoload
(defun stop ()
  "Stop instant preview of LaTeX snippets."
  (interactive)
  ;; only needed for manual start/stop
  (remove-hook 'after-change-functions #'-prepare-timer t)
  (-hide)
  (-interrupt-rendering))

(defun -prepare-timer (&rest _)
  "Prepare timer to call re-compilation."
  (when -timer
    (cancel-timer -timer)
    (setq -timer nil))
  (if (and (or (eq major-mode 'org-mode)
               (eq major-mode 'latex-mode))
           (-in-latex-p))
      (setq -timer
            (run-with-idle-timer delay nil #'start))
    (-hide)))

(defun -remove-math-delimeter (ss)
  "Chop LaTeX delimeters from SS."
  (setq -is-inline
        (or (s-starts-with? "\\(" ss)
            (s-starts-with? "$" ss)))
  (s-with ss
    (s-chop-prefixes '("$$" "\\(" "$" "\\["))
    (s-chop-suffixes '("$$" "\\)" "$" "\\]"))))

(defun -add-color (ss)
  "Wrap SS with color from default face."
  (let ((color (face-foreground 'default)))
    (format "\\color{%s}{%s}" color ss)))

(defun -in-latex-p ()
  "Return t if DATUM is in a LaTeX fragment, nil otherwise."
  (cond ((eq major-mode 'org-mode)
         (let ((datum (org-element-context)))
           (or (memq (org-element-type datum) '(latex-environment latex-fragment))
               (and (memq (org-element-type datum) '(export-block))
                    (equal (org-element-property :type datum) "LATEX")))))
        ((eq major-mode 'latex-mode)
         (-tex-in-latex-p))
        (t (message "We only support org-mode and latex-mode")
           nil)))

(defun -tex-in-latex-p ()
  "Return t if in LaTeX fragment in LaTeX."
  (let ((faces (face-at-point nil t)))
    (or (-contains? faces 'font-latex-math-face)
        (-contains? faces 'preview-face))))

(defun -has-latex-overlay ()
  "Return t if there is LaTeX overlay showing."
  (--first (or (overlay-get it 'xenops-overlay-type)
               (equal 'org-latex-overlay (overlay-get it 'org-overlay-type)))
           (append (overlays-at (point)) (overlays-at (1- (point))))))

(defun -get-tex-string ()
  "Return the string of LaTeX fragment."
  (cond ((eq major-mode 'org-mode)
         (let ((datum (org-element-context)))
           (org-element-property :value datum)))
        ((eq major-mode 'latex-mode)
         (let (begin end)
           (save-excursion
             (while (-tex-in-latex-p)
               (backward-char))
             (setq begin (1+ (point))))
           (save-excursion
             (while (-tex-in-latex-p)
               (forward-char))
             (setq end (point)))
           (let ((ss (buffer-substring-no-properties begin end)))
             (message "ss is %S" ss)
             ss)))
        (t "")))

(defun -get-tex-position ()
  "Return the end position of LaTeX fragment."
  (cond ((eq major-mode 'org-mode)
         (let ((datum (org-element-context)))
           (org-element-property :end datum)))
        ((eq major-mode 'latex-mode)
         (save-excursion
           (while (-tex-in-latex-p)
             (forward-char))
           (point)))
        (t (message "Only org-mode and latex-mode supported") nil)))

(defun -need-remove-delimeters ()
  "Return t if need to remove delimeters."
  (cond ((eq major-mode 'org-mode)
         (let ((datum (org-element-context)))
           (memq (org-element-type datum) '(latex-fragment))))
        ((eq major-mode 'latex-mode)
         (message "Not implemente.")
         t)
        (t "")))

(defun -get-headers ()
  "Return a string of headers."
  (cond ((eq major-mode 'org-mode)
         (plist-get (org-export-get-environment
                     (org-export-get-backend 'latex))
                    :latex-header))
        ((eq major-mode 'latex-mode)
         (message "Get header not supported in latex-mode yet.")
         "")
        (t "")))

:autoload
(defun start (&rest _)
  "Start instant preview."
  (interactive)
  (unless (and (not (string= tex2svg-bin ""))
               (executable-find tex2svg-bin))
    (message "You need to set org-latex-instant-preview-tex2svg-bin
for instant preview to work!")
    (error "Org-latex-instant-preview-tex2svg-bin is not set correctly"))

  ;; Only used for manual start
  (when (equal this-command #'start)
    (add-hook 'after-change-functions #'-prepare-timer nil t))

  (if (and (or (eq major-mode 'org-mode)
               (eq major-mode 'latex-mode))
       (-in-latex-p)
       (not (-has-latex-overlay)))
      (let ((tex-string (-get-tex-string))
            (latex-header
             (concat (s-join "\n" user-latex-definitions)
                     "\n"
                     (-get-headers))))
        (setq -current-window (selected-window))
        (setq -is-inline nil)
        ;; the tex string from latex-fragment includes math delimeters like
        ;; $, $$, \(\), \[\], and we need to remove them.
        (when (-need-remove-delimeters)
          (setq tex-string (-remove-math-delimeter tex-string)))

        (setq -position (-get-tex-position)
              ;; set forground color for LaTeX equations.
              tex-string (concat latex-header (-add-color tex-string)))
        (if (and -last-tex-string
                 (equal tex-string -last-tex-string))
            ;; TeX string is the same, we only need to update posframe
            ;; position.
            (when (and -last-position
                       (equal -position -last-position)
                       ;; do not force showing posframe when a render
                       ;; process is running.
                       (not -process)
                       (not -force-hidden))
              (-show))
          ;; reset `-force-hidden'
          (setq -force-hidden nil)
          ;; A new rendering is needed.
          (-interrupt-rendering)
          (-render tex-string)))
    ;; Hide posframe when not on LaTeX
    (-hide)))

(defun -interrupt-rendering ()
  "Interrupt current running rendering."
  (when -process
    (condition-case nil
        (kill-process -process)
      (error "Faild to kill process"))
    (setq -process nil
          ;; last render for tex string is invalid, therefore need to invalid
          ;; its cache
          -last-tex-string nil
          -last-preview nil))
  (when (get-buffer -output-buffer)
    (let ((kill-buffer-query-functions nil))
      (kill-buffer -output-buffer))))

(defun -render (tex-string)
  "Render TEX-STRING to buffer, async version.

Showing at point END"
  (message "Instant LaTeX rendering")
  (-interrupt-rendering)
  (setq -last-tex-string tex-string)
  (setq -last-position -position)
  (get-buffer-create -output-buffer)

  (setq -process
        (make-process
         :name "org-latex-instant-preview"
         :buffer -output-buffer
         :command (append (list tex2svg-bin
                                tex-string)
                          (when -is-inline
                            '("--inline")))
         ;; :stderr ::my-err-buffer
         :sentinel
         (lambda (&rest _)
           (condition-case nil
               (progn
                 (-fill-posframe-buffer)
                 (-show)
                 (kill-buffer -output-buffer))
             (error nil))
           ;; ensure -process is reset
           (setq -process nil)))))

(defun -insert-into-posframe-buffer (ss)
  "Insert SS into posframe buffer."
  (buffer-disable-undo -posframe-buffer)
  (let ((inhibit-message t))
    (with-current-buffer -posframe-buffer
      (image-mode-as-text)
      (erase-buffer)
      (insert ss)
      (image-mode))))

(defun -fill-posframe-buffer ()
  "Write SVG in posframe buffer."
  (let ((ss (with-current-buffer -output-buffer
              (buffer-string))))
    (unless (get-buffer -posframe-buffer)
      (get-buffer-create -posframe-buffer))
    ;; when compile error, ss is exactly the error message, so we do nothing.
    ;; Otherwise when compile succeed, do some hacks
    (when (s-contains-p "svg" ss)
      (setq ss
            (concat
             ;; 100% seems wierd
             "<svg height=\"110%\">"
             ;; ad-hoc for scaling
             (format "<g transform=\"scale(%s)\">" scale)
             ss
             "</g></svg>")))
    (-insert-into-posframe-buffer ss)
    (setq -last-preview ss)))

(defun -show (&optional display-point)
  "Show preview posframe at DISPLAY-POINT."
  (unless display-point
    (setq display-point -position))
  (when (and -current-window
             (posframe-workable-p)
             (<= (window-start) display-point (window-end))
             (not -force-hidden))
    (unless (get-buffer -posframe-buffer)
      (get-buffer-create -posframe-buffer)
      (when (and -last-preview
                 (not (string= "" -last-preview)))
        ;; use cached preview
        (-insert-into-posframe-buffer -last-preview)))
    (let ((temp -is-inline))
      (with-current-buffer -posframe-buffer
        (setq -is-inline temp)))

    ;; handle C-g
    (define-key keymap (kbd "C-g") #'abort-preview)
    (posframe-show -posframe-buffer
                   :position display-point
                   :poshandler posframe-position-handler
                   :parent-window -current-window
                   :internal-border-width border-width
                   :internal-border-color border-color
                   :hidehandler #'posframe-hidehandler-when-buffer-switch)))

(defun -hide ()
  "Hide preview posframe."
  (define-key keymap (kbd "C-g") nil)
  (posframe-hide -posframe-buffer)
  (when (get-buffer -posframe-buffer)
    (setq -last-preview
          (with-current-buffer -posframe-buffer
            (let ((inhibit-message t))
              (image-mode-as-text)
              (buffer-string))))
    (kill-buffer -posframe-buffer)))

(defun abort-preview ()
  "Abort preview."
  (interactive)
  (-interrupt-rendering)
  (define-key keymap (kbd "C-g") nil)
  (setq -force-hidden t)
  (-hide))

:autoload
(define-minor-mode mode
  "Instant preview of LaTeX in org-mode"
  nil nil keymap
  (if mode
      (progn
        (setq -output-buffer
              (concat -output-buffer-prefix (buffer-name)))
        (add-hook 'post-command-hook #'-prepare-timer nil t)
        )
    (remove-hook 'post-command-hook #'-prepare-timer t)
    (stop)))

;; end of namespace
)
(provide 'org-latex-instant-preview)
;;; org-latex-instant-preview.el ends here
