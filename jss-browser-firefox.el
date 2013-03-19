;;; jss-browser-firefox.el -- firefox implementation of jss's browser api
;;
;; Copyright (C) 2013 Edward Marco Baringer
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation; either version 2 of
;; the License, or (at your option) any later version.
;;
;; This program is distributed in the hope that it will be
;; useful, but WITHOUT ANY WARRANTY; without even the implied
;; warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
;; PURPOSE. See the GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public
;; License along with this program; if not, write to the Free
;; Software Foundation, Inc., 59 Temple Place, Suite 330, Boston,
;; MA 02111-1307 USA

;;; https://wiki.mozilla.org/Remote_Debugging_Protocol
;;; https://developer.mozilla.org/en-US/docs/Tools/Web_Console/remoting

;;; file:///mozilla-release/toolkit/devtools/debugger/dbp-client.jsm

;;; marco's understanding of the firefox remote debugging api (the
;;; syntax is a little home grown, the thing before the dot is the
;;; target, the thing aftre the dot is the type, the thing in { } are
;;; the, named, parameters, that is followed by a very hand wavy
;;; description of the returned object.

;;; firefox's api is structured around actors, actors are objects that
;;; you can send messages to (in the firefox docs these are refered to
;;; as packets, for consistency with all the other actor based stuff
;;; in the world, we call them messages here), and they will then
;;; anwser, or they can send you (the client) events. every actor has
;;; a globally unique id, a list of message types it can respond to,
;;; or send, and a state, which is exactly one of (in this description
;;; 'we' are the client):

;;; :idle - the actor is waiting for us to send a message to it

;;; :waiting - we have sent a message to the actor and we're waiting
;;;            for a response back

;;; :listening - we are waiting for messages from the actor (these
;;; messages will arrive without us doing anything)

;;; the only allowed state transitions are:

;;; :idle -> send-message -> :waiting -> handle-message -> :idle


;;; :idle -> start-listening -> :listening

;;; :listening -> stop-listening -> :idle

;;; Note: To make things a little bit simple all actor objects are
;;; kept in slots with CamelCase names.

;;; Known actor messages:

;;; Get the list of tabs on the browser:

;;; "root".listTabs { } -> {
;;;   "from": "root"
;;;   "selected": an integer with the currently selected (focused) tab
;;;   "tabs": an array of { actor: , title:, url:, consoleActor: }
;;;      title and url are strings. actor is the tab actor while
;;;      consoleActor is for console log messages (i assume)
;;;   "chromeDebugger": ?
;;;   "consoleActor": ?
;;;   "profilerActor": ?
;;; }

;;; Attach a debugger to a tab. Only after this message has been
;;; handled can we send the we get a consoleActor, with the
;;; consoleActor we can start the listeners.

;;; aTabActor."attach" {} -> {}

;;; Detach from a tab. This will, automatically and whether we like it
;;; or not, release all the tab related actors on the server.

;;; aTabActor."dettach" {} -> {}

;;; aTabActor can send an unsolicited messages when the user closes a
;;; tab or navigates to another tab

;;; aConsoleActor."startListeners" { listeners: [ ] } -> { }
;;;
;;;   listeners is an array of strings, each of which is either
;;;   "PageError", "ConsoleAPI", "NetworkActivity", "FileActivity",
;;;   "LocationChange"
;;; 
;;;   must follow aTabActor.attach (i think)

(defclass jss-firefox-browser (jss-generic-browser)
  ((connection :accessor jss-firefox-browser-connection :initform nil)
   (RootActor :accessor jss-firefox-browser-RootActor)
   (connected :accessor jss-browser-connected-p :initform nil)))

(defmethod jss-browser-description ((browser jss-firefox-browser))
  (format "Mozilla Firefox @ %s:%s\nNB: Only displaying tabs that can be debugged."
          (slot-value browser 'host) (slot-value browser 'port)))

(defmethod jss-browser-cleanup ((browser jss-firefox-browser))
  (jss-log-event (list :firefox :browser :cleanup browser))
  (setf (jss-browser-connected-p browser) nil)
  (jss-when-bind (conn (jss-firefox-browser-connection browser))
    (jss-firefox-connection-disconnect (jss-firefox-browser-connection browser))))

(defmethod jss-browser-find-tab ((browser jss-firefox-browser) tab-id)
  (find tab-id (slot-value browser 'tabs) :key 'jss-tab-id :test 'string=))

(defmethod jss-browser-tabs ((browser jss-firefox-browser))
  (slot-value browser 'tabs))

(defmethod jss-browser-get-tabs ((browser jss-firefox-browser))
  (lexical-let ((browser browser)
                (tabs-deferred (make-jss-deferred)))
    (jss-deferred-then
     (jss-firefox-send-message (jss-firefox-browser-RootActor browser) "listTabs")
     (lambda (response)
       (loop for properites across (cdr (assoc 'tabs response))
             for existing-tab = (jss-browser-find-tab browser (cdr (assoc 'actor properites)))
             if existing-tab
               do (let ((current-consoleActor (cdr (assoc 'consoleActor (slot-value existing-tab 'properites))))
                        (new-consoleActor (cdr (assoc 'consoleActor properites))))
                    (unless (string= current-consoleActor new-consoleActor)
                      (error "Console Actor has unexpectedly changed on %s. from %s to %s" existing-tab current-consoleActor new-consoleActor))
                    (setf (slot-value existing-tab 'properites) properites))
             else
               do (push (make-instance 'jss-firefox-tab
                                       :properties properites
                                       :browser browser)
                        (slot-value browser 'tabs)) 
             finally (jss-log-event (list :firefox :tabsListed (jss-browser-tabs browser)))
             finally (jss-deferred-callback tabs-deferred browser))))
    tabs-deferred))

(defclass jss-firefox-connection ()
  ((browser :initarg :browser :accessor jss-firefox-connection-browser)
   (host :initarg :host :initform "127.0.0.1")
   (port :initarg :port :initform 6000)
   (proc :initarg :proc)
   (state :initform nil)

   (open-deferred :accessor jss-firefox-connection-open-deferred)
   (close-deferred :accessor jss-firefox-connection-close-deferred)
   
   (actors :initform (make-hash-table :test 'equal) :accessor jss-firefox-connection-actors)))

(make-variable-buffer-local
 (defvar jss-current-connection-instance nil
   "The current, firefox, connection attached to a process."))

(defmethod jss-browser-connect ((browser jss-firefox-browser))
  (lexical-let ((browser browser)
                (RootActor (make-instance 'jss-firefox-RootActor
                                          :state :listening)))
    (let* ((conn (make-instance 'jss-firefox-connection
                                :browser browser
                                :host (jss-browser-host browser)
                                :port (let ((port (jss-browser-port browser)))
                                        (if (stringp port)
                                            (string-to-number port)
                                          port)))))
      
      (jss-firefox-connection-connect conn)

      (jss-deferred-then
       (jss-firefox-connection-open-deferred conn)
       (lambda (conn)
         (setf (jss-firefox-browser-connection browser) conn)
         ;; firefox will always send us an unsolicited 'hello' message
         ;; when the connection opens, so setup a handler for it (it's
         ;; only after this message that we can start sending requests).
         (setf (jss-firefox-browser-RootActor browser) (jss-firefox-register-actor browser RootActor))))

      (jss-deferred-then
       (jss-firefox-connection-close-deferred conn)
       (lambda (conn)
         (dolist (tab (jss-browser-tabs browser))
           (when (jss-tab-console tab)
             (jss-console-error-message (jss-tab-console tab) "Connection closed.")))))

      (jss-firefox-RootActor-ready-deferred RootActor))))

(defmethod jss-firefox-connection-send-string ((conn jss-firefox-connection) json)
  (process-send-string (slot-value conn 'proc) json))

(defun jss-firefox-process-filter (proc string)
  (jss-log-event (list :firefox :filter string))
  (when (buffer-live-p (process-buffer proc))
    (save-match-data
      (with-current-buffer (process-buffer proc)
        (goto-char (point-max))
        (insert string)

        (loop
         do (goto-char (point-min))
         when (eobp)
           do (return t)
         unless (looking-at "\\([0-9]+\\):")
           do (error "jss process filter syntax error, message at %s does not start with \\d+" (point))
         do (let ((prefix (match-string 0))
                  (length (string-to-number (match-string 1))))
              (goto-char (match-end 0))
              (if (< length (- (point-max) (length prefix)))
                  (let ((json (json-read)))
                    (delete-region (point-min) (point))
                    (jss-firefox-handle-message jss-current-connection-instance json)
                    (goto-char (point-min)))
                (jss-log-event (list :firefox :process-filter :message-incomplete))
                (return nil))))))))

(defun jss-firefox-process-sentinel (proc event)
  (jss-log-event (list :firefox :sentinel proc event))
  (with-current-buffer (process-buffer proc)
    (let* ((connection (or jss-current-connection-instance
                           (error "Proc buffer %s has no connection, but get proc event %s on %s." (current-buffer) event proc))))
      
      (with-slots (state) connection
        (setf state (cond
                     ((string= "open\n" event)
                      (unless (eql nil state)
                        (error "Invalid state transition. Was %s but got a %s event on %s.") state event proc)
                      :open)
                     ((cl-member event '("deleted\n" "finished\n" "connection broken by remote peer\n") :test 'string=)
                      (unless (eql :open state)
                        (error "Invalid state transition. Was %s but got a %s event on %s.") state event proc)
                      :closed)
                     (t (error "Unknown process event %s" (prin1-to-string event)))))
        (ecase state
          (:open (jss-firefox-connection-on-open connection))
          (:closed (jss-firefox-connection-on-close connection))))))
  t)

(defmethod jss-firefox-connection-connect ((conn jss-firefox-connection))
   (when (slot-boundp conn 'proc)
     (error "Attempting to connect to %s but it already has a process." conn))
  (with-slots (host port proc open-deferred close-deferred)
      conn
   
    (setf proc (make-network-process :name "firefox connection"
                                     :buffer (generate-new-buffer (format " *firefox@%s:%s*" host port))
                                     :server nil
                                     :host host
                                     :service port
                                     :coding '(utf-8 . utf-8)
                                     :nowait t
                                     :filter 'jss-firefox-process-filter))
    
    (when (slot-boundp conn 'open-deferred)
      (error "Attempting to connect to %s, but it already has an open-deferred." conn))
    (setf (jss-firefox-connection-open-deferred conn) (make-jss-deferred))
    
    (when (slot-boundp conn 'close-deferred)
      (error "Attempting to connect to %s, but it already has a close-deferred." conn))
    (setf (jss-firefox-connection-close-deferred conn) (make-jss-deferred))
    
    (set-process-sentinel proc 'jss-firefox-process-sentinel)
    (with-current-buffer (process-buffer proc)
      (setf jss-current-connection-instance conn)))
  conn)

(defmethod jss-firefox-connection-on-open ((conn jss-firefox-connection))
  (unless (slot-boundp conn 'open-deferred)
    (error "Connection %s has opened, but no open-deferred availble. state mis-match?"))
  (jss-deferred-callback (slot-value conn 'open-deferred) connection)
  (slot-makeunbound conn 'open-deferred))

(defmethod jss-firefox-connection-on-close ((conn jss-firefox-connection))
  (jss-log-event (list :firefox :connection :on-close conn))
  (unless (slot-boundp conn 'close-deferred)
    (error "Connection %s has closed, but no close-deferred availble. state mis-match?" conn))
  (unless (slot-boundp conn 'proc)
    (error "Connection %s has closed, but no proc. impossible state mis-match?" conn))
  (with-slots (close-deferred proc)
      conn
    (unless (processp proc)
      (error "Connect %s has closed, but its proc %s is not a process." conn proc))
    (delete-process proc)
    (kill-buffer (process-buffer proc))

    (jss-deferred-callback close-deferred connection)
    (slot-makeunbound conn 'close-deferred)))

(defclass jss-firefox-actor ()
  ((id :accessor jss-firefox-actor-id :initarg :id)
   (connection :accessor jss-firefox-actor-connection :initarg :connection)
   (message-queue :accessor jss-firefox-actor-message-queue :initform (make-jss-queue))
   (response-deferred :accessor jss-firefox-actor-response-deferred :initform nil)
   (state :accessor jss-firefox-actor-state
          :initform :idle
          :initarg :state
          :documentation "Either :idle, :waiting or :listening.")))

(defmethod jss-firefox-register-actor ((connection jss-firefox-connection) actor)
  (when (jss-firefox-actor-connection actor)
    (error "Attempting to register actor %s on %s, but it is already register on %s."
           actor connection (jss-firefox-actor-connection actor)))
  (setf (jss-firefox-actor-connection actor) connection
        (gethash (jss-firefox-actor-id actor) (jss-firefox-connection-actors connection)) actor)
  actor)

(defmethod jss-firefox-register-actor ((browser jss-firefox-browser) actor)
  (jss-firefox-register-actor (jss-firefox-browser-connection browser) actor))

(defmethod jss-firefox-actor-start-listening ((actor jss-firefox-actor))
  (if (eql :idle (jss-firefox-actor-state actor))
      (setf (jss-firefox-actor-state actor) :listening)
    (error "Actor has message in transit (current state %s), can't start listening now." (jss-firefox-actor-state actor))))

(defmethod jss-firefox-actor-stop-listening ((actor jss-firefox-actor))
  (if (eql :listening (jss-firefox-actor-state actor))
      (setf (jss-firefox-actor-state actor) :idle)
    (error "Actor is not currently listing (current state %s), can't stop." (jss-firefox-actor-state actor))))

(defmethod jss-firefox-actor-handle-event :before ((actor jss-firefox-actor) event-json)
  (when (eql :idle (jss-firefox-actor-state actor))
    (error "Actor is not ready to handle messages (current state is :idle).")))

(defmethod jss-firefox-send-message ((actor jss-firefox-actor) type &rest other-arguments)
  ; (jss-log-event (list :firefox :send-message actor type other-arguments))
;  (when (eql :listening (jss-firefox-actor-state actor))
;    (error "Attempt to send message %s to %s but this actor is currently listening." type actor))
  (lexical-let ((previous-state (jss-firefox-actor-state actor)))
    (setf (jss-firefox-actor-state actor) :idle)
    (unless (slot-boundp actor 'id)
      (error "Attempt to send message %s to %s, but this actor has no id." type actor))
    (let* ((deferred (make-jss-deferred))
           (message (list* (cons "to" (jss-firefox-actor-id actor))
                           (cons "type" type)
                           (loop
                            for (key value) on other-arguments by 'cddr
                            collect (cons key value)))))
      (jss-enqueue (jss-firefox-actor-message-queue actor) (cons message deferred))
      (jss-firefox-connection-process-next-message actor)
      (jss-deferred-add-callback
       deferred
       (lambda (value)
         (setf (jss-firefox-actor-state actor) previous-state)))
      deferred)))

(defun jss-firefox-encode-json-message (object)
  (let ((json-false :json-false)
        (json-null nil))
    (let ((string (json-encode object)))
      (format "%d:%s" (length string) string))))

(defmethod jss-firefox-connection-process-next-message ((actor jss-firefox-actor))
  (when (eql :idle (jss-firefox-actor-state actor))
    (destructuring-bind (message . deferred)
        (jss-dequeue (jss-firefox-actor-message-queue actor))
      (let ((json (jss-firefox-encode-json-message message)))
        (jss-log-event (list :firefox :process-message (jss-firefox-actor-id actor) message json deferred))
        (setf (jss-firefox-actor-state actor) :waiting
              (jss-firefox-actor-response-deferred actor) deferred)
        (jss-firefox-connection-send-string (jss-firefox-actor-connection actor) json)
        actor))))

(defmethod jss-firefox-handle-message ((connection jss-firefox-connection) json)
  ;(jss-log-event (list :firefox :handle-message json))
  (jss-with-alist-values (from)
      json
    (let ((actor (gethash from (jss-firefox-connection-actors connection))))
      (unless actor
        (error "Got message %s but don't have an actor with id %s."))
      (ecase (jss-firefox-actor-state actor)
        (:idle
         (error "Got message %s for %s, but actor's state is :idle." json actor))
        (:waiting
         (let ((deferred (jss-firefox-actor-response-deferred actor)))
           (unless deferred
             (error "Got message %s for %s, whose state is infact :waiting, but no response-handler found." json actor))
           (setf (jss-firefox-actor-state actor) :idle
                 (jss-firefox-actor-response-deferred actor) nil)
           (jss-deferred-callback deferred json)))
        (:listening
         (jss-firefox-actor-handle-event actor json))))))

(defclass jss-firefox-RootActor (jss-firefox-actor)
  ((ready-deferred :initform (make-jss-deferred) :accessor jss-firefox-RootActor-ready-deferred)))

(defmethod shared-initialize :after ((actor jss-firefox-RootActor) slot-names)
  (unless (slot-boundp actor 'id)
    (setf (jss-firefox-actor-id actor) "root")))

(defmethod jss-firefox-actor-handle-event ((actor jss-firefox-RootActor) event)
  (jss-with-alist-values (applicationType traits)
      event
    (unless (string= "browser" applicationType)
      (error "applicationType is not browser: %s" event))

    (let ((deferred (slot-value actor 'ready-deferred)))
      (slot-makeunbound actor 'ready-deferred)
      (jss-firefox-actor-stop-listening actor)
      (jss-deferred-callback deferred (jss-firefox-connection-browser (jss-firefox-actor-connection actor)))))
  
  actor)

(defclass jss-firefox-tab (jss-generic-tab)
  ((properites :initarg :properties)
   (Actor :accessor jss-firefox-tab-Actor)
   (ConsoleActor :accessor jss-firefox-tab-ConsoleActor)
   (ThreadActor :accessor jss-firefox-tab-ThreadActor)))

(defmethod jss-firefox-register-actor ((tab jss-firefox-tab) actor)
  (jss-firefox-register-actor (jss-tab-browser tab) actor))

(defmethod shared-initialize :after ((tab jss-firefox-tab) slots)
  (when (and (slot-boundp tab 'browser)
             (slot-boundp tab 'properites))
    (jss-with-alist-values (actor consoleActor)
        (slot-value tab 'properites)

      (unless (and actor consoleActor)
        (error "Attempting to create a tab from properties %s, but required fields actor and consoleActor are missing."
               (slot-value tab 'properties)))

      (message "actor: %s, consoleActor: %s" actor consoleActor)
      
      (let ((browser (jss-tab-browser tab)))
          
        (setf (jss-firefox-tab-Actor tab)
              (jss-firefox-register-actor browser (make-instance 'jss-firefox-TabActor :id actor))
              (jss-firefox-tab-ConsoleActor tab)
              (jss-firefox-register-actor browser (make-instance 'jss-firefox-ConsoleActor
                                                                 :console (jss-tab-console tab)
                                                                 :id consoleActor)))))))

(defmethod jss-firefox-tab-property ((tab jss-firefox-tab) property-name)
  (cdr (assoc property-name (slot-value tab 'properites))))

(defmethod jss-tab-url ((tab jss-firefox-tab))
  (jss-firefox-tab-property tab 'url))

(defmethod jss-tab-title ((tab jss-firefox-tab))
  (jss-firefox-tab-property tab 'title))

(defmethod jss-tab-id ((tab jss-firefox-tab))
  (jss-firefox-actor-id (jss-firefox-tab-Actor tab)))

(defmethod jss-tab-available-p ((tab jss-firefox-tab))
  (not (null (jss-firefox-tab-property tab 'consoleActor))))

(defmethod jss-firefox-make-actor ((tab jss-firefox-tab) id)
  (jss-firefox-make-actor (jss-tab-browser tab) id))

(defmethod jss-tab-connected-p ((tab jss-firefox-tab))
  (eql :listening (jss-firefox-actor-state (jss-firefox-tab-ConsoleActor tab))))

(defmethod jss-tab-connect ((tab jss-firefox-tab))
  (lexical-let ((tab tab)
                (deferred (make-jss-deferred))
                (requested-listeners ["ConsoleAPI" "FileActivity" "LocationChange" "NetworkActivity" "PageError"]))
    (jss-deferred-then
     (jss-firefox-send-message (jss-firefox-tab-Actor tab) "attach")
     (lambda (response)
       (jss-with-alist-values (type threadActor)
           response
         (unless (string= "tabAttached" type)
           (error "Unexpected response to %s.attach: %s" (jss-tab-id tab) response))
         (lexical-let ((ThreadActor (make-instance 'jss-firefox-ThreadActor :id threadActor)))
           (setf (jss-firefox-tab-ThreadActor tab)
                 (jss-firefox-register-actor (jss-tab-browser tab) ThreadActor))
           (jss-deferred-then
            (jss-firefox-send-message ThreadActor "attach")
            (lambda (response)
              (unless (and (string= "paused" (cdr (assoc 'type response)))
                           (cdr (assoc 'type (cdr (assoc 'why response))))
                           (string= "attached" (cdr (assoc 'type (cdr (assoc 'why response))))))
                (error "Unexpected response from attach message: %s." response))
              (jss-deferred-then
               (jss-firefox-send-message ThreadActor "resume" "pauseOnExceptions" t)
               (lambda (response)
                 (jss-deferred-then
                  (jss-firefox-send-message (jss-firefox-console-Actor (jss-tab-console tab))
                                            "startListeners"
                                            "listeners"
                                            requested-listeners)
                  (lambda (response)
                    (jss-with-alist-values (startedListeners)
                        response
                      (unless (equal requested-listeners (cl-sort startedListeners 'string<))
                        (error "Not all listeners started, only: %s" startedListeners))
                      (jss-firefox-actor-start-listening (jss-firefox-tab-ConsoleActor tab))
                      (jss-deferred-callback deferred tab))))))))))))
    deferred))

(defclass jss-firefox-TabActor (jss-firefox-actor)
  ())

(defclass jss-firefox-ThreadActor (jss-firefox-actor)
  ())

(defclass jss-firefox-console (jss-generic-console)
  ())

(defmethod jss-firefox-console-Actor ((console jss-firefox-console))
  (jss-firefox-tab-ConsoleActor (jss-console-tab console)))

(defmethod jss-tab-make-console ((tab jss-firefox-tab) &rest initargs)
  (apply 'make-instance jss-firefox-console initargs))

(defmethod jss-console-close ((console jss-firefox-console))
  (make-jss-completed-deferred console))

(defclass jss-firefox-actor-with-console-mixin ()
  ((console :accessor jss-firefox-ConsoleActor-console :initarg :console)))

(defclass jss-firefox-ConsoleActor (jss-firefox-actor jss-firefox-actor-with-console-mixin)
  ())

(defclass jss-firefox-NetworkEvent (jss-firefox-actor jss-firefox-actor-with-console-mixin)
  ())

(defclass jss-firefox-PageError (jss-firefox-actor jss-firefox-actor-with-console-mixin)
  ())

(defmethod jss-firefox-actor-handle-event ((ConsoleActor jss-firefox-ConsoleActor) event)
  (jss-with-alist-values (type)
      event
    (cond
     ((string= type "networkEvent")
      (jss-with-alist-values (actor)
          (cdr (assoc 'eventActor event))
        (jss-firefox-register-actor (jss-firefox-actor-connection ConsoleActor)
                                    (make-instance 'jss-firefox-NetworkEvent
                                                   :console (jss-firefox-ConsoleActor-console actor)
                                                   :id actor
                                                   :state :listening))))
     ((string= type "pageError")
      (jss-with-alist-values (actor)
          (cdr (assoc 'pageError event))
        (jss-firefox-register-actor (jss-firefox-actor-connection ConsoleActor)
                                    (make-instance 'jss-firefox-PageError
                                                   :console (jss-firefox-ConsoleActor-console actor)
                                                   :id actor
                                                   :state :listening))))
     ((string= type "locationChange")
      (jss-with-alist-values (url title state)
          event
        )))))

(defmethod jss-evaluate ((console jss-firefox-console) text)
  (lexical-let* ((console console)
                 (Actor (jss-firefox-console-Actor console))
                 (connection (jss-firefox-actor-connection Actor )))
    (jss-deferred-then
     (jss-firefox-send-message Actor "evaluateJS" "text" text)
     (lambda (response)
       (jss-with-alist-values (input result error errorMessage helperResult)
           response
         (make-jss-firefox-remote-object connection result))))))

(defclass jss-firefox-remote-object-mixin ()
  ((Actor :initarg :Actor)
   (properties :initarg :properties)))

(defmethod jss-remote-object-class-name ((object jss-firefox-remote-object-mixin))
  (cdr (assoc 'className (slot-value object 'properties))))

(defmethod jss-remote-object-label ((object jss-firefox-remote-object-mixin))
  (jss-firefox-remote-object-displayString object))

(defmethod jss-firefox-remote-object-displayString ((object jss-firefox-remote-object-mixin))
  (cdr (assoc 'displayString (slot-value object 'properties))))

(defclass jss-firefox-remote-object (jss-generic-remote-object jss-firefox-remote-object-mixin)
  ())

(defclass jss-firefox-ObjectActor (jss-firefox-actor)
  ())

(defclass jss-firefox-remote-function (jss-generic-remote-function jss-firefox-remote-object-mixin)
  ())

(defmethod jss-remote-value-description ((function jss-firefox-remote-function))
  (replace-regexp-in-string "[ \t\n\r\f]+"
                            " "
                            (jss-firefox-remote-object-displayString function)))

(defun make-jss-firefox-remote-object (connection result)
  (cond
   ((numberp result)
    (make-instance 'jss-generic-remote-number :value result))
   ((stringp result)
    (make-instance 'jss-generic-remote-string :value result))
   ((eql t result)
    (make-instance 'jss-generic-remote-true))
   ((eql nil result)
    (make-instance 'jss-generic-remote-no-value))
   ((eql :json-false result)
    (make-instance 'jss-generic-remote-false))
   ((consp result)
    (jss-with-alist-values (type className actor)
        result
      (cond
       ((string= "function" type)
        (make-instance 'jss-firefox-remote-function
                       :Actor (jss-firefox-register-actor connection (make-instance 'jss-firefox-ObjectActor :id actor))
                       :properties result))
       ((string= "object" type)
        (make-instance 'jss-firefox-remote-object
                       :Actor (jss-firefox-register-actor connection (make-instance 'jss-firefox-ObjectActor :id actor))
                       :properties result))
       ((string= "null" type)
        (make-instance 'jss-generic-remote-null))
       ((string= "undefined" type)
        (make-instance 'jss-generic-remote-undefined)))))))

(defmethod jss-remote-object-get-properties ((object jss-firefox-remote-object-mixin) tab)
  (lexical-let ((Actor (slot-value object 'Actor)))
;     (if (cdr (assoc 'inspectable (slot-value object 'properties)))
;         (jss-deferred-then
;          (jss-firefox-send-message Actor "inspectProperties")
;          (lambda (result)
;            (jss-firefox-make-object-properties (jss-firefox-actor-connection Actor) (cdr (assoc 'properties result)))))
;       (make-jss-completed-deferred '()))

    (jss-deferred-then
     (jss-firefox-send-message Actor "inspectProperties")
     (lambda (result)
       (jss-firefox-make-object-properties (jss-firefox-actor-connection Actor) (cdr (assoc 'properties result)))))
    
    ))

(defun jss-firefox-make-object-properties (connection property-array)
  (loop for p across property-array
        collect (cons (cdr (assoc 'name p))
                      (make-jss-firefox-remote-object connection (cdr (assoc 'value p))))))

(provide 'jss-browser-firefox)
