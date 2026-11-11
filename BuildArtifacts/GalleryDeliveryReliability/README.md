# Gallery delivery evidence — 11 November 2026

These compact JSON reports contain numeric synthetic-test evidence only. Raw logs,
xcresult bundles, Google resource IDs, session capabilities, historical customer
URLs and deployment rollback snapshots remain in the owner's private application
support directory and are excluded from Git.

- `baseline-durable.json`: original automatic recovery on baseline main, actual
  disk/media with controlled 20 ms POST / 80 ms verification delays.
- `pipelined-durable.json`: same benchmark/media after bounded recovery pipelining.
- `paced-tcp-matrix.json`: actual durable recovery over paced local TCP; includes
  20/50/100 strong backlogs, 0.5 Mbps weak20, improvement and lost-ACK cases.
- `adaptive-tcp-matrix.json`: final automatic-selection strong100/improvement20
  follow-up. Receipt timestamps differ from the earlier matrix.
- `live-drive-microexperiment.json`: real Google HTTPS, scoped sessions and exact
  hash/offset validation of private synthetic non-image files.
- `historical-readiness.json`: read-only live baseline check of an existing
  completed gallery, with all identities/URLs omitted.
- `backend-gate.json`: final backend suites and available numeric counts.
- `production-gate.json`: complete production suite; `final-mixed-backlog-tests.json`
  records the final-source affected recovery/scheduler/transport gate.
- `final-native-ui.json` and `final-ui-focused-retry.json`: initial 27/28 UI pass
  and the unchanged failing test's successful focused rerun. The initial failure
  is retained rather than hidden.
- `live-backend-validation.json`: real Apps Script/Drive/public Worker synthetic
  lifecycle, numeric evidence read from the completed owner execution log.
- `historical-after-worker.json` / `historical-after-backend31.json`: existing
  gallery readiness after the respective production deployments.
- `deployment-record.json`: exact active/rollback versions, preserved settings
  and remaining physical-device/hosted-CI blockers.
- `carlo-device-installation.json`: signed Release build, original identity,
  installed app and successful trusted launch; seven-day profile expiration.

The live backend report qualifies the server-side synthetic lifecycle. None of
these is a physical-iPad venue benchmark. See the [engineering/release record](../../docs/gallery-delivery-reliability-2026-11-11.md)
for methods, limitations, final gates, deployment and rollback status.
