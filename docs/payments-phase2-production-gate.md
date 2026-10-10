# Production gate

> **LIVE DEPLOYMENT NOT AUTHORIZED**

- Owner approval recorded; merchant QR Ph and withdrawal/payout eligibility confirmed without assuming `payment.paid` means bank settlement.
- Legal, privacy, tax/BIR and invoicing review complete; the keepsake is not represented as a compliant sales invoice.
- All Worker route/concurrency tests, full Swift suite, accessibility runtime checks, test simulator E2E, real iPad and VOZY G80 recovery tests pass.
- Separate live Worker name, domain, D1 database, webhook secret, PayMongo key, device fleet and Cron reviewed.
- Backups, migration rollback/forward plan, rate limits, alerts and incident owner approved.
- `LIVE_PAYMENTS_ENABLED` remains false until the final deliberate release step and controlled small transaction.
- Gallery Worker, Apps Script routes and historical printed URLs verified unchanged.
