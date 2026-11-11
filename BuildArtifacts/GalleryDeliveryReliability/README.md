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

None of these is a physical-iPad venue benchmark or full live Apps Script
transport-deployment acceptance. See the [engineering/release record](../../docs/gallery-delivery-reliability-2026-11-11.md)
for methods, limitations, final gates, deployment and rollback status.
