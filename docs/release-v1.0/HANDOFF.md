# Implementation handoff and release gates

**Phase 1 complete, 24 November 2026, Asia/Manila. Phase 2 may begin; stable release remains blocked.** Baseline `8baadb77c53321c576d4fe160efc66def199b8b8`; only preservation/documentation changed. Start with [readiness](README.md), [preservation](PRESERVATION.md) and the [concrete contract](PAYMENT-TRANSITION.md). Those documents replace another broad re-audit unless fresh repository/deployment state differs.

## Ordered backlog

| Priority / phase | Deliverable | Completion evidence |
| --- | --- | --- |
| P0 / Phase 2 first | Independent, default-off PayMongo creation flag; separate health/rollout semantics | TEST proves no new provider call/method lock with creation disabled, while legacy original status/reconciliation/webhooks/claims/print reporting still work. Keep inactive LIVE acceptance and existing legacy recovery available. This is a small protective prerequisite, not a provider replacement. |
| P0 / owner before Dec 1 | Inspect PayMongo account applicability, balances, payouts/refunds/disputes and exports | Private provider ledger/export and owner disposition. Supplied notice: December 1 key rotation/wallet/method restrictions; January 29, 2027 23:59 PHT existing Individual upgrade deadline. No automatic financial closure or transfer by Codex. |
| P1 / Phase 2 | New local/manual authority and durable cash path, immutable policy/receiving revisions, explicit Codable migration | Old records decode unchanged; provider policies never silently become manual; independent Regular/Event modes, offline free/cash, exact copies/format/price and original legacy recovery. Address TEST's missing 0008 in the controlled migration sequence. |
| P1 / Phase 2 | Mobile checkout, kiosk/mobile acknowledgment, scoped tokens, isolated receipt backend/private Drive lifecycle | Synthetic optional/required uploads, interruption/duplicate/lost-response and negative ACL/capability checks; every accepted receipt demonstrably private and recoverable. Required receipt cannot be bypassed. Digital starts disabled. |
| P1 / Phase 2 | Workspace integration, post-session verification, event/regular financial reporting and CSV | Reuse V5.1 routes/designs. Acknowledged versus funds-confirmed versus historical provider verification/cash provenance and physical utilization stay distinct. Pending review does not block unrelated guests. |
| P1 / Phase 3 | Practical backup/export/import/replacement recovery | Encrypted authenticated portable snapshot, schema/hash validation, isolated nonprinting restore, original identities/uncertain print protections, separate credential re-pairing. Cover settings/design/artwork/history/reports/checkpoints/pending galleries/receipt references/local payment journals. Do not restore an old D1 dump over newer history. |
| P1 / Phase 3 | Targeted hardening, security/retention/quotas and compatibility deployment | Private receipt root/project ACL proof; production migration/export checks; same gallery deployment/URLs; bounded polling and no read amplification. Inventory provider retirement obligations and keep unresolved duties isolated. |
| P1 / Phase 3 owner | Sustainable signing/distribution and CI account disposition | Preserve bundle/team/Keychain. Renew temporary profile only as temporary; inspect eligible paid individual registered-device distribution without purchasing/changing team silently. Owner handles billing/account decisions; equivalent local gate must be explicit if hosted CI is still unavailable. |
| P1 / Phase 3 | Freeze complete candidate, version 1.0.0 / new build, final production gate, signed binary and in-place Carlo install | Exact commit, build/binary hashes, code signature/profile expiration, pre/post data-retention proof, actual launch/connectivity, rollback ledger; annotated `v1.0.0-rc.1` prerelease. No uninstall/reset. |
| P1 / Phase 4 | Physical sustained qualification and supervised pilot | Camera, actual BLE/TCP paper, interruption/relaunch/network/mobile browsers and realistic ~100 sessions/~4–6 hours with observed counts/duration. Zero lost sessions/unauthorized duplicate prints. Promote same candidate to `v1.0.0` only when gates pass. |
| P2 / later | Maintenance/refactoring and historical-host recovery | Only demonstrated need, with scope/compatibility evidence. No paper-gap work, new automated gateway, OCR, banking-app automation, broad UI redesign or gallery rewrite. |

## Focused Phase 2 verification

Build after each meaningful implementation change as required by `AGENTS.md`; batch coherent changes. Run affected regressions once per changed boundary. No full application suite was run in Phase 1. The full final production/backend gate belongs to the frozen candidate in Phase 3.

Retain existing tests and their assertions. Especially preserve:

- `PocketPixelsBoothTests/EventLifecycleIntegrationTests.swift:242` — `testAcknowledgedUnknownPrintAllowsRelaunchRegularGuestEventStartAndEnd`.
- The same file at `:308` — `testParkedPaidGuestRelaunchNextRegularGuestAndFreeEventCycleKeepsOutstandingEvidence`.
- `CloseContinueRecoveryTests`, `PrintDurabilityTests`, `PrintReliabilityTests`, `PrepaidCopyAuthorizationTests`, checkout concurrency/recovery and event isolation tests for touched authorization/lifecycle code.
- `GalleryDeliveryHardeningTests`, `GalleryResumableTransportTests`, `GallerySchedulerV2Tests`, `GalleryFrontDoorMigrationTests` only if shared startup/storage/network/report code is affected. Do not rerun unrelated gallery benchmarks for payment labels.
- Existing Worker migration, scope/account/environment, method-lock, canonical webhook/reconciliation, entitlement/print and report tests. Add populated-table migration and v1/v2 compatibility tests rather than tests that merely echo new fields.

Add meaningful cases for kiosk/mobile acknowledgment racing required-receipt finalization, lost creation responses/capability recovery, expired/closed/foreign tokens, mismatched idempotency payloads, disabled/unconfigured receiver, account revision changes, local cash disk failure/relaunch/import duplication, optional versus required storage outages, image bounds/unsafe ACLs and a late receipt after a different guest/event starts. Receipt acceptance, funds confirmation and print authority must be asserted independently.

For the entitlement migration, verify every legacy row/ID/source/child relation and historical report amount/category against isolated pre-migration data. Test unknown print and in-session entitlement cases, not just an empty schema. Never put the private SQL exports into repository fixtures.

## RC acceptance checklist

These are gates, not results claimed in this audit.

- [ ] New sessions use no PayMongo creation/credential dependency. Independent disabled-creation health is confirmed in production; outstanding legacy retrieval/reports remain supported or explicitly unresolved.
- [ ] All payment modes work in Regular Booth and Event Mode as configured; free/cash work offline; missing permitted receiver disables digital. Event/design/format/copy/price snapshots cannot drift after admission.
- [ ] Each mobile QR is unique and scoped to its session; exact quantity/total and frozen receiver display correctly. Guest capability cannot claim entitlements or reach operator APIs.
- [ ] Acknowledgment-only, optional and required receipt policies behave distinctly on kiosk and mobile. An upload or acknowledgment never claims independent funds verification. Required policy never authorizes before private storage acceptance.
- [ ] Every accepted receipt has durable exact-checkout association and verified private Drive storage. Anonymous gallery/public Drive/download routes cannot retrieve it. Lost responses/resumes create no duplicates.
- [ ] Operator review and corrections are auditable, financial categories are accurate and overlapping totals are not double-counted. Historical PayMongo and cash provenance remain unchanged; unresolved obligations stay unresolved.
- [ ] Current checkout/media/print recovery survives termination and restoration. Inspection → acknowledgment → relaunch → different Regular guest → different event → end retains old evidence and prevents retrying possibly printed copies.
- [ ] Event reports/review/gallery sync do not create global guest locks. End/archive/removal and staged/live editing preserve existing V5.1 safeguards.
- [ ] Backup is restorable in isolation, no silent data loss is demonstrated, low-storage/corruption paths retain recoverable originals, and no unreviewed financial/media purge is scheduled.
- [ ] Production quotas/headroom, endpoint auth/rate limits/log privacy and compatibility/rollback versions are checked. Gallery source/URLs/resumable journals remain compatible; LIVE health index stays effective.
- [ ] Complete final native production/UI and backend gates pass on the candidate, with exact toolchain/results recorded. Infrastructure failures and physical limitations are distinguished from product failures.
- [ ] Marketing 1.0.0 / unique build is signed under compatible bundle/team; sustainable distribution chosen or explicitly blocked; exact profile expiration and binary hash recorded privately.
- [ ] Carlo is connected/unlocked/trusted, pre-install state preserved, candidate installed in place, launched and independently confirmed with data retention and intended-service connectivity.

Only after the complete candidate satisfies these gates should `v1.0.0-rc.1` be published. Do not upload private-device binaries/provisioning to the public repository/release.

## Stable acceptance

Use the exact installed RC binary. Exercise actual camera, print quality/copy quantities, BLE and TCP, paper depletion, printer interruption/restart, app relaunch, guest/event continuation and offline/weak/Wi-Fi-to-hotspot gallery recovery. Test representative Android/iOS checkout/receipt browsers with synthetic evidence; financial transfers are an owner activity. Do not reopen the accepted G80 gap.

Record actual session count, duration, physical observations and pilot outcome; simulator successes are not physical evidence. The target is approximately 100 realistic guest sessions over four to six cumulative hours, with no lost media/sessions or unauthorized duplicate/copy expansion. If hardware, pilot, signing or financial acceptance remains unresolved, retain RC status and list the exact gate. Correct only demonstrated blockers, create a new unique candidate when code changes, and requalify affected behavior. If the existing candidate passes unchanged, promote the same source/binary without an unnecessary rebuild/full-suite repeat.

## Owner actions and administrative access limits

1. Before December 1, inspect PayMongo Dashboard/support applicability and export/resolve provider financial obligations. App D1 records do not establish wallet funds or settlements. The full notice was supplied in chat; account sign-in and provider-ledger inspection were not completed.
2. Supply/configure an appropriate receiving account permitted for this use and its authorized QR in the application's future private settings, not in Git. Confirm account suitability; do not treat a manual flow as automatic permission from a provider.
3. Decide sustainable Apple distribution using the existing compatible identity/team. Current matching local profiles are expired; membership, purchases or team changes require an owner decision. Connect and unlock Carlo during later release work.
4. Resolve GitHub's hosted-CI billing lock if hosted gates are required. No subscription, billing or account-access change was made. Subscription API/Drive quota headroom and authenticated Apps Script version/properties need later readback before rollout.
5. Preserve the restricted local backup and arrange encrypted off-device custody. Portable iPad restore remains implementation/qualification work, not a claimed property of that Git backup.

## Next Codex session

Read `AGENTS.md` and these four files, then `git fetch origin --prune` and inspect the working tree/diff. Start from the delivered documentation commit on `main`, preserving the permanent legacy tag. Recheck changed production facts only when acting on them. The working tree was clean at Phase 1 start, but the pre-existing October safety stash and auxiliary Codex tree ref are preserved (see preservation ledger); do not apply/drop them or assume later sessions are clean.

Begin Phase 2 with the narrow creation flag and its tests, then implement the specified manual system coherently. Keep bundle ID/team, storage keys, Keychain service IDs, portrait orientation, receipts, camera/printer/gallery separation, archived data and recovery invariants. Do not repeat the legacy archive, overwrite the tag, create a second active canonical repository or blindly replay any migration/deployment. Use the private backup path in `PRESERVATION.md` for existing export evidence; fresh production mutations still need a fresh compatible backup/ledger check.

Phase 1 validation: backup/ref/SQL restore and read-only production evidence passed; no full app/backend regression suite or physical transaction was run. One final simulator build is recorded below. The code baseline is unchanged, so no claim of new payment functionality, RC or stable qualification is made.

**Simulator build: PASS**, Xcode 27.2 (27B52), generic iOS Simulator, existing `PocketPixelsBooth` scheme, ad hoc simulator signing, exit 0. No app/project/backend source changed. Existing compiler warnings remain, principally actor isolation/concurrency in unchanged code (see R18). Private raw log: `phase1-simulator-build.log` in the preservation backup directory. The retained V5.1 app also passed `codesign --verify --deep --strict`; this verifies its signature, not the usability of its expired provisioning. `git diff --check` and local Markdown link checks passed. No redundant build or full regression rerun is needed for this documentation result entry. The documentation-only delivery commit uses `[skip ci]` to avoid triggering full hosted suites for unchanged application/backend code; this does not change or certify the baseline's failed hosted gate.
