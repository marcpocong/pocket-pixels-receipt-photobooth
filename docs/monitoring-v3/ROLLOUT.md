# Manual rollout and rollback — NOT DEPLOYED

This release authorizes source integration only. No production D1 migration, Worker deploy,
secret change, webhook registration, live Telegram test, payment-backend change or Carlo
installation was executed. Hardware acceptance is separate from local/CI results.

## Safe order after explicit live-service authorization

1. Keep Carlo's installed app/data unchanged. Privately inspect current Monitoring /health,
   Worker deployment/version and the existing D1 migration ledger. Old ATTENTION wording is a
   mismatch clue, not proof of the live version. Compare to V3 public identity:
   `version:3`, `telemetryVersion:3`, `release:monitoring-v3-2026-10-30`.
2. Export the existing monitoring D1 privately and verify the export. Preserve all incident,
   notification, command/replay and device rows. Confirm the existing account remains Free;
   reuse the configured Worker/database and Cron. Do not create a new paid environment.
3. Apply ONLY unapplied additive migrations in this exact order:
   `0001_monitoring.sql` → `0002_notification_supersession.sql` →
   `0003_owner_commands.sql` → `0004_monitoring_v3.sql`.
   An already migrated V2 installation needs only 0004. If tables exist without matching
   migration-ledger entries, inspect and reconcile privately; do not blindly rerun old files.
   The new migration adds observations/history/episodes/leases/V3 queue plus one nullable
   episode_revision column on notifications. It drops/rewrites no existing evidence.
4. Package locally, then deploy the Monitoring Worker first. Verify /health and authenticated
   /v1/overview without displaying credentials. Confirm legacy Carlo reports still enroll.
   No Payments or Gallery Worker deployment is needed.
5. Preserve existing secret values. Required names: DEVICE_TOKEN, OWNER_READ_TOKEN,
   PAYMENTS_HEALTH_TOKEN, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID,
   TELEGRAM_WEBHOOK_SECRET. The distinct webhook secret is 32–256 characters; the chat ID is
   the private owner's user ID. PAYMENTS_HEALTH_TOKEN matches the Payments Worker's minimal
   MONITOR_READ_TOKEN. Confirm DEVICE_ALIAS, STALE_SECONDS=900, existing live payment-health
   URL, D1 binding and */5 Cron. Put any missing secrets through private Wrangler stdin;
   never paste values into shell arguments, source, reports or chat. Do not rotate working
   credentials as a routine rollout step.
6. If a valid V2 webhook already exists, preserve it. If setup is needed, privately call
   Telegram setWebhook for `https://<monitor-worker>/v1/telegram`, with matching secret_token
   and allowed_updates=["message"]. Preserve pending updates (`drop_pending_updates:false`).
   Verify getWebhookInfo privately (URL, pending count and last error), and the five owner
   commands in the private chat. Deny wrong-user/group requests in synthetic/local testing;
   do not invite others into the real owner chat for a test.
7. With Carlo available, take a private app-data snapshot, verify available storage and the
   existing bundle/team identity. Build/install the validated main in place with the existing
   signing. Do not uninstall, erase, clear Keychain, reset event state or overwrite records.
   Compare saved record hashes/counts and frozen pending gallery identities before/after.
8. Foreground/relaunch the updated app to negotiate V3. Verify accepted sample time and
   dimensions via owner /status and overview, then execute the physical acceptance checklist
   during a controlled test event. No historical uncertain receipt may be automatically sent.
9. Separately authorize and record one real bot-delivery/security check and controlled
   offline/recovery exercise. Do not edit production timestamps/incident rows to simulate
   failure. Confirm owner-only delivery, no storms, current release, queue retention and
   truthful recovery. Record actual observations; simulator results are not substitutes.

The exact maintenance commands below are DOCUMENTATION ONLY. Run from repository root after
separate live authorization, using a private export destination and existing credentials:

```sh
monitor_wrangler=Backend/PaymentsWorker/node_modules/.bin/wrangler
monitor_config=Backend/MonitoringWorker/wrangler.toml
"$monitor_wrangler" deploy --config "$monitor_config" --dry-run --outdir /tmp/mtk-monitor-package
"$monitor_wrangler" d1 migrations list made-to-keep-monitor --remote --config "$monitor_config"
"$monitor_wrangler" d1 export made-to-keep-monitor --remote --output /PRIVATE/monitor-backup.sql --config "$monitor_config"
"$monitor_wrangler" d1 migrations apply made-to-keep-monitor --remote --config "$monitor_config"
"$monitor_wrangler" deploy --config "$monitor_config"
```

## Rollback

Revert app and Worker CODE independently to the prior validated main version, preserving
bundle/signing/Keychain and all durable records. Leave 0004 and earlier additive schema/data
in place. Never restore an older D1/app-data backup over newer records. V1/V2 app schemas still
work on V3. V3 strips new fields for V2 and retries legacy after a rollback 422. Reconfigure or
relaunch after a server capability change because negotiation is process-cached.

The test suite executes the frozen V2 production module against the migrated database: old
queries, legacy heartbeats, command replay and pending replies remain usable. The V2 module
cannot consume the dedicated V3 printer/camera queue, so those pending records survive for
rollforward. V2 resumes its older classification/cooldown/unknown semantics; it is not a way
to retain V3 alert guarantees. Historical notification text is never rewritten. Watch for
old-version wording and report capability accurately. A V2 webhook can remain for a V2
rollback; a V1 rollback needs a separately authorized private webhook removal, preserving
pending updates, because V1 has no owner command endpoint. Do not rotate secrets or modify
payment infrastructure to roll back monitoring.
