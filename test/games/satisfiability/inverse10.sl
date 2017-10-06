(set-logic LIA)
(synth-fun inverse ((x Int)) Int)
(declare-var x Int)
(constraint (<= 0 (inverse x)))
(constraint (< (inverse x) 10))
(constraint (= (mod (+ x (inverse x)) 10) 0))
(check-synth)
