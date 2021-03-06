;; MCAS.lisp -- Multiple CAS on CAR/CDR of ref-cells.
;;
;; Adapted from UCAM-CL-TR-579 U.Cambridge Tech Report 579,
;; "Practical lock-freedom" by Keir Fraser, Feb 2004
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

(in-package #:mcas)
   
(declaim (optimize (speed 3) #|(safety 0)|# #+:LISPWORKS (float 0)))

;; ------------------
;; CCAS - Conditional CAS
;;
;; The job of CCAS is to conditionally acquire a reference on behalf
;; of an MCAS operation. The condition is that the MCAS operation must
;; still be in a state of :UNDECIDED.
;;
;; If this condition is met, we either acquire the ref cell with the
;; MCAS descriptor, or we fail because the ref cell did not contain
;; the expected old value
;;
;; If the CCAS acquires, but the condition is not met, it can only be
;; because another thread pushed us along to a :FAILED or :SUCCEEDED
;; resolution already. In other words we have already been through
;; here.  So even if we successfuly CAS again, we have to set the
;; value back to Old value.
;;

;; -------------------------------------------------------------

(defstruct ccas-desc
  ref old new pred)

(defun ccas-help (desc)
  ;; nudge along a ccas-desc to resolve as either an mcas-desc
  ;; or the old value of the ref
  (declare (ccas-desc desc))
  (let ((val  (if (funcall (ccas-desc-pred desc))
                  (ccas-desc-new desc)
                (ccas-desc-old desc))))
    ;;
    ;; If the ref cell still contains our CCAS desc, then this CAS
    ;; will succeeed.
    ;;
    ;; If not, then it is because another thread has already been
    ;; through here nudging our CCAS desc and succeeded.
    ;;
    (basic-cas (ccas-desc-ref desc) desc val)))

(defun ccas (ref old new pred)
  ;; CCAS -- conditional CAS, perform CAS only if PRED returns true.
  ;; Returns true if CAS was successful.
  (let ((desc  (make-ccas-desc
                :ref   ref
                :old   old
                :new   new
                :pred  pred)))
    (declare (ccas-desc desc))
    (um:nlet-tail iter ()
     (if (basic-cas ref old desc)
         (ccas-help desc)
       ;;
       ;;               CAS succeeded
       ;;                     |  
       ;;              ref-val EQ old -> CCAS desc
       ;;               |     |    |                   
       ;;   MCAS :UNDECIDED   |   MCAS :FAILED
       ;;                     |
       ;;         MCAS :SUCCEEDED && old EQ new
       ;;
       ;; We got it! Either this is the first time
       ;; through with MCAS :UNDECIDED or, since the
       ;; old value was eq the expected old, the MCAS was
       ;; pushed along by another thread and the state
       ;; must now be :FAILED.
       ;;
       ;; (Or else, the planned new value was the same as
       ;; the old value and MCAS :SUCCEEDED. Either way,
       ;; it put back the old value.).
       ;;
       ;; In the first case, we can now replace our CCAS
       ;; descriptor with the caller's MCAS descriptor.
       ;;
       ;; In the second case, we must put back the old value.
       ;;
       
       ;; else
       (let ((v (basic-ref-value ref)))
         (when (ccas-desc-p v)
           (ccas-help v)
           (iter)))
       ))))

(defun ccas-read (ref)
  ;; Return either an mcas-desc or an old value.
  ;; This nudges along any ccas-desc that may be claiming the ref.
  (let ((v (basic-ref-value ref)))
    (cond ((ccas-desc-p v)
           (ccas-help v)
           (ccas-read ref))

          (t  v)
          )))

;; ------------------
;; MCAS - Multiple CAS
;;
;; NOTE: Any ref that is used in an MCAS operation should really use
;; MCAS and MCAS-READ, even when not part of an ensemble (as in simple
;; CAS), and for querying the value.  This will detect MCAS in
;; progress and help it along for final resolution.

(defstruct mcas-desc
  triples
  (status   (ref :undecided)))

(defun mcas-help (desc)
  (declare (mcas-desc desc))
  (let ((triples  (mcas-desc-triples desc))
        (status   (mcas-desc-status desc)))

    (labels
        ((undecided-p ()
           ;; can't be declared dynamic-extent
           (eq :undecided (ref-value status)))
         
         (successful-p ()
           (eq :successful (ref-value status)))

         (patch-fail (ref old new)
           (declare (ignore new))
           (basic-cas ref desc old))

         (patch-succeed (ref old new)
           (declare (ignore old))
           (basic-cas ref desc new))
         
         (decide (desired-state)
           (cas status :undecided desired-state)
           (let* ((success (successful-p))
                  (patchfn (if success #'patch-succeed #'patch-fail)))
             (dolist (triple triples)
               (apply patchfn triple))
             (return-from mcas-help success)))
         
         (acquire (ref old new)
           (declare (ignore new))
           (um:nlet-tail iter ()
             (ccas ref old desc #'undecided-p)
             (let ((v (basic-ref-value ref)))
               (cond
                ((eq v desc))  ;; we got it
                
                ((and (eq v old)
                      (undecided-p))
                 (iter))
              
                ((mcas-desc-p v)
                 ;; someone else is trying, help them out, then
                 ;; try again
                 (mcas-help v)
                 (iter))
                
                (t ;; not a descriptor, and not eq old with
                   ;; :undecided, so we must have missed our
                   ;; chance, or else we already resolved to
                   ;; :failed or :successful, and this will
                   ;; have no effect.
                   (decide :failed))
                )))))
      (declare (dynamic-extent #'successful-p
                               #'patch-fail  #'patch-succeed
                               #'decide      #'acquire))
      (mp:with-interrupts-blocked
        (when (undecided-p)
          (dolist (triple triples)
            (apply #'acquire triple)))
        (decide :successful)
        ))))

(defun mcas (&rest triples)
  ;; triples - a sequence of (ref old new) as would be suitable for
  ;; CAS. But each ref must be a total-order MCAS-REF.
  (mcas-help (make-mcas-desc
              :triples (sort (apply 'um:triples triples)
                             '<
                             :key (lambda (tup)
                                    (order-id (first tup)))
                             ))))

(defun mcas-read (ref)
  (mp:with-interrupts-blocked
    (um:nlet-tail iter ()
      (let ((v (ccas-read ref)))
        (cond ((mcas-desc-p v)
               (mcas-help v)
               (iter))
            
              (t  v)
              )))))

;; -------------------------------------------------------------------------------------
;; MCAS can only be used on refs that can be sorted into total order.
;; All simple CAS ops must be performed using MCAS,
;; and all REF-VALUE calls must be performed using MCAS-READ.
;; We provide overloaded versions of CAS and REF-VALUE on MCAS-REF.

(defclass mcas-ref (ref <orderable-mixin>)
  ())

(defmethod mcas-ref (x)
  (make-instance 'mcas-ref
                 :val x))

(defmethod mcas-ref ((m mcas-ref))
  ;; as type conversion
  m)

(defmethod mcas-ref ((x ref))
  ;; type coercion
  (make-instance 'mcas-ref
                 :cell (ref-cell x)))

(defmethod ref-value ((x mcas-ref))
  (mcas-read x))

(defmethod cas ((x mcas-ref) old new)
  (mcas x old new))

;; -------------------------------------------------------------------------------------

#|
(defun tst1 (&optional (n 1000000))
  (let ((a  (mcas-ref 1))
        (b  (mcas-ref 2))
        (ct 0))
    (loop repeat n do
          (loop until (mcas a 1 7
                            b 2 8))
          (incf ct)
          (mcas a 7 1
                b 8 2))
    ct))

(defun tstx (&optional (n 1000000))
  (let ((a  (mcas-ref 1))
        (b  (mcas-ref 2))
        (ct 0))
    (rch:spawn-process (lambda ()
                         (loop repeat n do
                               (loop until (mcas a 1 3
                                                 b 2 4))
                               (incf ct)
                               (mcas a 3 5
                                     b 4 6))))
    (loop repeat n do
          (loop until (mcas a 5 7
                            b 6 8))
          (incf ct)
          (mcas a 7 1
                b 8 2))
    ct))

(defun tstxx (&optional (n 1000000))
  (let ((a  (mcas-ref 1))
        (b  (mcas-ref 2))
        (ct 0))
    (rch:spawn-process (lambda ()
                         (loop repeat n do
                               (loop until (mcas a 1 3
                                                 b 2 4))
                               (incf ct)
                               (mcas a 3 5
                                     b 4 6))))
    (rch:spawn-process (lambda ()
                         (loop repeat n do
                               (loop until (mcas a 5 7
                                                 b 6 8))
                               (incf ct)
                               (mcas a 7 9
                                     b 8 10))))
    (loop repeat n do
          (loop until (mcas a 9 11
                            b 10 12))
          (incf ct)
          (mcas a 11 1
                b 12 2))
    ct))
|#

  