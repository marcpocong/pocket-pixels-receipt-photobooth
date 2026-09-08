# Phase 9 — Event Operator Experience

Phase 8 checkpoint: `a0b7cdd326bc1b3f863c0cd5fc76da47c559604d`.

## Operator workflow

1. On Welcome, hold the logo for four seconds to open **Event Operations**. DEBUG builds also retain the existing Open Admin shortcut. Customer error/recovery screens offer hidden staff access by holding “Staff assistance required” for two seconds.
2. Review the status and specific reasons at the top. Set the Event Profile and Gallery Credentials if needed. Credentials are saved through the existing Keychain store.
3. Open **Run Event Preflight** and run the checks. Routine preflight does not print paper. It checks camera permission/initialization, configured Bluetooth raster readiness, queue/recovery state, archive/recovery accessibility, free space, gallery queue, credentials, network, and event profile.
4. Use **Camera Check** for a live preview before guests arrive. Camera initialization checks are invalidated on backgrounding or a customer-camera interruption/runtime error. Run preflight again after the session.
5. During the event, use Recent Sessions, Pending Uploads and Print Audit. The home screen shows storage, launch counters, and retained-audit statistics.
6. Before closing, use **Review End-of-Event Summary**. Resolve printer uncertainty and finish customer work. Keep the app open with internet if galleries remain. The summary does not delete data or reset counters.

## Readiness

- **READY FOR EVENT:** all available checks pass.
- **READY WITH ATTENTION:** critical checks pass; a noncritical item needs attention, such as offline internet, pending galleries, missing credentials, or a partially configured optional event profile.
- **NOT READY:** a critical check fails or is unverified. An empty check list never claims readiness.

The camera check verifies initialization, not image quality or uninterrupted future operation. Printer readiness uses the existing Bluetooth service's raster eligibility, including its recovery/text-test requirement. Wi-Fi readiness is conservatively marked unverified; this phase adds no new Wi-Fi probe or transport logic.

Storage thresholds use decimal bytes: below 100 MB is Critical; 100 MB to below 500 MB is Getting Low; 500 MB or more is Healthy. These thresholds are not an event-capacity estimate.

## Recovery and intentional reprints

**Recovery Center** is the production operator recovery entry point. When print status is unknown, a receipt may already have printed. Inspect the paper, restart the printer, and explicitly confirm both actions. Confirmation sends no print job and does not erase the recovery snapshot.

After reconnecting, the existing Bluetooth recovery path requires a diagnostic text test. **Print Diagnostic Text — Uses Paper** has a separate confirmation. Confirm successful physical output only after actually inspecting it. This is not part of routine preflight. Failed diagnostic transmission never retries automatically.

Recovery acknowledgement lasts for the current app launch and is tied to the saved snapshot identity. Relaunching with an unknown-print snapshot requires fresh acknowledgement. The historical physical result remains unknown even after acknowledgement.

Recent Sessions displays timestamps, session IDs, formats, thumbnails, retained print-audit context and pending-delivery context. A missing queue entry is explicitly not proof of successful gallery delivery. Copy counts are shown only when retained audit evidence exists.

An **OPERATOR REPRINT** uses the existing frozen archive and creates a new batch/job. It requires an idle printer, a clear shared recovery lock and no unacknowledged unknown print. Confirmation reminds staff to inspect earlier output. All existing transport guards remain in force.

## Pending galleries and storage

Pending Uploads shows the count, oldest queued time, session time, retry count, last attempt and network status. Retry All uses the existing serialized queue worker. It is disabled while running or offline. Individual retry is deferred because the existing operator worker is queue-based; View Session opens the matching archive search.

Failure messages are deliberately concise and omit raw service errors/URLs. Failed uploads retain their local data. No new printing dependency on internet was introduced.

Automatic age/count pruning of completed archives is disabled. Opening the store also no longer deletes staging directories, because another archive save may own those files. A failed save still cleans up its own staging files. Archive deletion controls are withheld until cleanup can protect delivery and recovery state. Abandoned staging files may therefore consume storage; monitor free space and defer cleanup to a deliberate maintenance workflow.

## Counters and lifecycle scope

Sessions completed, camera restarts and uptime are labeled **this app launch**. Requested copies are deduplicated by batch, and recovery events by job, within the retained audit (up to 200 jobs). Those audit statistics are not lifetime/event totals and can decrease as old audit records roll off.

Formal Start/End Event persistence is deferred. End-of-event review is informational. Automatic idle timeout is also deferred; existing cancellation/reset controls remain, with cancellation blocked during active or uncertain printing. Normal next-customer reset still clears identity, photos, gallery state and copy selection (back to one).

Rapid Start taps cannot replace an existing session. Preflight, camera restart, upload retry, reprint and recovery actions use working-state guards. Closing admin is disabled while preflight or printer work is active. Session-generation protection and print ownership logic are preserved.

## Diagnostics and development tools

Copy Diagnostic Report includes readiness, launch statistics, camera/printer/queue state, network, storage, and compact latest-print details. It excludes images, gallery URLs, gallery tokens, device credentials and raw service-error text. Print Audit presents up to 200 retained jobs and distinguishes transport completion from confirmed paper output.

Endurance/chaos tools, deep printer diagnostics, camera development tools, gallery development tools and the debug booth are grouped under **Developer Tools** in DEBUG builds only. Production operators use the concise operations views.

## Validation and hardware boundary

All 29 Phase 8 tests are retained unchanged. Phase 9 adds 16 focused tests for readiness, storage thresholds/probes, shared reprint policy, recovery acknowledgement, batch/job counters, repeated Start, next-customer reset and archive preservation (including in-progress staging data).

Simulator verification covers software behavior only. A real iPad and VOZY G80 are still required to validate camera capture/framing, physical text output confirmation, BLE interruptions before/after bytes, single/multiple copies, feed/cut behavior, long thermal-paper runs, lock/sleep/foreground recovery and event-duration resource usage. No BLE pacing, chunks, thermal timing, density, photo processing, raster commands or receipt design was changed.
