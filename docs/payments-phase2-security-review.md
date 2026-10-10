# Payments Phase 2 security review

- PayMongo secret and webhook keys are Worker secrets only. No secret value or global bearer credential is committed.
- Device credentials use Keychain (`AfterFirstUnlockThisDeviceOnly`); D1 stores only credential hashes and scopes. Operator endpoints require `operator` scope and account-scoped event lookup.
- Test/live endpoints, D1 bindings, webhook signature slots, and Worker names are distinct. `LIVE_PAYMENTS_ENABLED` defaults false.
- Webhooks verify `Paymongo-Signature` over `t + "." + raw body`, select `te` or `li`, enforce five-minute skew, use constant-time comparison, validate schema/environment and deduplicate provider event IDs.
- Cron is not a public mutation route. It retrieves Payment Intents server-to-server, uses bounded batches and exponential backoff, and cannot regress `PAID_VERIFIED` to expired/failed.
- Reports never assert settlement or fees. CSV excludes photos, gallery tokens, URLs and credentials and prefixes spreadsheet formula-leading cells.
- Cash count corrections are append-only and audited; guest declarations remain a separate expected amount.

Open risk: Phase 1 offline snapshots are authenticated by possession of a provisioned device record but are not asymmetrically signed. Offline acceptance therefore remains bounded by short expiry and server conflict review. A production release should add a Worker signing key and app-pinned verification key before broad offline deployment.
