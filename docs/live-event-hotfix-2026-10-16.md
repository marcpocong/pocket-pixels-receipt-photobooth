# October 16 live-event gallery hotfix

Retry All previously stopped on its first error; cancellation could release another upload's global lock. Queue recovery now snapshots and attempts every entry, reports partial success, serializes uploads across service instances, and retries retained work every 30 seconds while online. It first sweeps all uncertain public galleries before attempting any slow POST; each upload receives one attempt per pass so repeated backoff cannot starve later entries. Unknown deliveries first check their frozen public URL; completed public galleries reconcile without another POST. Remaining POSTs retain the original identity and use the existing idempotent backend. Failed attempts retain photos and uncertainty. Success requires the public completion marker.

Waiting Galleries now always shows Retry All, displays the current public-check/upload/verification step, refreshes queue counts every two seconds while visible, shows saved errors, and provides an explicit same-token replacement link for legacy-host records. Retry All wakes the existing worker between passes rather than launching another one. Frozen URLs and archives are unchanged. The original legacy QR is not claimed repaired. No backend deployment was needed.

The existing idle-reset task now waits 60 seconds on Thank You, then shows a 15-second countdown with Start Another Session available. Other customer states retain their previous timing. Payment/print safety guards, durable gallery tasks and recovery records are unchanged. Timer policy/reset isolation are tested; a physical 75-second thank-you cycle has not been observed during this hotfix.

## Validation and installation

- Baseline local and fetched main: `969e0c3207f79164d2349f998d522402f5bb80b9`, clean working tree.
- 63 focused simulator tests passed: delivery failures/restart, continue after failure, partial results, public reconciliation without duplicate POST, simultaneous retry/foreground triggers, cancellation lock safety, frozen URLs, customer reset/isolation, payment handoff and print durability. This is not a full Production Gate pass or a physical Wi-Fi reconnect drill.
- Signed Release build and strict codesign verification passed. Existing bundle `com.pocketpixels.PocketPixelsBooth`, team `PQ26682725`, version 1.0 (1) unchanged.
- Installed in place on paired Carlo (`00008112-000D08463E8BC01E`) after explicit owner confirmation of safe idle. Launch succeeded. No uninstall, container reset, financial transaction or physical print test.
- Before launch, all 3,635 Application Support files and 18 preference files were present after installation at unchanged sizes. Only system SplashBoard snapshots disappeared. Application Support and preferences were copied to local `/tmp/PocketPixels-live-preupdate-*` safeguards; these contain private customer data and are not committed.
- Initial queue: 24 galleries, all on the current front door; 23 delivery-unknown and one not started. Read-only app-style public checks returned 22 complete pages, one timeout and one page without the completion marker. Python's default client received Cloudflare 403; app-style and Safari-style clients reached completed pages. This does not establish iPad recovery counts.
- Post-launch device inventory confirms 2 of the original 24 galleries reconciled and 22 remain retained in the queue. Saved preferences were compared byte-for-byte after launch: all 18 unchanged. The remaining metadata retains delivery uncertainty and photos. Camera/printer appearance and the physical thank-you timer still require operator observation.
- Code pushed as `01e0a4e`; full Production Gate: https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/runs/38859354702 (pending at this report).

## Deferred until after the event

Redesign Event Mode start/stop, lifecycle explanations and event statistics as a separate task. Preserve selected event, lifecycle, payment mode, prices, authorized copies and receipt branding during this hotfix. Also defer broader background-upload architecture and restoration of the unavailable legacy hostname.

## Follow-up after owner reported a stationary “Uploading…” button

The first candidate could still spend multiple POST retries on an early gallery before checking later public pages; operator counts refreshed only after the full pass. Added the public-first sweep, one attempt per gallery per pass, observable activity, and live queue counts described above. A new synthetic regression covers an early unavailable page with later already-public galleries. **64 focused tests passed**, signed Release build/signature passed, and the follow-up was installed in place and launched while the owner kept Carlo idle in the operator screen.

Device inventory after the follow-up confirmed **6 of the original 24 queue records reconciled, 18 retained** at the observation point. During the pre/post installation observation interval, three earlier queued records completed and were removed from the upload queue; only queue metadata otherwise changed. Archives, payment state, app recovery, print audit and all preferences remained present at unchanged sizes. Successful queue reconciliation removes its redundant upload payload only after public verification; archived sessions remain saved. No failed record was discarded.

Physical Wi-Fi reconnection, camera/printer appearance and a full 75-second thank-you cycle remain operator checks; no new payment or print was issued. No backend deployment is pending. Full CI is separate from the 64-test local result.

## Slow public verification follow-up

When Carlo reached five remaining, all five original public pages returned HTTP 200 with the completion marker, correct photo counts and both receipts. Four cold responses took 10–15 seconds, exceeding the app's 8-second verification limit. All 27 embedded photo/receipt assets matched the original queued bytes exactly. Public checks warmed the cache and Carlo progressed from five to three without another installation.

Raised public verification request timeout to 30 seconds and total resource bound to 45 seconds. Upload request limits, backend contracts, identities and the public-success requirement are unchanged. **24 focused gallery tests passed**, including a synthetic nine-second public response that reconciles without any POST. Signed Release build and strict signature verification passed. After a fresh owner confirmation of safe idle, source `90f7cb3` was installed in place and launched successfully. Before launch, all 3,521 Application Support files and 18 preference files were retained at unchanged sizes; all three outstanding queue records remained present. Following launch, the queue progressed from three to two to **zero**. Device inventory confirms **all 24 original pending galleries recovered, with no new queued records at that observation**. The final five public galleries had already passed complete-page, photo-count, both-receipts and byte-for-byte asset verification. No backend change was required. Full CI for the tested code was still running: https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/runs/38860829665 .
