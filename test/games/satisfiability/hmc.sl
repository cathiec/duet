(set-logic LIA)
(synth-fun hours ((x Int)) Int)
(synth-fun minutes ((x Int)) Int)
(synth-fun seconds ((x Int)) Int)

(declare-var totsec Int)
(constraint (or (<= totsec 0) (= (+ (* 3600 (hours totsec)) (+ (* 60 (minutes totsec)) (seconds totsec))) totsec)))
(constraint (<= 0 (minutes totsec)))
(constraint (< (minutes totsec) 60))
(constraint (<= 0 (seconds totsec)))
(constraint (< (seconds totsec) 60))
(check-synth)
