; togetherly.el -- allow multiple users to edit a single buffer on-line

;; usage
;; -----
;; (require 'togetherly)
;;
;; - `M-x togetherly-server-start' to start a server
;; - `M-x togetherly-client-login' to join as a client

;; important issues
;; ----------------
;; - enhancement
;;   - クライアントを複数立ち上げられるように
;;     - ポートを切り替えてサーバーも複数立ち上がると楽しい
;;     - *Togetherly*の代わりにプロセスバッファを作って、各変数をバッファローカルにすればおｋ？
;;   - ここを見ろ！コマンド (ハイライト＋recenterを配信？)
;; - bugfix
;;   - プロセスが事故死したときの挙動が闇
;;     - logoutの中でプロセス殺すよりプロセスの死にフックしてlogout処理をすべき
;;       - byeメッセージが送れないけどまあいいっしょ

;; other issues
;; ------------
;; - enhancement
;;   - チャットができるといい？
;;   - 画面をシェアしつつ編集を許可しないということができてもいいかも
;;   - コンフリクト検出をもう少しまともに
;; - bugfix
;;   - 行末のオーバーレイがきもい
;;     - regionとpointの両方が見える
;;     - 複数のカーソルが同じ行末に来た時の挙動

(require 'cl-lib)
(require 'ido)

;; + customs

(defvar togetherly-cursor-sync-rate 0.5
  "Interval in seconds to sync cursor positions.")

(defvar togetherly-cursor-colors
  ;; (defun color-hsl-to-hex (h s l) (apply 'color-rgb-to-hex (color-hsl-to-rgb h s l)))
  ;; (mapcar (lambda (h) (color-hsl-to-hex h 0.6 0.3))
  ;;         '(0.0 0.125 0.25 0.375 0.5 0.625 0.75 0.875))
  ;; (mapcar (lambda (h) (color-hsl-to-hex h 0.6 0.8))
  ;;         '(0.0 0.125 0.25 0.375 0.5 0.625 0.75 0.875))
  (let ((lst (if (eq (frame-parameter nil 'background-mode) 'dark)
                 '("#7a1e1e" "#7a631e" "#4c7a1e" "#1e7a35"
                   "#1e7a7a" "#1e357a" "#4c1e7a" "#7a1e63")
               '("#eaadad" "#eadbad" "#cceaad" "#adeabc"
                 "#adeaea" "#adbcea" "#cbadea" "#eaaddb"))))
    (setcdr (last lst) lst))
  "(Possivly infinite) list of cursor colors.")

(defvar togetherly-region-colors
  ;; (mapcar (lambda (h) (color-hsl-to-hex h 0.6 0.2))
  ;;         '(0.0 0.125 0.25 0.375 0.5 0.625 0.75 0.875))
  ;; (mapcar (lambda (h) (color-hsl-to-hex h 0.6 0.9))
  ;;         '(0.0 0.125 0.25 0.375 0.5 0.625 0.75 0.875))
  (let ((lst (if (eq (frame-parameter nil 'background-mode) 'dark)
                 '("#511414" "#514214" "#335114" "#145123"
                   "#145151" "#142351" "#321451" "#511442")
               '("#f4d6d6" "#f4edd6" "#e5f4d6" "#d6f4dd"
                 "#d6f4f4" "#d6ddf4" "#e5d6f4" "#f4d6ed"))))
    (setcdr (last lst) lst))
  "(Possively infinite) list of region colors.")

;; + utilities

(defun togetherly--make-overlay (beg end bgcolor &optional priority)
  "Make cursor/region overlays."
  (let ((ov (make-overlay 1 1)))
    (overlay-put ov 'face `(:background ,bgcolor))
    (overlay-put ov 'bgcolor bgcolor)
    (overlay-put ov 'priority (or priority 0))
    (togetherly--move-overlay ov beg end)
    ov))

(defun togetherly--move-overlay (ov beg end)
  "Move cursor/region overlays."
  (let* ((eol (eql (char-before end) ?\n))
         (end (if eol (1- end) end))
         (after-str (when eol
                      (propertize " " 'face `(:background ,(overlay-get ov 'bgcolor))))))
    (move-overlay ov beg end (current-buffer))
    (overlay-put ov 'after-string after-str)))

(defun togetherly--buffer-string ()
  "Like `buffer-string' but not aware of narrowing and
text-properties."
  (save-restriction
    (widen)
    (buffer-substring-no-properties (point-min) (point-max))))

(defvar togetherly--last-display-name nil)
(defun togetherly--read-display-name ()
  "Read displayname with the minibuffer."
  (let ((name (read-string
               (if (null togetherly--last-display-name)
                   "Displayname : "
                 (format "Displayname (default:%s) : " togetherly--last-display-name)))))
    (if (and (string= name "") togetherly--last-display-name)
        togetherly--last-display-name
      (setq togetherly--last-display-name name))))

(defvar togetherly--last-host-address "localhost")
(defun togetherly--read-host-address ()
  "Read host address with the minibuffer."
  (let* ((addrs (when (and (fboundp 'network-interface-list)
                           (fboundp 'network-interface-info))
                  (mapcar (lambda (x)
                            (format-network-address
                             (car (network-interface-info (car x))) t))
                          (network-interface-list))))
         (addr (cl-case (length addrs)
                 ((0) (read-string
                       (format "Address (default:%s) : " togetherly--last-host-address)))
                 ((1) (car addrs))
                 (t   (ido-completing-read "Address: " addrs nil t)))))
    (if (string= addr "")
        togetherly--last-host-address
      (setq togetherly--last-host-address addr))))

(defvar togetherly--last-target-address "localhost")
(defun togetherly--read-target-address ()
  "Read target address with the minibuffer."
  (let ((addr (read-string
               (format "Address (default:%s) : " togetherly--last-target-address))))
    (if (string= addr "")
        togetherly--last-target-address
      (setq togetherly--last-target-address addr))))

(defvar togetherly--last-port 10000)
(defun togetherly--read-port ()
  "Read port number with the minibuffer."
  (let ((port (read-string (format "Port (default:%s) : " togetherly--last-port))))
    (if (string= port "")
        togetherly--last-port
      (setq togetherly--last-port (read port)))))

;; + the protocol

;; login / kick
;; - (login ID . KEYWORD) [Client->Server]
;; - (bye . REASON) [Server->Client] <Obsolete>
;; - (error . MESSAGE) [Server->Client]
;; * note that clients can also be disconnected without receiving `bye'.
;; * clients can logout from Togetherly by just disconnecting.

;; share buffer-string
;; - (refresh) [Client->Server]
;; - (welcome BUFFER_STRING . MAJOR_MODE) [Server->Client]
;; * `refresh' asks the server to send `welcome' message immediately.
;; * note that `welcome' can also be sent before `refresh' request, as needed.

;; share modifications
;; - (changed NAME BEG BEFORE_STRING . AFTER_STRING) [Server<->Client]
;; * `changed' message is broadcasted for ALL clients, including the
;;   client who actually made the change.

;; share members / cursor-positions
;; - (moved MARK . POINT) [Client->Server]
;; - (cursors (NAME1 RCOLOR1 PCOLOR1 MARK1 . POINT1) ...) [Server->Client]
;; * `cursors' is broadcasted every `togetherly-cursor-sync-rate' seconds.

;; + server
;;   + vars

(defvar togetherly--server nil)            ; (PROC NAME RCOLOR . PCOLOR)
(defvar togetherly--server-keyword nil)
(defvar togetherly--server-buffer nil)
(defvar togetherly--server-timer-object nil)
(defvar togetherly--server-clients nil) ; list of (PROC NAME RCOLOR PCOLOR REGION_OV . POINT_OV)

;;   + utils

(defun togetherly--server-send (client obj)
  "Send OBJ to CLIENT."
  (process-send-string (car client) (prin1-to-string obj)))

(defun togetherly--server-broadcast (obj)
  "Send OBJ to all clients."
  (dolist (client togetherly--server-clients)
    (togetherly--server-send client obj)))

;;   + server process

(defun togetherly--server-filter-function (proc str)
  (with-current-buffer (get-buffer-create " *togetherly-server-tmp*")
    (save-excursion
      (goto-char (point-max))
      (insert str))
    (let (message)
      (while (setq message (ignore-errors (read (current-buffer))))
        (togetherly--server-process-message proc message)
        (delete-region (point) (point-min)))
      (goto-char (point-min)))))

(defun togetherly--server-sentinel-function (proc message)
  (unless (string-match "^\\(open\\|delete\\)" message)
    (let ((client (assoc proc togetherly--server-clients)))
      (when client
        (togetherly--server-kick-client client "Terminated.")))))

(defun togetherly--server-kill-buffer-function ()
  (or (not (eq togetherly--server-buffer (current-buffer)))
      (when (y-or-n-p "This buffer is running the Togetherly server. Really kill buffer ? ")
        (togetherly-server-close)
        t)))

(defun togetherly-server-start ()
  "Start a Togetherly server with this buffer."
  (interactive)
  (cond ((null togetherly--server)
         (let* ((addr (togetherly--read-host-address))
                (server-port (togetherly--read-port))
                (server-name (togetherly--read-display-name))
                (server-proc (make-network-process
                              :name "togetherly-server" :server t
                              :service server-port :noquery t :host addr
                              :sentinel 'togetherly--server-sentinel-function
                              :filter 'togetherly--server-filter-function))
                (rcolor (car togetherly-region-colors))
                (pcolor (car togetherly-cursor-colors)))
           (setq togetherly-region-colors   (cdr togetherly-region-colors)
                 togetherly-cursor-colors   (cdr togetherly-cursor-colors)
                 togetherly--server         `(,server-proc ,server-name ,rcolor . ,pcolor)
                 togetherly--server-buffer  (current-buffer)
                 togetherly--server-clients nil
                 togetherly--server-keyword (read-passwd "Set Password : ")
                 togetherly--server-timer-object
                 (run-with-timer nil togetherly-cursor-sync-rate
                                 'togetherly--server-broadcast-cursor-positions))
           (set (make-local-variable 'header-line-format)
                (concat " " (propertize server-name 'face `(:background ,pcolor)))))
         (add-hook 'kill-emacs-hook 'togetherly-server-close)
         (add-hook 'before-change-functions 'togetherly--server-before-change nil t)
         (add-hook 'after-change-functions 'togetherly--server-after-change nil t)
         (add-hook 'kill-buffer-query-functions 'togetherly--server-kill-buffer-function))
        ((y-or-n-p "Togetherly server already started. Migrate to this buffer ? ")
         (set (make-local-variable 'header-line-format)
              (buffer-local-value 'header-line-format togetherly--server-buffer))
         (add-hook 'before-change-functions 'togetherly--server-before-change nil t)
         (add-hook 'after-change-functions 'togetherly--server-after-change nil t)
         (with-current-buffer togetherly--server-buffer
           (remove-hook 'before-change-functions 'togetherly--server-before-change t)
           (remove-hook 'after-change-functions 'togetherly--server-after-change t)
           (kill-local-variable 'header-line-format))
         (setq togetherly--server-buffer (current-buffer))
         (togetherly--server-broadcast `(welcome ,(togetherly--buffer-string) . ,major-mode)))
        (t
         (message "Togetherly: Canceled."))))

(defun togetherly-server-close ()
  "Close the Togetherly server."
  (interactive)
  (mapc (lambda (c) (togetherly--server-kick-client c "Server Closed."))
        togetherly--server-clients)
  (delete-process (car togetherly--server))
  (setq togetherly--server nil)
  (cancel-timer togetherly--server-timer-object)
  (with-current-buffer togetherly--server-buffer
    (kill-local-variable 'header-line-format))
  (remove-hook 'kill-emacs-hook 'togetherly-server-close)
  (remove-hook 'before-change-functions 'togetherly--server-before-change t)
  (remove-hook 'after-change-functions 'togetherly--server-after-change t)
  (remove-hook 'kill-buffer-query-functions 'togetherly--server-kill-buffer-function))

;;   + API

(defun togetherly--server-kick-client (client reason)
  "Kick CLIENT for REASON. REASON is sent to the client, if it's
not yet disconnected."
  (cl-destructuring-bind (proc name _ __ region-ov . point-ov) client
    (delete-overlay region-ov)
    (delete-overlay point-ov)
    (let* ((old-header (buffer-local-value 'header-line-format togetherly--server-buffer))
           (new-header (with-temp-buffer
                         (insert old-header)
                         (search-backward (regexp-quote (concat " " name " ")))
                         (replace-match "")
                         (buffer-string))))
      (with-current-buffer togetherly--server-buffer
        (setq header-line-format new-header)))
    (setq togetherly--server-clients (delq client togetherly--server-clients))
    (when (process-live-p proc)
      (process-send-string proc (format "(bye . \"%s\")" reason))
      (delete-process proc))
    (message "Togetherly: %s logged out." name)))

(defun togetherly--server-broadcast-cursor-positions ()
  "Broadcast all clients' cursor positions."
  (togetherly--server-broadcast
   (cons 'cursors
         (nconc
          (mapcar
           (lambda (c) (cl-destructuring-bind (_ name rcolor pcolor region-ov . ___) c
                         `(,name ,rcolor ,pcolor
                                 ,(overlay-start region-ov)
                                 . ,(1- (overlay-end region-ov)))))
           togetherly--server-clients)
          (with-current-buffer togetherly--server-buffer
            (cl-destructuring-bind (_ name rcolor . pcolor) togetherly--server
              `((,name ,rcolor ,pcolor ,(when mark-active (mark)) . ,(point)))))))))

;; Sync modifications on change.
(defvar togetherly--server-last-change nil)
(defun togetherly--server-before-change (beg end)
  (setq togetherly--server-last-change
        ;; store 2 extra characters to make it easier to detect conflictions
        ;;                                            vvvvvvvvvvvvvvvvvvvvvvvvvvv
        (cons beg (buffer-substring-no-properties beg (min (+ end 2) (point-max))))))
(defun togetherly--server-after-change (beg end _)
  (togetherly--server-broadcast
   `(changed ,(cadr togetherly--server)
             ,(car togetherly--server-last-change)
             ,(cdr togetherly--server-last-change)
             . ,(buffer-substring-no-properties beg (min (+ end 2) (point-max))))))

(defun togetherly--server-process-message (proc message)
  "Process MESSAGE from client process PROC."
  (cl-case (car message)

    ((login)
     (cl-destructuring-bind (name . keyword) (cdr message)
       (cond
        ((not (string= keyword togetherly--server-keyword))
         (process-send-string proc "(bye . \"Incorrect Password.\")")
         (delete-process proc))
        ((or (string= name (cadr togetherly--server))
             (member name (mapcar 'cadr togetherly--server-clients)))
         (process-send-string proc "(bye . \"Duplicate Displayname.\")")
         (delete-process proc))
        (t
         (let ((pcolor (car togetherly-cursor-colors))
               (rcolor (car togetherly-region-colors)))
           (setq togetherly-region-colors (cdr togetherly-region-colors)
                 togetherly-cursor-colors (cdr togetherly-cursor-colors))
           (with-current-buffer togetherly--server-buffer
             (push `(,proc ,name ,rcolor ,pcolor
                           ,(togetherly--make-overlay 1 2 rcolor 0)
                           . ,(togetherly--make-overlay 1 2 pcolor 1))
                   togetherly--server-clients)
             (setq header-line-format
                   (concat " " (propertize name 'face `(:background ,pcolor))
                           " " header-line-format))))
         (set-process-query-on-exit-flag proc nil)
         (togetherly--server-send
          (car togetherly--server-clients)
          (with-current-buffer togetherly--server-buffer
            `(welcome ,(togetherly--buffer-string) . ,major-mode)))
         (message "Togetherly: %s logged in." name)))))

    ((changed)
     (let ((client (assoc proc togetherly--server-clients))
           (inhibit-modification-hooks t))
       (when client
         (cl-destructuring-bind (_ beg before-string . after-string) (cdr message)
           (condition-case nil
               (with-current-buffer togetherly--server-buffer
                 (save-excursion
                   (goto-char beg)
                   (unless (looking-at (regexp-quote before-string)) (error ""))
                   (replace-match after-string t t))
                 (togetherly--server-broadcast message))
             ;; confliction detected
             (error
              (with-current-buffer togetherly--server-buffer
                (togetherly--server-send
                 client `(welcome ,(togetherly--buffer-string) . ,major-mode)))))))))

    ((moved)
     (let ((client (assoc proc togetherly--server-clients)))
       (when client
         (cl-destructuring-bind (mark . point) (cdr message)
           (condition-case nil
               (cl-destructuring-bind (_ __ ___ ____ region-ov . point-ov) client
                 (with-current-buffer togetherly--server-buffer
                   (togetherly--move-overlay point-ov point (1+ point))
                   (togetherly--move-overlay region-ov (or mark point) (1+ point))))
             ;; confliction detected
             (error
              (with-current-buffer togetherly--server-buffer
                (togetherly--server-send
                 client `(welcome ,(togetherly--buffer-string) . ,major-mode)))))))))

    ((refresh)
     (let ((client (assoc proc togetherly--server-clients)))
       (with-current-buffer togetherly--server-buffer
         (togetherly--server-send
          client `(welcome ,(togetherly--buffer-string) . ,major-mode)))))))

;; + client
;;   + vars

(defvar togetherly--client-name nil)
(defvar togetherly--client-process nil)
(defvar togetherly--client-overlays nil)
(defvar togetherly--client-timer-object nil)

;;   + utils

(defun togetherly--client-send (obj)
  "Send OBJ to the server."
  (unless togetherly--client-process
    (error "Togetherly: Not logged in."))
  (process-send-string togetherly--client-process (prin1-to-string obj)))

;;   + API

(defun togetherly-client-refresh ()
  "Send `refresh' request to the server."
  (interactive)
  (togetherly--client-send '(refresh)))

(defun togetherly--client-report-cursor-position ()
  "Report the cursor position to the server."
  (with-current-buffer "*Togetherly*"
    (togetherly--client-send `(moved ,(when mark-active (mark)) . ,(point)))))

(defvar togetherly--client-last-change nil)
(defun togetherly--client-before-change (beg end)
  (setq togetherly--client-last-change
        (cons beg (buffer-substring-no-properties beg (min (+ end 2) (point-max))))))
(defun togetherly--client-after-change (beg end _)
  (togetherly--client-send
   `(changed ,togetherly--client-name
             ,(car togetherly--client-last-change)
             ,(cdr togetherly--client-last-change)
             . ,(buffer-substring-no-properties beg (min (+ end 2) (point-max))))))

(defun togetherly--client-process-message (proc message)
  "Process MESSAGE from server process PROC."
  (cl-case (car message)

    ((welcome)
     (with-current-buffer "*Togetherly*"
       (read-only-mode -1)
       (let ((inhibit-modification-hooks t)
             (original-pos (point))
             (mode (cddr message)))
         (erase-buffer)
         (insert (cadr message))
         (if (and mode (fboundp mode))
             (funcall mode)
           (fundamental-mode))
         (goto-char (max (min original-pos (point-max)) (point-min)))
         ;; local hooks must be set after changing major-mode
         (add-hook 'before-change-functions 'togetherly--client-before-change nil t)
         (add-hook 'after-change-functions 'togetherly--client-after-change nil t)))
     (message "Togetherly: Buffer refreshed."))

    ((bye)
     (togetherly-client-logout)
     (message "Togetherly: Disconnected (%s)." (cdr message)))

    ((changed)
     (cl-destructuring-bind (name beg before-string . after-string) (cdr message)
       (unless (string= name togetherly--client-name)
         (condition-case nil
             (with-current-buffer "*Togetherly*"
               (save-excursion
                 (goto-char beg)
                 (unless (looking-at (regexp-quote before-string)) (error ""))
                 (let ((inhibit-modification-hooks t))
                   (replace-match after-string t t))))
           ;; confliction detected
           (error (togetherly-client-refresh))))))

    ((cursors)
     (mapc 'delete-overlay togetherly--client-overlays)
     (with-current-buffer "*Togetherly*"
       (setq header-line-format
             (mapconcat (lambda (c)
                          (cl-destructuring-bind (n _ p  . __) c
                            (concat " " (propertize n 'face `(:background ,p)))))
                        (cdr message) " "))
       (dolist (cursor (cdr message))
         (cl-destructuring-bind (name rcolor pcolor mark . point) cursor
           (unless (string= name togetherly--client-name)
             (when mark
               (push (togetherly--make-overlay mark (1+ point) rcolor 0)
                     togetherly--client-overlays))
             (push (togetherly--make-overlay point (1+ point) pcolor 1)
                   togetherly--client-overlays))))))))

;;   + client process

(defun togetherly--client-filter-function (proc str)
  (with-current-buffer (get-buffer-create " *togetherly-client-tmp*")
    (save-excursion
      (goto-char (point-max))
      (insert str))
    (let (message)
      (while (setq message (ignore-errors (read (current-buffer))))
        (togetherly--client-process-message proc message)
        (delete-region (point) (point-min)))
      (goto-char (point-min)))))

(defun togetherly--client-sentinel-function (proc message)
  (unless (string-match "^\\(open\\|delete\\)" message)
    (togetherly-client-logout)
    (message "Togetherly: Network error. (%s)" message)))

(defun togetherly--client-kill-buffer-function ()
  (or (not togetherly--client-process)
      (not (string= "*Togetherly*" (buffer-name)))
      (when (y-or-n-p "This buffer is running a Togetherly client. Really kill buffer ? ")
        (togetherly--client-logout-internal)
        t)))

(defun togetherly-client-login ()
  (interactive)
  (when (or (null togetherly--client-process)
            (when (y-or-n-p "Already running Togetherly client. Kill the client first ? ")
              (togetherly--client-logout-internal)
              t))
    (let* ((host (togetherly--read-target-address))
           (port (togetherly--read-port))
           (name (setq togetherly--client-name (togetherly--read-display-name)))
           (keyword (read-passwd "Password : ")))
      (setq togetherly--client-process
            (make-network-process
             :name "togetherly" :host host :service port :noquery t
             :sentinel 'togetherly--client-sentinel-function
             :filter 'togetherly--client-filter-function))
      (switch-to-buffer (get-buffer-create "*Togetherly*"))
      (setq togetherly--client-timer-object
            (run-with-timer nil togetherly-cursor-sync-rate
                            'togetherly--client-report-cursor-position))
      (read-only-mode 1) ; make the buffer read-only until `welcome' message
      (add-hook 'kill-buffer-query-functions 'togetherly--client-kill-buffer-function)
      (togetherly--client-send `(login ,name . ,keyword)))))

(defun togetherly--client-logout-internal ()
  "Logout from Togetherly server, but do not kill the Togetherly
buffer."
  (when togetherly--client-process
    (delete-process togetherly--client-process))
  (setq togetherly--client-process nil)
  (cancel-timer togetherly--client-timer-object)
  (remove-hook 'kill-buffer-query-functions 'togetherly--client-kill-buffer-function))

(defun togetherly-client-logout ()
  (interactive)
  (togetherly--client-logout-internal)
  (when (get-buffer "*Togetherly*")
    (kill-buffer "*Togetherly*")))

;; + provide

(provide 'togetherly)