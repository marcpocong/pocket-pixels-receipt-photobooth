# Gallery performance evidence — October 30, 2026

[Full report](../../docs/gallery-drive-performance-2026-10-30.md) · [Reproduction commands and definitions](../../Tools/GalleryPerformance/README.md)

- `baseline-swift.json` / `after-swift.json`: deterministic 1/3/6-photo × 1/5/20-guest queue matrix. Real preparation/persistence/encoding, controlled network delays.
- `baseline-node.json` / `after-node.json`: actual backend/Worker source with synthetic Drive and origin/cache delays, cold/warm full-response timings and operation counts.
- `validation.json`: builds and test totals. `full-tests.json` retains the initial six unsigned-simulator Keychain failures; `auth-environment-tests.json` records all 18 affected-suite tests passing with simulator-only ad hoc signing. No tests were disabled. Other JSON files preserve baseline and focused test summaries.

In this controlled backlog model, 20-guest queue drain time improves 62–66%, with identical request byte counts. This is not a live-service latency prediction. Actual Drive API comparisons, browser first paint and hardware checks remain unmeasured; rejected alternatives and on-device checks are explicit in the report.

Google Drive remains permanent storage. The local validation snapshot involved no deployment or remote push. The owner subsequently requested publication to GitHub `main` and CI validation; see the report’s follow-up section and final handoff. No production gallery/payment, production media change, dependency, credential or project signing change was performed.
