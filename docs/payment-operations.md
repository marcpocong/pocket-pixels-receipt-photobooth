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
