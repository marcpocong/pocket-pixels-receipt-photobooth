# Curated portrait and printer evidence

This directory versions the [historical delivery record](delivery-report.md), [G80 spacing investigation](g80-spacing-investigation.md), and the three synthetic operator screenshots linked by the delivery record:

- [Logo controls](carlo-portrait-receipt-header-logo-controls.png)
- [Typography controls](carlo-portrait-receipt-typography-controls.png)
- [Sticker review status](carlo-portrait-review-sticker-enabled.png)

The final empty-studio acceptance case also captures the complete receipt placeholder and disabled Print Sample action, without importing customer photos:

- [Black & White placeholder](empty-sample-black-and-white-placeholder.png)
- [Thermal placeholder](empty-sample-thermal-placeholder.png)

Final operator controls from the isolated run-management acceptance case:

- [Rename editor and clear-name control](event-rename-editor.png)
- [Run management actions](historical-run-management-actions.png)
- [Run removal review with explicit Cancel](historical-run-removal-review.png)

The current result and source/test map are in the [27 October handoff](../../docs/development-handoff-2026-10-27.md). The owner accepts the G80's remaining 16–17 mm physical bottom gap; digital margins are normal and paper-only blank-row trimming is retained. The failed cut-and-return probe is retired from production UI.

The delivery record's other named logs, `.xcresult` bundles, local screenshots and device inventory comparisons refer to local validation evidence at those historical checkpoints. Complete app-container inventories, raw build caches, signing files and local agent permissions are intentionally not published. Current exact-run test bundles are available from [GitHub Actions](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/workflows/ci.yml).
