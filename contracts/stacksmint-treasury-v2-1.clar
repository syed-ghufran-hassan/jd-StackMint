 ;; StacksMint Treasury Contract v2.2
;; Handles creator fee collection, royalty distribution, and platform revenue
;; Version: 2.2.0
;; Author: StacksMint Team
;; Upgrades: batch withdrawals, multi-sig execution, analytics

;; ============================================================================
;; Configuration Constants
;; ============================================================================

(define-constant CONTRACT_OWNER tx-sender)
(define-constant CREATOR_FEE u10000)           ;; 0.01 STX in microSTX
(define-constant MARKETPLACE_FEE_PERCENT u25)   ;; 2.5% marketplace fee (basis points / 10)
(define-constant MAX_ROYALTY_PERCENT u100)      ;; Maximum 10% royalty (in basis points / 10)
(define-constant MIN_WITHDRAWAL u100000)        ;; Minimum 0.1 STX withdrawal
(define-constant WHALE_THRESHOLD u10000000000)  ;; 10,000 STX for whale tier
(define-constant VIP_THRESHOLD u1000000000)     ;; 1,000 STX for VIP tier

;; ============================================================================
;; Error Constants
;; ============================================================================

(define-constant ERR_INSUFFICIENT_BALANCE (err u200))
(define-constant ERR_UNAUTHORIZED (err u201))
(define-constant ERR_INVALID_AMOUNT (err u202))
(define-constant ERR_INVALID_ROYALTY (err u203))
(define-constant ERR_WITHDRAW_FAILED (err u204))
(define-constant ERR_ZERO_AMOUNT (err u205))
(define-constant ERR_BELOW_MINIMUM (err u206))
(define-constant ERR_ALREADY_SIGNER (err u207))
(define-constant ERR_NOT_SIGNER (err u208))
(define-constant ERR_INSUFFICIENT_SIGNATURES (err u209))
(define-constant ERR_COOLDOWN_ACTIVE (err u210))
(define-constant ERR_BATCH_TOO_LARGE (err u211))

;; ============================================================================
;; Data Variables
;; ============================================================================

(define-data-var total-fees-collected uint u0)
(define-data-var total-royalties-distributed uint u0)
(define-data-var treasury-balance uint u0)
(define-data-var fee-paused bool false)
(define-data-var required-signatures uint u2)
(define-data-var withdrawal-cooldown uint u144) ;; ~1 day in blocks
(define-data-var batch-limit uint u20) ;; max batch withdrawals

;; ============================================================================
;; Data Maps
;; ============================================================================

(define-map creator-royalties principal uint)
(define-map pending-withdrawals principal uint)
(define-map authorized-signers principal bool)
(define-map withdrawal-signatures { recipient: principal, amount: uint } (list 5 principal))
(define-map user-tiers principal (string-ascii 10))
(define-map last-withdrawal principal uint)
(define-map daily-fees uint uint)
(define-map creator-lifetime-earnings principal uint)

;; ============================================================================
;; Private Helper Functions
;; ============================================================================

(define-private (is-contract-owner)
  (is-eq tx-sender CONTRACT_OWNER))

(define-private (is-authorized-signer (signer principal))
  (default-to false (map-get? authorized-signers signer)))

;; ============================================================================
;; Fee Tier System
;; ============================================================================

(define-read-only (get-fee-discount (user principal))
  (let ((tier (default-to "standard" (map-get? user-tiers user))))
    (if (is-eq tier "whale") u50
      (if (is-eq tier "vip") u25
        u0))))

(define-private (calculate-discounted-fee (base-fee uint) (user principal))
  (let ((discount (get-fee-discount user)))
    (- base-fee (/ (* base-fee discount) u100))))

(define-private (update-user-tier (user principal) (volume uint))
  (let ((current-earnings (default-to u0 (map-get? creator-lifetime-earnings user)))
        (new-total (+ current-earnings volume)))
    (begin
      (map-set creator-lifetime-earnings user new-total)
      (if (>= new-total WHALE_THRESHOLD)
        (map-set user-tiers user "whale")
        (if (>= new-total VIP_THRESHOLD)
          (map-set user-tiers user "vip")
          true)))))

;; ============================================================================
;; Public Functions
;; ============================================================================

;; Collect standard minting fee with tier discount
(define-public (collect-fee)
  (begin
    (asserts! (not (var-get fee-paused)) ERR_UNAUTHORIZED)
    (let ((discounted-fee (calculate-discounted-fee CREATOR_FEE tx-sender))
          (day-block (/ block-height u144)))
      (try! (stx-transfer? discounted-fee tx-sender CONTRACT_OWNER))
      (var-set total-fees-collected (+ (var-get total-fees-collected) discounted-fee))
      (var-set treasury-balance (+ (var-get treasury-balance) discounted-fee))
      (map-set daily-fees day-block (+ (default-to u0 (map-get? daily-fees day-block)) discounted-fee))
      (ok discounted-fee))))

;; Collect marketplace fee with royalty distribution
(define-public (collect-marketplace-fee (sale-price uint) (creator principal) (royalty-percent uint))
  (begin
    (asserts! (> sale-price u0) ERR_ZERO_AMOUNT)
    (asserts! (<= royalty-percent MAX_ROYALTY_PERCENT) ERR_INVALID_ROYALTY)
    (let ((discount (get-fee-discount tx-sender))
          (base-marketplace-fee (/ (* sale-price MARKETPLACE_FEE_PERCENT) u1000))
          (royalty-amount (/ (* sale-price royalty-percent) u1000))
          (day-block (/ block-height u144)))
      (let ((marketplace-fee (- base-marketplace-fee (/ (* base-marketplace-fee discount) u100))))
        (try! (stx-transfer? marketplace-fee tx-sender CONTRACT_OWNER))
        (var-set total-fees-collected (+ (var-get total-fees-collected) marketplace-fee))
        (map-set daily-fees day-block (+ (default-to u0 (map-get? daily-fees day-block)) marketplace-fee))
        ;; Distribute royalty
        (if (> royalty-amount u0)
          (begin
            (try! (stx-transfer? royalty-amount tx-sender creator))
            (map-set creator-royalties creator 
              (+ (default-to u0 (map-get? creator-royalties creator)) royalty-amount))
            (var-set total-royalties-distributed (+ (var-get total-royalties-distributed) royalty-amount))
            (update-user-tier creator royalty-amount)
            (ok { marketplace-fee: marketplace-fee, royalty: royalty-amount, discount: discount }))
          (ok { marketplace-fee: marketplace-fee, royalty: u0, discount: discount }))))))

;; Withdraw accumulated royalties with cooldown
(define-public (withdraw-royalties)
  (let ((amount (default-to u0 (map-get? creator-royalties tx-sender)))
        (last-withdraw (default-to u0 (map-get? last-withdrawal tx-sender))))
    (asserts! (>= amount MIN_WITHDRAWAL) ERR_BELOW_MINIMUM)
    (asserts! (>= block-height (+ last-withdraw (var-get withdrawal-cooldown))) ERR_COOLDOWN_ACTIVE)
    (map-set creator-royalties tx-sender u0)
    (map-set last-withdrawal tx-sender block-height)
    (ok amount)))

;; Batch withdrawal for multiple creators
(define-public (withdraw-royalties-batch (recipients (list 20 principal)))
  (asserts! (<= (len recipients) (var-get batch-limit)) ERR_BATCH_TOO_LARGE)
  (let ((total-withdrawn u0))
    (begin
      (for recipient recipients
        (let ((amount (default-to u0 (map-get? creator-royalties recipient))))
          (if (> amount u0)
            (begin
              (map-set creator-royalties recipient u0)
              (map-set last-withdrawal recipient block-height)
              (var-set total-royalties-distributed (+ (var-get total-royalties-distributed) amount))
              (var-set total-withdrawn (+ total-withdrawn amount))
              (try! (stx-transfer? amount CONTRACT_OWNER recipient))))))
      (ok total-withdrawn))))

;; ============================================================================
;; Multi-Sig Functions
;; ============================================================================

;; Add authorized signer (owner only)
(define-public (add-signer (signer principal))
  (begin
    (asserts! (is-contract-owner) ERR_UNAUTHORIZED)
    (asserts! (not (is-authorized-signer signer)) ERR_ALREADY_SIGNER)
    (map-set authorized-signers signer true)
    (ok true)))

;; Remove authorized signer (owner only)
(define-public (remove-signer (signer principal))
  (begin
    (asserts! (is-contract-owner) ERR_UNAUTHORIZED)
    (asserts! (is-authorized-signer signer) ERR_NOT_SIGNER)
    (map-delete authorized-signers signer)
    (ok true)))

;; Sign withdrawal request
(define-public (sign-withdrawal (recipient principal) (amount uint))
  (begin
    (asserts! (is-authorized-signer tx-sender) ERR_NOT_SIGNER)
    (let ((current-sigs (default-to (list) (map-get? withdrawal-signatures { recipient: recipient, amount: amount }))))
      (map-set withdrawal-signatures 
        { recipient: recipient, amount: amount }
        (unwrap! (as-max-len? (append current-sigs tx-sender) u5) ERR_UNAUTHORIZED))
      (ok true))))

;; Execute multi-sig withdrawal
(define-public (execute-withdrawal (recipient principal) (amount uint))
  (let ((sigs (default-to (list) (map-get? withdrawal-signatures { recipient: recipient, amount: amount }))))
    (asserts! (>= (len sigs) (var-get required-signatures)) ERR_INSUFFICIENT_SIGNATURES)
    (map-delete withdrawal-signatures { recipient: recipient, amount: amount })
    (try! (stx-transfer? amount CONTRACT_OWNER recipient))
    (ok amount)))

;; ============================================================================
;; Admin Functions
;; ============================================================================

;; Pause fee collection
(define-public (set-fee-paused (paused bool))
  (begin
    (asserts! (is-contract-owner) ERR_UNAUTHORIZED)
    (var-set fee-paused paused)
    (ok paused)))

;; Update required signatures
(define-public (set-required-signatures (count uint))
  (begin
    (asserts! (is-contract-owner) ERR_UNAUTHORIZED)
    (var-set required-signatures count)
    (ok count)))

;; Update withdrawal cooldown
(define-public (set-withdrawal-cooldown (blocks uint))
  (begin
    (asserts! (is-contract-owner) ERR_UNAUTHORIZED)
    (var-set withdrawal-cooldown blocks)
    (ok blocks)))

;; Update batch limit
(define-public (set-batch-limit (limit uint))
  (begin
    (asserts! (is-contract-owner) ERR_UNAUTHORIZED)
    (var-set batch-limit limit)
    (ok limit)))

;; ============================================================================
;; Read-Only Functions
;; ============================================================================

(define-read-only (get-total-fees) (var-get total-fees-collected))
(define-read-only (get-total-royalties) (var-get total-royalties-distributed))
(define-read-only (get-treasury-balance) (var-get treasury-balance))
(define-read-only (get-creator-royalties (creator principal)) (default-to u0 (map-get? creator-royalties creator)))
(define-read-only (get-user-tier (user principal)) (default-to "standard" (map-get? user-tiers user)))
(define-read-only (get-creator-lifetime-earnings (creator principal)) (default-to u0 (map-get? creator-lifetime-earnings creator)))
(define-read-only (get-daily-fees (day-block uint)) (default-to u0 (map-get? daily-fees day-block)))
(define-read-only (is-fee-paused) (var-get fee-paused))
(define-read-only (get-config)
  {
    creator-fee: CREATOR_FEE,
    marketplace-fee-percent: MARKETPLACE_FEE_PERCENT,
    max-royalty-percent: MAX_ROYALTY_PERCENT,
    min-withdrawal: MIN_WITHDRAWAL,
    required-signatures: (var-get required-signatures),
    withdrawal-cooldown: (var-get withdrawal-cooldown),
    batch-limit: (var-get batch-limit)
  })
