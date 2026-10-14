# Saved Drafts implementation

## Result

The guest draft shortcut and repeated exit prompt are removed. Operator Home exposes Saved Drafts with a meaningful count. The list groups preserved drafts by event/category, explains changed values, and routes Review to the exact draft. Save and Discard are visible ahead of the receipt preview. Discard is individually confirmed and commits only after the workspace file is written successfully.

## Compatibility and boundaries

- Stable typed draft/review routes; optional payment baseline decodes older workspace records without migration.
- Autosave retained. Comparisons ignore metadata, equivalent currency text, disabled offline dates and equivalent header defaults. Unknown baselines and other-connection payment intent are preserved.
- Payment review uses existing authenticated read-only detail calls, retains optimistic-version conflicts and never publishes/activates on review. Different-connection drafts cannot contact the current server through targeted review.
- Design save preserves current links and creation metadata and does not apply to guests. Existing drafts, including Release Sample, are kept unless explicitly resolved.
- No dependencies, bundle/signing change, Worker/API change, migration, deployment, payment or print operation.

## Validation

- Final Carlo Release build succeeds; strict code-signature verification passes.
- 62 XCTest and nine Swift Testing focused checks passed (71 total), covering discovery, normalized reversion, restart, individual discard, authorization/write failure, metadata, baseline compatibility, typed routes, connection isolation, conflicts, setup and cash regressions. The final save-metadata adjustment passed two additional focused checks.
- Five retained UI captures: list/review in portrait and landscape plus empty state. Visually inspected readable changes, visible resolution actions and rendered receipt preview. Synthetic missing-logo fixture correctly displays standard-header fallback; real artwork remains private.
- Earlier compile checks found actor-default, optional exclusivity and preview-helper references; corrected before the successful candidate. No failed build was installed.
- Full Production Gate and Carlo installation/integrity results follow the committed source revision; pending at this source-preparation checkpoint.
