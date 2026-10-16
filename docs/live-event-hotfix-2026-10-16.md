# October 16 live-event gallery hotfix

Retry All previously stopped on its first error; cancellation could release another upload's global lock. Queue recovery now snapshots and attempts every entry, reports partial success, serializes uploads across service instances, and retries retained work every 30 seconds while online. Unknown deliveries first check their frozen public URL; completed public galleries reconcile without another POST. Remaining POSTs retain the original identity and use the existing idempotent backend. Failed attempts retain photos and uncertainty. Success requires the public completion marker.

Waiting Galleries shows saved errors and an explicit same-token replacement link for legacy-host records. Frozen URLs and archives are unchanged. The original legacy QR is not claimed repaired. No backend deployment was needed.

The existing idle-reset task now waits 60 seconds on Thank You, then shows a 15-second countdown with Start Another Session available. Other customer states retain their previous timing. Payment/print safety guards, durable gallery tasks and recovery records are unchanged. Timer policy/reset isolation are tested; a physical 75-second thank-you cycle has not been observed during this hotfix.

## Validation and installation

- Baseline local and fetched main: `969e0c3207f79164d2349f998d522402f5bb80b9`, clean working tree.
- 63 focused simulator tests passed: delivery failures/restart, continue after failure, partial results, public reconciliation without duplicate POST, simultaneous retry/foreground triggers, cancellation lock safety, frozen URLs, customer reset/isolation, payment handoff and print durability. This is not a full Production Gate pass or a physical Wi-Fi reconnect drill.
- Signed Release build and strict codesign verification passed. Existing bundle `com.pocketpixels.PocketPixelsBooth`, team `PQ26682725`, version 1.0 (1) unchanged.
- Installed in place on paired Carlo (`00008112-000D08463E8BC01E`) after explicit owner confirmation of safe idle. Launch succeeded. No uninstall, container reset, financial transaction or physical print test.
- Before launch, all 3,635 Application Support files and 18 preference files were present after installation at unchanged sizes. Only system SplashBoard snapshots disappeared. Application Support and preferences were copied to local `/tmp/PocketPixels-live-preupdate-*` safeguards; these contain private customer data and are not committed.
- Initial queue: 24 galleries, all on the current front door; 23 delivery-unknown and one not started. Read-only app-style public checks returned 22 complete pages, one timeout and one page without the completion marker. Python's default client received Cloudflare 403; app-style and Safari-style clients reached completed pages. This does not establish iPad recovery counts.
- First post-launch queue snapshot still had 24 entries. Awaiting operator/device confirmation of retry counts, settings, camera/printer status and the physical thank-you timer.

## Deferred until after the event

Redesign Event Mode start/stop, lifecycle explanations and event statistics as a separate task. Preserve selected event, lifecycle, payment mode, prices, authorized copies and receipt branding during this hotfix. Also defer broader background-upload architecture and restoration of the unavailable legacy hostname.
