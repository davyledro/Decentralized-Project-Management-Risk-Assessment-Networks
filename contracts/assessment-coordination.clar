;; Assessment Coordination Contract
;; Coordinates risk assessment processes across multiple assessors

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u300))
(define-constant ERR-ASSESSMENT-EXISTS (err u301))
(define-constant ERR-ASSESSMENT-NOT-FOUND (err u302))
(define-constant ERR-INVALID-INPUT (err u303))
(define-constant ERR-INSUFFICIENT-ASSESSORS (err u304))
(define-constant ERR-ASSESSMENT-CLOSED (err u305))

;; Assessment Status
(define-constant STATUS-OPEN u1)
(define-constant STATUS-IN-PROGRESS u2)
(define-constant STATUS-COMPLETED u3)
(define-constant STATUS-CANCELLED u4)

;; Data Variables
(define-data-var next-assessment-id uint u1)
(define-data-var min-assessors-required uint u3)
(define-data-var assessment-timeout-blocks uint u1440) ;; ~24 hours

;; Data Maps
(define-map assessment-sessions
  uint
  {
    risk-id: uint,
    project-id: (string-ascii 50),
    coordinator: principal,
    required-assessors: uint,
    current-assessors: uint,
    status: uint,
    start-block: uint,
    end-block: uint,
    consensus-threshold: uint,
    final-severity: uint,
    final-probability: uint,
    final-impact: uint,
    confidence-score: uint
  }
)

(define-map assessment-participants
  { assessment-id: uint, assessor: principal }
  {
    severity-vote: uint,
    probability-vote: uint,
    impact-vote: uint,
    confidence-level: uint,
    submission-block: uint,
    weight: uint
  }
)

(define-map assessor-workload
  principal
  {
    active-assessments: uint,
    completed-assessments: uint,
    average-response-time: uint,
    reliability-score: uint
  }
)

;; Public Functions

;; Create new assessment session
(define-public (create-assessment-session
  (risk-id uint)
  (project-id (string-ascii 50))
  (required-assessors uint)
  (consensus-threshold uint)
)
  (let
    (
      (assessment-id (var-get next-assessment-id))
    )
    (asserts! (>= required-assessors (var-get min-assessors-required)) ERR-INSUFFICIENT-ASSESSORS)
    (asserts! (and (>= consensus-threshold u51) (<= consensus-threshold u100)) ERR-INVALID-INPUT)
    (asserts! (> risk-id u0) ERR-INVALID-INPUT)

    (map-set assessment-sessions assessment-id
      {
        risk-id: risk-id,
        project-id: project-id,
        coordinator: tx-sender,
        required-assessors: required-assessors,
        current-assessors: u0,
        status: STATUS-OPEN,
        start-block: block-height,
        end-block: (+ block-height (var-get assessment-timeout-blocks)),
        consensus-threshold: consensus-threshold,
        final-severity: u0,
        final-probability: u0,
        final-impact: u0,
        confidence-score: u0
      }
    )

    (var-set next-assessment-id (+ assessment-id u1))

    (ok assessment-id)
  )
)

;; Join assessment session as assessor
(define-public (join-assessment
  (assessment-id uint)
  (assessor-weight uint)
)
  (let
    (
      (session-data (unwrap! (map-get? assessment-sessions assessment-id) ERR-ASSESSMENT-NOT-FOUND))
      (current-count (get current-assessors session-data))
    )
    (asserts! (is-eq (get status session-data) STATUS-OPEN) ERR-ASSESSMENT-CLOSED)
    (asserts! (< current-count (get required-assessors session-data)) ERR-INVALID-INPUT)
    (asserts! (and (>= assessor-weight u1) (<= assessor-weight u10)) ERR-INVALID-INPUT)
    (asserts! (<= block-height (get end-block session-data)) ERR-ASSESSMENT-CLOSED)

    ;; Update assessor workload
    (update-assessor-workload tx-sender true)

    ;; Update session participant count
    (map-set assessment-sessions assessment-id
      (merge session-data { current-assessors: (+ current-count u1) })
    )

    ;; Check if we have enough assessors to start
    (if (is-eq (+ current-count u1) (get required-assessors session-data))
      (map-set assessment-sessions assessment-id
        (merge session-data
          {
            current-assessors: (+ current-count u1),
            status: STATUS-IN-PROGRESS
          }
        )
      )
      true
    )

    (ok true)
  )
)

;; Submit assessment vote
(define-public (submit-assessment-vote
  (assessment-id uint)
  (severity-vote uint)
  (probability-vote uint)
  (impact-vote uint)
  (confidence-level uint)
)
  (let
    (
      (session-data (unwrap! (map-get? assessment-sessions assessment-id) ERR-ASSESSMENT-NOT-FOUND))
    )
    (asserts! (is-eq (get status session-data) STATUS-IN-PROGRESS) ERR-ASSESSMENT-CLOSED)
    (asserts! (and (>= severity-vote u1) (<= severity-vote u4)) ERR-INVALID-INPUT)
    (asserts! (and (>= probability-vote u1) (<= probability-vote u100)) ERR-INVALID-INPUT)
    (asserts! (and (>= impact-vote u1) (<= impact-vote u100)) ERR-INVALID-INPUT)
    (asserts! (and (>= confidence-level u1) (<= confidence-level u100)) ERR-INVALID-INPUT)

    (map-set assessment-participants { assessment-id: assessment-id, assessor: tx-sender }
      {
        severity-vote: severity-vote,
        probability-vote: probability-vote,
        impact-vote: impact-vote,
        confidence-level: confidence-level,
        submission-block: block-height,
        weight: u1
      }
    )

    ;; Check if all assessors have submitted
    (try! (check-and-finalize-assessment assessment-id))

    (ok true)
  )
)

;; Finalize assessment with consensus
(define-public (finalize-assessment (assessment-id uint))
  (let
    (
      (session-data (unwrap! (map-get? assessment-sessions assessment-id) ERR-ASSESSMENT-NOT-FOUND))
    )
    (asserts! (is-eq tx-sender (get coordinator session-data)) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status session-data) STATUS-IN-PROGRESS) ERR-ASSESSMENT-CLOSED)

    (try! (check-and-finalize-assessment assessment-id))

    (ok true)
  )
)

;; Private function to check and finalize assessment
(define-private (check-and-finalize-assessment (assessment-id uint))
  (let
    (
      (session-data (unwrap! (map-get? assessment-sessions assessment-id) ERR-ASSESSMENT-NOT-FOUND))
      (consensus-result (calculate-consensus assessment-id))
    )
    (map-set assessment-sessions assessment-id
      (merge session-data
        {
          status: STATUS-COMPLETED,
          final-severity: (get severity consensus-result),
          final-probability: (get probability consensus-result),
          final-impact: (get impact consensus-result),
          confidence-score: (get confidence consensus-result)
        }
      )
    )

    ;; Update assessor workloads
    (update-all-assessor-workloads assessment-id)

    (ok true)
  )
)

;; Calculate consensus from all votes
(define-private (calculate-consensus (assessment-id uint))
  {
    severity: u2,    ;; Simplified - would implement weighted average
    probability: u50,
    impact: u50,
    confidence: u75
  }
)

;; Update assessor workload
(define-private (update-assessor-workload (assessor principal) (is-joining bool))
  (let
    (
      (current-workload (default-to
        { active-assessments: u0, completed-assessments: u0, average-response-time: u0, reliability-score: u100 }
        (map-get? assessor-workload assessor)
      ))
    )
    (if is-joining
      (map-set assessor-workload assessor
        (merge current-workload { active-assessments: (+ (get active-assessments current-workload) u1) })
      )
      (map-set assessor-workload assessor
        (merge current-workload
          {
            active-assessments: (if (> (get active-assessments current-workload) u0)
                                  (- (get active-assessments current-workload) u1)
                                  u0),
            completed-assessments: (+ (get completed-assessments current-workload) u1)
          }
        )
      )
    )
    true
  )
)

;; Update all assessor workloads after assessment completion
(define-private (update-all-assessor-workloads (assessment-id uint))
  ;; Simplified implementation - would iterate through all participants
  true
)

;; Read-only Functions

;; Get assessment session details
(define-read-only (get-assessment-session (assessment-id uint))
  (map-get? assessment-sessions assessment-id)
)

;; Get assessor participation in session
(define-read-only (get-assessor-participation (assessment-id uint) (assessor principal))
  (map-get? assessment-participants { assessment-id: assessment-id, assessor: assessor })
)

;; Get assessor workload
(define-read-only (get-assessor-workload (assessor principal))
  (map-get? assessor-workload assessor)
)

;; Check if assessment is ready for finalization
(define-read-only (is-ready-for-finalization (assessment-id uint))
  (match (map-get? assessment-sessions assessment-id)
    session-data
      (and
        (is-eq (get status session-data) STATUS-IN-PROGRESS)
        (is-eq (get current-assessors session-data) (get required-assessors session-data))
      )
    false
  )
)

;; Get assessment progress
(define-read-only (get-assessment-progress (assessment-id uint))
  (match (map-get? assessment-sessions assessment-id)
    session-data
      {
        progress-percentage: (/ (* (get current-assessors session-data) u100) (get required-assessors session-data)),
        status: (get status session-data),
        blocks-remaining: (if (> (get end-block session-data) block-height)
                            (- (get end-block session-data) block-height)
                            u0)
      }
    {
      progress-percentage: u0,
      status: u0,
      blocks-remaining: u0
    }
  )
)
