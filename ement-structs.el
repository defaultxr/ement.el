;;; ement-structs.el --- Ement structs               -*- lexical-binding: t; -*-

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

;;

;;; Code:


;;;; Requirements

(require 'cl-lib)

;;;; Structs

(cl-defstruct ement-user
  id displayname account-data room-display-names)

(cl-defstruct ement-event
  id sender content origin-server-ts type unsigned)

(cl-defstruct ement-server
  hostname port)

(cl-defstruct ement-session
  user server token transaction-id rooms next-batch)

(cl-defstruct ement-room
  id display-name
  summary state timeline timeline* ephemeral account-data unread-notifications)

;;;; Variables


;;;; Customization


;;;; Commands


;;;; Functions


;;;; Footer

(provide 'ement-structs)

;;; ement-structs.el ends here