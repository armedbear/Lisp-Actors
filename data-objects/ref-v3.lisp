;; ref.lisp -- SMP indirect refs
;;
;; DM/RAL  02/17
;; -------------------------------------------------------------
#|
The MIT License

Copyright (c) 2017-2018 Refined Audiometrics Laboratory, LLC

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
|#

(in-package #:ref)
   
(declaim (optimize (speed 3) #|(safety 0)|# #+:LISPWORKS (float 0)))

;; ------------------------------
;; All objects subject to FSTM must define a FSTM:CLONE method. It is
;; impossible, in the most general case, to know how to properly clone
;; an arbitrary object. So FSTM Vars must use only the simplest
;; possible cases.
;;
;; CLONE is called when opening for write access.
;;
;; NOTE: These are all shallow (skeleton spine) copies Be careful not
;; to mutate any of the contained objects, but mutation of spine cells
;; is fine.  When operating on a clone, the use of single-thread
;; algorithms is fine. No other threads can see it.

(defgeneric clone (obj)
  (:method (obj)
   (error "No CLONE defined for class: ~A" (class-of obj)))
  (:method ((obj number))
   obj)
  (:method ((obj character))
   obj)
  (:method ((obj function))
   obj)
  (:method ((obj symbol))
   obj)
  (:method ((obj sequence))
   ;; vectors, strings - will use array first, skipping this method
   (copy-seq obj))
  (:method ((s structure-object))
   (copy-structure s))
  (:method ((arr array))
   ;; potentially expensive
   ;; If arr is adjustable, the clone will be too.
   ;; If arr is displaced to another arr, clone will be a non-displaced copy
   ;; Only the structure is copied. If any elements are mutable objects
   ;; the cloned array will still point to those same mutable objects.
   ;; Be Careful!!
   (let* ((dims  (array-dimensions arr))
          (adj   (adjustable-array-p arr))
          (eltp  (array-element-type arr))
          (fillp (and (array-has-fill-pointer-p arr)
                      (fill-pointer arr)))
          (ans  (make-array dims
                            :adjustable adj
                            :fill-pointer fillp
                            :element-type eltp))
          (src  (make-array (array-total-size arr)
                            :element-type eltp
                            :displaced-to arr))
          (dst  (make-array (array-total-size ans)
                            :element-type eltp
                            :displaced-to ans)))
     (replace dst src)
     ans)))

;; -----------------------------------------------------
;; List types. Unadorned lists will be treated as simple.

(defstruct (alist
            (:constructor alist (lst))
            (:copier nil))
  ;; use to provide ALISTs with a better clone method
  lst)

(defmethod clone ((lst alist))
  (alist (copy-alist (alist-lst lst))))

(defstruct (tree
            (:constructor tree (lst))
            (:copier nil))
  ;; use to provide CONS-Trees with a better clone method
  lst)

(defmethod clone ((lst tree))
  (tree (copy-tree (tree-lst lst))))

;; ====================================================================
;; REF - a mostly read-only indirect reference cell.

(defstruct ref
  val)

(defgeneric ref (obj)
  (:method (obj)
   (make-ref
    :val obj)))

(defgeneric val (obj)
  ;; used in prep for non-destructive read ops
  (:method (obj)
   obj)
  (:method ((obj ref))
   (ref-val obj)))

(defgeneric wval (obj)
  ;; used in prep for destructive ops
  ;; for REF it is same as VAL
  ;; but see COW version...
  (:method (obj)
   obj)
  (:method ((obj ref))
   (ref-val obj)))

(defmethod set-val ((r ref) val)
  ;; store is atomic, but perhaps buffered and delayed
  (setf (ref-val r) val))

(defsetf val  set-val)
(defsetf wval set-val)

(defmethod cas ((r ref) old new)
  (sys:compare-and-swap (ref-val r) old new))

(defmethod atomic-exch ((r ref) new)
  (sys:atomic-exchange (ref-val r) new))

(defmethod atomic-incf ((r ref))
  (sys:atomic-fixnum-incf (ref-val r)))

(defmethod atomic-decf ((r ref))
  (sys:atomic-fixnum-decf (ref-val r)))

(defmethod um:rmw ((r ref) fn)
  (um:nlet-tail iter ()
    (let* ((old  (ref-val r))
           (new  (funcall fn old)))
      (if (cas r old new)
          new
        (iter))
      )))

;; ---------------------------------------------------------------
;; COW - Copy on Write
;;
;; Can't enforce COW behavior in Lisp, so on first deref, we assume we are
;; about to do damage to the underlying. Also, once written to, we are no
;; longer COW.
;;
;; So don't do
;;
;;    (let ((val (var-val v)) ;; read-only val
;;          (ref (var-ref v)))
;;      (setf (ref-val ref) val)
;;
;; but okay to do:
;;
;;    (let ((ref (var-ref v)))
;;      (setf (ref-val ref) (VAR-VAL v))
;;
;;  -- or --
;;
;;    (let ((val (var-val v)) ;; read-only val
;;          (ref (var-ref v)))
;;      (setf (ref-val ref) (CLONE val))
;;
;; Once opened for writing, all subsequent read refs use COW access,
;; which clones before reevealing the value.
;; -------------------------------------------------------------------

(defstruct (cow
            (:include ref)))

(defun cow (obj)
  (make-cow
   :val (list obj)))

(defmethod val ((obj cow))
  (car (ref-val obj)))

(defmethod wval ((obj cow))
  ;; Using preemptive cloning on direct DEREF. Once deref'd we lose
  ;; any control over possible mutation in client code, so we opt for
  ;; conservative safety. We rely on this behavior below...
  (let ((cell (ref-val obj)))
    (if (cdr cell)
        (car cell)
      (um:rmw obj #'identity))))

(defmethod set-val ((c cow) val)
  (call-next-method c (cons val t)))

(defmethod cas :around ((obj cow) old new)
  (call-next-method obj old (cons new t)))

(defun maybe-clone (cell)
  (if (cdr cell)
      (car cell)
    (clone (car cell))))

(defmethod atomic-exch ((obj cow) val)
  (maybe-clone (sys:atomic-exchange (ref-val obj) (cons val t))))

(defmethod atomic-incf ((obj cow))
  (um:rmw obj #'1+))

(defmethod atomic-decf ((obj cow))
  (um:rmw obj #'1-))

(defmethod um:rmw ((obj cow) fn)
  (um:nlet-tail iter ()
    (let* ((old-cell (ref-val obj))
           (new-val  (funcall fn (maybe-clone old-cell))))
      (if (cas obj old-cell new-val)
          new-val
        (iter))
      )))

;; ------------------------------------------------
;; Interesting... the use of COW becones ambiguous with LIST objects.
;; Consider the difference between COPY-LIST for when a list contains
;; simple data, and COPY-ALIST for when a list is used as a
;; dictionary.
;;
;; COW semantics provide for shallow copies, which suit lists of
;; simple data, but not for lists which will undergo subsequent use as
;; a dictionary. Any modification of the dictionary mutates a second
;; level of data which has not been copied in a COW dereferencing.
;;
;; It is impossible to discern intention from the simple LIST
;; representation.

;; -----------------------------------------------
;; REF/COW-aware getters/setters

(defun ielt (obj pos)
  (elt (val obj) pos))

(defun set-ielt (obj pos val)
  (setf (elt (wval obj) pos) val))

(defsetf ielt set-ielt)

;; -----------------------------------------------

(defun islot-value (obj id)
  (slot-value (val obj) id))

(defun set-islot-value (obj id val)
  (setf (slot-value (wval obj) id) val))

(defsetf islot-value set-islot-value)

;; -----------------------------------------------

(defun iaref (obj &rest indices)
  (apply #'aref (val obj) indices))

(defun  set-iaref (obj indices val)
  (setf (apply #'aref (wval obj) indices) val))

(defsetf iaref (obj &rest indices) (val)
  `(set-iaref ,obj (list ,@indices) ,val))


