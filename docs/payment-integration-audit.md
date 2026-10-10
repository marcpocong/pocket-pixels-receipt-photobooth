# Payment Integration Audit

Audited 10 October 2026 against `main` at `934a76d350fb3e09b63941c8e6436f85ab9cd43a`. A fetch confirmed this equals `origin/main`. The working tree already contained extensive uncommitted gallery, sticker, hardware-qualification, receipt, session, and test work; those changes were preserved.

## Existing integration points protected

- `EventProfile.isEnabled` and `isEventModeActive` remain branding/customer-screen controls. Commercial state lives separately in `CommercialEventRun` and `PaymentPolicySnapshot`.
- `BoothSessionViewModel` remains the single guest session coordinator. Format selection now branches to checkout for pay-per-print policies, and camera preparation is called only after a `CheckoutEntitlement` exists.
- `BoothSessionView` retains welcome, format, camera, review, Passport, Sticker Studio, receipt, printer recovery, and thank-you routing. Checkout screens were inserted between format and camera.
- `PrinterCoordinator`, BLE/Wi-Fi services, the 576-dot raster, and `PrintSpooler` were not replaced. The paid print gate fixes the requested quantity to the purchased quantity and keeps the existing sequential/ambiguous-print recovery behavior.
- `EventOperationalState` remains the source of known printer recovery and network readiness. Known recovery blocks session start before checkout.
- Gallery token generation, upload queue, Cloudflare gallery proxy, Google Apps Script, and all printed gallery routes remain separate. Existing user edits in those files were not modified by this implementation.
- Payment device credentials use a dedicated Keychain service and are not shared with the gallery upload token.

## Project inventory

- Xcode targets: `PocketPixelsBooth` application and `PocketPixelsBoothTests` unit-test bundle.
- Shared scheme/test plan: `PocketPixelsBooth`.
- iPad-only target family; iOS deployment target 18.0; Swift 5 language mode with Main Actor default isolation and approachable concurrency.
- No package dependencies were added.
- Existing backend components: public GET/HEAD gallery proxy and Google Apps Script gallery/upload renderer.
- New backend boundary: `Backend/PaymentsWorker`, with its own Worker names, D1 bindings, secrets, routes, and migrations.

## Trust and state boundaries

The iPad never receives a PayMongo secret. The Worker calculates totals from the active immutable policy revision. The client supplies only event, format, and copy selection. QR capture authorization is issued only by a verified server webhook/status result. Cash authorization is explicitly `UNVERIFIED_CASH_DECLARED`; offline cash is `LOCAL_UNSYNCED_CASH_DECLARED` until replay-safe sync succeeds.

Payment and camera states are distinct. A pending or unreachable QR attempt becomes reconciliation state and never silently falls back to cash. Private/prepaid is the migration default and requires no payment screens.

## Printer semantics

Existing printer code treats an interrupted/unknown transport as unresolved and requires operator inspection. This remains the safety boundary: software does not claim exactly-once physical printing. A paid entitlement limits copy indices and receipt identity; ambiguous copies are not automatically retried.

## Current limitations

- The operator commercial editor manages the local safe/default configuration used by the booth. Server-admin event creation and reporting APIs exist, but a complete remote event-list/reporting client screen and CSV export UI are not yet wired.
- Offline cash uses the repository's existing fsync + atomic-rename durability primitive, rather than SQLite/SwiftData. It is a durable file ledger with monotonic IDs and replay-safe server uniqueness, but does not provide database-at-rest encryption beyond iOS Data Protection.
- Backend reconciliation currently relies on signed webhooks/status stored by the Worker; an additional scheduled PayMongo retrieve job is documented as a production hardening step.
- External PayMongo test-simulator E2E was not run because no credentials or deployed test endpoint were configured.
