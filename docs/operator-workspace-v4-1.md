# Operator Workspace V4.1

## Scope and baseline

Baseline: `211c7e44b977e75f05410f0b845ba35809c8d5f5` (PR #17). Fetched origin/main before editing; no subsequent changes were present. Baseline [Production Gate](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/runs/40115475524) passed. Work is on `feature/operator-workspace-v4-1-management-gallery-export`.

This release preserves the iPad workspace, bundle ID, signing configuration, receipt composition, raster pipeline and printer transport. No dependencies were added. Validation uses synthetic simulator records and temporary storage. Carlo, production deployments, customer cleanup, payment operations and physical printing are outside this delivery.

## Gallery investigation and repair

The suspected root cause was confirmed by tracing `BoothSessionViewModel` → frozen `CommittedGallerySession` → `prepareAndPersistGallery` → durable queue → upload → public verification → `recordVerifiedDelivery` → queue clear. Previously the only successful-verification callback updated `EventRunStore.shared.updateSession`. That method cannot save evidence for a nonexistent event-run session. Recent Sessions then loaded only verified event-run sessions. Regular Booth and older sessions without those records therefore lost their independent delivery evidence after the queue cleared, even when the public read succeeded.

`GalleryVerificationStore` now stores one durability-critical, protected record per SHA-256 identity of the exact session ID, gallery token and frozen URL. The record has an evidence version, identity digest, verification time and source. It stores no full gallery URL or token. Concurrent/idempotent writes share a lock. A read of a mismatched version/identity fails closed. Event reporting still receives its callback after independent persistence succeeds.

The public verifier uses the existing `galleryStatus=1` contract: status version 1, successful complete status, exact token and session, supported schema and expected file count. Queued payloads require their exact schema/count. Historical archives require their photo count and the supported manifest asset-count range; the backend already checks exact manifest files. Legacy HTML requires the existing backend completion marker from the original frozen front door. A generic HTTP 200, URL existence, attempted upload or POST acceptance cannot produce proof. No token is minted, URL migrated, QR recomposed, gallery created or content uploaded during an explicit recheck.

After a successful POST, the queue records `posted`. Subsequent retries perform only verification/persistence, including when local evidence storage fails. The payload is cleared only after public verification and local evidence commit. Unknown POST outcomes still use the preexisting same-token idempotent reconciliation path. Historical rechecks and uploads share the same lease, preventing a recheck from deleting a payload during its POST.

Rows and detail share the same status source: Gallery Ready, Uploading, Waiting for Upload, Needs Attention, Not Yet Verified, Gallery Unavailable, Invalid Gallery Link. Only the backend's explicit versioned `unavailable` result establishes unavailability. Offline errors, 404s, malformed pages and incomplete evidence cannot establish absence. Verification observations are updated incrementally; successful evidence notifications identify one hashed gallery rather than refreshing all archive metadata.

Verify Gallery checks one original session. Recheck Unverified Galleries checks selected sessions, or eligible visible sessions when none are selected. Requests are serial with a one-second interval, bounded request/resource timeouts, explicit cancellation, incremental counts, and immediate batch suspension on HTTP 429. Nothing rechecks hundreds of galleries automatically on opening Sessions. Results report verified, still unknown, failed and skipped counts. Successful evidence survives relaunch.

Historical event-run timestamps are retained as historical reporting data. Because those old records do not bind a token and URL, they are not promoted into the new identity-specific proof. An explicit original-gallery recheck establishes that proof. Missing original identity or unavailable completion evidence remains honestly nonverified.

## Record management

Checkout Recovery presents Active Interruptions, Parked / Outstanding, and Resolved / Archived. Manage exposes detail, eligible resume, archive/restore and reviewed permanent cleanup. Active interactions must first use Close Session & Continue before being hidden. Hiding never resolves an obligation or removes it from Health's parked count. Bulk cleanup reviews eligible, archive-instead, blocked and cannot-inspect categories; each mutation repeats inspection and reports its own result.

Permanent checkout deletion requires operator authorization, a fresh read of the original payment-server checkout under its original environment/binding, unchanged local checkpoint, no live/armed guest ownership, and readable relevant cash/print/recovery dependencies. Genuinely empty checkpoints, conclusively unpaid attempts and authoritatively consumed entitlements can be eligible. Pending/unknown QR, usable entitlement, cash reconciliation, uncertain unacknowledged paper, changed checkpoints and incomplete inspection are retained. Offline operation cannot authorize deletion. Print audits remain evidence; unrelated historical print failures do not create a cleanup lock.

Checkout removal and an anti-resurrection tombstone are one atomic checkpoint-store commit. Failed writes retain the in-memory and durable record. Late enrichment cannot recreate a deleted checkpoint and a deliberate new guest must use a new session identity. No server record, cash journal, entitlement, audit or outbox entry is deleted.

Events exposes Manage beside each saved design and local occurrence. Edit, History, Archive/Restore, Delete Permanently and Delete Unused Local Run reuse the existing domain functions and authorization. Commercial identities and used/current records remain protected. Archived designs are outside ordinary selection; History retains access. Local design deletion never implies commercial-event deletion.

Sessions provides row/detail management, Select All Visible, Deselect, Hide Selected and reviewed Delete Selected. Delete Local Session Permanently removes only the selected archive directory: receipt/thermal previews, raster/reprint data, thumbnails and retained camera originals. Reprinting that deleted archive becomes unavailable. Public galleries, Photos-library exports, financial records, cash, print evidence, and event accounting remain.

Session cleanup checks live guest ownership, whole-batch reprint leases, current checkout fulfillment, unfinished physical sends, the exact recovery acknowledgement and independently retained gallery payloads. A completed paid session is not blocked by its historical payment. Queued galleries can retain their independent protected payload while unrelated archive media is removed. An archive write and deletion are serialized. A durable deletion intent precedes removal, relaunch finishes interrupted removals, and stale saves/thumbnail/original attachments cannot recreate an archive. Cache eviction is per archive. Bulk results never disguise partial failure as all-or-nothing success.

Minimal deletion evidence retains session identity, date and event/run references, without images or links. Event deletion checks this evidence, so removing media cannot make a used design/run appear unused. The print-critical archive commit now also preserves the existing payload's event/run IDs; inspection found that the former copy construction dropped them.

## Receipt preview and Photos export

The common `OperatorZoomableReceiptView` has no visible Fit/percentage/Reset toolbar. It begins with the entire image fitted without cropping, retains native pinch/pan, double-tap between Fit and 2×, relative zoom up to 4×, rotation adaptation and VoiceOver adjustable zoom plus a Fit action. A changed image resets the display transform. Zoom remains a display-only UIScrollView transform; archived PNG/raster bytes are never recomposed.

Save Receipt to Photos writes the exact archived receipt PNG at its archived dimensions. Save individual / Save All Photos writes the selected source's encoded bytes. `PhotosLibraryWriting` isolates authorization and confirmed transactions for failure testing. Production requests add-only access and uses Photos asset resources, without read access or a third-party library. Save never prints, uploads, replaces a QR, changes the archive or deletes source media. In-flight repeated taps are ignored. Success is shown only after Photos confirms the transaction. Denied/restricted authorization and storage/transaction failures have compact feedback. Temporary export files are protected and removed after completion.

The camera API now returns both its existing UIImage and `AVCapturePhoto.fileDataRepresentation()` bytes. Receipt/crop processing still uses the same normalized UIImage. Actual encoded captures are associated with shot index and retained only for customer sessions; qualification/sample photos do not become camera originals. New recovery snapshots optionally retain those bytes, and a separate non-print-critical OriginalPhotos transaction attaches exact files plus a manifest to the committed session archive. A retry compares existing bytes and cannot duplicate or cross-assign a shot. Optional fields preserve old recovery/archive compatibility. A retention failure surfaces a persistent operator warning without blocking an already safely archived receipt or printing.

Keep Original Photos for Export defaults on and can be disabled for future captures in Gallery Setup. Disabling does not remove existing originals. Gallery Setup reports approximate original-file storage. No historical bulk migration duplicates old archives. Files inherit protected app storage and backup exclusion. Photo bytes and private gallery identities are not included in diagnostic evidence.

Historical source order is actual retained capture, already-retained prepared/recovery photo under the same session/token/URL, then archive thumbnail. Detail labels Original capture, Prepared gallery photo, or Thumbnail only. An enlarged thumbnail is never called an original. Missing/unreadable media disables export with an explanation. The app does not download a public gallery or create online copies for this purpose. Deleting local archives does not delete gallery or Photos copies.

## Validation and evidence

See [V4.1 evidence](../BuildArtifacts/OperatorWorkspaceV4.1/README.md) for executed suites, screenshots, measurements and final delivery identifiers. Local Xcode is 27.1; the repository's unmodified Production Gate remains the compatibility/release gate. A local build alone does not authorize this release's merge.

Physical-only acceptance: actual camera encoded dimensions/orientation, iPad Photos permissions and storage-pressure behavior, native touch/VoiceOver, physical printer output and real gallery connectivity cannot be established by mocked simulator tests.

## Carlo acceptance checklist (owner action, synthetic records only)

- Launch in portrait; confirm Sessions scrolling and searching remain smooth.
- Compare Gallery Ready and Not Yet Verified; explicitly recheck one older original gallery.
- Save an archived receipt and an original photo to Photos; inspect their dimensions and orientation.
- Deny Photos permission, attempt Save, and confirm clear failure feedback with source media intact.
- Open short/long receipts at Fit; pinch, pan, double-tap back to Fit, and try VoiceOver zoom.
- Inspect individual/bulk session cleanup and its review using disposable synthetic records.
- Inspect event Manage, unused deletion and used-event archiving.
- Inspect checkout groups, archive/restore and cleanup reasons with synthetic records.
- Compare Home, Health and Recovery active/parked counts; hiding must not settle an obligation.
- Rotate to landscape and back; confirm selection/scroll behavior.
- Verify the active event/checkout and existing receipts/galleries were not changed.

Do not delete Carlo's existing customer records to perform acceptance. This implementation does not install or reset Carlo.
