;; Cipher Protocol - Decentralized Identity Verification Protocol
;; Smart contract for managing identity verifications on Stacks blockchain

;; Constants
(define-constant nexus-admin tx-sender)
(define-constant err-access-denied (err u1))
(define-constant err-identity-exists (err u2))
(define-constant err-invalid-tier (err u3))
(define-constant err-identity-not-found (err u4))
(define-constant err-invalid-params (err u5))

;; Data maps
(define-map nexus-identities 
    principal 
    {tier: (string-ascii 20),
     attestation-height: uint,
     guardian: principal,
     trust-score: (string-ascii 10),
     is-suspended: bool})

(define-map nexus-guardians principal bool)

(define-map identity-chronicles
    { identity: principal, chronicle-id: uint }
    { event: (string-ascii 20),
      block-height: uint,
      guardian: principal,
      metadata: (string-ascii 50) })

(define-map identity-chronicle-counters principal uint)

;; Private functions
(define-private (is-valid-tier (tier (string-ascii 20)))
    (or (is-eq tier "VERIFIED")
        (is-eq tier "PENDING")
        (is-eq tier "DECLINED")))

(define-private (is-valid-trust-score (trust-score (string-ascii 10)))
    (or (is-eq trust-score "MINIMAL")
        (is-eq trust-score "STANDARD")
        (is-eq trust-score "ELEVATED")))

(define-private (is-valid-event (event (string-ascii 20)))
    (or (is-eq event "VERIFIED")
        (is-eq event "UPDATED")
        (is-eq event "DECLINED")
        (is-eq event "SUSPENDED")
        (is-eq event "RESTORED")))

;; Public functions
(define-public (authorize-guardian (guardian principal))
    (begin
        (asserts! (is-eq tx-sender nexus-admin) err-access-denied)
        (asserts! (is-none (map-get? nexus-guardians guardian)) err-invalid-params)
        (ok (map-set nexus-guardians guardian true))))

(define-public (revoke-guardian (guardian principal))
    (begin
        (asserts! (is-eq tx-sender nexus-admin) err-access-denied)
        (asserts! (is-some (map-get? nexus-guardians guardian)) err-invalid-params)
        (ok (map-delete nexus-guardians guardian))))

(define-public (attest-identity (identity principal) (tier (string-ascii 20)) (trust-score (string-ascii 10)))
    (let ((is-guardian (default-to false (map-get? nexus-guardians tx-sender))))
        (begin
            (asserts! is-guardian err-access-denied)
            (asserts! (is-none (map-get? nexus-identities identity)) err-identity-exists)
            (asserts! (is-valid-tier tier) err-invalid-tier)
            (asserts! (is-valid-trust-score trust-score) err-invalid-params)
            (ok (map-set nexus-identities 
                identity 
                {tier: tier,
                 attestation-height: block-height,
                 guardian: tx-sender,
                 trust-score: trust-score,
                 is-suspended: false})))))

(define-public (update-identity-tier (identity principal) (new-tier (string-ascii 20)))
    (let ((is-guardian (default-to false (map-get? nexus-guardians tx-sender)))
          (identity-data (map-get? nexus-identities identity)))
        (begin
            (asserts! is-guardian err-access-denied)
            (asserts! (is-some identity-data) err-identity-not-found)
            (asserts! (is-valid-tier new-tier) err-invalid-tier)
            (ok (map-set nexus-identities 
                identity 
                (merge (unwrap-panic identity-data) {tier: new-tier}))))))

(define-public (batch-attest-identities (identities (list 200 principal)) (tier (string-ascii 20)))
    (let ((is-guardian (default-to false (map-get? nexus-guardians tx-sender))))
        (begin
            (asserts! is-guardian err-access-denied)
            (asserts! (is-valid-tier tier) err-invalid-tier)
            (ok (map attest-single-identity identities)))))

(define-private (attest-single-identity (identity principal))
    (match (map-get? nexus-identities identity)
        prev-entry false
        (map-set nexus-identities 
            identity 
            {tier: "VERIFIED",
             attestation-height: block-height,
             guardian: tx-sender,
             trust-score: "STANDARD",
             is-suspended: false})))

(define-read-only (is-attestation-stale (identity principal))
    (match (map-get? nexus-identities identity)
        identity-data (> (- block-height (get attestation-height identity-data)) u365)
        false))

(define-private (get-next-chronicle-id (identity principal))
    (let ((current-id (default-to u0 (map-get? identity-chronicle-counters identity))))
        (begin
            (map-set identity-chronicle-counters identity (+ current-id u1))
            (+ current-id u1))))

(define-public (chronicle-identity-event 
    (identity principal) 
    (event (string-ascii 20)) 
    (metadata (string-ascii 50)))
    (let (
        (is-guardian (default-to false (map-get? nexus-guardians tx-sender)))
        (chronicle-id (get-next-chronicle-id identity))
    )
        (begin
            (asserts! is-guardian err-access-denied)
            (asserts! (is-some (map-get? nexus-identities identity)) err-identity-not-found)
            (asserts! (is-valid-event event) err-invalid-params)
            (asserts! (<= (len metadata) u50) err-invalid-params)
            (ok (map-set identity-chronicles
                { identity: identity, chronicle-id: chronicle-id }
                { event: event,
                  block-height: block-height,
                  guardian: tx-sender,
                  metadata: metadata })))))

(define-public (set-identity-suspension 
    (identity principal) 
    (suspend-status bool) 
    (justification (string-ascii 50)))
    (let ((is-guardian (default-to false (map-get? nexus-guardians tx-sender)))
          (identity-data (map-get? nexus-identities identity)))
        (begin
            (asserts! is-guardian err-access-denied)
            (asserts! (is-some identity-data) err-identity-not-found)
            (asserts! (<= (len justification) u50) err-invalid-params)
            (let ((updated-identity-data (merge (unwrap-panic identity-data) { is-suspended: suspend-status })))
                (ok (begin 
                    (map-set nexus-identities identity updated-identity-data)
                    (chronicle-identity-event identity 
                        (if suspend-status "SUSPENDED" "RESTORED") 
                        justification)))))))

;; Read-only functions
(define-read-only (get-identity-profile (identity principal))
    (map-get? nexus-identities identity))

(define-read-only (is-nexus-guardian (address principal))
    (default-to false (map-get? nexus-guardians address)))

(define-read-only (get-identity-chronicle (identity principal) (chronicle-id uint))
    (map-get? identity-chronicles { identity: identity, chronicle-id: chronicle-id }))

(define-read-only (get-latest-chronicle-id (identity principal))
    (default-to u0 (map-get? identity-chronicle-counters identity)))

(define-read-only (get-identity-analytics (identity principal))
    (let ((identity-data (map-get? nexus-identities identity))
          (latest-chronicle-id (default-to u0 (map-get? identity-chronicle-counters identity))))
        (if (is-none identity-data)
            (err err-identity-not-found)
            (ok {
                attestation-age: (- block-height 
                    (get attestation-height (unwrap-panic identity-data))),
                total-chronicles: latest-chronicle-id,
                is-stale: (is-attestation-stale identity),
                current-tier: (get tier (unwrap-panic identity-data)),
                current-trust-score: (get trust-score (unwrap-panic identity-data)),
                is-suspended: (get is-suspended (unwrap-panic identity-data))
            }))))

;; New function to update identity trust score
(define-public (update-identity-trust-score 
    (identity principal) 
    (new-trust-score (string-ascii 10))
    (justification (string-ascii 50)))
    (let ((is-guardian (default-to false (map-get? nexus-guardians tx-sender)))
          (identity-data (map-get? nexus-identities identity)))
        (begin
            (asserts! is-guardian err-access-denied)
            (asserts! (is-some identity-data) err-identity-not-found)
            (asserts! (is-valid-trust-score new-trust-score) err-invalid-params)
            (asserts! (<= (len justification) u50) err-invalid-params)
            (let ((updated-identity-data (merge (unwrap-panic identity-data) 
                    {trust-score: new-trust-score})))
                (ok (begin 
                    (map-set nexus-identities identity updated-identity-data)
                    (chronicle-identity-event identity 
                        "UPDATED"
                        justification)))))))