# Passport validation and device checks

Passport is a two-photo novelty keepsake format. The receipt prints two stacked landscape passport-style cards. The upper card holds the title area and Photo 2, the wide 4:3 hero photo. The lower card holds Photo 1, a 3:4 portrait, plus the keepsake details and the signature. The existing QR/gallery footer follows the cards. The design avoids official-document elements: no emblems, no seals, no machine-readable zone and no document numbers. It uses "POCKET PASSPORT", "KEEPSAKE · NO EXPIRY" and "MEMORY PASS" wording.

## Flow

Choose Passport → Photo 1 (Passport Portrait) → Photo 2 (Hero Photo) → Review (each photo retakeable on its own) → Details → Signature → Passport Preview → Receipt → Print → Thank You.

The new `BoothSessionState` cases are `passportDetails`, `passportSignature` and `passportPreview`. Passport reuses the existing camera sequence, generation guards, receipt composition task, gallery upload, archive and print path. Passport can only commit from its preview. `continueToReceipt()` called from review is redirected to Details.

## Receipt dimensions

The values below come from `ReceiptComposer` plans and composed receipts at 8 dots/mm. Raster width is **576 dots = 72 mm = 7.2 cm**, on 80 mm paper.

| Configuration | Raster, dots | Length, mm | Length, cm |
| --- | --- | --- | --- |
| Default (Classic, sample details, QR) | 576 × 902 | 112.75 | 11.275 |
| Default, no details entered, QR | 576 × 902 | 112.75 | 11.275 |
| Default, metadata footer without QR | 576 × 737 | 92.125 | 9.2125 |
| Maximum-length text in every field, birthplace and age, QR | 576 × 966 | 120.75 | 12.075 |
| Event Mode (event name title, label, subtitle, date/location, message), QR | 576 × 930 | 116.25 | 11.625 |
| Worst custom event: tall custom header at max scale/spacing, every event and Passport field at its limit (W characters), QR | 576 × 1008 | 126.0 | 12.6 |
| Worst event-text configuration (same limits, event-name title), QR | 576 × 1008 | 126.0 | 12.6 |

Every configuration stays far below the unchanged 3,500-dot safeguard. Raster length excludes extra paper from the printer's feed/cut commands, so measure real cut receipts before ordering sleeves.

## Text limits

| Field | Limit |
| --- | --- |
| Name | 32 |
| Nationality | 24 |
| Profession | 32 |
| Birthplace (optional) | 24 |
| Passport title | 32 |
| Subtitle | 48 |
| Event label | 32 |

Whitespace is collapsed and control characters are removed. Emoji ZWJ sequences are preserved, and limits count visible characters. At maximum length with wide `W` characters, each value fits by shrinking or wrapping to two lines without truncation. The layout tests verify this for every theme.

## Privacy

- Passport details and the signature are stored only in the active session, in the committed recovery snapshot and in the local Recent Sessions archive (needed for reprints). In-progress drafts are never written to disk.
- When the session is committed, the age is frozen and the birth year is dropped.
- The gallery still receives both photos (`photo-01.jpg`, `photo-02.jpg`). Its `receipt-color.jpg` is a separately composed, redacted Passport receipt: photos and branding only, with blank fields and no signature. Tests verify that the upload request metadata contains none of the entered values.
- No backend change was needed: two photos are inside the existing 1–6 limit.

## Validation

- `xcodebuild -list` lists scheme `PocketPixelsBooth`.
- The app build and build-for-testing succeeded with no new warnings.
- The full `PocketPixelsBoothTests` suite passed on the iPad Pro 11-inch (M5) simulator, iOS 26.5: **103 tests passed, 0 failed** (80 existing and 23 new in `PassportFormatTests`). The 1,000-session contamination test passed unchanged.
- The run used `-parallel-testing-enabled NO`. Parallel simulator clones filled the disk during an earlier attempt.
- Customer screens (format selection, review, details, signature, preview) were rendered at 834 × 1194 and 1194 × 834 and visually inspected. Color and 1-bit thermal receipts for every theme and the dimension fixtures were inspected too. The QR code decodes from both.

### Pre-existing bug fixed

`CameraService.deinit` dispatched `stopSession()`, whose closure retained `self` after deallocation. The result was an intermittent `EXC_BAD_ACCESS` whenever a view model was released (it was seen in tests). `deinit` now captures only the capture session.

## Not validated

No physical iPad camera, Apple Pencil, keyboard or VOZY G80 validation was performed.

## Manual iPad / VOZY G80 checklist

- Choose Passport. Capture Photo 1 (portrait guide) and Photo 2 (landscape guide). Retake each photo and confirm the other photo is unchanged.
- Enter details. Skip the birthday, then enter a birthday with and without a year (age appears only with a year). Check that the keyboard never hides Continue, that Next/Previous/Done work and that Hide Keyboard works.
- Sign with a finger and with Apple Pencil. Use Undo and Clear, sign again, and continue without a signature.
- On the preview, go Back to Details, edit, return, use Redo Signature, then Continue.
- Inspect the full receipt. Scan the QR and confirm the gallery has both photos and a redacted receipt.
- Print one copy and multiple copies. Check face recognizability, the border and stamp lines, the label legibility and the cut length.
- In Event Mode, test each Passport Title Area option, the custom header graphic, Event Text Block on and off, and every theme. Check the Event Setup preview with Passport selected.
- Archive a session, change the active event and theme, then reprint the old Passport. Its name, signature, photos and theme must be unchanged.
- Start a new customer and confirm the previous details and signature are gone.
