# Close & Continue implementation evidence

October 24, 2026 (Asia/Manila). Branch `codex/close-continue-recovery`, main baseline `3ff44be6653b121e2a1b519f4670065082ec2d7a`. Validation was recorded before publication. The owner subsequently authorized committing, pushing and merging these changes; see GitHub history for delivery. No production deployment or physical device update was performed.

The [operator and technical runbook](../../docs/close-continue-recovery.md) covers root causes, exact changes, financial and physical boundaries, persistence paths, limitations and the 28 requested regression categories.

## Screen review

Actual SwiftUI views hosted by `OperatorDashboardV2Tests` in the iOS 27 iPad simulator, exported from `/tmp/pp-close-verified-focused27.xcresult`:

- [Help & Recovery, portrait](help-recovery-portrait.png)
- [Help & Recovery, landscape](help-recovery-landscape.png)

These show an idle/reconciled recovery screen. The rendering suite also covers Home, staged setup, reports, Regular Booth settings and large text. The screenshots do not demonstrate live payment, actual receipt output or all interrupted-state confirmations. Recovery state and button policy are additionally covered by persistence-backed tests.

## Validation

| Check | Result |
| --- | --- |
| Complete iOS 27 production suite | **782 passed**, zero failures/skips |
| Complete iOS 26.5 supporting production suite | **781 passed**, zero failures/skips |
| Final iOS 26.5 focused recovery/lifecycle/payment/print/UI suite | **143 passed**, zero failures/skips/test runtime warnings |
| iOS 27 focused recovery/lifecycle/payment/print/UI suite | **142 passed**, zero failures/skips/test runtime warnings |
| Debug simulator builds throughout implementation | Passed |
| Signed device Release build and `codesign --verify --deep --strict` | Passed |
| Payments Worker / syntax | **223 passed** / passed |
| Monitoring Worker | **9 passed** |
| Gallery proxy | **39 passed** |
| Apps Script pure/schema/storage/retry/readiness | Passed |

The complete runs retain the same internal QoS priority-inversion runtime warning previously documented on main. Existing repository Swift 5 isolation/deprecation warnings remain. The newly introduced default server-binding isolation warning was corrected; the final focused build/run has no such conformance warning.

The supporting iOS 26 full run preceded the final idle unfinished-send and resume-asset guards. The iOS 27 complete run includes those final behavioral changes. An explicit nonisolated declaration was then verified by the final iOS 26 focused run and signed Release build. Machine-readable summaries record these boundaries and SHA-256 digests of the delivered production Swift files.

Relevant bundles/logs:

- `/tmp/pp-close-production27.xcresult`, `/tmp/pp-close-production27.log`
- `/tmp/pp-close-final-full26.xcresult`, `/tmp/pp-close-final-full26.log`
- `/tmp/pp-close-delivery-focused26.xcresult`, `/tmp/pp-close-delivery-focused26.log`
- `/tmp/pp-close-verified-focused27.xcresult`
- `/tmp/pp-close-signing-check.log`

Initial targeted runs exposed assertions relying on hidden physical acknowledgement, false success after an ACK write failure, and unchanged local paid-cancellation state. They were corrected to assert durable review/parking and preserved financial evidence. New fixtures were corrected to use disk-normalized timestamps and a real pre-checkout snapshot. Older interrupted/superseded runs are not counted as completed passes.

No physical iPad acceptance, physical printing, live payments, production event changes, deployment or physical device update was performed. Owner-supervised camera, paper/transport, payment-provider, force-quit and accessibility acceptance remain outstanding. Partly printed purchases stay protected and require explicit review; the app never automatically sends a possibly printed copy.


`final-git-status.txt` is the pre-publication validation snapshot. Publication commits do not change the validated production source.

## Changed files

| Files | Responsibility |
| --- | --- |
| `PocketPixelsBooth/PaymentCheckoutRecovery.swift` | Transactional resolution, independent parking/closure history, legacy migration, authoritative classification, race handling, outstanding items and server-only receipt review. |
| `PocketPixelsBooth/PrintOutcomeOutbox.swift` | Explicit recovery-write failures/retry, exact-copy inspection, protected corrupt originals, durable completion and report ACK accounting. |
| `PocketPixelsBooth/AppRecoveryStore.swift` | Critical acknowledgement file, unique checkpoint identity, idempotent retained snapshots and corrupt-checkpoint protection. |
| `PocketPixelsBooth/DetachedCheckoutStore.swift` | Separate operator asset retention, safe snapshot lookup for resume, and weak access to the mounted guest controller. |
| `PocketPixelsBooth/BoothSessionViewModel.swift`, `BoothSessionView.swift` | Durable close/cancel, late callback isolation, original resume/asset protections, no-byte refinement and consistent admission/print policy. |
| `PocketPixelsBooth/SessionSetupCoordinator.swift` | Typed scoped decisions and correct recovery destinations; parked obligations no longer freeze unrelated operation. |
| `PocketPixelsBooth/EventOperationalState.swift` | Saved receipt checks, transactional closure orchestration, explicit errors and current-versus-historical recovery state. |
| `PocketPixelsBooth/EventOperationsView.swift` | Shared Close & Continue workflow, outstanding payments and direct return-to-operation controls. |
| `PocketPixelsBooth/PaymentsOperatorView.swift` | Reusable checkout recovery list, visible parked obligations/copy evidence, retry feedback and offline-ledger connection protection. |
| `PocketPixelsBooth/PaymentsAPIClient.swift` | Read-only original server-binding identity. |
| `PocketPixelsBooth/OperatorDashboardView.swift`, `ProductionHealth.swift` | Recovery shortcut and current-action health separate from parked follow-up. |
| `PocketPixelsBoothTests/CloseContinueRecoveryTests.swift` | New disk-backed fault, lifecycle, evidence-retention, idempotency and scoped-gate regressions. |
| `PocketPixelsBoothTests/PaymentRecoveryConcurrencyTests.swift` | Park/refresh races, late verification, durable unpaid retry and server-only paper review. |
| `PocketPixelsBoothTests/EventLifecycleIntegrationTests.swift` | Full paid park/inspection/relaunch/new guest/event cycle and exact-copy acknowledgement in the existing cycle. |
| `PocketPixelsBoothTests/LiveEventPaymentRecoveryTests.swift` | Held verification after authorized close cannot authorize the next guest. |
| `PocketPixelsBoothTests/EventFinalizationTests.swift`, `PaymentsPhase4Tests.swift` | Updated durable paid-cancel, legacy-dismissal, physical-review and report-write expectations. |
| `docs/close-continue-recovery.md` | Operator instructions, production decisions, storage/runbook details, coverage matrix and limitations. |
| `docs/recovery-friction-prevention.md`, `docs/payments-phase2-operator-runbook.md` | Links to the current unified recovery workflow. |
| `BuildArtifacts/CloseContinueRecovery/` | This report, machine-readable test summaries and two reviewed SwiftUI screenshots. |

The pre-existing untracked `.claude/` directory was left untouched. Tests regenerated existing gallery screenshots and receipt/raster fixtures; those initially clean generated outputs were restored to their baseline after testing. Xcode project, Info.plist, backend source and dependency files remain unchanged.
