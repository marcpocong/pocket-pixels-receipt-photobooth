# Phase 10 — Customer Experience

## Customer journey

The production flow remains Welcome → Format Selection → Camera Preparation → Camera Ready → Countdown and Capture → Review and Retake → Receipt Composition → Receipt Preview and Copy Selection → Printing → Thank You and Gallery → Welcome.

The existing customer experience already provides large booth-distance controls, visual format cards, photo-number context, a Reduce Motion-aware countdown, shutter feedback, a photo-first review, individual and full retakes, background receipt composition, a large receipt preview, a 1–10 copy stepper, multi-copy progress, a high-contrast gallery QR code and a clean next-customer reset. Phase 10 keeps that state machine and its print/session ownership rules.

## Event customization

Event Setup now separates customer-screen content from printed-receipt content. Operators can enable screen branding, set a screen title and subtitle, add independent welcome and thank-you messages, and select a controlled theme. Blank screen title and subtitle values fall back to the existing event name and host. Screen fields are normalized to one line and have fixed character limits.

Receipt event branding remains separately enabled and continues to use the existing receipt event name, subtitle, date, location and receipt message. Screen customization does not add content or length to the thermal receipt.

Five screen themes are available: Pocket Pixels Classic, Warm Celebration, Minimal Light, Evening and Editorial. They change customer-screen background and event-text treatment only. Thermal receipt output remains monochrome and unchanged. The default preserves the Pocket Pixels appearance.

Event Operations includes a static customer preview, and Event Setup shows welcome and thank-you previews while editing. Preview rendering does not start a customer session, create a gallery, create an archive, alter event counters or send a print.

## Idle and reset behavior

Format selection, camera-ready waiting, review, receipt preview and thank-you are eligible for idle handling. Standard customer states wait five minutes; thank-you waits two minutes. The app then presents a 30-second “Still there?” warning with a large Continue Session action.

Idle reset is blocked during camera preparation, countdown, capture, between-photo transitions, retakes, receipt composition, printer connection, printing, recovery-required and error states. It is also blocked whenever a print batch is active, the printer is working, the printer recovery lock is set or an unresolved print exists. Backgrounding cancels the idle timer. A completed idle reset uses the existing session reset path, which invalidates callbacks, clears customer photos and gallery identity, and resets copies to one while preserving archives, pending uploads and operator recovery records.

## Customer and operator errors

Customer screens use short categories such as “Camera needs attention,” “Printer needs attention,” and “We couldn't prepare your photos,” followed by a request for operator help. Raw Swift errors, BLE identifiers, network details, paths and tokens are not shown. Event Operations retains technical diagnostics and recovery context for staff.

## Accessibility and kiosk behavior

The customer flow retains large touch targets, semantic button labels, high-contrast QR presentation, safe-area padding, constrained iPad layouts and Reduce Motion alternatives. Customer navigation remains full-screen and hides navigation chrome. Staff access remains a protected long press on the welcome brand mark; DEBUG shortcuts and developer tools remain compilation-gated.

For deployment, enable iPad Guided Access manually, disable unwanted system interruptions, lock the intended orientation, connect power, verify storage and run Event Preflight before guests arrive. Guided Access cannot be enabled by the app.

## Gallery and thank-you behavior

The thank-you screen displays the committed session QR and optional event thank-you message. It only claims the gallery is ready after upload success. Offline, unknown and queued delivery states explain that the same QR will remain valid while upload work continues. Pending data is retained across customer reset.

## Compatibility

New EventProfile fields decode with disabled screen branding, empty screen text and the Classic theme when loading older saved profiles. Existing receipt fields and rendering behavior are unchanged.

## Validation still requiring hardware

The following remain deferred: real iPad camera framing and exposure, screen brightness and physical touch ergonomics, front-camera timing, VOZY G80 Bluetooth behavior, paper feed and cutter timing, receipt physical quality, multi-copy physical timing, disconnect behavior before and after bytes, multi-hour thermal endurance, scanning the printed QR and a full event-duration run.
