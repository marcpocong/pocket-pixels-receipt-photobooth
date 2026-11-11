# Gallery delivery reliability — 11 November 2026

## Release status

Implemented against fetched, clean `main` at
`9a2f9b574d00c00206bc9e6d6533b57500342e6e`. The backend transport is deployed and
live synthetic checks passed. The signed Release app is installed and launches on
Carlo after developer trust; physical workflow qualification remains pending. See the release
ledger for the exact integrated commit, tests and deployments.

## What was wrong

The previous benchmark submitted galleries independently. Automatic recovery
instead waited for each gallery's upload, public verification and cleanup before
starting the next. It also reconciled uncertain galleries sequentially before
working through the rest of the queue. Those barriers prevented the existing
scheduler from overlapping useful work. An online-to-online network change did
not reliably wake old retry deadlines. A single upload could hold the only send
lane while waiting for a connection; there was no byte-progress evidence to
distinguish this from a useful slow upload.

The schema-4 photo compression, derived monochrome receipt and omission of new
GIFs already existed. This change preserves those bytes and quality. Base64 JSON
still expands the binary media by approximately one third and cannot resume a
partially transmitted request. The Drive mutation lock remains necessary for
identity consistency; there is no live measurement proving its share of the
remaining strong-network latency.

## Delivery lifecycle

Capture/receipt preparation → atomic local media and metadata → bounded queue
admission → transfer → remote storage → publication → public verification through
the frozen QR URL → durable local proof → pending cleanup.

`retryPendingQueue()` now supplies at most six metadata tasks, interleaving
read work (uncertain **and already accepted**) with unsent galleries. A mixed-state
regression reproduced an idle transmission lane when accepted reads filled the
feeder; the final ordering corrects that case. Media opens after scheduler admission.
There is one gallery transmission lane and two independent public-read/publication
lanes. Each token retains one owner across its entire operation. Fresh guests
retain the existing two-fresh-then-old fairness rule. Accepted galleries use
GET-only recovery. Public verification and local proof remain prerequisites for
deleting pending media.

Network signatures compare interfaces, gateways, DNS/IP support and path cost
locally; those values are never logged. Meaningful online changes, foregrounding
and throttled validated backend acknowledgments reevaluate eligible temporary
failures. Authentication, inspection and real server cooldowns keep their gates.
A generation check after disk persistence prevents a late old-path failure from
reinstating stale backoff.

Actual URLSession byte/metrics callbacks distinguish waiting, connecting, slow
progress, transferring and awaiting response. The watchdog cancels partial/no-byte
requests only after 45 seconds without progress (30 seconds waiting for
connectivity); it does not cancel useful slow transfer or a completely sent body
while awaiting the response. Request/resource bounds remain separate. Logs contain
numeric counts/times, not gallery identities, URLs or credentials. Operator Gallery
Setup shows active byte tasks, stored/publishing galleries, remaining media,
verified-this-launch count and rate/phase.

## Transport decision

| Option | Evidence and consequence | Decision |
| --- | --- | --- |
| Existing single JSON POST | Fewer round trips; fastest in the zero-origin-latency strong TCP fixture. Base64 overhead and no partial-request recovery. | Retain on recently measured fast, unconstrained paths. |
| Scoped binary resumable Drive | Real Google HTTPS confirmed capability-only PUTs, server-offset resume and exact SHA-256. Paced app recovery used 25.7% fewer request-body bytes and drained 20 galleries 26.8% faster at 0.5 Mbps. | Use on unknown/weak/constrained paths; finish every persisted transfer with the same protocol. |
| R2 staging plus Drive synchronization | Would add another durable store, publication worker, credentials and orphan/retention lifecycle. Direct Drive already provides the demonstrated binary/resume benefit. No live R2 performance claim was made. | No second production implementation or new recurring service. Revisit only if measured Google latency remains the limiting factor. |

Automatic selection requires acknowledged throughput of at least 256 KiB/s,
measured within 60 seconds, before choosing JSON for a fresh gallery on an
unconstrained path. A network change/error clears the estimate; a weaker sample
drops it immediately. Acknowledgment time is included so kernel buffering does
not masquerade as upstream capacity. Unknown/weak paths start resumable when the
backend advertises support. Unsupported older backends retain JSON. A persisted
resumable journal always takes precedence, including after a capability rollback.

Apps Script authenticates the existing device token and reserves stable file IDs
under its coordination lock before issuing scoped upload sessions. The media PUTs
go directly to Drive, outside the lock. Private server journals survive lost
initialization responses. The app persists a protected journal and file-backed
256 KiB chunks, probes the server's offset on resume, and uses one or two asset
senders according to measured rate/path cost. Expired sessions refresh only the
missing asset using its reserved ID. Finalization validates exact parent,
filename, MIME type, size and SHA-256 before writing the existing manifest.

This implementation uses foreground URLSession transfers with file-backed chunks
and durable relaunch recovery. It does not claim continued execution while iPadOS
suspends/terminates the app, nor introduce an unvalidated background-session
handoff. Storage/publication are distinct from delivery; the app still verifies
the exact original customer URL before clearing local files.

## Measurements and their limits

Machine-readable [numeric evidence](../BuildArtifacts/GalleryDeliveryReliability/README.md)
contains p50/p95, first-ready, bytes, memory and heartbeat results. These are
controlled single runs, not venue service-level guarantees.

| Experiment | Before / comparison | Improved / chosen behavior |
| --- | --- | --- |
| Actual durable recovery, mocked 20 ms POST / 80 ms public verification, 20/50/100 galleries | 2.857 / 7.049 / 13.998 s | Pipelined 1.511 / 2.388 / 5.780 s; identical media/request bytes |
| Real local TCP, aggregate 0.5 Mbps, 20 galleries, identical 17,729,040 media bytes | JSON 394.000 s; first ready 19.731 s; bodies 23,914,100 B | Binary 288.484 s; first ready 14.482 s; bodies 17,757,880 B |
| Strong zero-latency local TCP, 100 galleries | Forced JSON 0.927 s | Forced binary 7.483 s; automatic follow-up 1.869 s (one binary gallery, then JSON) |
| Local TCP improves from 0.25 Mbps to unrestricted at 4 s, 20 galleries | JSON 4.487 s; forced binary 6.284 s | Automatic follow-up 4.792 s |
| Lost chunk acknowledgment, 50-gallery local TCP backlog | Server accepts chunk, drops response | 4.055 s; zero accepted media retransmitted; zero duplicate publications |
| Real Google Drive HTTPS, 1 MiB synthetic binary, probe at 256 KiB | Single unpaced sample: init 0.957 s, total 2.845 s | Paced 0.25 / 0.5 Mbps: 34.547 / 17.785 s; exact SHA-256; zero unnecessary media bytes |
| Real staged Apps Script 31 → scoped Drive → actual Worker/page, two synthetic JPEG assets | 1,883,288 media bytes; repeated init/finalize; ignored first chunk ACK | 53.726 s total; resumed at 262,144 B; exact stored hashes; zero unnecessary retransmission or duplicate files; publicly ready |

The TCP matrix uses actual app preparation, disk queue and recovery with synthetic
Google/public endpoints bridged to loopback. It excludes Google execution/Drive
latency, TLS radio behavior, real CDN geography and device/printer contention.
The adaptive follow-up regenerates a receipt with a different timestamp, so its
bytes are not asserted identical to the earlier forced matrix. Peak simulator
resident memory was approximately 349 MB. Main-actor heartbeat gaps were mostly
18–29 ms; the interrupted case peaked at 119.85 ms. These are simulator observations,
not physical capture/printing qualifications.

The earlier Drive microexperiments used private non-image files. The final live
backend check used two valid synthetic JPEG assets and the real staged Apps
Script/Drive/public Worker lifecycle. It exercised repeated initialization,
discarded a chunk acknowledgment, confirmed the persisted offset, verified remote
hashes, finalized twice and verified readiness plus the complete public HTML.
Its 53.726 s includes repeated coordination requests: initialization pair 11.470 s,
binary phase 8.229 s, finalization pair 13.213 s. These are owner-script initiated
server-to-server transfers, not a measured iPad venue drain time or a comparative
live speed claim. Real Apps Script round trips remain material on this sample;
automatic fast-path JSON retention avoids imposing them on every fresh gallery.

A read-only live check against an existing completed schema-4 gallery returned
HTTP 200, `status=complete`, the matching token and six files through the existing
Worker. This establishes baseline historical reachability for that gallery; it
does not qualify the new transport. Customer URLs and identities are omitted from
the checked-in evidence.

## Compatibility, cost and rollback

Bundle ID, team/signing settings, gallery token/session identity, frozen QR URLs,
original media, receipt variants, Keychain and print/history behavior are retained.
Historical schemas 1–4 and optional GIFs remain supported. No printing recovery
gate or automatic physical resend is introduced. The full regression gate includes
the existing acknowledgment → relaunch → next guest/event tests.

No dependency, paid plan, R2 bucket or new subscription is added. Existing Google
Drive storage and Apps Script/Drive quotas apply; binary sessions still incur API
operations. Incomplete private journals/media are retained for recovery and need
explicit review, not automatic expiration/deletion. Worker invocation query strings
are redacted to avoid recording gallery capabilities.

For rollout, sync both Apps Script files while preserving the manifest and all
properties. The owner must authorize/run `enableResumableUploadsForOwner` before
activation. Verify a staged synthetic gallery through initialization, interruption,
finalization and the actual Worker/public page; then update the existing production
deployment ID. Preserve `Execute as: Me` / anonymous gallery access. Check existing
galleries and diagnostic version/capability afterward. The Worker change is solely
query-string redaction; deploy with `--keep-vars` and compare settings.

For rollback, stop fresh resumable choices by disabling
`MTK_RESUMABLE_UPLOADS_ENABLED`; keep compatible server code available to finish
saved binary transfers when enabled again. Do not replace tokens/URLs or delete
journals/files. Repointing the existing deployment to version 30 restores the old
backend and published-gallery reads, but saved binary work waits for compatible
code. Rolling an iPad back before this client version likewise requires retaining
its full container and pending data; old clients cannot resume the new journal.
Restore the saved previous Worker version if necessary; no route/binding/origin
change is part of this release.

The historical `pocket-pixels-gallery.pocketpixels-ceb.workers.dev` hostname already
failed DNS in the October baseline. That remains an infrastructure limitation for
old printed URLs; preserving token/manifest compatibility does not repair a removed
hostname. This change does not rewrite those receipts or falsely mark them ready.

## Release ledger

- Source integration: pushed directly to `main` as
  `3c15adda30527b9dce9594f37f88be5206cc96cf`.
- Complete local production gate: 996 cases passed (1,031 runs including dynamic
  parameters), zero failed/skipped. Native UI: 27/28 passed initially; the receipt
  inspector visibility wait timed out, then the unchanged test passed on a focused
  final-source rerun. No assertion was removed or weakened. Final corrections
  distinguish temporary coordination failures from busy cooldowns and prevent
  accepted reads filling the feeder ahead of unsent work: 26 affected recovery,
  scheduler and resumable tests passed on the final source, following a reproduced
  mixed-backlog failure before the fix. Hosted Actions previously reported an
  account billing lock. The source commit's
  [Actions run](https://github.com/marcpocong/pocket-pixels-receipt-photobooth/actions/runs/42944732625)
  could not start its jobs for that same reason. Local results above are the
  executed evidence; hosted CI is not green. No billing settings changed.
- Backend gate: payments, monitoring, gallery Worker, existing Apps Script,
  resumable contract and isolated Drive experiment contract all passed.
- Apps Script: version 31 was validated in a separate staged deployment.
  Owner authorization and full staged live synthetic validation succeeded, then
  the **existing production deployment was updated to version 31** with its URL,
  anonymous access and execution identity preserved. Diagnostic:
  `made-to-keep-gallery-v10-resumable-20261111`, both `base64-json` and
  `drive-resumable-v1` advertised. Version 31 exactly matches the committed core
  source. The temporary owner diagnostic was removed from HEAD and was never in
  production version 31. The temporary staging deployment was retired after
  activation; version 30 remains the rollback version. An existing completed
  gallery passed live Worker readiness again after the production backend update.
- Gallery Worker: active `ef02c41b-ca24-47aa-bf9b-8630929da2c2` at 100%,
  deployed from `3c15add` with `--keep-vars`. The only intentional setting change
  is query-string redaction. Origin/bindings/runtime/remaining observability
  settings matched the saved baseline; an existing completed gallery passed a
  live readiness check afterward. Rollback:
  `2b10f3ca-e7d4-4ed4-808d-945991b32c73`.
- Carlo: the app was absent before this install.
  The earlier Xcode account/profile blocker is resolved. A signed Release build
  succeeded using the original bundle/team, the code signature and Carlo's profile
  inclusion were verified, and Made to Keep Studios 1.0 (3) was installed. Developer
  Mode is enabled. The first launch was denied by iPadOS's signature/entitlement/
  developer-trust check. After the owner trusted the profile, launch succeeded and
  the running process was independently rechecked. The owner then ran Check Gallery
  Backend in the installed app and confirmed `v10 resumable 20261111`, verifying
  device-side reachability of the released backend. A private installed-state
  snapshot was retained outside Git. The profile
  expires **18 November 2026 at 19:28 Manila time**: this is a seven-day development
  install and requires renewal. No uninstall/erase or Keychain edit was performed.
  Physical gallery, camera, printer and venue-network qualification remain pending.
