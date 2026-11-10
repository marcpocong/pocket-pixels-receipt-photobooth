# Photo Pass and legacy Passport validation

The stored `BoothFormat` raw value remains `.passport`. Visual compatibility is selected independently by `PassportDesignVersion`: new sessions freeze `.photoPassV2`, while an archive or recovery record with no `designVersion` decodes as `.legacyPassport`. That default is intentional: records created before design versioning existed must reproduce the receipt the customer originally received.

Both designs use the production `ReceiptComposer`, the Core Graphics renderers, a fixed **576-dot (72 mm at 8 dots/mm)** receipt width, the same complete-receipt thermal raster path, print spooler, recovery snapshot, Recent Sessions archive, and reprint path.

## Photo Pass V2

Photo Pass V2 is the current customer experience and deterministic receipt geometry. Photo 1 is the portrait; Photo 2 is the wide hero image. The customer enters a name, may add a note, and may draw a signature. Date, Event, and Location are not customer-entered: they are populated from the `EventProfile` snapshot frozen when the session starts.

Flow: Choose Photo Pass → portrait → hero → Review → Details → Signature → Photo Pass Preview → Receipt → Print → Thank You. The WYSIWYG preview is the image produced by `ReceiptComposer`; printing uses the same composed receipt through `ThermalImageRasterizer.rasterize(..., purpose: .completeReceipt)`.

The gallery uses a separately composed redacted receipt. It removes the name, note, signature, and all legacy personal fields before either digital receipt is made. `receipt-color.jpg` is encoded from that redacted composition. `receipt-bw.png` is the lossless 1-bit preview produced by thermal-rasterizing that same redacted composition—not by grayscaling the color JPEG. The session GIF contains only the two captured color photos, in portrait → hero order, and has no customer text metadata.

Current validation covers design-version decoding, deterministic geometry, portrait/hero placement, field limits, redaction, archive/reprint stability, receipt/raster regression, gallery queue persistence, and session isolation. On-device validation should still confirm crop appearance, QR readability, and VOZY G80 output.

## Legacy Passport

Legacy Passport is retained exclusively for existing archives and recovery data. It is the former two-card novelty keepsake: the upper card contains the title and Photo 2 hero; the lower card contains Photo 1 portrait, legacy details, and signature. It avoids official-document elements and uses novelty wording such as “POCKET PASSPORT,” “KEEPSAKE · NO EXPIRY,” and “MEMORY PASS.”

Legacy fields include name, nationality, profession, optional birthplace/birthday-derived age, title, subtitle, event label, and signature. Historic limits remain part of compatibility testing: Name 32, Nationality 24, Profession 32, Birthplace 24, title 32, subtitle 48, and event label 32 visible characters. Whitespace/control-character normalization and emoji sequence handling are preserved.

Useful legacy thermal fixtures include the default, no-details, maximum-text, event-mode, worst-event-text, worst-custom-header, and theme variants. Their historical heights ranged from 737 to 1,008 dots, safely below the unchanged 3,500-dot limit. These fixtures now live under `BuildArtifacts/LegacyPassport`; they must not be treated as Photo Pass V2 baselines.

Legacy gallery receipts remain privacy-redacted: no legacy personal field or signature is uploaded. Existing schema-v1 galleries (`photos`, `receipt-color.jpg`, `manifest.json`) and their original QR URLs remain readable. Old archives continue to invoke the legacy renderer and must not be silently upgraded to Photo Pass V2.

## Thermal and physical validation

- Confirm every composed receipt is exactly 576 dots wide and below the height safeguard.
- Validate raster command dimensions/data length and sanitizer output before transport.
- Scan QR codes from both the color receipt and actual 1-bit thermal output.
- On a real iPad, verify portrait/hero crops, Photos import orientation, keyboard, finger/Pencil signature, retakes, and state clearing between customers.
- On a VOZY G80, print one and multiple copies, verify face detail, text, feed/cut behavior, BLE/Wi-Fi recovery, and archived reprints after changing the active event.
- Verify the operator Sample Print has no fake preview QR and creates no gallery, archive, recovery snapshot, or customer counter change.

No document should claim physical iPad or VOZY G80 qualification until those checks have actually been performed.
