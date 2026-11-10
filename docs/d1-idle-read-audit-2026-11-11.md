# D1 idle read alert investigation — 11 November 2026

The daily 75% D1 read warning is explained by the production monitor's five-minute
Payments health check. The latest-run lookup scans and sorts all retained reconciliation
runs. The history grows every five minutes regardless of event activity. Guest gallery
visits are not needed to produce this usage.

## Read-only production evidence

Inspected the existing Cloudflare account with its existing Wrangler OAuth session.
During the initial inspection, no remote data, code, triggers, secrets, billing or payment settings were changed.
No guest media or credential values were retrieved. Times below use Philippine time
(UTC+8) unless explicitly marked UTC.

- All three account D1 databases are the expected LIVE payments, TEST payments and
  monitoring databases. The gallery proxy has no D1 binding.
- LIVE events: three archived and one ended; zero active.
- LIVE reconciliation history: 8,333 retained runs at the initial inspection, beginning
  12 October at 20:45:39 UTC; seven existing migrations (0001–0007).
- The deployed public monitoring identity is version 1. The repository's V3 source
  is a separate, undeployed release; this repair does not require that upgrade.
- `sqlite_master` shows only the primary-key index on `reconciliation_runs`.
- `EXPLAIN QUERY PLAN` reports `SCAN reconciliation_runs` and
  `USE TEMP B-TREE FOR ORDER BY` for the health query below.
- A subsequent direct execution with 8,334 retained runs reports **16,668 rows read**
  and zero rows written to return one completion timestamp.

Wrangler D1 Insights, rolling windows sampled during the inspection (sampled analytics;
not a complete security audit):

| Database / query | Window | Executions | Rows read |
| --- | --- | ---: | ---: |
| LIVE latest-run health lookup | 24 hours | 275 | 4,508,260 |
| LIVE latest-run health lookup | 7 days | 1,984 | 29,079,380 |
| LIVE interrupted QR creation check | 24 hours | 275 | 8,250 |
| LIVE pending payment reconciliation selection | 24 hours | 276 | 8,004 |
| Monitoring notification retention cleanup | 24 hours | 270 | 58,050 |
| TEST pending payment reconciliation selection | 7 days | 2,000 | 16,000 |

The health lookup accounts for over 99% of the LIVE read volume shown in the 24-hour
query results. The largest other queries are much smaller. The observed five-minute
cadence and SQL identify internal monitoring as the dominant consumer, rather than
guest traffic. These metrics do not establish that every possible security issue is absent.

```sql
SELECT finished_at FROM reconciliation_runs
WHERE environment=? ORDER BY started_at DESC LIMIT 1;
```

The account warning threshold is 3,750,000 rows (75% of 5,000,000). At approximately
16,668 rows per check and 288 checks per day, this query alone projects to about
4.80 million reads per day at the current history size. Cloudflare resets the daily
allowance at midnight UTC, which is **8 AM Philippine time**. At that rate the warning
threshold is reached roughly 18 hours 45 minutes later, around **2:45 AM**. This is an
estimate, not a claim to have reconstructed individual email delivery times. Continued
history growth makes the alert earlier and can eventually exhaust the allowance.

Cloudflare documents [how indexes reduce scanned rows](https://developers.cloudflare.com/d1/best-practices/use-indexes/),
[D1 pricing and daily limits](https://developers.cloudflare.com/d1/platform/pricing/), and
[query insights](https://developers.cloudflare.com/d1/observability/find-expensive-queries/).
The warning concerns database reads; reaching the limit can cause requests to fail until
reset, without deleting stored data.

## Prepared repair

Migration `0008_reconciliation_health_index.sql` adds one covering index:

```sql
CREATE INDEX reconciliation_runs_environment_started_idx
    ON reconciliation_runs(environment, started_at DESC, finished_at);
```

The existing query can then find the newest matching run and its completion time directly.
No Worker redeployment, iPad installation, dependency, plan upgrade, event mutation,
history deletion, payment retry or print action is required. Index construction has a
one-time read/write cost; subsequent reconciliation inserts/completion updates maintain
the index. The additive migration preserves every run and existing health semantics.

Local regression coverage upgrades a populated 0007 database with 10,000 historical
runs. It verifies the unindexed read amplification, identical results after the migration,
a covering-index search without a scan or temporary sort, and at most two rows read for
the indexed lookup. It also verifies authentication, stale history, recent success,
newest unfinished-run handling, completion updates and environment isolation.

Validation completed:

- Payments Worker: **224/224 tests passed**, including the populated-database upgrade
  regression and Wrangler's local migration runner.
- `npm run check` and TEST/LIVE `npm run validate:config`: passed; packaging was dry-run
  only and uploaded nothing.
- iPad app simulator build: **BUILD SUCCEEDED**, with existing Swift concurrency and
  other compiler warnings in unchanged app sources. No iPad source, signing or bundle
  identity was changed. iOS tests were not run for this database-index-only repair.
- `git diff --check`: passed. The pre-existing edit to
  `docs/gallery-drive-performance-2026-10-30.md` was left untouched.

## Production application — completed after owner authorization

The owner subsequently authorized production application. On 11 November Philippine time,
the existing LIVE database received migration 0008 only. No Worker deployment was needed;
a plain LIVE Worker deployment can disable payments because of the checked-in safety default.

Verified execution results:

- Rechecked the migration ledger: 0008 was the only pending migration.
- Exported a private 2,857,101-byte SQL backup outside the repository, with restricted
  directory/file permissions. Restored it into an in-memory SQLite database and verified
  `integrity_check=ok` and zero foreign-key violations before changing production.
- Private backup and verification manifest are under
  `~/Library/Application Support/PocketPixelsBooth/Backups/CloudflareD1/20261110T190937Z/`.
  SQL SHA-256: `8d10de4acbf0df572a4947fef68e1f684b93d8c26ec741a3415e0786601d95ad`.
- The migration runner applied 0008 successfully; no migrations remain pending for LIVE.
- Production query plan now uses
  `SEARCH reconciliation_runs USING COVERING INDEX reconciliation_runs_environment_started_idx`.
- The exact health lookup fell from **16,668 rows read to 1**, with the identical completion
  timestamp `2026-11-10T19:05:44.681Z` immediately before/after. This is a 99.994% reduction
  in reads for that lookup; it is not a claim of that reduction for all account queries.
- All 8,334 reconciliation runs present in the backup remained immediately after migration.
- The next normal scheduled reconciliation started at 03:10:43 and completed at 03:10:44
  Philippine time on 11 November, with zero pending attempts inspected and no failure
  summary. A fresh health lookup returned that new completion timestamp and still read
  exactly one row. The monitor's reconciliation incident was inactive during verification.
- Public LIVE identity still reports `environment:live`, `liveEnabled:true`, version 3.
  Monitoring remains its existing version 1. No TEST/monitoring database migration,
  secret change, billing change, app install or payment/print action was performed.

Procedure used / follow-up checks, from the repository root:

1. Privately export the current LIVE D1 to a restricted destination outside the repository
   and verify the export succeeded. Preserve all data. Recheck the remote migration ledger
   and index definitions so the approved change is still the only pending migration.
2. Apply only migration 0008 to the existing LIVE database using the existing migration
   runner, explicit `--env live`, explicit config and `--remote`. Abort if other migrations
   are pending. No TEST or monitoring database change is needed for the immediate repair.
3. Repeat `EXPLAIN QUERY PLAN` and the exact health SQL, verifying an indexed search,
   approximately 1–2 rows read, and the same newest completion timestamp. Allow for the
   normal five-minute reconciliation tick when comparing timestamps.
4. Check the public LIVE identity still reports `liveEnabled:true`. Observe subsequent
   monitoring health and new D1 usage; rolling 24-hour/7-day analytics retain pre-fix reads
   until those windows pass. The next complete 8 AM–8 AM daily window (11–12 November)
   remains a follow-up observation; it cannot be verified during this pre-dawn repair.

Migration command used after the ledger check and verified private backup:

```sh
Backend/PaymentsWorker/node_modules/.bin/wrangler d1 migrations apply \
  pocket-pixels-payments-live --env live --remote \
  --config Backend/PaymentsWorker/wrangler.toml
```

If rollback were needed, remove only the new index after inspection. Never restore an
older backup over newer financial history. The repair changes query access paths only;
it does not alter recovery, acknowledgment, entitlement or physical print behavior.
