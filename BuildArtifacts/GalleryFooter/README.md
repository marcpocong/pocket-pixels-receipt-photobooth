# Gallery footer implementation and validation

Audited local branch `main` at `8ade190` on October 17, 2026. Initial working tree already contained edits to `ReceiptDesignSystem.swift` and `EventTypography.swift`, plus an untracked `.claude/` directory. The existing footer model edits were reused; `.claude/` was left alone. Bundle ID, signing configuration, dependencies, backend services, and production records were not changed.

## Implementation

`ReceiptComposer` remains the rendering authority. Its existing photo/card arrangements, artwork loading, typography, sticker clipping, thermal rasterization, and print transport remain in use. The integrated footer replaces the decorative barcode with a full-size gallery QR, caption, one divider, and a stacked monogram/timestamp. Classic mode retains the original barcode footer and separate QR section. Decorative mode prints the original footer without a gallery QR.

The secure gallery token and frozen session URL are unchanged. A pending upload can finish after printing without changing its QR. No backend deployment, customer gallery, payment, physical print, device install, or data reset was performed for this work.

## Operator controls

- **Session Setup → Receipt & Branding → Device Gallery Code Style** sets the regular-session default immediately for future sessions.
- **Session Setup → Receipt & Branding → Event Gallery Code Style** sets an optional event override, regardless of the event-logo switch. Save Design and Review & Start apply the event through the existing workflow.
- **Restore Default** on the device selects Integrated Gallery QR. The event action restores inheritance.
- **Branding & Design → Physical Printing → Gallery Code Style** exposes the same device preference.
- **Sample Print Studio → Gallery Code Style** previews or prints a display sample in any of the three modes. Samples retain `galleryURL = nil`, create no token/upload/payment, and show an outlined `SAMPLE / NO LIVE GALLERY` box instead of a scannable code.

The decorative-only option warns that its barcode provides no gallery access. The guest's on-screen gallery QR remains available in all modes.

## Defaults, migration, and session lifetime

| Source | Effective result |
|---|---|
| New install / missing device preference | Integrated Gallery QR |
| Legacy device QR ON | Integrated Gallery QR |
| Explicit legacy device QR OFF | Decorative Barcode Only |
| Explicit new style | Saved style |
| Event without an override | Device default |
| Event with override, logo OFF or ON | Event override |
| Unknown serialized style | Integrated Gallery QR |
| Frozen legacy `ReceiptPrintOptions` with boolean ON | Classic Barcode + Gallery QR, preserving historical geometry |
| Frozen legacy `ReceiptPrintOptions` with boolean OFF | Decorative Barcode Only |

The footer choice freezes when admission reaches format selection, before payment and capture. Sticker preparation, Photo Pass preview, final composition, gallery redaction, copies, and archive metadata use that value. New checkout checkpoints and app recovery snapshots retain it. Archived reprints continue sending their original stored raster; older archives decode without the new optional metadata.

Recovered paid checkouts reuse their matching recovery snapshot's original gallery token, URL, and session date. A current checkpoint whose original gallery recovery record is missing or invalid fails explicitly and retains the paid checkout for operator review. Legacy checkpoints without a frozen style use a matching snapshot choice when available, otherwise the historical classic style. Legacy recovery without a matching snapshot retains the previous app behavior; it cannot reconstruct an unavailable historical gallery URL.

## QR geometry

The old decorative barcode column is too narrow for a production-length secure URL at reliable module sizes, so integrated mode uses two columns.

- Canvas: 576 printer dots; 36-dot photo/footer side margins.
- Medium error correction; existing 64-character secure gallery tokens.
- Minimum four printer dots per module; four white quiet-zone modules on every side.
- Base QR allocation: 236 × 236 dots. The production-length fixture has a 49-module matrix: 196-dot matrix + 32-dot quiet zones = 228 dots, centered with four additional white dots per side.
- Integrated allocation expands to the next required four-dot module size, up to a 288-dot safety limit. The largest accepted test fixture is a 245-byte URL with a 61-module matrix in a 276-dot allocation. Classic's separate QR can expand within the 504-dot printable width.
- Oversized URLs throw an explicit layout error instead of shrinking modules or printing a truncated code. The generator also rejects allocations smaller than the matrix plus quiet zones.
- Core Image’s native one-module border is removed before measuring the symbol and adding the explicit four-module quiet zone.
- QR raster is drawn at 1:1 size, on integer coordinates, with interpolation disabled. Photographic processing is confined to photos. Sticker-protected rectangles cover the code, quiet zones, and caption.
- Printed QR metadata is false for samples and decorative-only receipts.

## Visual evidence

All receipt PNGs were generated by the production composer and rasterizer using synthetic test photos and a clearly synthetic event logo. They contain test URLs with synthetic tokens, not customer galleries. `_1bit.png` files represent the exact final raster preview sent through the existing print pipeline, including its safety sanitizer. Plain `.png` files are the corresponding composed receipts. `.raster.bin` files are the actual packed 1-bit printer data (MSB first, 72 bytes per 576-dot row); `raster-manifest.json` records their dimensions and selected style.

Each of the six supported formats has all three footer styles with event logo ON and OFF: 72 receipt PNGs and 36 packed rasters. Six comparison images cover Solo, Strip, and Passport / Photo Pass with logo ON and OFF. The comparison's “Before / Classic + QR” panel uses the retained historical rendering path with the same fixture. It is not a separately rendered screenshot from an older executable.

| Format | Logo OFF | Logo ON |
|---|---|---|
| Solo | [Comparison](comparison_solo_logo_false.png) | [Comparison](comparison_solo_logo_true.png) |
| Strip | [Comparison](comparison_strip_logo_false.png) | [Comparison](comparison_strip_logo_true.png) |
| Passport / Photo Pass | [Comparison](comparison_passport_logo_false.png) | [Comparison](comparison_passport_logo_true.png) |

Regenerate receipt images by running `ReceiptFooterModeTests.testAllModesFormatsAndFinalThermalQRWithVisualArtifacts` in Xcode. Then, from the repository root, run:

```sh
swift Tools/ReceiptFooter/MakeComparisons.swift
```

Artifact paths derive from the test source location; the comparison tool accepts an optional directory argument. Neither uses a developer-specific absolute path.

## Automated validation

Final results and exact changed paths are recorded in `validation.md` and `changed-files.txt` beside this file. The new tests cover settings migration, event overrides and inheritance without a logo, all modes/formats, legacy Passport, exact decoded URLs from final thermal output, zero/one printed QR counts, module sizing and white quiet zones, pixel preservation in printer bits, oversize rejection, the largest supported integrated allocation, non-live samples, admission freezing, checkpoint reload, and older archive decoding with unchanged reprint bytes.

Existing tests cover payment verification/recovery, printer journals and copies, gallery retries, Passport privacy, artwork, stickers, session isolation, and preview geometry. No automated decoding claim implies physical scan validation or successful online customer upload.

## Physical validation after explicit approval

1. Install the signed build on Carlo without uninstalling the current app or clearing its records; inspect retained pending payments, prints, and galleries first.
2. On the VOZY G80 at the production density/speed, print Integrated mode for Solo, Strip, and Photo Pass; inspect 36-dot side clearance, quiet zones, divider, caption, and feed/cut clearance. Smoke-test Duo, Grid, Grid Six, and legacy Passport if used.
3. Scan each paper QR with iPhone and Android cameras. Confirm its exact frozen URL and that it opens only that customer's gallery after upload completion.
4. Print before upload completes, restore connectivity, and verify the same paper URL works after the existing retry pipeline succeeds.
5. Check Classic mode has one functional QR below its decorative footer. Check Decorative mode has no printed gallery QR while the iPad QR still works.
6. With event logo OFF, apply each event override and inheritance; restart the app and verify persistence.
7. Change the device preference during an admitted guest session. Confirm the active session retains its admitted mode and the next guest receives the new default.
8. Print multiple copies and an archived reprint; verify identical footer/QR and no extra entitlement use. Exercise supported operator recovery without duplicating a payment or a print.
9. Print a display sample in each mode; verify the placeholder cannot scan and no gallery or transaction was created.

Physical print quality, paper scan distance, real upload completion, and signed installation remain hardware checks requiring the user's approval. No physical validation has been claimed.

## Install readiness and remaining limits

The signed development build is ready for an approved install on Carlo, with its existing signing configuration preserved. Signature verification passed, and the embedded profile includes Carlo. That development profile expires **October 19, 2026 at 4:10 PM Asia/Manila**. Carlo was disconnected when inventoried; no install was attempted. Renew the existing signing through the normal Xcode workflow for use after the expiry.

Automated scan checks prove that the exact frozen input URL survives the final printer raster. They do not establish real paper scan quality or live customer upload completion. Complete the physical checklist before production sign-off. Full-run console evidence is retained because Xcode failed to save that run's result bundle; the final focused test summary is intact.
