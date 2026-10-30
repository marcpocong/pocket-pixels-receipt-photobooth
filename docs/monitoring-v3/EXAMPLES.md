# Owner message examples

Illustrative controlled states, not live Telegram deliveries. Real messages contain actual
transition/observation/report times in dated PHT and the actual accepted device sample time.
No guest/session/payment/QR identity is included. All commands are read-only.

```text
Made to Keep Studios · Carlo
WARNING: Printer needs attention
Event: active (last reported)
Transition: 30 Oct 2026, 14:08 PHT
Condition observed: 30 Oct 2026, 14:08 PHT
Printer connection: connected (bluetooth)
Readiness: ready
Physical-print evidence: requires review
Physical print outcome uncertain. A previous receipt may or may not have printed.
Open Equipment & Recovery on Carlo. Inspect the original receipt before deciding whether to reprint.
Last device report: 30 Oct 2026, 14:08 PHT; sample: 2026-10-30T06:08:00.000Z. Report generated 30 Oct 2026, 14:08 PHT.
```

During a current printing/recovery guest or a recovery lock this is CRITICAL. An idle radio
disconnect alone is visible through commands without an automatic warning. A persistent
active-event connection warning describes disconnected/unavailable and does not invent
physical uncertainty. Reconnection alone does not generate a full recovery while evidence
requires review. Recovery wording explicitly says reported conditions cleared and physical output remains NOT VERIFIED.

```text
Made to Keep Studios · Carlo
WARNING: Carlo heartbeat missing
Event: active (last reported)
Monitoring contact overdue. Current device/equipment state UNKNOWN.
Check Carlo is foregrounded and has network access. Missing contact does not diagnose equipment failure.
```

The real message also includes transition/observation/report and device times. Its recovery
says “Monitoring contact was restored,” gives the latest reported status time, and states that
equipment readiness is only known where explicitly reported; physical output is not verified.

/status includes freshness, heartbeat/sample times, booth/event context, network-path caveat,
printer dimensions and outstanding review, passive camera, coarse guest state, device payment
state and independently timestamped backend health, storage and correlated incident count.
A legacy sample labels printer observation as legacy and physical output NOT VERIFIED; an
uninitialized camera is “unknown / not checked.”

/event includes last-reported event reference/state, coarse guest state and observed activity.
It does not invent event names or session totals. It explicitly says inactivity is not a fault
and automated stall detection is unsupported.

/uploads reports “Last reported unverified queue,” uploading/verifying/attention counts and
oldest/activity times. It says only public verification establishes availability. Missing
metrics say observation unavailable; prior incidents remain last known.

/incidents groups printer causes with the last-known component conditions, severity,
transition, current/unknown evidence and local action. Other independent incidents stay
separate. “No unresolved incidents recorded” never claims equipment readiness.

/help lists only /status, /event, /uploads, /incidents and /help, and states read-only limits.
