;;; -*- mode: lisp -*-

;;;; | File with documentation header comments.
;;;;
;;;; Some more documentation strings in consequent lines. Some more
;;;; documentation strings in consequent lines. Some more documentation
;;;; strings in consequent lines.
;;;;
;;;; Foo foo foo foo. Foo foo foo foo. Foo foo foo foo. Foo foo foo
;;;; foo. Foo foo foo foo. Foo foo foo foo. Foo foo foo foo. Foo foo foo
;;;; foo.

(module Test10)

;;; | Main entry function.
(= main
   ;; This is not a documentation comment.
   (foo "Module with doc comments."))

;;; | Comment for function foo.
(= (foo str)
   (>> (putStrLn str)
       (bar 15 27)))

;;; | Comment for function bar.
;;;
;;; This comment spans multiple lines. Bar bar bar bar bar bar bar bar
;;; bar bar bar bar bar bar bar bar bar bar.
;;;
;;; Bar bar bar bar bar bar bar bar bar bar bar bar bar bar bar bar bar
;;; bar bar bar bar bar bar bar bar bar bar bar bar bar bar bar bar bar
;;; bar bar bar.
;;;
(= (bar a b)
   (putStrLn (++ "From bar: " (show (+ a b)))))
