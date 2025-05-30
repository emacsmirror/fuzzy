;;; fuzzy.el --- Fuzzy Matching                    -*- lexical-binding: t -*-

;; Copyright (C) 2010-2015  Tomohiro Matsuyama
;; Copyright (c) 2020-2025 Jen-Chieh Shen

;; Author: Tomohiro Matsuyama <m2ym.pub@gmail.com>
;; Keywords: convenience
;; URL: https://github.com/auto-complete/fuzzy-el
;; Keywords: lisp fuzzy
;; Version: 0.3
;; Package-Requires: ((emacs "24.3"))

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;; This package implements fuzzy matching, completion and searching,
;; using Jaro Winkler Distance or QuickSilver's abbreviation scoring.

;;; Code:

(require 'cl-lib)
(require 'regexp-opt)

(defgroup fuzzy nil
  "Fuzzy Matching"
  :group 'convenience
  :prefix "fuzzy-")


;;; Utilities

(defun fuzzy-current-time-float ()
  (let ((time (current-time)))
    (+ (* (float (cl-first time)) (lsh 2 16))
       (float (cl-second time))
       (/ (float (cl-third time)) 1000000))))

(cl-defmacro fuzzy-with-stopwatch
    ((&optional (elapsed-name 'elapsed))
     &body body)
  (declare (indent 1))
  (let ((start (gensym "START")))
    `(let ((,start (fuzzy-current-time-float)))
       (cl-flet ((,elapsed-name () (- (fuzzy-current-time-float) ,start)))
         ,@body))))

(cl-defun fuzzy-add-to-list-as-sorted
    (list-var value &key (test '<) (key 'identity))
  (let ((list (symbol-value list-var)))
    (if (or (null list)
            (funcall test
                     (funcall key value)
                     (funcall key (car list))))
        (set list-var (cons value list))
      (while (and list
                  (cdr list)
                  (funcall test
                           (funcall key (cadr list))
                           (funcall key value)))
        (setq list (cdr list)))
      (setcdr list (cons value (cdr list))))))

(cl-defmacro fuzzy-with-timeout
    ((timeout &optional timeout-result (tick-name 'tick))
     &body body)
  (declare (indent 1))
  (let ((elapsed (gensym "ELAPSED")))
    `(catch 'timeout
       (fuzzy-with-stopwatch (,elapsed)
                             (cl-flet ((,tick-name
                                        ()
                                        (when (and ,timeout (< ,timeout (,elapsed)))
                                          (throw 'timeout ,timeout-result))))
                               ,@body)))))

(defun fuzzy-count-matches-in-string (regexp string &optional start end)
  (setq start (or start 0)
        end   (or end (length string)))
  (cl-loop for start = start then (1+ matched)
           for matched = (let ((case-fold-search nil))
                           (string-match regexp string start))
           while (and matched (< (1+ matched) end))
           count matched))


;;; Jaro-Winkler Distance

(defun fuzzy-jaro-winkler-distance (s1 s2)
  "Compute Jaro-Winkler distance.
See http://en.wikipedia.org/wiki/Jaro-Winkler_distance."
  (let* ((l1 (length s1))
         (l2 (length s2))
         (r (max 1 (1- (/ (max l1 l2) 2))))
         (m 0)
         (tr 0)
         (p 0)
         cs1 cs2)
    (cl-loop with seen = (make-vector l2 nil)
             for i below l1
             for c1 = (aref s1 i)
             do
             (cl-loop for j from (max 0 (- i r)) below (min l2 (+ i r))
                      for c2 = (aref s2 j)
                      if (and (char-equal c1 c2)
                              (null (aref seen j)))
                      do
                      (push c1 cs1)
                      (aset seen j c2)
                      (cl-incf m)
                      and return nil)
             finally
             (setq cs1 (nreverse cs1)
                   cs2 (cl-loop for i below l2
                                for c = (aref seen i)
                                if c collect c)))
    (cl-loop for c1 in cs1
             for c2 in cs2
             if (not (char-equal c1 c2))
             do (cl-incf tr))
    (cl-loop for i below (min m 5)
             for c1 across s1
             for c2 across s2
             while (char-equal c1 c2)
             do (cl-incf p))
    (if (eq m 0)
        0.0
      (setq m (float m))
      (let* ((dj (/ (+ (/ m l1) (/ m l2) (/ (- m (/ tr 2)) m)) 3))
             (dw (+ dj (* p 0.1 (- 1 dj)))))
        dw))))

;; Make sure byte-compiled.
(cl-eval-when (eval)
  (byte-compile 'fuzzy-jaro-winkler-distance))

(defalias 'fuzzy-jaro-winkler-score 'fuzzy-jaro-winkler-distance)


;;; Fuzzy Matching

(defcustom fuzzy-match-score-function 'fuzzy-jaro-winkler-score
  "Score function for fuzzy matching."
  :type 'function
  :group 'fuzzy)

(defcustom fuzzy-match-accept-error-rate 0.10
  "Fuzzy matching error threshold."
  :type 'number
  :group 'fuzzy)

(defcustom fuzzy-match-accept-length-difference 2
  "Fuzzy matching length difference threshold."
  :type 'number
  :group 'fuzzy)

(defvar fuzzy-match-score-cache
  (make-hash-table :test 'equal :weakness t))

(defun fuzzy-match-score (s1 s2 function)
  (let ((cache-key (list function s1 s2)))
    (or (gethash cache-key fuzzy-match-score-cache)
        (puthash cache-key
                 (funcall function s1 s2)
                 fuzzy-match-score-cache))))

(cl-defun fuzzy-match (s1 s2 &optional (function fuzzy-match-score-function))
  "Return t if S1 and S2 are matched.
FUNCTION is a function scoring between S1 and S2.
The score must be between 0.0 and 1.0."
  (and (<= (abs (- (length s1) (length s2)))
           fuzzy-match-accept-length-difference)
       (>= (fuzzy-match-score s1 s2 function)
           (- 1 fuzzy-match-accept-error-rate))))


;;; Fuzzy Completion

(defun fuzzy-all-completions (string collection)
  "Like `all-completions' but with fuzzy matching."
  (cl-loop with length = (length string)
           for str in collection
           for len = (min (length str)
                          (+ length fuzzy-match-accept-length-difference))
           if (fuzzy-match string (substring str 0 len))
           collect str))


;;; Fuzzy Search

(defvar fuzzy-search-some-char-regexp
  (format ".\\{0,%s\\}" fuzzy-match-accept-length-difference))

(defun fuzzy-search-regexp-compile (string)
  (cl-flet ((opt
             (n)
             (regexp-opt-charset
              (append (substring string
                                 (max 0 (- n 1))
                                 (min (length string) (+ n 2)))
                      nil))))
    (concat
     "\\("
     (cl-loop for i below (length string)
              for c = (if (cl-evenp i) (opt i) fuzzy-search-some-char-regexp)
              concat c)
     "\\|"
     (cl-loop for i below (length string)
              for c = (if (cl-oddp i) (opt i) fuzzy-search-some-char-regexp)
              concat c)
     "\\)")))

(defun fuzzy-search-forward (string &optional bound _noerror _count)
  (let ((regexp (fuzzy-search-regexp-compile string))
        match-data)
    (save-excursion
      (while (and (null match-data)
                  (re-search-forward regexp bound t))
        (if (fuzzy-match string (match-string 1))
            (setq match-data (match-data))
          (goto-char (1+ (match-beginning 1))))))
    (when match-data
      (store-match-data match-data)
      (goto-char (match-end 1)))))

(defun fuzzy-search-backward (string &optional bound _noerror _count)
  (let* ((regexp (fuzzy-search-regexp-compile string))
         match-data begin end)
    (save-excursion
      (while (and (null match-data)
                  (re-search-backward regexp bound t))
        (setq begin (match-beginning 1)
              end   (match-end 1))
        (store-match-data nil)
        (goto-char (max (point-min) (- begin (* (length string) 2))))
        (while (re-search-forward regexp end t)
          (if (fuzzy-match string (match-string 1))
              (setq match-data (match-data))
            (goto-char (1+ (match-beginning 1)))))
        (unless match-data
          (goto-char begin)))
      (if match-data
          (progn
            (store-match-data match-data)
            (goto-char (match-beginning 1)))
        (store-match-data nil)))))


;;; Fuzzy Incremental Search

(defvar fuzzy-isearch nil)
(defvar fuzzy-isearch-failed-count 0)
(defvar fuzzy-isearch-enabled 'on-failed)
(defvar fuzzy-isearch-original-search-fun nil)
(defvar fuzzy-isearch-message-prefix
  (concat (propertize "[FUZZY]" 'face 'bold) " "))

(defun fuzzy-isearch-activate ()
  (setq fuzzy-isearch t)
  (setq fuzzy-isearch-failed-count 0))

(defun fuzzy-isearch-deactivate ()
  (setq fuzzy-isearch nil)
  (setq fuzzy-isearch-failed-count 0))

(defun fuzzy-isearch ()
  (cond ((or (bound-and-true-p isearch-word)            ; emacs <  25.1
             (bound-and-true-p isearch-regexp-function) ; emacs >= 25.1
             isearch-regexp)
         (isearch-search-fun-default))
        ((or fuzzy-isearch
             (eq fuzzy-isearch-enabled 'always)
             (and (eq fuzzy-isearch-enabled 'on-failed)
                  (null isearch-success)
                  isearch-wrapped
                  (> (cl-incf fuzzy-isearch-failed-count) 1)))
         (unless fuzzy-isearch
           (fuzzy-isearch-activate))
         (if isearch-forward 'fuzzy-search-forward 'fuzzy-search-backward))
        (t
         (if isearch-forward 'search-forward 'search-backward))))

(defun fuzzy-isearch-end-hook ()
  (fuzzy-isearch-deactivate))

(defun turn-on-fuzzy-isearch ()
  (interactive)
  (setq fuzzy-isearch-original-search-fun isearch-search-fun-function)
  (setq isearch-search-fun-function 'fuzzy-isearch)
  (add-hook 'isearch-mode-end-hook 'fuzzy-isearch-end-hook))

(defun turn-off-fuzzy-isearch ()
  (interactive)
  (setq isearch-search-fun-function fuzzy-isearch-original-search-fun)
  (remove-hook 'isearch-mode-end-hook 'fuzzy-isearch-end-hook))

(defadvice isearch-message-prefix (after fuzzy-isearch-message-prefix activate)
  (if fuzzy-isearch
      (setq ad-return-value
            (concat fuzzy-isearch-message-prefix ad-return-value))
    ad-return-value))


;;; QuickSilver's Abbreviation Scoring

(defun fuzzy-quicksilver-make-abbrev-regexp (abbrev)
  (concat "^"
          (cl-loop for char across (downcase abbrev) concat
                   (format ".*?\\(%s\\)"
                           (regexp-quote (string char))))))

(defun fuzzy-quicksilver-abbrev-penalty (string skip-start skip-end)
  (let ((skipped (- skip-end skip-start)))
    (cond
     ((zerop skipped) 0)
     ((string-match "[ \\t\\r\\n_-]+$" (substring string skip-start skip-end))
      (let ((seps (- (match-end 0) (match-beginning 0))))
        (+ seps (* (- skipped seps) 0.15))))
     ((let ((case-fold-search nil))
        (eq (string-match "[[:upper:]]" string skip-end) skip-end))
      (let ((ups (let ((case-fold-search nil))
                   (fuzzy-count-matches-in-string
                    "[[:upper:]]" string skip-start skip-end))))
        (+ ups (* (- skipped ups) 0.15))))
     (t skipped))))

(defun fuzzy-quicksilver-abbrev-score-nocache (string abbrev)
  (cond
   ((zerop (length abbrev))             0.9)
   ((< (length string) (length abbrev)) 0.0)
   ((let ((regexp (fuzzy-quicksilver-make-abbrev-regexp abbrev))
          (case-fold-search t))
      (string-match regexp string))
    (cl-loop with groups = (cddr (match-data))
             while groups
             for prev    = 0 then end
             for start   = (pop groups)
             for end     = (pop groups)
             for matched = (- end start)
             for skipped = (- start prev)
             for penalty = (fuzzy-quicksilver-abbrev-penalty string prev start)
             sum (+ matched (- skipped penalty)) into point
             finally return
             (let* ((length (length string))
                    (rest (- length end)))
               (/ (+ point (* rest 0.9)) (float length)))))
   (t 0.0)))

;; Make sure byte-compiled.
(cl-eval-when (eval)
  (byte-compile 'fuzzy-quicksilver-abbrev-score-nocache))

(defvar fuzzy-quicksilver-abbrev-score-cache
  (make-hash-table :test 'equal :weakness t))

(defun fuzzy-quicksilver-abbrev-score (string abbrev)
  (let ((cache-key (cons string abbrev)))
    (or (gethash cache-key fuzzy-quicksilver-abbrev-score-cache)
        (puthash cache-key
                 (fuzzy-quicksilver-abbrev-score-nocache string abbrev)
                 fuzzy-quicksilver-abbrev-score-cache))))

(cl-defun fuzzy-quicksilver-realtime-abbrev-score
    ( list abbrev
           &key limit timeout (quality 0.7)
           &aux new-list)
  (fuzzy-with-timeout (timeout (nreverse new-list))
                      (cl-loop with length = 0
                               for string in list
                               for score = (fuzzy-quicksilver-abbrev-score string abbrev)
                               if (>= score quality) do
                               (fuzzy-add-to-list-as-sorted
                                'new-list (cons string score)
                                :test '<
                                :key 'cdr)
                               (cl-incf length)
                               if (and limit (> length limit)) do
                               (pop new-list)
                               (setq length limit)
                               do (tick)
                               finally return (nreverse new-list))))

;;; _
(provide 'fuzzy)
;; Local Variables:
;; indent-tabs-mode: nil
;; End:
;;; fuzzy.el ends here
