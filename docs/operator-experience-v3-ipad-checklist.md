# Operator Experience V3 — physical iPad acceptance

**Status: not performed.** These checks are for the owner after separately authorizing the device/build, any app installation, event activation, physical print budget and payment testing. Carlo must not be installed/uninstalled or have data deleted under the implementation authorization. Use a designated test iPad and synthetic guests/events where possible. Do not initiate LIVE payment/event activity without its own owner authorization.

Record tester, date, device/iPadOS, build/commit, printer model, connection type, approved paper budget and authorized payment environment. Keep existing archives, photos, events and payment records.

## Everyday operation

- [ ] Open Operator Home in portrait and landscape. Regular Booth Settings, Quick Start Event and Recent Sessions are visible at the top. Return to Booth remains reachable.
- [ ] Open Regular Booth Settings directly, without an event. Change maximum copies and default copies; Save is reachable in the navigation bar without scrolling to the bottom.
- [ ] Set default 2 / maximum 3. Verify a new Regular Booth guest receives these settings. Disable guest copy choice and verify the guest cannot increase or decrease the included quantity.
- [ ] Turn formats off/on and verify the next guest sees exactly the enabled formats, including readable Grid 6 and Photo Pass labels.
- [ ] Close and relaunch the app without deleting data. Copies, formats, footer, logo/caption and gallery style persist.
- [ ] Begin a synthetic guest session. Change defaults in Operator. Verify that guest keeps its starting configuration and the following guest gets the new configuration.
- [ ] Verify standard receipts retain the established Made to Keep appearance. Preview each selected footer/gallery style. Decorative barcode mode clearly explains that there is no printed gallery access.
- [ ] Add/replace a logo, preview it, save and relaunch. Prior archived receipts retain their original artwork/raster. A missing logo is explained rather than producing an unexplained blank space.

## Printer and camera

- [ ] With Bluetooth selected, verify disconnected → reconnecting/busy → ready states match the actual printer. Changing printers is understandable and safe.
- [ ] With Wi-Fi selected and Bluetooth off, reconnect and verify Wi-Fi readiness without a false Bluetooth warning. Confirm the configured printer address and port under Advanced.
- [ ] With Auto selected, confirm the expected printer/transport is used and a connected Bluetooth printer's required post-recovery text test cannot be bypassed by old Wi-Fi evidence.
- [ ] While a separately approved diagnostic print is busy, verify Home does not say the printer is disconnected or prompt an unnecessary recovery action.
- [ ] Open Manual Test Print. Verify opening/previewing alone consumes no paper. Only after separate authorization, request one print and inspect image detail, footer/QR, paper feed and cutting.
- [ ] Run Camera Check; verify live framing and accurate status. Background/foreground the app and verify it requests a fresh check. Denied permission/unavailable camera must not appear ready.
- [ ] If owner monitoring is configured, verify healthy Wi-Fi with unused Bluetooth stays healthy, busy printing does not create a false printer incident, and repeated identical real failures do not flood alerts. Never paste monitoring credentials into a report.

## Event workflow

- [ ] Create a synthetic event and locate copies/formats, logo, footer/caption, gallery style and preview before launch.
- [ ] Save for Later while a synthetic recovery item exists. Confirm the event/design saves but the active guest setup and event admission stay unchanged.
- [ ] Save an unfinished design with personalization on but no logo. Saving is allowed; activation explains what needs completing.
- [ ] With separate event authorization, review and start a free event. There is one review page and no redundant second confirmation sheet.
- [ ] Pause/resume the free event. End it with the explicit End Event review. Verify return to saved Regular Booth defaults and retained history/statistics.
- [ ] Switch between two saved events, make distinct copy/design edits, save and relaunch. Verify each event's saved settings and staged edits stay with that event.
- [ ] In an authorized TEST payment environment, verify a changed server version requires review, the exact price/methods are shown, operator cash authorization is required and ambiguous paid transitions remain closed. Verify switching away from paid operation uses the safe transition path.

## Recovery and intentional reprints

- [ ] Use an authorized synthetic interrupted session before printing. Keep Session & Continue retains its photos in Retained Interrupted Sessions and does not mark it printed or resolve a payment.
- [ ] Only with a separately approved diagnostic fault test, interrupt a synthetic print after bytes could have started. Verify the app says the receipt may already have printed and never automatically retries.
- [ ] Inspect actual paper and restart the printer. Record the check, reconnect and complete any required short paper test. Verify the original outcome stays uncertain.
- [ ] Relaunch after acknowledgment. The same old checkpoint stays historical, and its retained photos remain viewable. A different uncertain checkpoint must require a fresh check.
- [ ] For a simulated failure before any bytes, verify the wording says nothing was sent and does not claim an uncertain physical outcome.
- [ ] Open Recent Sessions, find a synthetic receipt/gallery and preview the original QR. With a separate print authorization, intentionally print one extra archived copy; verify it uses the exact old raster and records a separate reprint batch.
- [ ] Verify interrupted payments, print accounting and unreadable storage still require the appropriate review before activation. Ordinary safe settings edits remain available.

## Layout, access and closeout

- [ ] Repeat key flows in portrait, landscape, split/narrow presentation if used, and accessibility text sizes. Check toolbar Save, Back, Start, End, copy controls, footer pickers and long event names.
- [ ] With VoiceOver, verify action labels, copy steppers, formats, status and preview navigation are understandable. Operator-only photos, recovery, payments and settings stay behind operator access.
- [ ] Confirm no customer archive/photo/gallery/payment/history/journal was deleted or reassigned. Record any failure with synthetic session ID, observed state and approved diagnostic evidence; exclude customer images, tokens and credentials.

Acceptance result: pending owner testing. Record approved exceptions and unresolved hardware/venue issues before any production rollout.
