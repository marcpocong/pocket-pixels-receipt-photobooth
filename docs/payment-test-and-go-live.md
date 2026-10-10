# Payment Test and Go-Live Gate

## Test-mode trial

1. Review and deploy a dedicated test Worker/D1 only; apply both migrations.
2. Configure test PayMongo secret/public keys and a distinct test webhook secret in Worker secrets.
3. Pair one iPad with a per-device booth credential in Keychain. Configure `PAYMENTS_API_BASE_URL` as HTTPS and `PAYMENTS_ENVIRONMENT=test` without embedding secrets.
4. Create and activate a test pay-per-print event. Verify QR-only, cash-only, both methods, paused/ended, and private/prepaid.
5. Use PayMongo `test_url` for success/failure. Do not scan a test QR with a real wallet.
6. Test airplane-mode cash, restart before/after declaration, replay sync, stale policy, pending QR connection loss, and duplicate taps.
7. On an actual iPad and VOZY G80, test 1/2/3/10 identical copies, partial/uncertain print recovery, Passport, stickers, gallery QR, VoiceOver, Dynamic Type, portrait, and landscape.
8. Confirm old printed gallery links and queued uploads still work.

## Owner prerequisites

- Confirm QR Ph live eligibility and payout/withdrawal state in PayMongo.
- Confirm legal, registration, invoicing, tax, privacy, and retention obligations with qualified advisers. A photobooth keepsake is not automatically a BIR-compliant sales invoice.
- Establish operator credential issuance/rotation/revocation and recovery procedures.
- Add production rate-limit monitoring, reconciliation scheduling, alerting, backups, and incident ownership.

## Manual live release gate

Live requires a separate live Worker, D1, domain, API key, webhook secret/endpoint, device provisioning, and `LIVE_PAYMENTS_ENABLED=true`. Perform a small controlled transaction only after explicit owner authorization and checklist sign-off. Never reuse test records or secrets.

## PRODUCTION GO-LIVE NOT AUTHORIZED

This repository change does not authorize live deployment, production D1 migrations, secret publication, real QR payment, or gallery routing changes.
