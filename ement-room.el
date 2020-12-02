;;; ement-room.el --- Ement room buffers             -*- lexical-binding: t; -*-

;; Copyright (C) 2020  Adam Porter

;; Author: Adam Porter <adam@alphapapa.net>
;; Keywords:

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; EWOC is a great library.  If I had known about it and learned it
;; sooner, it would have saved me a lot of time in other projects.
;; I'm glad I decided to try it for this one.

;;; Code:

;;;; Debugging

(eval-and-compile
  (setq-local warning-minimum-log-level nil)
  (setq-local warning-minimum-log-level :debug))

;;;; Requirements

(require 'ewoc)
(require 'shr)
(require 'subr-x)

(require 'ement-api)
(require 'ement-macros)
(require 'ement-structs)

;;;; Variables

(defvar-local ement-ewoc nil
  "EWOC for Ement room buffers.")

(defvar-local ement-room nil
  "Ement room for current buffer.")

(defvar-local ement-session nil
  "Ement session for current buffer.")

(defvar-local ement-room-retro-loading nil
  "Non-nil when earlier messages are being loaded.
Used to avoid overlapping requests.")

(declare-function ement-view-room "ement.el")
(defvar ement-room-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'ement-room-sync)
    (define-key map (kbd "r") #'ement-view-room)
    (define-key map (kbd "q") #'quit-window)
    (define-key map (kbd "v") #'ement-room-view-event)
    (define-key map (kbd "RET") #'ement-room-send-message)
    (define-key map (kbd "<backtab>") #'ement-room-goto-prev)
    (define-key map (kbd "TAB") #'ement-room-goto-next)
    (define-key map [remap scroll-down-command] #'ement-room-scroll-down-command)
    (define-key map [remap mwheel-scroll] #'ement-room-mwheel-scroll)
    map)
  "Keymap for Ement room buffers.")

;;;; Customization

(defgroup ement-room nil
  "Options for room buffers."
  :group 'ement)

(defcustom ement-room-buffer-name-prefix "*Ement Room: "
  "Prefix for Ement room buffer names."
  :type 'string)

(defcustom ement-room-buffer-name-suffix "*"
  "Suffix for Ement room buffer names."
  :type 'string)

(defcustom ement-room-timestamp-format " [%H:%M:%S]"
  "Format string for event timestamps.
See function `format-time-string'."
  :type '(choice (const " [%H:%M:%S]")
                 (const " [%Y-%m-%d %H:%M:%S]")
                 string))

(defcustom ement-room-username-display-property '(raise -0.25)
  "Display property applied to username strings.
See Info node `(elisp)Other Display Specs'."
  :type '(choice (list :tag "Raise" (const raise :tag "Raise") (number :tag "Factor"))
		 (list :tag "Height" (const height)
		       (choice (list :tag "Larger" (const + :tag "Larger") (number :tag "Steps"))
			       (list :tag "Smaller" (const - :tag "Smaller") (number :tag "Steps"))
			       (number :tag "Factor")
			       (function :tag "Function")
			       (sexp :tag "Form"))) ))

(defface ement-room-membership
  '((t (:inherit font-lock-comment-face)))
  "Membership events (join/part).")

(defface ement-room-timestamp
  '((t (:inherit font-lock-comment-face)))
  "Event timestamps.")

(defface ement-room-user
  '((t (:inherit font-lock-function-name-face :weight bold)))
  "Usernames.")

(defface ement-room-self
  '((t (:inherit font-lock-variable-name-face :weight bold)))
  "Own username.")

(defface ement-room-self-message
  '((t (:inherit font-lock-variable-name-face)))
  "Own messages.")

;;;; Commands

(defun ement-room-goto-prev (num)
  "Goto the NUM'th previous message in buffer."
  (interactive "p")
  (ewoc-goto-prev ement-ewoc num))

(defun ement-room-goto-next (num)
  "Goto the NUM'th next message in buffer."
  (interactive "p")
  (ewoc-goto-next ement-ewoc num))

(defun ement-room-scroll-down-command ()
  "Scroll down, and load NUMBER earlier messages when at top."
  (interactive)
  (condition-case _err
      (scroll-down nil)
    (beginning-of-buffer
     (when (call-interactively #'ement-room-retro)
       (message "Loading earlier messages...")))))

(defun ement-room-mwheel-scroll (event)
  "Scroll according to EVENT, loading earlier messages when at top."
  (interactive "e")
  (with-selected-window (posn-window (event-start event))
    (condition-case _err
        (mwheel-scroll event)
      (beginning-of-buffer
       (when (call-interactively #'ement-room-retro)
         (message "Loading earlier messages..."))))))

(defun ement-room-retro (session room number &optional buffer)
  ;; FIXME: Naming things is hard.
  "Retrieve NUMBER older messages in ROOM on SESSION."
  (interactive (list ement-session ement-room
                     (if current-prefix-arg
                         (read-number "Number of messages: ")
                       10)
                     (current-buffer)))
  (unless ement-room-retro-loading
    (pcase-let* (((cl-struct ement-session server token) session)
                 ((cl-struct ement-room id prev-batch) room)
                 (endpoint (format "rooms/%s/messages" (url-hexify-string id))))
      (ement-api server token endpoint
        (apply-partially #'ement-room-retro-callback room)
        :timeout 5
        :params (list (list "from" prev-batch)
                      (list "dir" "b")
                      (list "limit" (number-to-string number)))
        :else (lambda (&rest args)
                (when buffer
                  (with-current-buffer buffer
                    (setf ement-room-retro-loading nil)))
                (signal 'error (format "Ement: loading earlier messages failed (%S)" args))))
      (setf ement-room-retro-loading t))))

(declare-function ement--make-event "ement.el")
(defun ement-room-retro-callback (room data)
  "Push new DATA to ROOM on SESSION and add events to room buffer."
  (pcase-let* (((cl-struct ement-room) room)
	       ((map _start end chunk state) data)
	       (buffer (cl-loop for buffer in (buffer-list)
				when (equal room (buffer-local-value 'ement-room buffer))
				return buffer)))
    ;; FIXME: These are pushed onto the front of the lists.  Doesn't
    ;; really matter, but maybe better to put them at the other end.
    (cl-loop for event across state
	     ;; FIXME: Need to use make-event
	     do (push event (ement-room-state room)))
    (cl-loop for event across-ref chunk
	     do (setf event (ement--make-event event))
	     (push event (ement-room-timeline room)))
    (when buffer
      (with-current-buffer buffer
	(when-let* ((window (get-buffer-window buffer))
                    (point-node (with-selected-window window
                                  (ewoc-locate ement-ewoc (window-start)))))
          (cl-loop for event across chunk
                   do (ement-room--insert-event event))
          (with-selected-window (get-buffer-window buffer)
            (set-window-start nil (ewoc-location point-node))
            ;; FIXME: Experiment with this.
            (forward-line -1)))
        (setf (ement-room-prev-batch room) end
              ement-room-retro-loading nil)))))

;; FIXME: What is the best way to do this, with ement--sync being in another file?
(declare-function ement--sync "ement.el")
(defun ement-room-sync (session)
  "Sync SESSION (interactively, current buffer's)."
  (interactive (list ement-session))
  (ement--sync session))

(defun ement-room-view-event (event)
  "Pop up buffer showing details of EVENT (interactively, the one at point)."
  (interactive (list (ewoc-data (ewoc-locate ement-ewoc))))
  (require 'pp)
  (let* ((buffer-name (format "*Ement event: %s*" (ement-event-id event)))
         (event (ement-alist :id (ement-event-id event)
                             :sender (ement-user-id (ement-event-sender event))
                             :content (ement-event-content event)
                             :origin-server-ts (ement-event-origin-server-ts event)
                             :type (ement-event-type event)
                             :unsigned (ement-event-unsigned event))))
    (with-current-buffer (get-buffer-create buffer-name)
      (erase-buffer)
      (pp event (current-buffer))
      (view-mode)
      (pop-to-buffer (current-buffer)))))

(defun ement-room-send-message ()
  "Send message in current buffer's room."
  (interactive)
  (cl-assert ement-room) (cl-assert ement-session)
  (let ((body (read-string "Send message: ")))
    (unless (string-empty-p body)
      (pcase-let* (((cl-struct ement-session server token) ement-session)
                   ((cl-struct ement-room id) ement-room)
                   (endpoint (format "rooms/%s/send/%s/%s" (url-hexify-string id)
				     "m.room.message" (cl-incf (ement-session-transaction-id ement-session))))
		   (json-string (json-encode (ement-alist "msgtype" "m.text"
							  "body" body))))
        (ement-api server token endpoint
          (lambda (&rest args)
            (message "SEND MESSAGE CALLBACK: %S" args))
	  :data json-string
          :method 'put)))))

;;;; Functions

(define-derived-mode ement-room-mode fundamental-mode "Ement Room"
  "Major mode for Ement room buffers.
This mode initializes a buffer to be used for showing events in
an Ement room.  It kills all local variables, removes overlays,
and erases the buffer."
  (let ((inhibit-read-only t))
    (erase-buffer))
  (remove-overlays)
  (setf buffer-read-only t
        left-margin-width (length ement-room-timestamp-format)
        ;; TODO: Use EWOC header/footer for, e.g. typing messages.
        ement-ewoc (ewoc-create #'ement-room--pp-event)))

(defun ement-room--buffer (session room name)
  "Return a buffer named NAME showing ROOM's events on SESSION."
  (or (get-buffer name)
      (with-current-buffer (get-buffer-create name)
        (ement-room-mode)
        ;; FIXME: Move visual-line-mode to a hook.
        (visual-line-mode 1)
        (setf ement-session session
              ement-room room)
        (mapc #'ement-room--insert-event (ement-room-timeline room))
        (mapc #'ement-room--insert-event (ement-room-timeline* room))
        ;; Move new events to main list.
        (setf (ement-room-timeline room) (append (ement-room-timeline* room) (ement-room-timeline room))
              (ement-room-timeline* room) nil)
        ;; Return the buffer!
        (current-buffer))))

(defun ement-room--user-display-name (user room)
  "Return the displayname for USER in ROOM."
  ;; SPEC: <https://matrix.org/docs/spec/client_server/r0.6.1#calculating-the-display-name-for-a-user>.
  (if-let ((member-state-event (cl-loop for event in (ement-room-state room)
                                        when (and (equal "m.room.member" (ement-event-type event))
                                                  (equal user (ement-event-sender event)))
                                        return event)))
      (or (alist-get 'displayname (ement-event-content member-state-event))
          ;; FIXME: Add step 3 of the spec.  For now we skip to step 4.
          ;; No displayname given: use raw user ID.
          (ement-user-id user))
    ;; No membership state event: use pre-calculated displayname or ID.
    (or (ement-user-displayname user)
        (ement-user-id user))))

;;;;; EWOC

(defun ement-room--insert-event (event)
  "Insert EVENT into current buffer."
  (let* ((ewoc ement-ewoc)
         (event< (lambda (a b)
                   "Return non-nil if event A's timestamp is before B's."
                   (< (ement-event-origin-server-ts a)
                      (ement-event-origin-server-ts b))))
         (node-before (ement-room--ewoc-node-before ewoc event event< :pred #'ement-event-p))
         new-node)
    (setf new-node (if (not node-before)
                       (progn
                         (ement-debug "No event before it: add first.")
                         (if-let ((first-node (ewoc-nth ewoc 0)))
                             (progn
                               (ement-debug "EWOC not empty.")
                               (if (and (ement-user-p (ewoc-data first-node))
                                        (equal (ement-event-sender event)
                                               (ewoc-data first-node)))
                                   (progn
                                     (ement-debug "First node is header for this sender: insert after it, instead.")
                                     (setf node-before first-node)
                                     (ewoc-enter-after ewoc first-node event))
                                 (ement-debug "First node is not header for this sender: insert first.")
                                 (ewoc-enter-first ewoc event)))
                           (ement-debug "EWOC empty: add first.")
                           (ewoc-enter-first ewoc event)))
                     (ement-debug "Found event before new event: insert after it.")
                     (when-let ((next-node (ewoc-next ewoc node-before)))
                       (when (and (ement-user-p (ewoc-data next-node))
                                  (equal (ement-event-sender event)
                                         (ewoc-data next-node)))
                         (ement-debug "Next node is header for this sender: insert after it, instead.")
                         (setf node-before next-node)))
                     (ewoc-enter-after ewoc node-before event)))
    ;; Insert sender where necessary.
    (if (not node-before)
        (progn
          (ement-debug "No event before: Add sender before new node.")
          (ewoc-enter-before ewoc new-node (ement-event-sender event)))
      (ement-debug "Event before: compare sender.")
      (if (equal (ement-event-sender event)
                 (cl-typecase (ewoc-data node-before)
                   (ement-event (ement-event-sender (ewoc-data node-before)))
                   (ement-user (ewoc-data node-before))))
          (ement-debug "Same sender.")
        (ement-debug "Different sender: insert new sender node.")
        (ewoc-enter-before ewoc new-node (ement-event-sender event))
        (when-let* ((next-node (ewoc-next ewoc new-node)))
          (when (ement-event-p (ewoc-data next-node))
            (ement-debug "Event after from different sender: insert its sender before it.")
            (ewoc-enter-before ewoc next-node (ement-event-sender (ewoc-data next-node)))))))))

(cl-defun ement-room--ewoc-node-before (ewoc data <-fn
                                             &key (from 'last) (pred #'identity))
  "Return node in EWOC that matches PRED and belongs before DATA according to COMPARATOR."
  (cl-assert (member from '(first last)))
  (if (null (ewoc-nth ewoc 0))
      (ement-debug "EWOC is empty: returning nil.")
    (ement-debug "EWOC has data: add at appropriate place.")
    (cl-labels ((next-matching
                 (ewoc node next-fn pred) (cl-loop do (setf node (funcall next-fn ewoc node))
                                                   until (or (null node)
                                                             (funcall pred (ewoc-data node)))
                                                   finally return node)))
      (let* ((next-fn (pcase from ('first #'ewoc-next) ('last #'ewoc-prev)))
             (start-node (ewoc-nth ewoc (pcase from ('first 0) ('last -1)))))
        (unless (funcall pred (ewoc-data start-node))
          (setf start-node (next-matching ewoc start-node next-fn pred)))
        (if (funcall <-fn (ewoc-data start-node) data)
            (progn
              (ement-debug "New data goes before start node.")
              start-node)
          (ement-debug "New data goes after start node: find node before new data.")
          (let ((compare-node start-node))
            (cl-loop while (setf compare-node (next-matching ewoc compare-node next-fn pred))
                     until (funcall <-fn (ewoc-data compare-node) data)
                     finally return (if compare-node
                                        (progn
                                          (ement-debug "Found place: enter there.")
                                          compare-node)
                                      (ement-debug "Reached end of collection: insert there.")
                                      (pcase from
                                        ('first (ewoc-nth ewoc -1))
                                        ('last nil))))))))))

;;;;; Formatting

(defun ement-room--pp-event (struct)
  "Pretty-print STRUCT.
To be used as the pretty-printer for `ewoc-create'."
  (cl-etypecase struct
    (ement-event (insert "" (ement-room--format-event struct)))
    (ement-user (insert (ement-room--format-user struct)))))

(defun ement-room--format-event (event)
  "Format `ement-event' EVENT."
  (pcase-let* (((cl-struct ement-event sender type content origin-server-ts) event)
               ((map body format ('formatted_body formatted-body)) content)
               (ts (/ origin-server-ts 1000)) ; Matrix timestamps are in milliseconds.
               (body (if (not formatted-body)
                         body
                       (pcase format
                         ("org.matrix.custom.html"
                          (ement-room--render-html formatted-body))
                         (_ (format "[unknown formatted-body format: %s] %s" format body)))))
               (timestamp (propertize
                           " " 'display `((margin left-margin)
                                          ,(propertize (format-time-string ement-room-timestamp-format ts)
                                                       'face 'ement-room-timestamp))))
               (body-face (pcase type
                            ("m.room.member" 'ement-room-membership)
                            (_ (if (equal (ement-user-id sender)
                                          (ement-user-id (ement-session-user ement-session)))
				   'ement-room-self-message 'default))))
               (string (pcase type
                         ("m.room.message" body)
                         ("m.room.member" "")
                         (_ (format "[unknown event-type: %s] %s" type body)))))
    (add-face-text-property 0 (length body) body-face 'append body)
    (prog1 (concat timestamp string)
      ;; Hacky or elegant?  We return the string, but for certain event
      ;; types, we also insert a widget (this function is called by
      ;; EWOC with point at the insertion position).  Seems to work...
      (pcase type
        ("m.room.member"
         (widget-create 'ement-room-membership
			:button-face 'ement-room-membership
                        :value (list (alist-get 'membership content))))))))

(defun ement-room--render-html (string)
  "Return rendered version of HTML STRING.
HTML is rendered to Emacs text using `shr-insert-document'."
  (with-temp-buffer
    (insert string)
    (save-excursion
      (cl-letf (((symbol-function 'shr-fill-line) #'ignore))
        (shr-insert-document
         (libxml-parse-html-region (point-min) (point-max)))))
    (string-trim (buffer-substring (point) (point-max)))))

(defun ement-room--format-user (user)
  "Format `ement-user' USER for current buffer's room."
  (let ((face (if (equal (ement-user-id user) (ement-user-id (ement-session-user ement-session)))
		  'ement-room-self 'ement-room-user)))
    (propertize (or (gethash ement-room (ement-user-room-display-names user))
		    (puthash ement-room (ement-room--user-display-name user ement-room)
			     (ement-user-room-display-names user)))
		'display ement-room-username-display-property
		'face face)))

;;;;; Widgets

(require 'widget)

(define-widget 'ement-room-membership 'item
  "Widget for membership events."
  :format "%{ %v %}"
  :sample-face 'ement-room-membership)

;;;; Footer

(provide 'ement-room)

;;; ement-room.el ends here
