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
