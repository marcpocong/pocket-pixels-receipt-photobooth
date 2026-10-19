# QR gallery receipt styles — October 20, 2026

Backend support is deployed and the signed app is installed in place on Carlo. The implementation is on `feat/qr-gallery-receipt-styles`. A new production synthetic-gallery round trip remains unverified, so this is not full production sign-off.

## Source and scope

Initial local commit: `adcabf3`. The workspace was fast-forwarded, without conflicts, to current remote main `7ab80c82ca7ac437bf3781a95434d86c16593325` before implementation. Remote main was fetched again on October 20 and had no additional commits. The unrelated untracked `.claude/` directory was preserved. The final implementation commit is the commit containing this report (`git log -1 --oneline`).

No dependency, bundle identifier, signing configuration, payment policy, camera, printer transport, ESC/POS, rasterizer, queue, fingerprint or reprint implementation was changed.

## Behavior

Branding & Design has a separate **Customer Gallery → Default QR Gallery Receipt Style** preference: **Share-Friendly** (the fallback) or **Same as Physical Print**. Its dedicated UserDefaults key/store is independent of `ReceiptPrintSettingsStore`. Physical Printing → Gallery Code Style, its `device-gallery-code-style` identifier, and the Session Setup shortcut are preserved.

The event Receipt & Branding panel offers **Use Device Default**, **Share-Friendly**, and **Same as Physical Print**, outside the logo switch. The override is an optional field of the full EventProfile and survives normalization, even when `activeReceiptSnapshot` is nil. Existing draft/save/review/start logic applies it. Save Design does not mutate the applied profile; regular setup clears the prior event override.

The resolved choice freezes at admission, before format selection, payment or capture. Committed sessions, app recovery snapshots, checkout checkpoints, detached recovery records, prepared payloads and pending-upload metadata retain it. Missing historical fields decode without invalidating records; recovery falls back to Share-Friendly, never to a newly changed device preference.

New customer galleries use schema 3. Original `receipt-color.jpg` and smooth grayscale `receipt-bw.png` retain their meaning. QR-bearing physical footer modes add one authentic `ReceiptComposer` composition as `receipt-share-color.jpg`. It uses the same frozen photos, timestamp, profile, typography, stickers, URL and processing profile, with only the footer changed to decorative barcode. Photo Pass input is redacted before every public composition. No completed image is cropped or covered to remove a QR. Decorative-only sessions store no duplicate alternative.

The original Color Receipt and Black & White Receipt cards remain. One compact selector updates their preview, Save, Share and lightbox filenames together. Share-Friendly B&W is `receipt-share-bw.png`, derived by the existing deterministic grayscale function. Each variant has distinct caches and object URLs. Revisions prevent late async work from replacing the current choice; placeholders and disabled actions prevent a QR-bearing fallback during loading/error. The selector is omitted when both styles are identical. Only QR-bearing As Printed shows the requested privacy note. Success announcements are available to screen readers without another visible UI row.

The backend validates schema-v3 enum values, filenames, signatures, roles, budgets, manifests, folder reconstruction and retries. Property order cannot break retry identity. Existing schemas 1 and 2 keep their previous presentation and complete through their original upload schema; no historical manifest, token, file or completed folder is rewritten. Public image retrieval now preserves PNG/GIF MIME types as well as JPEG.

The app preparation boundary also now accepts its existing UUID-suffixed session identifiers (the prior 32-character check rejected production's longer identifiers; the backend already supported them).

## Validation

- Apps Script Node suite: passed, including 12 schema/footer/default/count combinations, invalid metadata/assets/manifests, size rejection, and an in-memory Drive contract running the real writer, inspection, manifest and retry paths for v1/v2/v3. Partial repair, missing files, completed retries, conflicts and property-order independence are covered.
- Cloudflare Gallery Worker: **29 passed, 0 failed**.
- Payments Worker: **223 passed, 0 failed**; no real payment transactions.
- Monitoring Worker: **9 passed, 0 failed**.
- Full iOS 26.5 suite: **705 passed, 0 failed, 0 skipped** (740 parameter-expanded executions), result bundle `Test-PocketPixelsBooth-2026.10.20_01-05-32-+0800.xcresult`; 635 seconds, no reported runtime warnings..
- iOS 27 browser + operator authentication/workspace suites: **26 passed, 0 failed, 0 skipped**, result bundle `Test-PocketPixelsBooth-2026.10.20_01-06-38-+0800.xcresult`.
- Final browser screenshots with matching before/after photograph assets: **10 passed, 0 failed, 0 skipped**, result bundle `Test-PocketPixelsBooth-2026.10.20_01-12-44-+0800.xcresult`; visually reviewed phone and desktop Receipt Copy captures..
- Debug simulator test build: passed using the repository's CI ad hoc signing flags. Signed device Release build passed again on October 20 with bundle `com.pocketpixels.PocketPixelsBooth`, team `PQ26682725`, and the existing Apple Development identity. No signing setting was edited.

The earlier unsigned full run had **700 passes and 3 failures**, all operator Keychain tests. The CI workflow explicitly requires ad hoc simulator signing to embed Keychain entitlements; the incorrectly unsigned test host caused these failures. They pass in the corrected signed run. An earlier iOS 27 browser run also reported a WebKit `InvalidTransition` during fixture navigation; the corrected final runs retain all assertions and are reported separately above. Blank initial screenshots were rejected and replaced by captures attached to a real UIWindowScene; the screenshot test now checks that captures contain rendered content.

Tests cover every receipt format × all three physical footers × both digital defaults, QR absence in alternatives, exact privacy-safe composer output, smooth grayscale, durable queue restart and unchanged physical raster commands. Existing footer/branding/sticker/preview/print/recovery suites remain part of the full run. Browser coverage includes 320/375/390/430/768/1024/1440px, both cards and all actions, rapid switching, optional-asset failure with no QR fallback, historical galleries, native-share stubs, gallery sharing, photo downloads, lightbox/focus, placeholder dimensions and touch targets.

Synthetic screenshot evidence: [GalleryReceiptStyles](../BuildArtifacts/GalleryReceiptStyles/README.md). No customer photographs or live tokens are included. These gradient assets test gallery layout; actual composer/privacy/QR fidelity is checked by the receipt tests.

## Size and timing

Worst-case tested noisy six-photo Grid Six with long event branding:

| Measurement | Result |
| --- | ---: |
| Decoded upload assets | 2,977,829 bytes |
| Encoded JSON body | 4,032,443 bytes |
| Additional Share-Friendly JPEG | 248,145 bytes |
| Image preparation on iOS 26.5 simulator | 0.612 seconds |

The 5.5 MiB app decoded budget, 6 MiB backend decoded budget, 9 MiB request budget and 9 MiB embedded-base64 limit were unchanged. Photographs in payloads with/without receipt alternatives are byte-identical in the noisy-session test. Simulator timing is not a Carlo hardware benchmark; network/upload/page-load timing for a new production gallery is unverified.

## Deployment and compatibility

| Component | Verified state |
| --- | --- |
| Apps Script project | Existing Pocket Pixels Gallery Backend |
| Existing Web App deployment | **Version 28**, October 20, 2026, 1:10 AM Manila |
| Backend diagnostic | `made-to-keep-gallery-v7-receipt-styles-20261018` |
| Public proxy diagnostic | Healthy upstream HTTP 200; v7 recognized |
| Previous Web App / rollback | Version 27, v6 monochrome backend |
| Cloudflare Worker | Existing `gallery`; **not redeployed** |
| Worker version | `2d21941f-e3a5-4d34-84be-c2d9371e6414` |
| Cache namespace | `made-to-keep-fit-20261018`, unchanged |
| Public domain | `gallery.madetokeepstudios.workers.dev`, unchanged |

Before editing, the authenticated Apps Script editor matched main's v6 source exactly; Web App version 27 and the authenticated Worker deployment were inspected. The saved final source was compared with the tested local candidate (119,979 characters; matching full-text fingerprint), and the existing Apps Script Phase 6C self-checks passed. Version 28 updates the same deployment ID and preserves owner execution and Anyone access. No credentials, properties, Drive root, account, domain or route was replaced.

After deployment, two existing completed customer galleries were fetched privately through the uncached Apps Script raw route. Both still rendered exactly two receipt cards and no style selector (704,945 and 798,929 HTML characters). Their photos/tokens were not saved in repository evidence. The proxy diagnostic independently reports v7. Completed-page cache TTL remains one hour; newly generated tokens require no cache namespace change.

To roll back backend code, select version 27 on the same deployment. Do not delete gallery folders or edit stored manifests. Version 27 cannot render schema-v3 galleries; if any new app has uploaded schema 3, preserve v3 support when rolling back presentation changes.

## Remaining verification

- **Carlo:** reconnected over USB during the final October 20 check. Installed app was version 1.0/build 3 under the existing bundle. A fresh private Library backup retained 3,272 files (3,229 Application Support files); there were no unresolved checkouts, recovery snapshot or queued gallery assets, and all 267 print-outbox entries were locally delivered (117 reported, 150 not applicable). The old development profile had expired October 19; Xcode refreshed the existing team's profile with `-allowProvisioningUpdates`, without a project/signing change. The final Release build uses the same Apple Development identity, team and application identifier; its refreshed profile includes Carlo and expires October 27 Manila time. `devicectl` verified successful in-place installation and launch on October 20, and a private screen capture confirmed the idle welcome screen. No uninstall/reset/container replacement occurred. The post-launch backup retained all 3,250 compared files outside caches/snapshots with none missing or added. All Application Support records and preferences are byte-identical; only the HTTP storage SQLite shared-memory and write-ahead journals changed. Keychain records were not independently inspected, so launch/data checks are not a claim of exhaustive Keychain verification.
- **New production synthetic upload:** unverified. A genuine composer-generated schema-v3 payload was exported only into ignored/private local storage, with a placeholder upload credential. Browser policy rejected local fixture-file access; no credential was extracted, no replacement service was created and no production synthetic gallery is claimed. Backend upload/storage paths and browser behavior were verified separately. A real upload and public-page round trip remain necessary before app production sign-off.
- Physical printer output, camera capture and real iOS/Android share sheets were not exercised. Automated native-share stubs and raster invariance tests are not hardware qualification.

Local detailed logs and result bundles are under ignored `TestResults/GalleryReceiptStyles` and `DerivedData/Logs/Test`; the private October 20 device backups are outside the repository at `/Users/marc/.codex/attachments/gallery-receipt-style-release-private/oct20-before/Library` and `oct20-after/Library`.

## Files changed

- `PocketPixelsBooth/GalleryReceiptStyle.swift` — independent preference, store and variant metadata.
- `PocketPixelsBooth/EventProfile.swift`, `EventReceiptDesignPanel.swift`, `OperatorHomeStatusView.swift`, `SessionSetupCoordinator.swift` — operator preference and event lifecycle.
- `PocketPixelsBooth/BoothSessionEnvironment.swift`, `BoothSessionViewModel.swift`, `AppRecoveryStore.swift`, `PaymentCheckoutRecovery.swift` — admission freeze, composition and recovery.
- `PocketPixelsBooth/GalleryUploadModels.swift`, `GoogleGalleryNetworkSupport.swift`, `GoogleDriveGalleryUploadService.swift`, `GalleryPendingUploadStore.swift` — schema-v3 transport and durable upload assets.
- `Backend/GoogleAppsScript/Code.gs`, `GridSixValidation.test.cjs` — backend validation/storage/rendering and Node coverage.
- `PocketPixelsBoothTests/GalleryReceiptStyleTests.swift`, `ReceiptFooterModeTests.swift`, `DetachedCheckoutTests.swift`, `SessionSetupTests.swift`, `MonochromeReceiptPreviewTests.swift`, `EventFinalizationTests.swift` — focused tests and browser evidence.
- `BuildArtifacts/GalleryReceiptStyles/README.md` and 28 PNG captures — synthetic before/after evidence.
- `docs/qr-gallery-receipt-styles-release.md` — this report.
