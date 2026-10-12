# Payment Operations and Recovery

## Guest flow

- Private/prepaid: Welcome → Format → Camera → existing editing/Passport/Sticker/receipt flow → Print → Thank You.
- Pay per print: Welcome → Format → Copies → Payment → authorized entitlement → Camera → existing flow → exact purchased copies → Thank You.
- Cash: guest hands cash to the attendant and taps “I’ve Paid.” No operator approval occurs. Reports must call this self-reported/unverified.
- QR Ph: camera remains locked until the Worker returns a verified entitlement.

## Incident rules

- Pending/unknown QR: do not take cash for the same order and do not call it failed. Leave it in reconciliation until provider state is definitive.
- Paid before camera: preserve entitlement and resume; never charge again.
- Printer unavailable after payment: preserve entitlement and receipt payload; recover only missing copies.
- Ambiguous printer send: do not auto-reprint. Operator inspects and records the recovery decision.
- Offline cash conflict: retain the local record with conflict reason. Never delete it silently.
- Paused/ended event: stop new sessions; retain already-authorized fulfillment rights.

## Reporting language

- QR Ph Verified excludes test transactions from live gross.
- Cash Self-Reported is not independently verified.
- Cash Unsynced is device-local and absent from server totals.
- Total Reported mixes verification levels and must say so.
- `payment.paid` is not a bank-settlement or payout claim.

## Data handling

Logs contain IDs/status only, never raw webhook bodies, keys, photos, private gallery URLs, or QR images. Offline cash records contain operational IDs, price snapshot, copies, timestamps, and sync state—no provider secret or customer financial credential.

## Operator access and recovery

Hold the Welcome wordmark for four seconds, then unlock with Apple device-owner authentication. The separate **Use iPad Passcode** button reads a device-bound Keychain proof protected by a passcode-only ACL, so it opens the system passcode prompt directly. Face ID remains available through Unlock Operator Controls. The owner sets and recovers the passcode through iPad Settings and Apple's device recovery process; the app has no default PIN or bypass and never stores the passcode. Keep the passcode restricted to approved operators. No device passcode means no operator access. Done, backgrounding, or five minutes locks access; cancelling or failing authentication leaves tools locked. Inactive scenes conceal controls without interfering with Apple's authentication prompt. Lockout never deletes payment journals, unresolved print evidence, customer archives, pairing or gallery records.

LIVE booth and operator credentials have separate D1 rows/scopes. Pair the booth-only token first, then authorize the operator-only token for the same server/account. LIVE administration never falls back to the booth credential. Operator tokens use `WhenUnlockedThisDeviceOnly` Keychain storage bound to the exact server URL/environment. Pairing probes credentials before replacing existing settings; changing pairing is blocked by current sessions, unresolved checkout/print evidence or queued print reports. A failed Keychain update preserves the previous credential.

Recover device access with the owner first, then reissue/revoke the affected server credential if needed. Revocation is a deliberate account operation: use the known device ID and dedicated environment, `UPDATE devices SET revoked_at=datetime('now') WHERE id='<reviewed-device-id>'`. Do not delete operational rows. A lost operator credential requires an authenticated account owner to issue another operator-only token; it does not require an app reinstall or archive deletion.

## LIVE monitoring and reconciliation

LIVE runs `*/5 * * * *` in UTC. Disabled LIVE reconciliation returns `live_disabled` before D1/provider access. Once approved and enabled, inspect the latest `reconciliation_runs` every attended pilot session and at opening/closing. Review any `failure_summary`, an unfinished run, no run within 15 minutes, or unresolved QR rows older than provider expiry plus reconciliation grace. Provider timeouts remain unknown and retry with bounded backoff. Late-paid/superseded orders require manual review and never receive a usable entitlement automatically.

Use PayMongo Webhooks → Event Deliveries for delivery visibility, the authenticated `/v1/admin/diagnostics` for unresolved/review counts, and each event's sales/orders view for unclaimed paid entitlements and incomplete batches. On the iPad, inspect Interrupted Paid Sessions and Print Accounting for queued completion, conflict or uncertain outcomes. Capture IDs/status/times only; keep export data and archives private. The designated attendant checks these surfaces; no separate monitoring platform is required for the supervised pilot.

If a payment/print incident occurs, stop new paid guest sessions by deliberately returning to Private / Prepaid and preserve the affected checkout. Do not use Private / Prepaid to fulfil an ambiguous paid print. Pause the event to stop new orders while preserving previously authorized fulfillment and reconciliation. Keep the payment gate enabled only if the authorized incident procedure permits ongoing reconciliation. Turning it off blocks LIVE QR, provider reconciliation and webhook authorization; it is an emergency containment action, not proof that outstanding payments are unpaid. Never automatically refund or resend an uncertain print.

## Backup and rollback

From `Backend/PaymentsWorker`, confirm the destination using `wrangler d1 info pocket-pixels-payments-live --env live` and migration history before every schema operation. LIVE D1 ID is `3417d35d-3d47-457a-bd45-0d6371fadc8f`; TEST ID is `d7b7bfe1-b981-4289-b69b-bd120703887d`. Never omit `--env`. Back up populated LIVE D1 before schema changes and at pilot close; use a private mode-0600 export outside the repository. Suppress Wrangler's signed export URL from shared logs. Verify the export by loading it into local SQLite and recording its SHA-256 privately.

`wrangler d1 time-travel info DB --env live` identifies the current restore bookmark. Retention depends on the account plan; verify it in Cloudflare rather than assuming 30 days. A restore rewinds payment/accounting records and requires owner incident approval, a current backup and independent PayMongo reconciliation. Do not run a destructive restore as a rehearsal. The signed iPad build, pre-install Application Support backup and settings snapshot are retained privately; rollback never uninstalls the app or deletes journals.

Inspect `wrangler deployments list --env live` and use `wrangler rollback <reviewed-version-id> --env live` for a compatible Worker version. Never roll back D1 automatically. Confirm health/environment/gate and credential bindings after rollback; secret changes also create Worker versions. The first inert code version is `bd9ac10c-2afa-48d9-ac4f-b98da7feaa2a`; it predates owner-entered secrets and must not be assumed to contain the current secret configuration.

The photo keepsake is not claimed to be a BIR sales invoice. QR eligibility does not establish business registration or invoicing compliance. Record the owner's applicable invoicing arrangement before collecting customer revenue, independently of PayMongo activation.
