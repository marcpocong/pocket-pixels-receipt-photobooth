# Customer & operator UI release with native emoji — October 20, 2026

Branch `feat/customer-operator-ui-emoji-release`, starting from `main` at `02f95455e262738ee14050e65824fbdf4c26514a`.

This is a client-side presentation release. Camera capture and countdown, `ReceiptComposer`, thermal rasterization, ESC/POS, the VOZY G80 transport and spooler, print recovery, payments, checkout recovery, the event state machine, gallery tokens, URLs, schemas 1–4, archive integrity and reprint fingerprints are unchanged. No Apps Script or Worker change is needed, and nothing was deployed.

## 1. Customer receipt preview

- The guest now sees **one** receipt preview. The Keepsake / Black & White switch and its state are gone. `ReceiptPreviewMode` is replaced by `GuestReceiptPreview`.
- That preview is the existing smooth `MonochromeReceiptRenderer` output, which is rendered in the same background task as the print raster (nothing new runs on the main thread). If that optional render fails, the same composed receipt is shown through a display-only grayscale filter. Before composition the guest sees a "Preparing your black & white preview…" card, never a color stand-in.
- The layout follows the reference: lockup, *Your receipt is ready* in italic serif, the supporting line, the receipt on white paper with a scalloped tear, the copies control, one filled burgundy **PRINT RECEIPT** action and the thermal note: "Printed in black and white on thermal paper. Final print texture may vary."
- In landscape, the receipt sits on the left at nearly full height and the heading and actions sit on the right, so Strip and Grid Six stay large.
- Copy rules are unchanged. Pay-per-print shows the purchased count, read-only. The stepper follows `canIncreasePrintCopies` / `canDecreasePrintCopies`. The print button keeps the same view-model path and disabled rule.
- While printing, the paper-feed animation uses the monochrome image.
- The color receipt and every other digital variant are still uploaded to, and shown in, the QR gallery.

## 2. Camera screen

The camera engine is unchanged. Presentation changes only:

- Logo on the left; *PHOTO 1 OF N* centered with session step marks below it; **Cancel** on the right, in an equal-width column so the counter stays centered.
- Rounded ivory mount with a softer shadow, a larger *Ready when you are.* line, and one filled **START PHOTOS** action with a camera icon.
- `CameraScreenLayout.actionHeight` grows from 54 to 72. `CapturePresentationTests` still prove a 300-pt minimum aperture, no overflow and no aperture jumps for every format in portrait and landscape.
- Shared accents (`MadeToKeepScrapbookAccents`) appear on both screens: a torn paper scrap, a looping line, a sketched heart, sparkle strokes and a sepia print corner. They are vector, drawn behind content, not hit-testable and hidden from VoiceOver.

## 3. Recent Sessions

- **Collection.** Ivory cards are grouped by day and laid out as an adaptive grid. Each card shows fanned photo thumbnails, the time and date, the event name, a format pill, a concise print status (`ArchivedPrintSummary`), the gallery status and the reprint count. Search, day grouping, pull-to-refresh, loading and corrupt-archive states are kept. New filter chips: **format** and **Needs attention**. Thumbnails are downsampled once during refresh, off the main thread, so scrolling never decodes images. Session IDs are no longer printed on every card.
- **Detail.** Sections are Session, Original Receipt (zoomable), Customer Gallery, Photos, Operator Reprint (separate card, same confirmation and safety gates) and Technical Details (collapsed; session ID copyable; archive token redacted). Wide screens use two columns.
- **Original gallery QR.** `ArchivedGalleryLink` accepts `archive.galleryURL` only if it is an HTTPS `<front door>?g=<this archive's token>` link. Both the legacy Pocket Pixels and the Made to Keep front doors pass. The QR is drawn by `GalleryQRCodeGenerator` with its white quiet zone. Nothing is minted, uploaded, migrated or rewritten. An invalid or foreign URL shows no QR and an explicit "Gallery link unavailable" state. Actions: Open Gallery, Copy Gallery Link, Share Link, and Manage Gallery Upload.
- **Truthful status** (`ArchivedGalleryStatus`):
  - *Gallery ready* only when `EventRunStore` recorded a public verification.
  - *Waiting for upload* while the item is queued as not started or posted.
  - *Needs attention* when delivery is unknown.
  - *Delivery not verified* otherwise.

  Every state except *Gallery ready* says the photos may not be ready yet.
- **Logging.** Reprint debug logs previously printed the archive ID, which is the gallery token. They now print it redacted. A test scans the file to keep it that way.

## 4. Operator zoomable receipt viewer

`OperatorZoomableReceiptView` wraps a `UIScrollView` (`ReceiptZoomScrollView`):

- Default is Fit: the largest scale at which the whole receipt is visible. Top and bottom are visible together, the aspect is preserved, nothing is cropped, and there is no minimum width.
- Native pinch zoom, pan while zoomed, and double-tap (2× at the tap point, or back to Fit).
- Presets: **Fit / 150% / 200% / 300% / Reset**. Percentages are relative to Fit; the maximum is 4× Fit.
- At Fit the viewer's pan is disabled, so surrounding scroll views and navigation keep their gestures.
- Exact rasters use nearest-neighbour magnification; digital receipts use linear magnification.
- Zoom only changes a view transform. Tests prove the source image, archive bytes and reprint fingerprint are unchanged.

Used in: Recent Sessions detail and its full-screen sheet, Sample Print Studio, the event receipt design preview (`EventReceiptComposerPreview`), the Sticker Studio preview results, the new emoji print test, and the debug raster preview.

## 5. Native Unicode emoji stickers

- **Data.** `EmojiData/UnicodeEmojiCatalog.json` was generated by `Tools/EmojiCatalog/make_emoji_catalog.py` from Unicode **emoji-test.txt 18.0**, keeping fully-qualified entries only. It holds 2,203 base emoji in 9 groups plus 1,760 skin-tone forms folded under their base, like the keyboard's long-press. The data is licensed under the Unicode License V3, included as `docs/third-party/UNICODE-LICENSE.txt`. There is no runtime dependency.
- **Coverage is honest.** iOS has no public API that lists the keyboard's emoji, so this is a standards-based list, not a claim to match Apple's keyboard exactly. Entries newer than Emoji 15.0 are kept only when this iPad's system font draws them as a single glyph. **Choose from Keyboard** accepts any emoji the guest picks from the ordinary system keyboard, including the emoji keyboard, without forcing a keyboard switch.
- **Validation** (`EmojiGlyphValidator`):
  - Accepted: exactly one extended grapheme cluster, built only from emoji scalars, joiners, selectors, keycap marks, tags or a regional-indicator pair. This covers skin tones, flags, ZWJ families, tag flags, keycaps and hearts with selectors.
  - Rejected: text, empty input, multiple characters, bare skin-tone modifiers, lone regional indicators, digits or `#` without a keycap, and pastes over 128 UTF-16 units or 16 scalars.
  - Text-default pictographs gain U+FE0F so they render in emoji style.
  - The glyph must render as one Apple Color Emoji glyph, which rejects sequences this iPad cannot draw.
- **Rendering** (`EmojiStickerRenderer`, run off the main actor):
  - Core Text draws the glyph large. Its real ink bounds are measured and cropped with a 7% transparent margin, so no edge is clipped, and the result is bounded to 768 px.
  - The editor shows that color glyph.
  - Print artwork applies a tone curve (yellow ≈ 60% gray, highlights stay white) and a solid dark outline, so light emoji, even a white heart, print as a clear silhouette. It then goes through the existing `StickerPrintPreparation`.
  - Both images share pixel size, so `StickerGeometry`, the clip regions and the QR quiet zone are identical to other stickers.
  - A render failure refuses the emoji with a clear message; a very light result gets a warning.
- **Editing.** Emoji insert through the existing `StickerStudioSession`. Drag, pinch, rotate, select, delete, undo/redo, the sticker limit, per-session isolation, freeze and close are all unchanged. The color editor artwork is part of the undo snapshot, but it is never frozen or printed. Recent emoji are kept per guest session; before first use the lead tab shows a Popular set.
- **Defaults and migration.** `StickerStudioSettings` schema 1 → 2 adds `emojiCollectionEnabled`, default **on**. The original Made to Keep artwork is retired from the default palette: schema-1 installs migrate it to **off**. It stays installed as an optional legacy source, and the operator's choice persists after that. Operator imports are untouched. The master switch still defaults off. When both emoji and artwork are on, guests switch with an Emoji / Stickers control.
- **Operator.** Operator › Sticker Studio has separate toggles for Emoji (primary), Original Made to Keep Artwork (legacy) and Imported Operator Stickers, plus a catalog summary. **Emoji Print Preview Test** places 😀 👍🏽 🇵🇭 👨‍👩‍👧‍👦 ❤️ 🏳️‍🌈 on synthetic photos and shows the keepsake and the exact printer raster in the zoom viewer. It creates no payment, gallery, upload, archive or print.

## Known limitations

- Gallery color receipts show emoji in grayscale. Stickers are drawn by `ReceiptComposer` from the frozen print artwork, as before. Showing color in the gallery would require composer changes that are out of scope.
- The emoji list is Unicode's RGI set, not Apple's keyboard order or Apple-only symbols. Search uses CLDR short names plus a small synonym list, not the full CLDR keyword annotations.
- Very long receipts on the guest screen still scroll when the fitted width would be under 250 pt (the existing `ReceiptPreviewLayout` rule). Landscape now gives them nearly the full height.
- Simulator verification only. A physical VOZY G80 print of emoji stickers, and the camera screen with a live feed, still need checking on Carlo.
