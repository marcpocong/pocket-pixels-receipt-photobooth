# Payments Phase 2 architecture

```text
Protected operator UI ── bearer/operator scope ─┐
Booth checkout UI ─────── bearer/device scope ──┼─ Payments Worker ─ D1 ledger
PayMongo webhook ─ raw-body HMAC test/live ─────┤       │
Cloudflare Cron ─ non-public scheduled handler ─┘       └─ PayMongo Payment Intent API

Existing Gallery Worker / Apps Script / printed gallery URLs: unchanged and isolated
```

Commercial lifecycle is `DRAFT → ACTIVE ↔ PAUSED → ENDED`; policy revisions and orders are immutable snapshots. Pausing/ending blocks new orders but does not remove paid entitlements. Existing installations default to local `PRIVATE_PREPAID`; branding mode remains independent.

QR authorization is created only by the canonical provider-evidence transition used by webhook and Cron reconciliation. It validates intent, amount, PHP currency, environment and final provider state, and relies on unique order/intent/entitlement constraints. Cash produces `UNVERIFIED_CASH_DECLARED` or `LOCAL_UNSYNCED_CASH_DECLARED`; sync never upgrades its verification.

The view model gates camera preparation, capture and printing. Paid quantity is frozen before capture and the preview cannot raise it. One entitlement binds one session and one receipt fingerprint; uncertain physical output remains an operator recovery item.

Offline cash requires the cached policy’s explicit expiry and durable atomic local ledger. The unavoidable last-known-state window is bounded by that expiry. QR never falls back to cash from an unknown state.
