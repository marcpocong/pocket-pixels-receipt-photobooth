# Carlo hardware qualification — October 15, 2026

## Mode B: PASS for physical printer endurance

Read directly from Carlo's existing app container after the owner reported completion. The original app displayed **UNVERIFIED** because its verdict incorrectly counted out-of-scope release checks as missing requirements. The preserved original JSON still contains that historical event. The corrected verdict evaluates only the selected run's required checks; it does not rewrite evidence or claim full production readiness.

- Run: `87D7A3C3-96A4-46E3-9C45-87B27B5B01F0`.
- Time: October 15, 2026, 01:03:27 AM–01:42:59 AM Manila; duration 39 minutes 32 seconds.
- Device: Carlo, iPad Pro 11-inch (4th generation), iPadOS 26.6.1; app 1.0 (1).
- Printer: VOZY G80; Bluetooth Auto / Balanced / Experimental Balanced policy.
- Plan: seed 20261009, 100 sessions, all six formats; 125 receipts.
- Sessions: 100 passed, zero failed; 125 jobs completed and 125 receipts operator-confirmed on paper.
- Violations, stale-callback violations, unsafe retry attempts and duplicate detections: zero.
- Checkpoints acknowledged: printer power cycle (session 62), background/return (63), gallery attestation (90). Gallery delivery is attestation only, not a qualification upload.
- Peak reported memory: 91 MB.
- Commit SHA, paper stock and operator name were not recorded by the tested build. Do not retroactively attribute this run to the new hands-free build.

Evidence: [original device record](mode-b-original.json), [session table](mode-b-sessions.csv).
Original JSON SHA-256: `e8ae87f5d168e31e4b67043a977f12115a25fbd2c594610242072f818307f88f`.

## Remaining release evidence

Mode B uses diagnostic photos and does not validate live-camera sessions. The separate camera/session Mode C, Bluetooth disconnect during bytes, paper-out/reload and multi-hour operation are still outside this successful printer endurance result. The 39-minute run is not a multi-hour test. Existing October 9 Mode C was stopped at session 18 while waiting for Photo Pass input; it does not satisfy the 100-session requirement.

## Updated app

Mode C now defaults to hands-free: one explicit approval covers the selected complete run; real captures, diagnostic Photo Pass details/signature, receipt composition, printing, archive verification and reset advance automatically. Routine physical checkpoints are skipped and remain unverified. Fault gates, uncertain-print handling and operator stop/pause controls remain active. Supervised Mode C remains available by switching Hands-free run off. Mode B printing behavior is unchanged; its PASS badge identifies printer endurance scope.

Validation: simulator build and all 25 qualification tests passed across the full run and a focused rerun after updating one old scoped-verdict expectation. The signed Release build for Carlo passed; strict signature, unchanged bundle/team, iPad-only device family and provisioning membership were verified. Release executable SHA-256: `54c52937646b84cefd9ef74699adf97dd3aa68367dabb7f6109db214b2812fa1`.

A private pre-install copy contains 2,404 app-container files (2,167 Application Support files), including all four historical qualification records. No private app backup, customer photos or credentials are included in Git. Installation is pending at this source/evidence commit.

## Carlo installation completed

- Source/evidence commit: `1ce96e6` (pushed to GitHub main before installation).
- Signed Release app 1.0 (1) installed successfully in place with `devicectl`, using the unchanged bundle ID and signing identity. No uninstall or data reset.
- The new application launched successfully on Carlo. No new qualification or physical print test was started.
- Completed before/after SHA-256 comparison: **2,185 protected files, zero missing, zero changed** across Application Support, preferences and Documents. All four original qualification JSON records are unchanged. Private backups remain outside Git.
- The app derives the new scoped PASS from the unchanged historical Mode B evidence; its original event log continues to say UNVERIFIED, preserving what the earlier build reported.
- Physical hands-free Mode C execution remains to be performed on the new build. Installation does not retrospectively qualify that build's camera pipeline or printer behavior.

Installation verification recorded October 15, 2026, 01:49 AM Manila.

## Mode C copy-authorization and Stop run correction

After the initial hands-free rollout, Carlo's Mode C run `F6455FE5-F5B5-4F28-BCFB-3D5FCBF1962C` completed its first 22 sessions, then hit its five-copy Grid 6 batch at session 23. The harness changed the requested copy count but retained the session's one-copy private-prepaid entitlement. The production quantity guard rejected the print before transport. The harness's popup reported stale “Receipt ready” status instead of the printer error; repeated Retry could not fix the mismatch.

The popup's Stop run response also only failed the current session and allowed the loop to advance. The owner used the separate Abort control; the saved record is stopped, contains 25 attempted sessions and 23 transmitted receipts, and has no in-flight print checkpoint. No physical paper confirmation was collected in the hands-free run. This is not a passing complete Mode C run. The original device record is preserved in [mode-c-stopped-original.json](mode-c-stopped-original.json).

The correction authorizes the selected diagnostic copy quantity through a qualification-only view-model entry point after the engine's run-bound budget/safety gate. It rejects customer sessions, paid entitlements, invalid quantities and active print batches; the normal production print quantity guard remains in place. The entry point also handles remaining-copy retries. Printer failures now supply the popup's actual error. Every Stop run prompt response sets the run-wide abort/stop flags, and no later scenario/checkpoint starts after that stop.

Regression coverage includes diagnostic quantities 1/2/3/5/10, remaining-copy retry authorization, customer rejection, invalid quantities, and Stop run ending the run without a second session. Installation evidence follows after checks complete.

Stopped Mode C original JSON SHA-256: `f4890935e4b0a096d7283f7d13fcea1d62e8146d2a577e823ba6ff9e65abbc93`.

Validation: all **27 hardware qualification tests passed** in the full simulator suite. Signed Release build and strict signature/identity verification passed for Carlo. Corrected executable SHA-256: `d8f77f6fa3734ba1cfbbf2364e484efd2a8444e0d198d6167d793ea64bdde5b2`.

The corrected signed Release app from source `ed1b95e` was installed in place and launched on Carlo. Complete before/after SHA-256 comparison verified **2,378 protected saved-data files unchanged**, with zero missing or changed files, including the stopped Mode C and successful Mode B evidence. No new print or qualification test was started. Physical confirmation of the corrected multi-copy Mode C batch remains outstanding.
