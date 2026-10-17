# Operator Dashboard V2 implementation and release evidence

## Scope and baseline

PR [#9](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/pull/9) merged as `2d7bdc2fc954236bb6beb71c8929f936ef88f6ea` after both mandatory gates passed ([run 39065341364](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/runs/39065341364)). All four PR #8 commits, including its head `ecf83d4`, are ancestors of that merge; no unique #8 work remains. GitHub automatically marked #8 merged through inclusion. Its older branch was never independently merged. The dashboard branch was created from this integrated main, whose tree exactly matches tested PR #9 head `adcabf3`.

## Native operator experience

Exactly four primary destinations: Home, Events, Reports, System. One authenticated NavigationStack survives adaptive layout changes; landscape uses a persistent sidebar and portrait uses four accessible navigation buttons. Optional additions to the existing schema preserve old routes and drafts. Each section restores its detail route; informational navigation never publishes setup or activates events.

Home uses the existing authoritative lifecycle coordinator and preserves active-session, printer, recovery, and remote-transition barriers. Local pause and server pause have distinct labels. End Event remains in a separate confirmed control. Equipment states distinguish unchecked from verified. Four journal metrics are scoped to the current run and report unavailable/incomplete data explicitly; delivered printer bytes never imply sensor-confirmed paper output.

Events consolidates current setup, reusable saved events, durable drafts, regular booth configuration, customization, and historical records. Four setup stages end in the existing explicit review/activation workflow. Reusable prepaid settings are stored additively per saved event. Browsing or saving a draft does not change the accepting booth. Device gallery defaults are read-only during staged setup.

Reports offers Overview, Sessions, Sales. Exact run identity scopes metrics, hourly activity, formats, sessions, and order matching. Search and format/status filters lead directly to archived receipt previews and the existing guarded intentional reprint flow. Historical attribution remains separate from exact journals. LIVE verified payments, TEST payments, attendant cash, declared cash, unresolved orders, and offline cash remain separate. Whole-event totals use the authoritative payments connection and existing authenticated reporting.

System provides printer, camera, galleries, storage, monitoring, Booth Check, and Advanced. Existing diagnostic and physical qualification tools retain their guards. No physical testing starts automatically.

The dashboard does not modify camera capture, printer transport/raster, receipt composition, payment verification, customer sessions, gallery tokens, original photos, upload credentials, or monochrome rendering services. No dependencies, bundle identifier, signing team, entitlement, or project build configuration changed.

## Regression repair

An existing CSV test excluded the text `b1` using a substring assertion. A randomly generated run UUID could contain `b1`, causing a false failure. The test now checks the exact exported session_id column set `{a1, a2}`, retaining record count and other content assertions. CSV implementation is unchanged.

## Local validation

- Original integrated gallery full iOS 26.5 suite: 689 passed, zero failed/skipped.
- Final gallery repair focused iOS 27: 19 passed, zero failed/skipped, no runtime warnings. Includes delayed image loading, mobile/desktop layout, gallery navigation, monochrome previews, original compatibility, and physical raster regression checks.
- Refined dashboard focused setup/drafts/design suite: 63 passed, zero failed/skipped.
- Backend: 223 payment tests, 9 monitoring tests, 29 gallery proxy tests, and Apps Script pure/fixture checks passed.
- Final dashboard full iOS 26.5 suite: **697 passed, zero failed/skipped, no runtime warnings**. Rebuilt after copying onto integrated main; all app/test source bytes matched the full-suite source, and focused navigation/setup/history/authentication tests passed again (41 passed, zero failed/skipped).
- Simulator rendering: actual SwiftUI UIHosting renders, 834×1194 and 1194×834, plus 700×1024 at Accessibility 3. Synthetic data only; no customer photos or tokens in committed evidence. Review includes all four sections, all setup stages, Reports/Sessions/Sales, empty/unavailable archives, and printer recovery.

## Production services

Immediately before mutation, Apps Script was still version 26 (healthy v5-fit) and saved source matched `709e335`; no newer production source was overwritten. After PR #9 passed and merged, the existing Web App deployment was updated to **version 27**, `made-to-keep-gallery-v6-monochrome-20261018`, at October 18, 2026 04:39 Manila. Saved editor source matched tested `adcabf3` (normalized 98,917 characters, FNV-1a32 `1fc4f5c3`). This functional update enables historical smooth B&W and stable image loading, rather than merely synchronizing history. Existing deployment ID, URL, execute-as owner and Anyone access were preserved. Origin diagnostic passed; public proxy diagnostic returned `ok: true`, upstream 200 and v6. The healthy Cloudflare gallery worker **2d21941f-e3a5-4d34-84be-c2d9371e6414 was not redeployed**. Completed gallery HTML can remain cached for up to an hour. Chrome verification of tested synthetic historical galleries confirmed smooth B&W, lightbox, privacy copy, six loaded images, zero overflow and the approved Instagram URL; WKWebView tests cover mobile/desktop widths. The dashboard itself requires no backend changes. The pre-existing legacy printed hostname remains NXDOMAIN as recorded in the gallery deployment documentation; current-hostname historical tokens remain compatible.

## Carlo preservation and validation

Carlo was independently identified as the paired iPad Pro 11-inch (4th generation), iPadOS 26.6.1. Initial installed app: com.pocketpixels.PocketPixelsBooth 1.0 (3), team PQ26682725. The original app does not expose a source SHA, so its exact initial source cannot be established.

A private complete app-container backup and SHA-256 inventory were made outside Git before installation (3,470 files, approximately 426 MB). They include archives, artwork, event history, saved events/drafts, preferences, payment and recovery journals. Keychain is outside the copied container; in-place installation preserves the same app identity and access groups but does not allow an independent secret comparison.

Final signed Release, in-place installation, post-install integrity comparison and physical interaction: pending. Never uninstall the app. No LIVE event transitions, charges, customer deletion, or diagnostic prints are used to exercise the dashboard.

## Review artifacts

Selected synthetic renders: [BuildArtifacts/OperatorDashboardV2](../BuildArtifacts/OperatorDashboardV2/README.md). CI and final device provenance are recorded in the final release report after the actual operations complete.
