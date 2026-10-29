# Manual acceptance — all items pending

No physical iPad, VOZY G80, real weak-network event or live Telegram delivery was tested in this
release. Use synthetic guests and a separate test event; preserve existing event/session data.

## Receipt Studio

- On the 11-inch iPad in portrait, open an existing saved design and a new design. Confirm full
  receipt on the left, tools on the right, whole co-brand header selected, and usable touch targets.
- Pinch, pan, switch Header / Footer / Text, edit a caption, move an individual identity, undo,
  redo and change typography. Confirm manual viewport stays stable. Check Fit Full, Fit Width,
  expanded preview, rotation, keyboard and large accessibility text.
- Move Whole Header with Fine / Normal / Fast. Check 1 / 4 / 12-dot moves where space permits;
  at bounds, arrows must stop at printable margins. Check supported size controls and all modes.
- Recenter at a non-default size: sizing/crop remain. Reset Selection: selected defaults return,
  and the uploaded artwork remains available. Whole reset restores the combined adjustments.
- Save to Setup, Save Design / Save Defaults, close and reopen, then relaunch. Check persistence.
  Cancel a different edit and reopen: cancelled changes must not appear.
- Print the same synthetic receipt before/after opening an untouched editor using the G80.
  Compare width, length, margins, header/footer, QR readability, raster direction and boundaries.
  Guides and selection highlights must never appear on paper.

## Gallery delivery

- With a synthetic test session, go offline before preparation and before POST. Confirm local
  media remains saved, the original QR identity is retained, and receipt printing / next guest work.
- On weak Wi-Fi/hotspot, interrupt a POST. Reconnect quickly several times and press Retry Now
  and Retry Gallery close together. Observe one delivery at a time and truthful Uploading /
  Verifying / Needs Attention state with last-attempt information.
- Queue several older galleries, then complete consecutive new guests while recovery runs.
  Confirm the active operation finishes, fresh work gets a timely slot, and old work progresses.
- Restart the app with pending and accepted-but-unverified galleries. Background and foreground
  it. Confirm eventual verification through the **original printed QR**, followed by cleanup.
  Check original photos and all receipt variants. Never regenerate identity or clear unknown media.
- Confirm authentication/configuration problems remain visible until repaired; repeated Retry Now
  and reconnections must respect a server rate-limit deadline. Do not alter production secrets
  or production records to simulate these failures.
- Retain uncertain print evidence. Acknowledge current printer recovery, relaunch, then admit a
  new guest / start the next test event. No old receipt may automatically print or gate operations
  merely because it appears in print history.

## Telegram (after separately authorized deployment)

- Export D1 privately, apply migration 0003 after 0001/0002, deploy the reviewed Worker, configure
  the distinct webhook secret and manually register the private owner webhook. Keep credentials
  out of screenshots, shell history, logs and the iPad. Do not enable paid infrastructure.
- Send /status, /event, /uploads, /incidents and /help from the allowlisted private owner chat.
  Compare the report generation time, heartbeat/sample time, backend check time and queue counts
  with Carlo. No response may claim unverified galleries are available or physical output is proven.
- Confirm another user/group cannot obtain a report and unknown/mutation commands do nothing.
- Pause a synthetic event, create a local retained upload backlog, recover connectivity, and observe
  appropriate warning/recovery delivery without repeat noise. Verify idle offline waiting is quiet.
- Close/background the app long enough for a stale heartbeat. Check both alerts and command
  responses label stale information; foreground and verify recovery. Remember iPadOS suspension
  can stop telemetry. Test actual Telegram delivery separately from mocked CI results.

## Rollout / rollback

Keep PR #20 a draft until release checks and required manual acceptance are reviewed. Deploy the
monitoring Worker and additive migration before enabling V2 commands. The app negotiates old
heartbeat schemas and can run against the previous Worker. No Gallery/Payments Worker deploy
is required by these changes. No live webhook has been registered by the implementation task.

Rollback app/Worker code without restoring old customer/session databases. Leave additive
monitoring tables intact and keep pending gallery directories, frozen tokens, QR URLs, archived
sessions, artwork, payment evidence and uncertain print records. If reverting the Worker to a
version without inbound commands, privately disable its Telegram webhook. Older apps ignore
optional queue metadata; they retain their prior retry policy, so rollout/rollback needs operator
supervision around rate-limited or attention items.
