#lang racket/base
(require "../common/struct-star.rkt"
         "../syntax/syntax.rkt"
         "../syntax/scope.rkt"
         "../syntax/taint.rkt"
         "../syntax/match.rkt"
         "../namespace/module.rkt"
         "../syntax/binding.rkt"
         "env.rkt"
         "../syntax/track.rkt"
         "../syntax/error.rkt"
         "../expand/parsed.rkt"
         "dup-check.rkt"
         "use-site.rkt"
         "../namespace/core.rkt"
         "../boot/runtime-primitive.rkt"
         "context.rkt"
         "liberal-def-ctx.rkt"
         "reference-record.rkt"
         "prepare.rkt"
         "log.rkt"
         "main.rkt")

(provide expand-body
         expand-and-split-bindings-by-reference)

;; Expand a sequence of body forms in a definition context; returns a
;; list of body forms
(define (expand-body bodys ctx
                     #:source s
                     #:stratified? [stratified? #f])
  (log-expand ctx 'enter-block bodys)
  ;; In principle, we have an outside-edge scope that identifies the
  ;; original content of the definition context --- but a body always
  ;; exists inside some binding form, so that form's scope will do;
  ;; the inside-edge scope identifies any form that appears (perhaps
  ;; through macro expansion) in the definition context
  (define inside-sc (new-scope 'intdef))
  (define init-bodys
    (for/list ([body (in-list bodys)])
      (add-scope body inside-sc)))
  (log-expand ctx 'block-renames init-bodys bodys)
  (define phase (expand-context-phase ctx))
  (define frame-id (make-reference-record)) ; accumulates info on referenced variables
  (define def-ctx-scopes (box null))
  ;; Create an expansion context for expanding only immediate macros;
  ;; this partial-expansion phase uncovers macro- and variable
  ;; definitions in the definition context
  (define body-ctx (struct*-copy expand-context ctx
                                 [context (list (make-liberal-define-context))]
                                 [name #f]
                                 [only-immediate? #t]
                                 [def-ctx-scopes def-ctx-scopes]
                                 [post-expansion #:parent root-expand-context
                                                 (lambda (s) (add-scope s inside-sc))]
                                 [scopes (append (unbox (or (root-expand-context-use-site-scopes ctx)
                                                            (box null)))
                                                 (cons inside-sc
                                                       (expand-context-scopes ctx)))]
                                 [use-site-scopes #:parent root-expand-context (box null)]
                                 [frame-id #:parent root-expand-context frame-id]
                                 [reference-records (cons frame-id
                                                          (expand-context-reference-records ctx))]))
  ;; Increment the binding layer relative to `ctx` when we encounter a binding
  (define (maybe-increment-binding-layer ids body-ctx)
    (if (eq? (expand-context-binding-layer body-ctx)
             (expand-context-binding-layer ctx))
        (increment-binding-layer ids body-ctx inside-sc)
        (expand-context-binding-layer body-ctx)))
  ;; Save the name for the last form
  (define name (expand-context-name ctx))
  ;; Loop through the body forms for partial expansion
  (let loop ([body-ctx body-ctx]
             [bodys init-bodys]
             [done-bodys null] ; accumulated expressions
             [val-idss null]   ; accumulated binding identifiers
             [val-keyss null]  ; accumulated binding keys
             [val-rhss null]   ; accumulated binding right-hand sides
             [track-stxs null] ; accumulated syntax for tracking
             [trans-idss null] ; accumulated `define-syntaxes` identifiers that have disappeared
             [trans-stxs null] ; accumulated `define-syntaxes` forms for tracking
             [stx-clauses null] ; accumulated syntax-binding clauses, used when observing
             [dups (make-check-no-duplicate-table)]
             [just-saw-define-syntaxes? #f]) ; make sure that `define-syntaxes` isn't last
    (cond
     [(null? bodys)
      ;; Partial expansion is complete, so finish by rewriting to
      ;; `letrec-values`
      (finish-expanding-body body-ctx frame-id def-ctx-scopes
                             (reverse val-idss) (reverse val-keyss) (reverse val-rhss) (reverse track-stxs)
                             (reverse stx-clauses) (reverse done-bodys)
                             #:original-bodys init-bodys
                             #:source s
                             #:stratified? stratified?
                             #:just-saw-define-syntaxes? just-saw-define-syntaxes?
                             #:name name
                             #:disappeared-transformer-bindings (reverse trans-idss)
                             #:disappeared-transformer-forms (reverse trans-stxs))]
     [else
      (define rest-bodys (cdr bodys))
      (log-expand body-ctx 'next)
      (define exp-body (expand (car bodys) (if (and name (null? (cdr bodys)))
                                               (struct*-copy expand-context body-ctx
                                                             [name name])
                                               body-ctx)))
      (case (core-form-sym exp-body phase)
        [(begin)
         ;; Splice a `begin` form
         (log-expand body-ctx 'prim-begin exp-body)
         (define-match m exp-body '(begin e ...))
         (define (track e) (syntax-track-origin e exp-body))
         (define splice-bodys (append (map track (m 'e)) rest-bodys))
         (log-expand body-ctx 'splice splice-bodys)
         (loop body-ctx
               splice-bodys
               done-bodys
               val-idss
               val-keyss
               val-rhss
               track-stxs
               trans-idss
               trans-stxs
               stx-clauses
               dups
               just-saw-define-syntaxes?)]
        [(define-values)
         ;; Found a variable definition; add bindings, extend the
         ;; environment, and continue
         (log-expand body-ctx 'prim-define-values exp-body)
         (define-match m exp-body '(define-values (id ...) rhs))
         (define ids (remove-use-site-scopes (m 'id) body-ctx))
         (log-expand body-ctx 'rename-one (list ids (m 'rhs)))
         (define new-dups (check-no-duplicate-ids ids phase exp-body dups))
         (define counter (root-expand-context-counter ctx))
         (define local-sym (and (expand-context-normalize-locals? ctx) 'loc))
         (define keys (for/list ([id (in-list ids)])
                        (add-local-binding! id phase counter
                                            #:frame-id frame-id #:in exp-body
                                            #:local-sym local-sym)))
         (define extended-env (for/fold ([env (expand-context-env body-ctx)]) ([key (in-list keys)]
                                                                               [id (in-list ids)])
                                (env-extend env key (local-variable id))))
         (loop (struct*-copy expand-context body-ctx
                             [env extended-env]
                             [binding-layer (maybe-increment-binding-layer ids body-ctx)])
               rest-bodys
               null
               ;; If we had accumulated some expressions, we
               ;; need to turn each into the equivalent of
               ;;  (defined-values () (begin <expr> (values)))
               ;; form so it can be kept with definitions to
               ;; preserve order
               (cons ids (append
                          (for/list ([done-body (in-list done-bodys)])
                            null)
                          val-idss))
               (cons keys (append
                           (for/list ([done-body (in-list done-bodys)])
                             null)
                           val-keyss))
               (cons (m 'rhs) (append
                               (for/list ([done-body (in-list done-bodys)])
                                 (no-binds done-body s phase))
                               val-rhss))
               (cons (keep-as-needed body-ctx exp-body #:for-track? #t)
                     (append
                      (for/list ([done-body (in-list done-bodys)])
                        #f)
                      track-stxs))
               trans-idss
               trans-stxs
               stx-clauses
               new-dups
               #f)]
        [(define-syntaxes)
         ;; Found a macro definition; add bindings, evaluate the
         ;; compile-time right-hand side, install the compile-time
         ;; values in the environment, and continue
         (log-expand body-ctx 'prim-define-syntaxes exp-body)
         (define-match m exp-body '(define-syntaxes (id ...) rhs))
         (define ids (remove-use-site-scopes (m 'id) body-ctx))
         (log-expand body-ctx 'rename-one (list ids (m 'rhs)))
         (define new-dups (check-no-duplicate-ids ids phase exp-body dups))
         (define counter (root-expand-context-counter ctx))
         (define local-sym (and (expand-context-normalize-locals? ctx) 'mac))
         (define keys (for/list ([id (in-list ids)])
                        (add-local-binding! id phase counter
                                            #:frame-id frame-id #:in exp-body
                                            #:local-sym local-sym)))
         (log-expand body-ctx 'prepare-env)
         (prepare-next-phase-namespace ctx)
         (log-expand body-ctx 'enter-bind)
         (define vals (eval-for-syntaxes-binding 'define-syntaxes (m 'rhs) ids body-ctx))
         (define extended-env (for/fold ([env (expand-context-env body-ctx)]) ([key (in-list keys)]
                                                                               [val (in-list vals)]
                                                                               [id (in-list ids)])
                                (maybe-install-free=id-in-context! val id phase body-ctx)
                                (env-extend env key val)))
         (log-expand body-ctx 'exit-bind)
         (loop (struct*-copy expand-context body-ctx
                             [env extended-env]
                             [binding-layer (maybe-increment-binding-layer ids body-ctx)])
               rest-bodys
               done-bodys
               val-idss
               val-keyss
               val-rhss
               track-stxs
               (cons ids trans-idss)
               (cons (keep-as-needed body-ctx exp-body #:for-track? #t) trans-stxs)
               (cons (datum->syntax #f (list ids (m 'rhs)) exp-body) stx-clauses)
               new-dups
               #t)]
        [else
         (cond
          [stratified?
           ;; Found an expression, so no more definitions are allowed
           (unless (null? done-bodys) (error "internal error: accumulated expressions not empty"))
           (loop body-ctx
                 null
                 (if (and (null? val-idss) (null? trans-idss))
                     (reverse (cons exp-body rest-bodys))
                     (list (datum->syntax #f (cons (core-id '#%stratified-body phase)
                                                   (cons exp-body rest-bodys)))))
                 val-idss
                 val-keyss
                 val-rhss
                 track-stxs
                 trans-idss
                 trans-stxs
                 stx-clauses
                 dups
                 #f)]
          [else
           ;; Found an expression; accumulate it and continue
           (loop body-ctx
                 rest-bodys
                 (cons exp-body done-bodys)
                 val-idss
                 val-keyss
                 val-rhss
                 track-stxs
                 trans-idss
                 trans-stxs
                 stx-clauses
                 dups
                 #f)])])])))

;; precondition: xs is a list with at least one element
(define (last xs)
  (if (null? (cdr xs))
      (car xs)
      (last (cdr xs))))

;; Partial expansion is complete, so assumble the result as a
;; `letrec-values` form and continue expanding
(define (finish-expanding-body body-ctx frame-id def-ctx-scopes
                               val-idss val-keyss val-rhss track-stxs
                               stx-clauses done-bodys
                               #:original-bodys init-bodys
                               #:source s
                               #:stratified? stratified?
                               #:just-saw-define-syntaxes? just-saw-define-syntaxes?
                               #:name name
                               #:disappeared-transformer-bindings disappeared-transformer-bindings
                               #:disappeared-transformer-forms disappeared-transformer-forms)
  (when (or (null? done-bodys)
            just-saw-define-syntaxes?)
    (raise-syntax-error (string->symbol "begin (possibly implicit)")
                        "the last form is not an expression"
                        (datum->syntax #f (cons 'begin init-bodys) s)
                        (if (null? init-bodys) #f (last init-bodys))))
  ;; As we finish expanding, we're no longer in a definition context
  (define accum-ctx (accumulate-def-ctx-scopes body-ctx def-ctx-scopes))
  (define finish-ctx (struct*-copy expand-context accum-ctx
                                   [context 'expression]
                                   [use-site-scopes #:parent root-expand-context (box null)]
                                   [only-immediate? #f]
                                   [def-ctx-scopes #f]
                                   [scopes (append (unbox (root-expand-context-use-site-scopes accum-ctx))
                                                   (expand-context-scopes accum-ctx))]
                                   [post-expansion #:parent root-expand-context #f]))
  ;; Helper to expand and wrap the ending expressions in `begin`, if needed:
  (define (finish-bodys finish-ctx)
    (define last-i (sub1 (length done-bodys)))
    (log-expand body-ctx 'enter-list done-bodys)
    (define exp-bodys
      (for/list ([done-body (in-list done-bodys)]
                 [i (in-naturals)])
        (log-expand body-ctx 'next)
        (expand done-body (if (and name (= i last-i))
                              (struct*-copy expand-context finish-ctx
                                            [name name])
                              finish-ctx))))
    (log-expand body-ctx 'exit-list exp-bodys)
    (reference-record-clear! frame-id)
    exp-bodys)
  (cond
   [(and (null? val-idss)
         (null? disappeared-transformer-bindings))
    ;; No definitions, so just return the body list
    (log-expand finish-ctx 'block->list)
    (finish-bodys finish-ctx)]
   [else
    (log-expand finish-ctx 'block->letrec val-idss val-rhss done-bodys)
    ;; Roughly, finish expanding the right-hand sides, finish the body
    ;; expression, then add a `letrec-values` wrapper:
    (define exp-s (expand-and-split-bindings-by-reference
                   val-idss val-keyss val-rhss track-stxs
                   #:split? (not stratified?)
                   #:frame-id frame-id #:ctx finish-ctx
                   #:source s #:had-stxes? (pair? stx-clauses)
                   #:get-body finish-bodys #:track? #f))
    (if (expand-context-to-parsed? body-ctx)
        (list exp-s)
        (let ([exp-s (attach-disappeared-transformer-bindings
                      exp-s
                      disappeared-transformer-bindings)])
          (let ([tracked-exp-s
                 (for/fold ([exp-s exp-s]) ([form (in-list disappeared-transformer-forms)]
                                            #:when form)
                   (syntax-track-origin exp-s form))])
            (log-expand finish-ctx 'finish-block (list tracked-exp-s))
            (list tracked-exp-s))))]))

;; Roughly, create a `letrec-values` for for the given ids, right-hand sides, and
;; body. While expanding right-hand sides, though, keep track of whether any
;; forward references appear, and if not, generate a `let-values` form, instead,
;; at each binding clause. Similar, end a `letrec-values` form and start a new
;; one if there were forward references up to the clause but not beyond.
;; Returns a single form.
(define (expand-and-split-bindings-by-reference idss keyss rhss track-stxs
                                                #:split? split?
                                                #:frame-id frame-id #:ctx ctx 
                                                #:source s #:had-stxes? had-stxes?
                                                #:get-body get-body #:track? track?)
  (define phase (expand-context-phase ctx))
  (let loop ([idss idss] [keyss keyss] [rhss rhss] [track-stxs track-stxs]
             [accum-idss null] [accum-keyss null] [accum-rhss null] [accum-track-stxs null]
             [ctx ctx]
             [track? track?] [get-list? #f])
    (cond
     [(null? idss)
      (cond
       [(and (null? accum-idss)
             get-list?)
        (get-body ctx)]
       [else
        (define exp-body (get-body ctx))
        (define result-s
          (if (expand-context-to-parsed? ctx)
              (if (null? accum-idss)
                  (parsed-let-values (keep-properties-only s) null null exp-body)
                  (parsed-letrec-values (keep-properties-only s)
                                        (reverse accum-idss)
                                        (reverse (map list accum-keyss accum-rhss))
                                        exp-body))
              (rebuild
               #:track? track?
               s
               `(,(if (null? accum-idss)
                      (core-id 'let-values phase)
                      (core-id 'letrec-values phase))
                 ,(build-clauses accum-idss accum-rhss accum-track-stxs)
                 ,@exp-body))))
        (if get-list? (list result-s) result-s)])]
     [else
      (log-expand ctx 'next)
      (define ids (car idss))
      (define expanded-rhs (expand (car rhss) (as-named-context ctx ids)))
      (define track-stx (car track-stxs))
      
      (define local-or-forward-references? (reference-record-forward-references? frame-id))
      (reference-record-bound! frame-id (car keyss))
      (define forward-references? (reference-record-forward-references? frame-id))
      
      (cond
       [(and (not local-or-forward-references?)
             split?)
        (unless (null? accum-idss) (error "internal error: accumulated ids not empty"))
        (define-values (next-idss next-ctx) (create-binding-layer (cdr idss) (cdr keyss) ctx))
        (define exp-rest (loop next-idss (cdr keyss) (cdr rhss) (cdr track-stxs)
                               null null null null
                               next-ctx
                               #f #t))
        (define result-s
          (if (expand-context-to-parsed? next-ctx)
             (parsed-let-values (keep-properties-only s)
                                (list ids)
                                (list (list (car keyss) expanded-rhs))
                                exp-rest)
             (rebuild
              #:track? track?
              s
              `(,(core-id 'let-values phase)
                (,(build-clause ids expanded-rhs track-stx))
                ,@exp-rest))))
        (if get-list? (list result-s) result-s)]
       [(and (not forward-references?)
             (or split? (null? (cdr idss))))
        (define-values (next-idss next-ctx) (create-binding-layer (cdr idss) (cdr keyss) ctx))
        (define exp-rest (loop next-idss (cdr keyss) (cdr rhss) (cdr track-stxs)
                               null null null null
                               next-ctx
                               #f #t))
        (define result-s
         (if (expand-context-to-parsed? next-ctx)
             (parsed-letrec-values (keep-properties-only s)
                                   (reverse (cons ids accum-idss))
                                   (reverse
                                    (cons (list (car keyss) expanded-rhs)
                                          (map list accum-keyss accum-rhss)))
                                   exp-rest)
             (rebuild
              #:track? track?
              s
              `(,(core-id 'letrec-values phase)
                ,(build-clauses (cons ids accum-idss)
                                (cons expanded-rhs accum-rhss)
                                (cons track-stx accum-track-stxs))
                ,@exp-rest))))
        (if get-list? (list result-s) result-s)]
       [else
        (loop (cdr idss) (cdr keyss) (cdr rhss) (cdr track-stxs)
              (cons ids accum-idss) (cons (car keyss) accum-keyss)
              (cons expanded-rhs accum-rhss) (cons track-stx accum-track-stxs)
              ctx
              track? get-list?)])])))

(define (create-binding-layer idss keyss ctx)
  (cond
    [(or (expand-context-to-parsed? ctx)
         (null? idss))
     (values idss ctx)]
    [else
     ;; In case of expansion to a syntax object, we need to create a
     ;; scope to reflect a new `let[rec]-values` context, otherwise
     ;; re-expansion can lead to ambiguous bindings. The scope is
     ;; added to the binding of subsequent identifiers in the expanded
     ;; form, and we want the extra scope to show up on the expanded
     ;; form of a reference to those variables; so, update the
     ;; environment's mapping for the local-binding key to have the
     ;; identifier with extra scopes.
     (define sc (new-scope 'local))
     (define new-idss (for/list ([ids (in-list idss)])
                        (for/list ([id (in-list ids)])
                          (add-scope id sc))))
     (define env (expand-context-env ctx))
     (define new-env (for/fold ([env env]) ([new-ids (in-list new-idss)]
                                            [keys (in-list keyss)]
                                            #:when #t
                                            [new-id (in-list new-ids)]
                                            [key (in-list keys)])
                       (env-extend env key (local-variable new-id))))
     (values new-idss
             (struct*-copy expand-context ctx
                           [env new-env]))]))

(define (build-clauses accum-idss accum-rhss accum-track-stxs)
  (map build-clause
       (reverse accum-idss)
       (reverse accum-rhss)
       (reverse accum-track-stxs)))

(define (build-clause ids rhs track-stx)
  (define clause (datum->syntax #f `[,ids ,rhs]))
  (if track-stx
      (syntax-track-origin clause track-stx)
      clause))

;; Helper to turn an expression into a binding clause with zero
;; bindings
(define (no-binds expr s phase)
  (define s-runtime-stx (syntax-shift-phase-level runtime-stx phase))
  (datum->syntax (core-id '#%app phase) ; for `values` application
                 `(,(core-id 'begin phase)
                   ,expr
                   (,(datum->syntax s-runtime-stx 'values)))
                 s))

(define (log-tag? had-stxes? ctx)
  (and had-stxes?
       (not (expand-context-only-immediate? ctx))))
