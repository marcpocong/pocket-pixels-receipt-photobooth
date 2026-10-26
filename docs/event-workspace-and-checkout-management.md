# Event workspace and checkout management

## Operator workflow

Before: create an event in a separate sheet, enable Event Mode, advance through four required stages, connect paid checkout separately, and visit another editor for typography and footer settings.

After: Events offers Quick Start, Customize New Event and Use Previous Event. All open the same staged workspace. Enter a name and venue, open Payment & Prints, Customize Receipt, Guest Screens or Gallery & QR Settings as needed, then choose Save for Later or Review & Start. The final reviewed Start action stays visible below the summary and preview.

New workspaces start with no guest payment, even if the previous event charged guests. Previous-event templates receive a fresh design identity and copy reusable settings without commercial links, retired commercial identities, transactions or runs. Saving for later creates a reusable local event without creating or publishing a server event.

Draft writes are debounced on the existing ordered background queue. Navigation/backgrounding checkpoints the latest draft; explicit saves flush the queue and report failures. Reopening an unfinished workspace restores its identity and edits.

For paid events, Review & Start coordinates server creation, linking, versioned save, activation/publication and read-back verification. The original operation journal and unknown-outcome recovery remain authoritative. Valid locally reviewed prices survive initial linking; incomplete local policies cannot replace an existing server policy. Local preparation is restored only during verified creation recovery; ordinary refresh reads the server’s latest draft. The library owns the commercial identity, including when an older editor remains open.

## Receipt and guest customization

Customize Receipt uses controls beside the live preview in wide iPad layouts. Portrait and accessibility layouts provide an editor/preview switch. Caption & Footer contains caption, default caption reset, footer layout and gallery appearance. Header & Logo contains studio-logo reset, import, placement and existing artwork controls. Event information, typography and Photo Pass remain available in the same editor.

The preview uses the production compositor and thermal rasterizer off the main thread, with debouncing and generation checks. Black & White uses the smooth grayscale renderer; Thermal Raster uses actual printer dots. Either encoded preview can be saved to Photos. Display-sample previews and printing continue to use Sample Print Studio.

A new optional receipt-extras flag allows a newly edited caption or event-detail block without requiring a custom logo. Missing flags preserve the old receipt behavior. Existing captured profiles remain frozen.

Studio logo, caption and guest-screen defaults are copied into the staged event; their reset actions explicitly copy current studio values. Footer layout and gallery-appearance selectors can inherit device defaults or store event overrides. Event edits never write studio defaults. The upload connection and sticker library remain device-wide and are labeled accordingly. Studio defaults remain editable from Booth settings without starting an event.

Live events use the same workspace, with Cancel Changes and Apply to Next Sessions. The existing between-session commit boundary, version checks, price acknowledgment, publication verification and frozen guest snapshots remain in use. Cosmetic changes do not publish unrelated paid drafts or create another run.

## Checkout cleanup and retained evidence

- Archive Checkout and Force Remove from Workspace hide a closed interaction durably and allow Restore Visibility without requiring an online payment read.
- Delete Eligible Selected keeps the existing authoritative eligibility checks.
- Force Delete Local Checkout/Selected removes local workspace checkpoints after review. Original checkout identity, payment/order/entitlement references, amounts and last-known status move to independent financial-recovery records in the same atomic write as the deletion tombstone.
- Cash journals, session snapshots, photos, original entitlements, print-outcome records and server transactions are retained. Deletion never settles a payment, authorizes a guest or resends paper.
- Active guests, armed resumes, operator reprints and in-flight sends remain protected. Failed preservation keeps the original checkpoint. Uncertain print evidence stays evidence and is never automatically resent.
- Late callbacks cannot recreate tombstoned checkpoints. Separate read-only financial follow-up can update retained payment status. Only authoritative terminal evidence clears its outstanding count.
- Workspace counts exclude hidden parked records. Financial Follow-up and Health include outstanding archived/removed evidence. Bulk results identify successes and failures per checkout.

## Event naming

Saved designs have Rename Event in Manage. Completed, archived and historical runs have the same action in Events and History. Runs store an optional display-name override. Original context, run IDs, commercial IDs, attribution, session snapshots and printed images remain unchanged. Renaming a design does not rename its historical occurrences.

## Production Gate investigation

Both failed runs used an 11-inch iPad Pro on iOS 26.2. Their logs, xcresult attachments and accessibility trees were inspected.

- [Gate #143](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/runs/40306823493): the saved-design navigation control and Manage proxy both inherited `saved-design-…`. Manage appeared as an outer accessibility button around another button with the same bounds. XCTest found the proxy but computed the hit point as `{-1,-1}`. The row identifier no longer propagates to its controls. Manage is an independently identified native button, with actions in a management sheet. Removal confirmation and failures stay inside the same management sheet, so no second presentation competes with dismissal. Archive/restore commit before dismissing. Rename and navigation actions use the dismissal callback.
- [Gate #142](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/runs/40296012902): Gallery Actions was already onscreen at `{728,223,90,58}` above the sessions scroll view. Its accessibility tree likewise exposed an outer button around the actual Menu button. AX scroll-to-visible failed because the selected proxy had no usable hit point, rather than because it needed another list swipe. Gallery Actions is now one native button with a stable identifier and an action dialog; explicit adaptive layout keeps one instance during export-feedback changes.

[Gate #144](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/runs/40320938089) confirmed both original fixes on iOS 26.2. It passed all 873 unit/integration tests and 11 UI tests, exposing five additional UI failures. The checkout Manage control used the same inaccessible Menu pattern, so it now uses an independently identified native button and a single management/review sheet. Three event tests observed actions before deferred dismissal callbacks had run or lost a subsequent error presentation; archive/restore now commit before dismissal and removal/error review stays within its sheet. The draft test terminated before waiting for the background save and read the newly opened editor before restoration completed; it now asserts the entered text, waits for the confirmed Saved state, and requires the exact restored value before proceeding.

The previously failing tests remain enabled and assert unique identifiers, actual tappability and their original outcomes. Coordinate menu/switch taps, screenshot sleeps and repeated blind scrolling were removed from the affected helpers. No assertions were weakened or checks removed.

Production Gate now runs the complete native UI target first, followed by the complete unit/integration target, once each against the same build and simulator. Both are required for the iOS job to pass. Both result bundles are uploaded and included in failure summaries. This surfaces runtime-specific interaction failures before spending time on the slower receipt suite.

## Validation record

Local focused validation covered 186 distinct tests. The broad run passed 183, exposing an incomplete-local-policy regression and the menu-to-confirmation handoff. After their fixes, the affected Session Setup suite and native event tests were rerun with no remaining failing cases. Both originally failing Production Gate tests passed locally. Coverage includes acknowledgment → relaunch → next guest/event, unknown create outcomes, live server revisions, receipt/raster behavior, draft persistence, historical identities, late callbacks, offline cleanup, bulk mixed outcomes and storage failures.

The signed build succeeded, installed over the existing app on Carlo's iPad Pro 11-inch (4th generation), and launched normally afterward. Four distinct physical acceptance tests passed across the initial run and targeted corrections: creation/activation/live edits/relaunch, commercially linked removal/restore, checkout archive/restore/force deletion/relaunch, and saved/historical naming. That earlier delivery reviewed portrait and landscape editor screenshots. The final portrait-only successor and its acceptance record are documented in [Portrait event workspace](portrait-event-workspace.md). All final physical checks used iOS 26.6.1. Real Canon capture, physical paper output and real paid transactions were not exercised by these synthetic tests.

Local simulator validation uses iOS 26.5. iOS 26.2 is unavailable locally and remains covered by the Production Gate environment. The existing bundle identity and signing configuration are unchanged. The final handoff supplies the delivered commit SHA and that commit's confirmed Production Gate URL/status.

All physical destructive-action checks use the explicit Debug event-validation entry point and its UUID-scoped temporary directory. Studio defaults and payment/print recovery are injected for these fixtures. Production ContentView and its payment, camera and printer workers are not started by this fixture.
