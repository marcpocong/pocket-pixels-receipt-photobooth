# Phase 3.2 — payment-first checkout

**Made to Keep Studios 1.0.0 (5)** · **v1.0.0-rc.2** · **25 November 2026, Manila**

The iPad shows the configured receiving QR, exact amount and copy count. When the account has no QR, it shows the receiving details. Guests enter the amount in their payment app and tap **I’ve paid**. Receipt upload uses a separate QR and the existing camera opens as soon as the chosen policy is satisfied.

| Receipt policy | Guest experience |
| --- | --- |
| Acknowledgment Only | Local acknowledgment opens the camera, including while the checkout backend is offline. |
| Optional Receipt Submission | The guest can upload a screenshot or choose **Skip for now**. The first completed choice opens the camera. Later evidence stays attached to the original checkout. |
| Required Receipt Submission | The booth verifies the original checkout link and the signed private Drive connection before it shows payment details. Acknowledgment plus the matching stored receipt opens the camera automatically. An outage before payment offers retry and cash when the operator enabled it. |

The mobile page accepts one screenshot submission with an explicit transfer notice and shows confirmation after verified Drive storage. Existing capability links remain usable. Receiving revisions, payment amount, session, copy count and entitlement identity are frozen. Receipt evidence, guest acknowledgment, independent funds review and physical print outcomes retain their existing meaning. Recovery retains the original claim and uses the existing safeguards for copies that may have printed.

## Screenshots

The iPad screenshots are from the 11-inch simulator with fictional receiver details and synthetic QR payloads. The mobile screenshots use a fictional receipt.

| iPad policy or state | Payment | Receipt |
| --- | --- | --- |
| Acknowledgment Only | [Payment QR](assets/phase3.2/ipad-ack_only-pay.jpg) | |
| Optional | [Payment QR](assets/phase3.2/ipad-optional-pay.jpg) | [Receipt QR and Skip](assets/phase3.2/ipad-optional-receipt.jpg) |
| Required | [Payment QR](assets/phase3.2/ipad-required-pay.jpg) | [Receipt QR and waiting state](assets/phase3.2/ipad-required-receipt.jpg) |
| Required, prepayment outage | [Retry and cash alternative](assets/phase3.2/ipad-required-unavailable.jpg) | |

- WebKit widths [320](assets/phase3.2/mobile-320.png), [375](assets/phase3.2/mobile-375.png) and [430](assets/phase3.2/mobile-430.png) points.
- LIVE Chrome at 375 points. [Receipt selection](assets/phase3.2/live-mobile-375.png) · [Preview and submit](assets/phase3.2/live-mobile-preview-375.png) · [Confirmation](assets/phase3.2/live-mobile-received-375.png).

The kiosk reuses the Made to Keep wordmark, burgundy, cream paper texture, editorial type, and primary button treatment. Each checkout screen has a single QR with a wide quiet zone. Optional and required policies show subdued step progress.

## Validation and LIVE rollout

- **22 native and WebKit tests passed.** The run covered all three policies, readiness gating, cash fallback, original identity, camera progression, relaunch and next-guest/event recovery, physical print intent and lost upload confirmation. A software decoder verified the payload of each rendered checkout QR.
- **26 Worker and private receipt bridge tests passed.** The run covered signed owner-private readiness, lost and duplicate submissions, late receipts on the original checkout, authenticated preview compatibility and existing print evidence bounds.
- **LIVE Payments Worker 9b552bae-a6ba-4954-823c-24a51cbf19ab.** Live and manual checkout are enabled. New PayMongo creation and legacy scheduled reconciliation remain disabled. The deployed bindings matched RC 1. The private receipt Apps Script deployment advanced to **version 9** for the signed read-only readiness check. It retains the existing roots and keys. D1 schema, gallery and monitoring deployments stayed in place.
- LIVE Chrome submitted fictional evidence in one action. The stored receipt matched the original session and copy count. Duplicate submission retained the same receipt ID. The authenticated operator preview matched the stored image hash, and the Drive root, receipt folder and file were owner-only. The synthetic checkout was closed and its scoped test credentials revoked.

For a rollback, restore Worker version d5d9dae3-98d2-4c02-9781-3fdb7e0029b9 with the existing LIVE bindings. Keep bridge version 9 available while a kiosk running build 5 uses Required Receipt Submission. Version 9 also serves the prior upload contract. Preserve D1 and Drive evidence.

## Carlo and distribution

The signed Release archive preserves com.pocketpixels.PocketPixelsBooth, its entitlements and fixed iPad portrait. The compatible profile includes Carlo and expires **2 December 2026 at 12:14 a.m. Manila time**. The archive and signing evidence remain in the private owner handoff.

Carlo was updated in place and launched as **1.0.0 (5)**. The wired display showed the Welcome screen. All 15 pre-existing files were byte-identical before and after launch, including the enabled receiving account, payment journal and operator settings. The checkout screens and QR payloads were exercised on the simulator with fictional details. Physical checkout navigation, QR scanning, phone compatibility and the sustained hardware qualification remain open.
