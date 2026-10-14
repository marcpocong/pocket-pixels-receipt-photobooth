# Payment Operations and Recovery

## Guest flow

- Private/prepaid: Welcome → Format → Camera → existing editing/Passport/Sticker/receipt flow → Print → Thank You.
- Pay per print: Welcome → Format → Copies → Payment → authorized entitlement → Camera → existing flow → exact purchased copies → Thank You.
- Online cash (current app): the guest sees “Please pay the attendant,” hands over the displayed amount and taps **I’ve paid the attendant**. No Face ID/passcode or operator token is needed for this declaration. The booth credential calls `POST /v1/orders/{orderID}/cash-declaration`; the server records `SELF_REPORTED` / `UNVERIFIED_SELF_REPORTED` and issues the existing unverified-cash entitlement. Camera access still follows its booth-scoped claim. The button is the customer's statement, not proof that the attendant received money.
- Signed offline cash retains **Attendant: Confirm Cash Received** and genuine device-owner authentication; it is never an automatic fallback for an online checkout.
- QR Ph: camera remains locked until the Worker returns a verified entitlement.

Session Setup offers No Payment Required, QR Ph Only, Cash Only, and QR Ph + Cash. Event Mode and saved receipt designs are separate from payment authorization. Saving a design or setup draft does not authorize publishing or activating a LIVE event.

## Cash provenance and attendant confirmation

The attendant-only confirmation API remains supported for compatible clients, but the current online guest button does not call it. Confirm only cash physically received, for the exact order total and purchased copy count. The Worker requires operator scope in the order's account and a cash-enabled accepted policy; the booth credential cannot confirm cash. An order already locked to QR Ph cannot be converted to cash. Replayed confirmation returns the same entitlement rather than another purchase. An uncertain response requires status/recovery inspection before another transaction; never collect cash twice or manufacture a paid record in D1.

The online attempt retains method `CASH_DECLARED` for compatibility but uses state/verification `OPERATOR_CONFIRMED` and audit action `CASH_OPERATOR_CONFIRMED`. Its entitlement retains the existing `UNVERIFIED_CASH_DECLARED` authorization source: this is staff attestation, not provider verification. No database migration is required for this endpoint. Keep booth and operator credentials separate and reuse valid pairing; missing operator authorization is not a reason to fall back to a booth token.

The current online guest flow and historical clients call `/v1/orders/{orderID}/cash-declaration`. Those records remain `SELF_REPORTED`, and cannot be relabelled as attendant-confirmed. Keep the legacy endpoint until a separately reviewed compatibility/deprecation decision. Signed offline cash remains provisional/self-reported in server reporting even when local attendant authentication occurs; it is never a fallback for an unresolved online QR checkout.

## Incident rules

- Pending/unknown QR: do not take cash for the same order and do not call it failed. Leave it in reconciliation until provider state is definitive.
- Paid before camera: preserve entitlement and resume; never charge again.
- Printer unavailable after payment: preserve entitlement and receipt payload; recover only missing copies.
- Ambiguous printer send: do not auto-reprint. Operator inspects and records the recovery decision.
- Offline cash conflict: retain the local record with conflict reason. Never delete it silently.
- Paused/ended event: stop new sessions; retain already-authorized fulfillment rights.

## Reporting language

- QR Ph Verified excludes test transactions from live gross.
- Cash Attendant-Confirmed (`CASH_OPERATOR_CONFIRMED`, `cashOperatorConfirmedCentavos`) is staff-attested and separate from historical self-reported cash; it is not PayMongo-verified revenue.
- Cash Self-Reported is not independently verified.
- Cash Unsynced is device-local and absent from server totals.
- Physical cash-count variance compares the count with both attendant-confirmed and self-reported cash. Pending local sync/conflicts keep the count provisional.
- Total Reported mixes verification levels and must say so.
- `payment.paid` is not a bank-settlement or payout claim.

## Data handling

Logs contain IDs/status only, never raw webhook bodies, keys, photos, private gallery URLs, or QR images. Offline cash records contain operational IDs, price snapshot, copies, timestamps, and sync state—no provider secret or customer financial credential.

## Operator access and recovery

Hold the Welcome wordmark for four seconds, then unlock with Apple device-owner authentication. The separate **Use iPad Passcode** button reads a device-bound Keychain proof protected by a passcode-only ACL, so it opens the system passcode prompt directly. Face ID remains available through Unlock Operator Controls. The owner sets and recovers the passcode through iPad Settings and Apple's device recovery process; the app has no default PIN or bypass and never stores the passcode. Keep the passcode restricted to approved operators. No device passcode means no operator access. Operator controls have no inactivity timeout. Done/returning to the booth or backgrounding locks access; cancelling or failing authentication leaves tools locked. Inactive scenes conceal controls without interfering with Apple's authentication prompt. Lockout never deletes payment journals, unresolved print evidence, customer archives, pairing or gallery records.

LIVE booth and operator credentials have separate D1 rows/scopes. Pair the booth-only token first, then authorize the operator-only token for the same server/account. LIVE administration never falls back to the booth credential. Operator tokens use `WhenUnlockedThisDeviceOnly` Keychain storage bound to the exact server URL/environment. Pairing probes credentials before replacing existing settings; changing pairing is blocked by current sessions, unresolved checkout/print evidence or queued print reports. A failed Keychain update preserves the previous credential.

Recover device access with the owner first, then reissue/revoke the affected server credential if needed. Revocation is a deliberate account operation: use the known device ID and dedicated environment, `UPDATE devices SET revoked_at=datetime('now') WHERE id='<reviewed-device-id>'`. Do not delete operational rows. A lost operator credential requires an authenticated account owner to issue another operator-only token; it does not require an app reinstall or archive deletion.

## LIVE monitoring and reconciliation

LIVE runs `*/5 * * * *` in UTC. Disabled LIVE reconciliation returns `live_disabled` before D1/provider access. Once approved and enabled, inspect the latest `reconciliation_runs` every attended pilot session and at opening/closing. Review any `failure_summary`, an unfinished run, no run within 15 minutes, or unresolved QR rows older than provider expiry plus reconciliation grace. Provider timeouts remain unknown and retry with bounded backoff. Late-paid/superseded orders require manual review and never receive a usable entitlement automatically.

The checked-in LIVE configuration defaults `LIVE_PAYMENTS_ENABLED=false`, while the existing deployed service was enabled with a CLI variable override. Before any approved LIVE release, inspect the active version and bindings. Preserve the enabled gate explicitly with `--env live --var LIVE_PAYMENTS_ENABLED:true` when that is the reviewed intended state; a plain deployment would restore the false default. Preserve existing secrets, D1 binding and Cron. A dry run (`wrangler deploy --dry-run --env live --var LIVE_PAYMENTS_ENABLED:true`) uploads nothing and does not authorize deployment. Stop new acceptance through approved event lifecycle changes while keeping verification/reconciliation available for accepted orders.

Before supervised cash qualification, finish app integrity and non-payment preview/sample checks. Obtain separate owner approval for LIVE deployment, event policy/lifecycle changes, the real cash transaction and paper consumption. Reuse a suitable isolated pilot; leave the Regular Sessions ₱25 draft unchanged and inactive. Confirm actual paper output separately from transport delivery, then pause/reconcile the pilot. A short pilot does not satisfy the 100-session physical qualification gate.

Operator Home → Print Display Samples uses applied branding. The link under a receipt-design preview instead passes a snapshot of that preview, including unsaved design edits, into Sample Print Studio as **Preview Design**. This does not save/apply the draft, start acceptance, create orders or upload galleries. Import the operator's sample photos and review the thermal raster before an approved print. Samples are never a substitute for recovering an ambiguous paid print.

Use PayMongo Webhooks → Event Deliveries for delivery visibility, the authenticated `/v1/admin/diagnostics` for unresolved/review counts, and each event's sales/orders view for unclaimed paid entitlements and incomplete batches. On the iPad, inspect Interrupted Paid Sessions and Print Accounting for queued completion, conflict or uncertain outcomes. Capture IDs/status/times only; keep export data and archives private. The designated attendant checks these surfaces; no separate monitoring platform is required for the supervised pilot.

If a payment/print incident occurs, stop new paid guest sessions by deliberately returning to Private / Prepaid and preserve the affected checkout. Do not use Private / Prepaid to fulfil an ambiguous paid print. Pause the event to stop new orders while preserving previously authorized fulfillment and reconciliation. Keep the payment gate enabled only if the authorized incident procedure permits ongoing reconciliation. Turning it off blocks LIVE QR, provider reconciliation and webhook authorization; it is an emergency containment action, not proof that outstanding payments are unpaid. Never automatically refund or resend an uncertain print.

## Backup and rollback

From `Backend/PaymentsWorker`, confirm the destination using `wrangler d1 info pocket-pixels-payments-live --env live` and migration history before every schema operation. LIVE D1 ID is `3417d35d-3d47-457a-bd45-0d6371fadc8f`; TEST ID is `d7b7bfe1-b981-4289-b69b-bd120703887d`. Never omit `--env`. Back up populated LIVE D1 before schema changes and at pilot close; use a private mode-0600 export outside the repository. Suppress Wrangler's signed export URL from shared logs. Verify the export by loading it into local SQLite and recording its SHA-256 privately.

`wrangler d1 time-travel info DB --env live` identifies the current restore bookmark. Retention depends on the account plan; verify it in Cloudflare rather than assuming 30 days. A restore rewinds payment/accounting records and requires owner incident approval, a current backup and independent PayMongo reconciliation. Do not run a destructive restore as a rehearsal. The signed iPad build, pre-install Application Support backup and settings snapshot are retained privately; rollback never uninstalls the app or deletes journals.

Inspect `wrangler deployments list --env live` and use `wrangler rollback <reviewed-version-id> --env live` for a compatible Worker version. Never roll back D1 automatically. Confirm health/environment/gate and credential bindings after rollback; secret changes also create Worker versions. The first inert code version is `bd9ac10c-2afa-48d9-ac4f-b98da7feaa2a`; it predates owner-entered secrets and must not be assumed to contain the current secret configuration.

The photo keepsake is not claimed to be a BIR sales invoice. QR eligibility does not establish business registration or invoicing compliance. Record the owner's applicable invoicing arrangement before collecting customer revenue, independently of PayMongo activation.

## Interrupted cash before capture

Closing the app after cash authorization but before printing leaves the original entitlement outstanding. With the same paying guest present, open Advanced → Payment Maintenance → Interrupted Paid Checkouts → Check Interrupted Checkouts, then Resume for This Guest and confirm Resume for Guest Present Now. Confirmation returns directly to the booth and preserves setup drafts, without a separate unsaved-setup prompt. Tap Make a Memory to continue; the original session ID, purchased copies and entitlement are reused. Do not take another payment or dismiss the record merely because the app restarted.

Recovery ignores stale “no payment taken” auto-resolutions when a later successful response saved an order/entitlement. Existing affected local records reopen on load and are checked against the server. A missing server recovery view cannot resolve a known purchase as unpaid. Operator dismissals are preserved, and print-started sessions still need paper inspection rather than automatic resumption.

## Saved Drafts

The customer Welcome screen has no draft button. Unlock operator controls, return to the Operator dashboard and open **Saved Drafts · [count]** beside Session Setup. Entries are grouped by event and category: receipt design, payment settings, session selection, studio-wide branding, private/prepaid settings and unfinished new events.

Review shows changed fields with previous/current values and a design preview. It opens the exact saved draft rather than the last operator destination. Price/copy changes use the existing payment settings editor, preserving server-version conflicts and separate publication/start confirmation. New payment drafts retain an optional original baseline for offline review; older records use read-only server comparison when available. Unknown previous values are identified. Drafts for another payments connection remain readable/discardable locally but cannot open that connection's payment editor until explicitly reconnected.

Autosave protects edits across restart. Metadata, equivalent peso spellings and normalized header defaults do not count as new changes; reverting to saved values clears the corresponding draft. Returning to Booth keeps drafts without a repeated keep/discard dialog. Only individual Discard Changes actions are offered; confirmation names the event and category, and a failed disk write keeps the draft. Discarding does not delete saved designs/artwork or another event's drafts, or change accepted payment/print records.

Save Design changes only the saved local design, preserving current server links and creation metadata; it does not apply branding to guests. An older studio-wide branding draft can be saved as an event design without activating it. Publishing payment changes, starting guest acceptance and sending paper remain separate explicit actions. Existing Release Sample drafts are preserved and discoverable in this list.
