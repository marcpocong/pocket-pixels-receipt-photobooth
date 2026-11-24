# PayMongo decommissioning inventory

New automated PayMongo QR creation is disabled. The private pre-change LIVE export was restored and checked. The app-side snapshot contained 28 verified QR payment attempts, 28 completed QR orders and 28 consumed QR entitlements. This evidence covers application records. Provider-side payout and settlement closure requires the owner account.

| Resource | Disposition | Evidence needed before later retirement |
|---|---|---|
| `legacy-paymongo-final`, historical source and prerelease | Permanent archive | Preserve the current tag and backup references. |
| LIVE and TEST D1 payment histories | Retain, backed up privately | Preserve payment, entitlement, print, webhook and review evidence. Any later deletion requires a separate approved retention decision. |
| Provider lookup in scheduled LIVE reconciliation | Disabled with the reviewed release flag | Keep one-shot lookup and webhook handling for a later known obligation. Cron still maintains rate-limit rows. TEST is independent. |
| Provider webhook paths, original-order lookup, report routes and credentials | Retain for recovery | Establish provider settlement record, handling of late notifications, and offline access to needed records before removing bindings or endpoint access. |
| Automatic checkout creation route | Disabled for new QR attempts | Keep the existing guarded compatibility behavior while an old client can still look up original evidence. |
| PayMongo product account, provider export and wallet | Owner review | Review the supplied December 1 notice and download relevant provider records privately. No financial transfer is part of this release. |
| Old provider health alert | Scheduled reconciliation freshness omitted when LIVE reports reconciliation disabled | General service health, receipt and booth alerts remain active. |
| Current gallery Worker, existing gallery Apps Script and Drive folders | Active production | Independent of PayMongo. Preserve URLs and original customer assets. |

For an unexpected legacy obligation, locate the original order through authorized recovery or historical reporting. Use an authorized provider lookup while credentials work, or reconcile from the owner account and preserved records. Escalate discrepancies as unresolved. Preserve current state and avoid a replacement payment for an original claim.

The supplied PayMongo notice gives December 1, 2026 for Individual-account live key rotation, wallet and payment-method restrictions, and pausing Storefront and Pages. It gives January 29, 2027 at 11:59 p.m. Manila time as the upgrade deadline for existing Individual accounts. Verify applicability and export the provider ledger from the owner account. The application export does not establish the wallet balance, bank payouts, disputes or settlement status.
