# Smooth black & white customer receipts — October 18, 2026

Customers no longer see the printer's 1-bit dithered raster. The iPad receipt screen and the QR gallery show a smooth grayscale **Black & White** receipt instead. The physical print still uses the original thermal raster, unchanged.

## How it works

| Surface | Before | Now |
| --- | --- | --- |
| iPad receipt picker | Keepsake · **As printed** (exact 1-bit raster) | Keepsake · **Black & White** (smooth grayscale) · In Motion where already supported |
| iPad note | "Prints in black and white on thermal paper." | "Printed in black and white on thermal paper. Final print texture may vary." |
| QR gallery card | "Thermal Receipt — just like it came out of the booth" | "Black & White Receipt — A digital preview of your printed keepsake." |
| New gallery `receipt-bw.png` | 1-bit printer raster (RGBA PNG) | Smooth 8-bit grayscale PNG (IHDR color type 0) |
| Historical gallery | Raster displayed and saved | Raster is no longer sent to the page. The browser derives grayscale from the stored color receipt; Save/Share produce that monochrome PNG |
| Operator diagnostics | Various "Thermal"/"As printed" labels | "Exact Printer Raster — Diagnostic" (and similar). They still show the exact raster |

`MonochromeReceiptRenderer` (Core Graphics + ImageIO, no dependencies) converts an already composed receipt pixel by pixel:

- integer Rec. 709 luma `(54·R + 183·G + 19·B + 128) >> 8` on sRGB values;
- a restrained contrast of 1.05 around mid-gray (white stays 255, black stays 0);
- orientation baked in and transparency flattened onto white;
- no resizing, cropping, blur or texture.

Output is deterministic. `Code.gs` uses the identical math for historical galleries, so old and new galleries look the same.

- **iPad:** `BoothSessionViewModel.monochromeReceiptPreview` is rendered from the composed receipt in the same background task as the raster. A failure leaves it `nil`, the Black & White choice stays disabled, and printing is unaffected. `thermalReceiptPreview` and `receiptRasterizedImage` are unchanged and are used only for printing, archives and operator diagnostics.
- **Gallery upload:** `GalleryUploadPreparation.preparedMonochromeReceiptData` renders from the privacy-redacted gallery composition (`galleryReceiptImage`), resized to 576 px like the color copy. The manifest schema, field names (`thermalReceipt`) and filename (`receipt-bw.png`) are unchanged for compatibility; only the meaning of the bytes changed.
- **Gallery backend:** `isSmoothMonochromeReceiptPNG_` reads the PNG IHDR. Anything other than 8-bit grayscale is treated as a legacy raster. `customerMonochromeReceipt_` then embeds `{deriveFrom: "receipt-color.jpg"}` without the raster bytes. Pending queue items prepared before this release are handled the same way. No Drive file, manifest, token or URL is rewritten.

## Printing integrity

The diff does not touch `ThermalImageRasterizer`, ESC/POS generation, calibration/tone profiles, sanitization, the spooler, archive fingerprints, reprints, payments, events, QR tokens, GIFs, camera or stickers. The tests confirm the raster command and fingerprint are identical before and after rendering the customer preview for every format. `ReceiptPreviewAccuracyTests` still proves that the diagnostic raster preview matches the printer bits exactly.

## Verification

- `MonochromeReceiptPreviewTests` covers:
  - gradients (>200 levels, monotonic, not binary);
  - determinism and the luma math;
  - orientation and transparency;
  - legacy vs smooth PNG signatures;
  - every format × Event Mode (long text) × printed QR on/off: geometry, tone deviation ≤ 8, typography stays dark, QR decodable;
  - stickers and mixed photo orientations;
  - printer raster unchanged;
  - picker modes and copy;
  - upload payloads for every format within budget, plus a worst-case noisy Grid Six (≈346 KB B&W, 2.7 MB total, under the 5.5 MB budget);
  - Photo Pass: uploaded B&W equals the redacted gallery copy, differs from the private print, and has no signature ink.
- `GalleryBrowserLayoutTests` (WKWebView) adds a historical-raster gallery: derived image shown from a `blob:`, pure gray with >32 levels at 576×1112, raster not embedded, Save/Share yield a monochrome `receipt-bw.png`, the lightbox is labeled "black & white receipt". New galleries keep the stored grayscale bytes unchanged. The fixture loader now uses a unique ignored URL parameter per load and polls the new document. This fixes the iOS 27 simulator stall that failed PR #8's CI.
- `node Backend/GoogleAppsScript/GridSixValidation.test.cjs --fixtures` adds IHDR detection, raster omission, byte-exact new receipts and schema-v1 checks. Worker tests are unchanged (29/29).
- Chrome before/after evidence (synthetic assets only) is in [BuildArtifacts/MonochromeReceipt](../BuildArtifacts/MonochromeReceipt).

## Deployment

The Cloudflare `gallery` Worker needs no change and was not redeployed. Completed pages are cached for at most one hour under the existing namespace, so they refresh to the new HTML within that window.

Deployment results are recorded below.
