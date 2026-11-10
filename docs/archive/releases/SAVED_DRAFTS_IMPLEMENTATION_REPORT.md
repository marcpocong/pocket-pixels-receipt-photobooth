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
- The unfinished-new-event review also omits unentered, unchanged fields; its focused regression test and a fresh signed Release build passed.
- Initial iOS Production Gate job `115956102661` passed all 408 XCTest and 89 Swift Testing checks (497 total). Its overall run still failed the separate backend throttle test described below.
- Final app source is `4ea7dd300f2bb5acf5fd1af504b935fb657e4a86`, with a frozen signed candidate and strict signature verification. [Production Gate 38596623171](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/runs/38596623171) passed both jobs: 409 XCTest plus 89 Swift Testing checks (498 iPad tests), with zero failures; backend checks also passed.

## Carlo rollout — October 15, 2026

After the final CI pass, a fresh 1,400-file app-container backup was retained privately. The candidate installed once in place and launched successfully at approximately 00:57 Manila. A direct device screenshot verifies Welcome without the draft shortcut.

The post-install copy also contains 1,400 files. Every Application Support file retains its exact hash, including the design library, genuine Release Sample draft, payment journals, artwork, receipt archives and print audit. Preferences dictionaries are identical. Changes are limited to the dyld cache and four replaced system launch snapshots. No saved draft was resolved during installation. Bundle ID, signing and existing app identity are preserved. No event, price, payment or print operation was performed.

List/review rendering was verified in both iPad orientations in the focused test run. The owner then opened Saved Drafts → Release Sample → Review on Carlo. A direct portrait screenshot at approximately 00:59 verifies the exact preserved draft, three human-readable changes (personalization, logo artwork, header mode), visible Edit/Save/Discard actions and the rendered co-branded thermal receipt preview. The draft remains unsaved, undiscarded and unapplied.

A further container copy after operator review confirms the genuine design draft is identical. The only changed Application Support file is the operator workspace: its navigation path advanced and equivalent payment-draft records were pruned after the read-only server comparison. All other support files, including financial and print records, retain their pre-install hashes.

## CI timing correction

Production Gate `38594060132` failed its backend job because the existing authentication throttle test crossed a UTC minute boundary: its request burst began at 15:58:59 and ended at 15:59:00, legitimately resetting the fixed-minute counter. This was not caused by draft UI or a deployed Worker change. The opt-in test harness clock now freezes Date.now only inside that test isolate; assertions check the exact fixed bucket, 30 unauthorized responses followed by two rate-limit responses, and a second client address remaining independent. All 207 Worker tests and syntax checks pass locally. No production source/configuration/deployment changes. The original iOS job continues; the corrected source has its own Production Gate run.
