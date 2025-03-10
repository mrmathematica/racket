
(define (condition->exception-constructor v)
  (cond
   [(or (and (format-condition? v)
             (or (string-prefix? "incorrect number of arguments" (condition-message v))
                 (string-suffix? "values to single value return context" (condition-message v))
                 (string-prefix? "incorrect number of values received in multiple value context" (condition-message v))))
        (and (message-condition? v)
             (or (string-prefix? "incorrect argument count in call" (condition-message v))
                 (string-prefix? "incorrect number of values from rhs" (condition-message v)))))
    exn:fail:contract:arity]
   [(and (format-condition? v)
         (who-condition? v)
         (#%memq (condition-who v) '(/ modulo remainder quotient atan angle log))
         (string=? "undefined for ~s" (condition-message v)))
    exn:fail:contract:divide-by-zero]
   [(and (format-condition? v)
         (who-condition? v)
         (#%memq (condition-who v) '(expt atan2))
         (string=? "undefined for values ~s and ~s" (condition-message v)))
    exn:fail:contract:divide-by-zero]
   [(and (format-condition? v)
         (string-prefix? "fixnum overflow" (condition-message v)))
    exn:fail:contract:non-fixnum-result]
   [(and (format-condition? v)
         (or (string=? "attempt to reference undefined variable ~s" (condition-message v))
             (string=? "attempt to assign undefined variable ~s" (condition-message v))))
    (lambda (msg marks)
      (|#%app| exn:fail:contract:variable msg marks (car (condition-irritants v))))]
   [(and (format-condition? v)
         (string-prefix? "~?.  Some debugging context lost" (condition-message v)))
    exn:fail]
   [(and (who-condition? v)
         (eq? 'time-utc->date (condition-who v)))
    exn:fail]
   [(and (format-condition? v)
         (who-condition? v)
         (#%memq (condition-who v) '(make-string make-vector make-fxvector make-flvector make-bytevector))
         (string-prefix? "~s is not a valid " (condition-message v))
         (string-suffix? " length" (condition-message v))
         (exact-nonnegative-integer? (car (condition-irritants v))))
    exn:fail:out-of-memory]
   [else
    exn:fail:contract]))

(define rewrites-added? #f)

(define rewrite-who
  (lambda (n)
    (unless rewrites-added?
      (letrec-syntax ([rename
                       (syntax-rules ()
                         [(_) (void)]
                         [(_ from to . args)
                          (begin
                            (putprop 'from 'error-rename 'to)
                            (rename . args))])])
        (rename bytevector-u8-ref bytes-ref
                bytevector-u8-set! bytes-set!
                bytevector-length bytes-length
                bytevector-copy bytes-copy
                make-bytevector make-bytes
                bitwise-arithmetic-shift arithmetic-shift
                fixnum->flonum fx->fl
                flonum->fixnum fl->fx
                fxarithmetic-shift-right fxrshift
                fxarithmetic-shift-left fxlshift
                fxsll/wraparound fxlshift/wraparound
                fxsrl fxrshift/logical
                exact inexact->exact
                real->flonum ->fl
                time-utc->date seconds->date
                make-record-type-descriptor* make-struct-type)
        (set! rewrites-added? #t)))
    (getprop n 'error-rename n)))

(define (rewrite-format who str irritants)
  (define is-not-a-str "~s is not a")
  (define result-arity-msg-head "returned ")
  (define result-arity-msg-tail " values to single value return context")
  (define invalid-removal-mask "invalid removal mask ~s")
  (define invalid-addition-mask "invalid addition mask ~s")
  (cond
   [(equal? str "attempt to reference undefined variable ~s")
    (values (string-append
             "~a: undefined;\n cannot reference an identifier before its definition"
             "\n  alert: compiler pass failed to add more specific guard!")
            irritants)]
   [(and (equal? str "undefined for ~s")
         (equal? irritants '(0)))
    (values "division by zero" null)]
   [(and (string-prefix? result-arity-msg-head str)
         (string-suffix? result-arity-msg-tail str))
    (values (string-append "result arity mismatch;\n"
                           " expected number of values not received\n"
                           "  expected: 1\n"
                           "  received: " (let ([s (substring str
                                                              (string-length result-arity-msg-head)
                                                              (- (string-length str) (string-length result-arity-msg-tail)))])
                                            (if (equal? s "~a")
                                                (number->string (car irritants))
                                                s)))
            null)]
   [(equal? str "~s is not a pair")
    (format-contract-violation "pair?" irritants)]
   [(and (equal? str "incorrect list structure ~s")
         (cxr->contract who))
    => (lambda (ctc)
         (format-contract-violation ctc irritants))]
   [(and (or (eq? who 'list-ref) (eq? who 'list-tail))
         (equal? str "index ~s is out of range for list ~s"))
    (cond
      [(and (eq? who 'list-ref)
            (not (pair? (cadr irritants))))
       (format-contract-violation "pair?" (list (cadr irritants)))]
      [else
       (format-error-values (string-append "index too large for list\n"
                                           "  index: ~s\n"
                                           "  in: ~s")
                            irritants)])]
   [(and (or (eq? who 'list-ref) (eq? who 'list-tail))
         (equal? str "index ~s reaches a non-pair in ~s"))
    (cond
      [(and (eq? who 'list-ref)
            (not (pair? (cadr irritants))))
       (format-contract-violation "pair?" (list (cadr irritants)))]
      [else
       (format-error-values (string-append "index reaches a non-pair\n"
                                           "  index: ~s\n"
                                           "  in: ~s")
                            irritants)])]
   [(or (eq? who 'memq) (eq? who 'memv))
    (format-error-values "not a proper list\n  in: ~s" irritants)]
   [(equal? str  "~s is not a valid index for ~s")
    (cond
     [(exact-nonnegative-integer? (car irritants))
      (let-values ([(what len)
                    (let ([v (cadr irritants)])
                      (cond
                       [(vector? v) (values "vector" (vector-length v))]
                       [(bytes? v) (values "byte string" (bytes-length v))]
                       [(string? v) (values "string" (string-length v))]
                       [(fxvector? v) (values "fxvector" (fxvector-length v))]
                       [(flvector? v) (values "flvector" (flvector-length v))]
                       [(stencil-vector? v) (values "stencil vector" (stencil-vector-length v))]
                       [else (values "value" #f)]))])
        (if (eqv? len 0)
            (format-error-values (string-append "index is out of range for empty " what "\n"
                                                "  index: ~s\n"
                                                "  " what ": ~s")
                                 irritants)
            (format-error-values (string-append "index is out of range\n"
                                                "  index: ~s\n"
                                                "  valid range: [0, " (if len (number->string (sub1 len)) "...") "]\n"
                                                "  " what ": ~s")
                                 irritants)))]
     [else
      (format-error-values (string-append "contract violation\n  expected: "
                                          (error-contract->adjusted-string
                                           "exact-nonnegative-integer?"
                                           primitive-realm)
                                          "\n"
                                          "  given: ~s\n"
                                          "  argument position: 2nd\n"
                                          "  first argument...:\n"
                                          "   ~s")
                           irritants)])]
   [(equal? str "~s is not a valid unicode scalar value")
    (format-contract-violation "(and/c (integer-in 0 #x10FFFF) (not/c (integer-in #xD800 #xDFFF)))" irritants)]
   [(and (string-prefix? "~s is not a valid " str)
         (string-suffix? " length" str)
         (#%memq who '(make-string make-vector make-fxvector make-flvector make-bytevector)))
    (if (exact-nonnegative-integer? (car irritants))
        (values (string-append "out of memory making "
                               (case who
                                 [(make-string) "string"]
                                 [(make-vector) "vector"]
                                 [(make-fxvector) "fxvector"]
                                 [(make-flvector) "flvector"]
                                 [(make-bytevector) "byte string"])
                               "\n  length: ~s")
                irritants)
        (format-contract-violation "exact-nonnegative-integer?" irritants))]
   [(and (> (string-length str) (string-length is-not-a-str))
         (equal? (substring str 0 (string-length is-not-a-str)) is-not-a-str)
         (= 1 (length irritants)))
    (let ([ctc (desc->contract (substring str (string-length is-not-a-str) (string-length str)))])
      (format-contract-violation ctc irritants))]
   [(equal? str "index ~s is not an exact nonnegative integer") ; doesn't match `is-not-a-str`
    (format-contract-violation "exact-nonnegative-integer?" irritants)]
   [(equal? str "cannot extend sealed record type ~s as ~s")
    (format-error-values (string-append "cannot make a subtype of a sealed type\n"
                                        "  type name: ~s\n"
                                        "  sealed type: ~s")
                         (reverse irritants))]
   [(eq? who 'time-utc->date)
    (values "integer is out-of-range" null)]
   [(or (and (eq? who 'stencil-vector)
             (equal? str "invalid mask ~s"))
        (and (eq? who 'stencil-vector-update)
             (or (equal? str invalid-removal-mask)
                 (equal? str invalid-addition-mask))))
    (format-error-values (string-append "contract violation\n  expected: "
                                        (error-contract->adjusted-string
                                         "(integer-in 0 (sub1 (expt 2 (stencil-vector-mask-width))))"
                                         primitive-realm)
                                        "\n"
                                        (cond
                                          [(equal? str invalid-removal-mask) "  argument position: 2nd\n"]
                                          [(equal? str invalid-addition-mask) "  argument position: 3rd\n"]
                                          [else ""])
                                        "  given: ~s")
                         irritants)]
   [(or (equal? str "mask ~s does not match given number of items ~s")
        (equal? str "addition mask ~s does not match given number of items ~s"))
    (values (format (string-append "mask does not match given number of items\n"
                                   "  mask: ~s\n"
                                   "  given items: ~s")
                    (car irritants)
                    (cadr irritants))
            null)]
   [(equal? str "mask of stencil vector ~s does not have all bits in ~s")
    (format-error-values (string-append "mask of stencil vector does not have all bits in removal mask\n"
                                        "  stencil vector: ~s\n"
                                        "  removal mask: ~s")
                         irritants)]
   [(equal? str "mask of stencil vector ~s already has bits in ~s")
    (format-error-values (string-append "mask of stencil vector already has bits in addition mask\n"
                                        "  stencil vector: ~s\n"
                                        "  addition mask: ~s")
                         irritants)]
   [(and (or (equal? str "invalid bit index ~s")
             (equal? str "invalid start index ~s")
             (equal? str "invalid end index ~s"))
         (#%memq who '(bitwise-bit-set? bitwise-bit-field flbit-field)))
    (cond
      [(exact-nonnegative-integer? (car irritants))
       (cond
         [(and (eq? who 'flbit-field) (> (car irritants) 64))
          ;; must be an out-of-range index
          (format-contract-violation "(integer-in 0 64)" irritants)]
         [else
          ;; must be an out-of-range end index
          (format-error-values (string-append
                                "ending index is smaller than starting index\n  ending index: ~s")
                               irritants)])]
      [else
       (format-contract-violation (if (eq? who 'flbit-field) "(integer-in 0 64)" "exact-nonnegative-integer?") irritants)])]
   [(and (equal? str "invalid value ~s")
         (eq? who 'bytevector-u8-set!))
    (format-contract-violation "byte?" irritants)]
   [else
    (format-error-values str irritants)]))

(define (format-contract-violation contract-str irritants)
  (format-error-values (string-append
                        "contract violation\n  expected: "
                        (error-contract->adjusted-string contract-str primitive-realm)
                        "\n  given: ~s")
                       irritants))

(define (format-error-values str irritants)
  (let ([str (string-copy str)]
        [len (string-length str)])
    (let loop ([i 0] [accum-irritants '()] [irritants irritants])
      (cond
       [(fx= i len)
        ;; `irritants` should be empty by now
        (values str (append (reverse accum-irritants) irritants))]
       [(and (char=? #\~ (string-ref str i))
             (fx< (fx+ i 1) len))
        (case (string-ref str (fx+ i 1))
          [(#\~ #\%) (loop (fx+ i 2) accum-irritants irritants)]
          [(#\s)
           (string-set! str (fx+ i 1) #\a)
           (loop (fx+ i 2)
                 (cons (reindent/newline (error-value->string (car irritants)))
                       accum-irritants)
                 (cdr irritants))]
          [else (loop (fx+ i 2)
                      (cons (car irritants)
                            accum-irritants)
                      (cdr irritants))])]
       [else (loop (fx+ i 1) accum-irritants irritants)]))))

(define (string-prefix? p str)
  (and (>= (string-length str) (string-length p))
       (string=? (substring str 0 (string-length p)) p)))

(define (string-suffix? p str)
  (and (>= (string-length str) (string-length p))
       (string=? (substring str (- (string-length str) (string-length p)) (string-length str)) p)))

;; Maps a function name like 'cadr to a contract
;; string like "(cons/c any/c pair?)"
(define (cxr->contract who)
  (let-syntax ([gen (lambda (stx)
                      (letrec ([add-all
                                (lambda (pre p tmpl)
                                  (cond
                                   [(null? p) '()]
                                   [else
                                    (cons
                                     (list (string-append (caar p) pre)
                                           (format tmpl (cadar p)))
                                     (add-all pre (cdr p) tmpl))]))])
                        (let ([combos
                               (reverse
                                (let loop ([alts '(x x x)])
                                  (cond
                                   [(null? alts)
                                    `(["a" "pair?"]
                                      ["d" "pair?"])]
                                   [else
                                    (let ([r (loop (cdr alts))])
                                      (append
                                       (add-all "a" r "(cons/c ~a any/c)")
                                       (add-all "d" r "(cons/c any/c ~a)")
                                       r))])))])
                          (with-syntax ([(combo ...)
                                         (map (lambda (c)
                                                (list (list (datum->syntax
                                                             #'here
                                                             (string->symbol (string-append "c" (car c) "r"))))
                                                      (cadr c)))
                                              combos)])
                            #`(case who
                                combo ...
                                [else #f])))))])
    (gen)))

(define (desc->contract str)
  (cond
   [(equal? str " mutable vector")
    "(and/c vector? (not/c immutable?))"]
   [(equal? str " bytevector")
    "bytes?"]
   [(equal? str " mutable bytevector")
    "(and/c bytes? (not/c immutable?))"]
   [(equal? str " mutable box")
    "(and/c box? (not/c immutable?))"]
   [(equal? str " character")
    "char?"]
   [(equal? str " real number")
    "real?"]
   [(equal? str " proper list")
    "list?"]
   [(equal? str "n flvector")
    "flvector?"]
   [else
    (let* ([l (string->list str)]
           [l (cond
               [(and (pair? l)
                     (eqv? (car l) #\space))
                (cdr l)]
               [(and (pair? l)
                     (eqv? (car l) #\n)
                     (pair? (cdr l))
                     (eqv? (cadr l) #\space))
                (cddr l)]
               [else l])])
      (list->string
       (let loop ([l l])
         (cond
          [(null? l) '(#\?)]
          [(eqv? (car l) #\space) (cons #\- (loop (cdr l)))]
          [else (cons (car l) (loop (cdr l)))]))))]))
