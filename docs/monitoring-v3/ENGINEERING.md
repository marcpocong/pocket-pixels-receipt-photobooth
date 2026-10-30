# Monitoring V3

## Audit before implementation (30 October 2026)

Clean main and fetched origin/main: c422b59cfa5a994da49871e43a7c73226fd745cd.
Reviewed monitoring app/Worker/tests/migrations, printer coordinator/BLE readiness, event
operational state, guest model/state/content mounting, camera callbacks/watchdog, and current
print durability, acknowledgment/relaunch, session isolation, event/payment/gallery regressions.
The production gate and V2 corrective/validation records are historical evidence, not V3 results.

| Source observation | What it establishes | V3 policy |
|---|---|---|
| BLE connected + characteristic | Transport connected; paper/output unverified | Report connection separately |
| BLE disconnected / connecting | Radio link unavailable / in progress; no mechanical diagnosis | Idle informational; active persistent warning |
| Diagnostic text required | Readiness prerequisite, not a broken printer | Explicit diagnostic-required; contextual warning |
| Normal busy send | In progress, no proof of physical output | Busy; no availability alarm |
| Coordinator recovery lock | Current operation requires local recovery | Immediate attention; never acknowledge remotely |
| Current unresolved print/checkpoint/outbox inspection | Original receipt may have printed | Immediate uncertainty; survives reconnect |
| Historical acknowledged uncertainty | Retained evidence, no outstanding acknowledgment | No new uncertainty incident |
| Unreadable evidence store | Physical evidence unknown | Preserve prior incident; storage critical |
| Wi-Fi selected, BLE absent | BLE is unused | Read only selected Wi-Fi observation; no probe |
| Old Wi-Fi verification | Historical socket check, not current readiness | Unknown after observation ages out |
| Heartbeat missing | Monitoring contact overdue; device could be suspended/offline | Event-aware communications warning only |
| Missing/old optional metric | No fresh observation | Unknown, never recovery |

V2 snapshot emits `printer` for disconnected/awaitingTest/unresolved, and `uncertain_print`
for hasUnresolvedPrint/requiresRecovery. One recovery episode therefore creates two independent
notification streams. Operator state is designed for local admission/UI, not mechanical diagnosis.
BLE success cannot establish physical output. hasUnresolvedPrint already excludes acknowledged
historical records; preserve that logic. Monitoring currently performs an idle Wi-Fi socket probe;
V3 removes this monitoring side effect. No transport/admission/recovery behavior is changed.

The reported 14:08 printer + uncertainty pair is consistent with these overlapping predicates,
but cannot identify the original receipt or physical condition. 14:30 missing heartbeat describes
contact only. 14:39 recoveries require inspection of fresh evidence to justify them. V2 clears
missing upload metrics and all omitted incident codes, and applies a 15-minute cooldown to
recovery too. Old `ATTENTION` wording suggests V1 deployment; source is V2. Without querying
the authorized production service, the live version remains unverified. No physical-failure or
all-false-alert conclusion is justified.

## Implemented architecture and policy

Carlo samples existing state every five minutes; existing foreground-triggered reports remain.
No monitoring camera activation, connection probe, payment permission, print, resend, recovery
acknowledgment or guest-state transition is introduced. The selected transport alone supplies
connection/readiness. Wi-Fi reports the existing operator connection-check result for at most
five minutes, scoped to its endpoint; an absent/old check is unknown. Auto prefers connected
BLE, otherwise an observed Wi-Fi result, otherwise unknown. A normal active print checkpoint
is unverified/in progress, not by itself an inspection incident. Explicit outbox inspection,
qualification inspection, checkout receipt review and recovery locks remain immediate evidence.
Acknowledged historical uncertainty stays in the journal without creating a new operation gate.

V3 adds typed printer connection/readiness/evidence/transport, passive camera and coarse guest
state, with `telemetryVersion:3` and snapshot `reportedAt`. Unreadable event/admission storage reports unknown event context, not invented idle; that new enum value is omitted for older schemas. The app negotiates `/health` and
strips V3 fields for V2; V1 receives only legacy fields. A 422 after rollback retries once with
V1 fields. Capability is process-cached; relaunch/reconfigure after changing server capability.
Old clients remain accepted. Explicit V2 idle/active context uses the contextual policy; context-free V1 warnings remain conservative and immediate because unavailable and recovery cannot be reliably separated. An old server cannot provide V3 policies.

| Condition | Telegram policy |
|---|---|
| Storage error / verified paid session blocked | Critical immediately |
| Recovery lock | Critical immediately, including when idle |
| Unresolved print affecting current printing/recovery guest | Critical immediately |
| Other genuine unresolved print evidence | Warning immediately, even with unknown connection |
| V3 idle disconnect / diagnostic | Informational observation on commands; no automatic message |
| Active unavailable / connecting / diagnostic with usable event context | Warning after two fresh unhealthy reports spanning >=90 seconds |
| Active guest already needing local recovery + observed unavailable transport | Warning promptly; no invented physical uncertainty |
| Normal busy print / idle guest / initializing camera | No availability/stall alarm |
| Explicit camera failure, interruption or permission denial | Warning in last-reported active event; idle observation only |
| Gallery attention / active-event backlog older than 10 minutes | Warning; missing queue is unknown |
| Last-reported active event missing contact | Overdue at >=10 minutes |
| Idle, paused, recovery or unknown event missing contact | Overdue at >=15 minutes (existing STALE_SECONDS default) |
| Never-enrolled device | Unknown; no invented offline episode |

The 90-second printer minimum rejects rapid foreground/radio transitions; with five-minute
heartbeats it normally alerts at the second report, around five minutes. It never delays
inspection, storage or recovery-lock evidence. Cron remains five-minute periodic sampling,
so offline notifications normally arrive at the next check in the 10–15 / 15–20 minute range,
not at an exact second. Contact restored requires an accepted fresh sample. Old samples do not
restore contact, clear equipment incidents or replace a newer device sample. iPadOS suspension,
weak internet and app closure are possible explanations for lost contact, not proven diagnoses.

Each observation is healthy (0), unhealthy (1) or unknown (NULL), with source capability,
observed time and continuous unhealthy start. Unknown leaves the incident active/clear value
unchanged. An older capability cannot clear newer printer evidence. Missing upload metrics,
initializing/unknown camera, stale samples and unavailable local evidence cannot establish
recovery. Storage errors also prevent absent payment/event-recovery signals being treated as
successful clears. Worker failure does not synthesize a healthy heartbeat. UTC epoch times
are persisted; owner messages show dated Asia/Manila timestamps and explicit sample times.

Camera uses the mounted guest model's existing running/unavailable/initializing flags, a
passive interruption flag maintained in existing callbacks, and AVFoundation authorization.
Successful existing initialization clears the interruption observation. An observed runtime error remains recovery_required until existing initialization succeeds. No mounted model and
no current observation means unknown; old preflight success is never promoted to current
readiness. Guest telemetry maps the existing enum to idle/guest_in_progress/capture_waiting/
printing/recovery_required/unknown. Activity timestamps are process observations, not audit
history. Automated stall alerts are deliberately unsupported: there is no trustworthy,
process-wide transition deadline covering legitimate payment, review, sticker, signature and
operator waits. Existing camera watchdog/recovery remains the sole owner of capture recovery.

## Correlation, delivery and recovery

`incidents` retains separate printer/readiness and uncertain_print records. New
`incident_history` retains every subsequent component transition; old notification history is
unchanged by migration. A durable `notification_episodes` row correlates them for delivery.
A component mask and monotonic revision identify notifications. New components or critical
escalation generate an update; partial resolution generates no recovery. A recurring independent
component can alert again. Full recovery requires explicit clearing of involved components;
unknown is never recovery. Known standalone uncertainty can alert with unknown connectivity.
A source-version change cannot erase the higher-capability observation.

A separate `v3_notifications` queue holds printer-group and camera messages so a real V2
rollback cannot consume unknown codes or send an undefined title. Existing supported-code
notifications and command replies retain their tables. Fresh V3 contact bridges pre-existing
V2 printer evidence; old component warnings are superseded, retained as unsent/sent evidence,
and replaced with one coherent episode. A previously delivered V2 warning can receive one
combined recovery. Unsent alerts do not generate a pointless recovery.

A durable state lease serializes heartbeat/Cron mutations across Worker isolates. Accepted device report, observation,
incident history, episode revision and notification insertion commit in one D1 batch. A failed ingestion cannot replace the last accepted report. A
transactional ownership guard aborts a late writer after lease takeover. Delivery has per-code
leases plus atomic per-row claims and rechecks the current revision/evidence before sending.
Obsolete revisions are superseded before bounded queue selection; critical alerts outrank
other pending work. Heartbeat deliveries allow three sends, Cron two alerts plus two replies,
leaving Free-plan request headroom. Batches count as one D1 API request; a test proxy enforces
<=40 D1 requests including deferred work in heavy scenarios, below the documented limit of 50.
See [Cloudflare D1 limits](https://developers.cloudflare.com/d1/platform/limits/).
Actual production CPU/account-wide quota behavior still requires deployment observation.

The former 15-minute cooldown delayed real recoveries and urgent re-openings. V3 deduplicates
by durable transitions instead: no routine reminders, no repeat sends for unchanged evidence,
and no cooldown delaying a justified recovery/escalation. Debounce applies to connectivity,
not genuine uncertainty. Unknown/stale pending messages wait for fresh evidence; an obsolete
warning is superseded rather than arriving after its newer recovery. Recovery cannot overtake
an already leased send for the same episode. If the earlier Telegram request is already in
flight, its message cannot be recalled; recovery may drain at the next heartbeat/Cron check.

Five attempts maximum, backoff 1/5/15/60/60 minutes and Telegram Retry-After (bounded to a day)
remain. Exhausted notifications and command replies remain visible; completed/superseded
notifications expire after 30 days, delivered commands/replay rows after seven days. The
accepted update-date window is only 24 hours. Rate-window cleanup remains bounded. Unsent
exhausted command replies are no longer deleted by the seven-day replay cleanup.

Telegram sendMessage has no general idempotency key. A crash/timeout after remote acceptance
but before recording success can duplicate a bounded retry. Durable deduplication, leases,
supersession and ordering reduce duplicates; they do not promise end-to-end exactly once.

## Security and privacy

Webhook secret validation precedes bounded 4 KiB UTF-8 parsing. Owner user AND private chat
must match, sender must not be a bot, forwarded/edited/group/channel messages are rejected.
Only /status, /event, /uploads, /incidents and /help (optional bot suffix, no arguments) exist.
Replay IDs, ten commands/minute atomic limits, durable replies and bounded retries remain.
Device writes still use only the existing device Keychain credential; separate owner-read,
payment-health, Telegram and webhook credentials stay server-side. Public /health contains
only service/version/telemetryVersion/release. It does not prove which build is deployed until
an authorized operator actually reads the production endpoint.

Telemetry accepts bounded enums, queue counts/times and an existing event reference; no names,
images, payment/session IDs, QR identities, gallery URLs, raw logs or credentials are added.
Network path does not prove internet reachability; a POST does not prove a public gallery;
BLE/socket success does not prove physical paper output. Printing, payments, receipt pixels,
recovery acknowledgment and gallery durability code are unchanged.
