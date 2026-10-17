// Run with: node Backend/GoogleAppsScript/GridSixValidation.test.cjs
// Only pure validation runs locally; no Drive writes or network requests.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const scriptProperties = new Map();
const context = vm.createContext({
  Utilities: {
    base64Decode: value => Array.from(Buffer.from(value, 'base64')),
    base64Encode: value => Buffer.from(value).toString('base64'),
    formatDate: () => 'Oct 7, 2026 6:00 PM',
  },
  HtmlService: {
    XFrameOptionsMode: { ALLOWALL: 'ALLOWALL' },
    createHtmlOutput: html => ({
      getContent: () => html,
      setTitle() { return this; },
      setXFrameOptionsMode() { return this; },
    }),
  },
  PropertiesService: {
    getScriptProperties: () => ({
      getProperty: key => scriptProperties.get(key) ?? null,
      setProperty: (key, value) => scriptProperties.set(key, value),
      deleteProperty: key => scriptProperties.delete(key),
    }),
  },
});
vm.runInContext(fs.readFileSync(path.join(__dirname, 'Code.gs'), 'utf8'), context);
assert.equal(context.validateUploadToken_('').code, 'SERVER_NOT_CONFIGURED');
scriptProperties.set('POCKET_PIXELS_DEVICE_TOKEN', 'correct-device-token-value');
context.runPocketPixelsSelfTest();
context.runPhase6CBackendSelfChecks();
assert.equal(context.validateUploadToken_('').code, 'MISSING_DEVICE_TOKEN');
assert.equal(context.validateUploadToken_('wrong-device-token-value').code, 'INVALID_DEVICE_TOKEN');
assert.equal(context.validateUploadToken_('correct-device-token-value'), null);
for (const count of [1, 2, 3, 4, 5, 6]) {
  const payload = context.makeSelfTestPayload_(count);
  assert.equal(context.validateUploadPayload_(payload).ok, true);
  assert.equal(payload._validatedImages.length, count + 3);
  assert.deepEqual(Array.from(payload._expectedPhotoFilenames), Array.from({ length: count }, (_, i) => `photo-${String(i + 1).padStart(2, '0')}.jpg`));
  assert.equal(context.expectedFilenames_(count, 2).length, count + 3);
}
const degraded = context.makeSelfTestPayload_(2);
delete degraded.gif;
assert.equal(context.validateUploadPayload_(degraded).ok, true);
assert.equal(degraded._validatedImages.length, 4);
assert.equal(context.expectedFilenames_(2, 2, false).length, 4);
assert.equal(context.makeCompleteManifest_(degraded).gif, undefined);
const legacy = context.makeSelfTestPayload_(2);
legacy.schemaVersion = 1;
legacy.receipt = legacy.colorReceipt;
delete legacy.colorReceipt;
delete legacy.thermalReceipt;
delete legacy.gif;
assert.equal(context.validateUploadPayload_(legacy).ok, true);
assert.equal(context.expectedFilenames_(2, 1).length, 3);
assert.equal(Object.hasOwn(context.makeSelfTestPayload_(2), 'receipt'), false);
for (const count of [0, 7, 36]) {
  const payload = context.makeSelfTestPayload_(count);
  if (count === 0) payload.photos = [];
  assert.equal(context.validateUploadPayload_(payload).code, 'INVALID_PHOTO_COUNT');
}
const missingSixth = context.makeSelfTestPayload_(6);
missingSixth.photos[5].filename = 'photo-04.jpg';
assert.equal(context.validateUploadPayload_(missingSixth).code, 'INVALID_PHOTO_FILENAME');
console.log('Grid 6 backend validation passed: existing counts, six filenames, upper bound, sixth image validation.');

const fixture = galleryFixture(2);
const loaded = context.loadGalleryAssets_(fixture.filesByName, fixture.manifest);
assert.equal(loaded.gif.filename, 'session.gif');
assert.equal(loaded.gif.mimeType, 'image/gif');
assert.equal(loaded.gif.role, 'gif');
const html = context.renderGalleryPage_(fixture, {}, Date.now()).getContent();
assert.doesNotMatch(html, /Your GIF|Save GIF|Share GIF|motionTitle|motionToggle|image-session\.gif|data-open="session\.gif"/);
assert.match(html, /your moments,<br><em>made to keep\./);
assert.match(html, /View, save and share the photographs from your session\./);
assert.match(html, /Save your favourites before closing this page\./);
assert.match(html, /prefers-reduced-motion:reduce/);
assert.doesNotMatch(html, /<details/);
assert.match(html, /item\.filename.*item\.mimeType/);
assert.match(html, /showEmbeddedImages\(\)/);
assert.match(html, /Color Receipt/);
assert.match(html, /Black &amp; White Receipt/);
assert.match(html, /A digital preview of your printed keepsake\./);
assert.doesNotMatch(html, /Thermal Receipt|just like it came out|exact print|as printed/i);
assert.doesNotMatch(html, /good people|same energy|big memories|class="handwritten"/i);
assert.equal(context.makeCompleteManifest_(context.makeSelfTestPayload_(2)).gif, 'session.gif');

const legacyFixture = galleryFixture(2, 1);
const legacyHTML = context.renderGalleryPage_(legacyFixture, {}, Date.now()).getContent();
assert.doesNotMatch(legacyHTML, /id="motionTitle"|class="gif-section|id="motionToggle"/);
assert.match(legacyHTML, /Color Receipt/);

const soloFixture = galleryFixture(1, 2, false);
const soloHTML = context.renderGalleryPage_(soloFixture, {}, Date.now()).getContent();
assert.doesNotMatch(soloHTML, /id="motionTitle"|class="gif-section|id="motionToggle"|data-download="session\.gif"|data-share="session\.gif"/);
assert.match(soloHTML, /data-download="photo-01\.jpg"/);

// Made to Keep Studios visible rebrand (Phase 1). The legacy completed-gallery marker stays
// because the Cloudflare Worker uses it for cache decisions.
const pendingHTML = context.renderPendingGalleryPage_().getContent();
const invalidHTML = context.renderInvalidGalleryPage_().getContent();
const tooLargeHTML = context.renderGalleryTooLargePage_().getContent();
for (const page of [html, legacyHTML, pendingHTML, invalidHTML, tooLargeHTML]) {
  assert.match(page, /<title>Made to Keep Studios Gallery<\/title>/);
  assert.match(page, /aria-label="Made to Keep Studios"/);
  assert.match(page, /class="brand-wordmark">made to keep</);
  assert.match(page, /class="brand-secondary">studios</);
  assert.doesNotMatch(page, /Pocket Pixels/i);
  assert.doesNotMatch(page, /@pocketpixels\.ceb|instagram\.com\/pocketpixels/i);
  assert.doesNotMatch(page, /data:image\/png;base64,/, 'No embedded bitmap logo (legacy PP monogram) in the gallery');
}
for (const page of [html, legacyHTML]) {
  assert.match(page, /data-pocket-pixels-gallery-status="complete"/);
  assert.match(page, /Photo Gallery/);
  assert.match(page, /Receipt Copy/);
  assert.match(page, /Download all photos/);
  assert.match(page, /data-download="photo-01\.jpg">/);
  assert.match(page, /data-share="photo-01\.jpg">/);
  assert.match(page, /class="footer-tagline">little moments, made to keep\.</);
  assert.match(page, /title:\\?"Made to Keep Studios\\?"/);
  assert.match(page, /alt="Made to Keep Studios photo 1"/);
}
assert.doesNotMatch(html, /Animated Made to Keep Studios session GIF/);
assert.match(html, /Black &amp; White Receipt/);

// Black & white receipt: new galleries embed the booth's smooth 8-bit grayscale PNG as stored;
// historical galleries (1-bit printer raster in receipt-bw.png) never send the raster to the page
// and derive a grayscale copy from the color receipt in the browser instead.
function pngHeader(colorType, bitDepth = 8) {
  const bytes = Buffer.alloc(64, 0x11);
  Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52]).copy(bytes);
  bytes.writeUInt32BE(576, 16); bytes.writeUInt32BE(1400, 20); bytes[24] = bitDepth; bytes[25] = colorType;
  return bytes.toString('base64');
}
assert.equal(context.isSmoothMonochromeReceiptPNG_(pngHeader(0)), true);
for (const legacyType of [2, 6, 4, 3]) assert.equal(context.isSmoothMonochromeReceiptPNG_(pngHeader(legacyType)), false);
assert.equal(context.isSmoothMonochromeReceiptPNG_(pngHeader(0, 1)), false, '1-bit grayscale is a raster');
assert.equal(context.isSmoothMonochromeReceiptPNG_('iVBORw0KGgo='), false);
assert.equal(context.isSmoothMonochromeReceiptPNG_(''), false);
assert.equal(context.isSmoothMonochromeReceiptPNG_(Buffer.alloc(64, 0xff).toString('base64')), false);
function embeddedGalleryData(page) {
  const start = page.indexOf('const galleryData=') + 'const galleryData='.length;
  const end = page.indexOf(';\nconst startedAt=', start);
  return JSON.parse(page.slice(start, end));
}
const historicalRaster = galleryFixture(2);
const rasterBase64 = pngHeader(6);
historicalRaster.filesByName['receipt-bw.png'].getBlob = () => ({ getBytes: () => Array.from(Buffer.from(rasterBase64, 'base64')) });
const historicalHTML = context.renderGalleryPage_(historicalRaster, {}, Date.now()).getContent();
const historicalData = embeddedGalleryData(historicalHTML);
assert.equal(historicalData.thermalReceipt.deriveFrom, 'receipt-color.jpg');
assert.equal(historicalData.thermalReceipt.filename, 'receipt-bw.png');
assert.equal(historicalData.thermalReceipt.mimeType, 'image/png');
assert.equal(historicalData.thermalReceipt.base64Data, undefined);
assert.equal(historicalHTML.includes(rasterBase64), false, 'Legacy printer raster bytes never reach the customer page');
assert.ok(historicalData.receipt.base64Data.length > 0);
assert.match(historicalHTML, /Black &amp; White Receipt/);
assert.match(historicalHTML, /data-download="receipt-bw\.png"/);
const smoothGallery = galleryFixture(2);
const smoothBase64 = pngHeader(0);
smoothGallery.filesByName['receipt-bw.png'].getBlob = () => ({ getBytes: () => Array.from(Buffer.from(smoothBase64, 'base64')) });
const smoothData = embeddedGalleryData(context.renderGalleryPage_(smoothGallery, {}, Date.now()).getContent());
assert.equal(smoothData.thermalReceipt.base64Data, smoothBase64, 'New smooth receipts are embedded byte-for-byte');
assert.equal(smoothData.thermalReceipt.deriveFrom, undefined);
assert.equal(context.customerMonochromeReceipt_(null, smoothData.receipt), null);
assert.equal(embeddedGalleryData(legacyHTML).thermalReceipt, null, 'Schema-v1 galleries keep their single color receipt');
console.log('Black & white receipt: smooth/new, historical raster derivation and schema-v1 checks passed.');
assert.match(pendingHTML, /your photos are still being prepared\./);
assert.match(invalidHTML, /This gallery link cannot be opened\./);
for (const page of [html, legacyHTML, soloHTML, pendingHTML, invalidHTML, tooLargeHTML]) {
  // Self-contained: no third-party fonts, scripts, images or Google Drive links.
  const navigationLinks = [...page.matchAll(/<a\b[^>]*href="(https?:[^\"]+)"[^>]*>/g)];
  for (const [tag, destination] of navigationLinks) {
    assert.equal(destination, 'https://www.instagram.com/madetokeep.studios/');
    assert.match(tag, /target="_blank"/);
    assert.match(tag, /rel="noopener noreferrer"/);
    assert.match(tag, /referrerpolicy="no-referrer"/);
  }
  assert.equal(navigationLinks.length, page.includes('data-pocket-pixels-gallery-status="complete"') ? 2 : 0, 'Only the menu and promotional card link to Instagram');
  assert.doesNotMatch(page.replace(/<a\b[^>]*>/g, ''), /(?:src|href)=["']?https?:/i, 'No external scripts, images, fonts or arbitrary links');
  assert.doesNotMatch(page, /@import|url\(["']?https?:|<(?:script|link|iframe)[^>]*(?:src|href)="https?:/i);
  assert.doesNotMatch(page, /[?&](?:g|token)=[a-f0-9]{64}/i, 'Private token is never embedded into outbound links');
  assert.doesNotMatch(page, /drive\.google\.com|googleusercontent|fonts\.googleapis/i);
  assert.match(page, /<meta name="referrer" content="no-referrer">/);
}
// Pending checks back off and stop (the counter survives reloads); invalid links never poll.
assert.match(pendingHTML, /var delays=\[6,10,15,20,30,45\]/);
assert.match(pendingHTML, /sessionStorage/);
assert.match(pendingHTML, /data-gallery-state="pending"/);
assert.doesNotMatch(invalidHTML, /setTimeout|location\.reload/);
assert.match(invalidHTML, /data-gallery-state="invalid"/);
assert.match(tooLargeHTML, /data-gallery-state="unavailable"/);
// Manifest values are escaped before they reach the page.
const hostile = galleryFixture(2);
hostile.manifest.sessionID = 'PP-<img src=x onerror=alert(1)>';
const hostileHTML = context.renderGalleryPage_(hostile, {}, Date.now()).getContent();
assert.doesNotMatch(hostileHTML, /<img src=x onerror/);
assert.doesNotMatch(hostileHTML.split('<script>')[1], /<\/?img src=x/);
// Every photo count renders every photo individually with its own actions.
for (const count of [1, 2, 3, 4, 5, 6]) {
  const countHTML = context.renderGalleryPage_(galleryFixture(count), {}, Date.now()).getContent();
  assert.match(countHTML, new RegExp('photo-grid photo-count-' + count + '"'));
  for (let i = 1; i <= count; i++) {
    const name = 'photo-0' + i + '\\.jpg';
    assert.match(countHTML, new RegExp('data-open="' + name + '"'));
    assert.match(countHTML, new RegExp('data-download="' + name + '">'));
  }
}
console.log('Made to Keep Studios gallery branding checks passed (v1, v2, pending, invalid, too large).');

// Made to Keep gallery front-door migration (Phase 2). New upload responses use the preferred
// Made to Keep property, the legacy Pocket Pixels property stays a valid fallback, and gallery
// rendering/lookup never depends on which public front door is configured.
const legacyGalleryBase = 'https://pocket-pixels-gallery.pocketpixels-ceb.workers.dev/';
const madeToKeepTestBase = 'https://gallery.madetokeep.test/';
const frontDoorToken = 'c'.repeat(64);
const savedCustomerProperties = {
  preferred: scriptProperties.get('MADE_TO_KEEP_CUSTOMER_GALLERY_BASE_URL'),
  legacy: scriptProperties.get('POCKET_PIXELS_CUSTOMER_GALLERY_BASE_URL'),
};
function setCustomerProperties(preferred, legacy) {
  for (const [key, value] of [['MADE_TO_KEEP_CUSTOMER_GALLERY_BASE_URL', preferred], ['POCKET_PIXELS_CUSTOMER_GALLERY_BASE_URL', legacy]]) {
    if (value === undefined) scriptProperties.delete(key); else scriptProperties.set(key, value);
  }
}
function renderFixtureHTML() {
  return context.renderGalleryPage_(galleryFixture(2), {}, 0).getContent();
}

setCustomerProperties(undefined, legacyGalleryBase);
assert.equal(context.makeGalleryURL_(frontDoorToken), `${legacyGalleryBase}?g=${frontDoorToken}`, 'Legacy-only property must keep generating legacy URLs.');
assert.equal(context.checkCustomerGalleryConfig().usesLegacyProperty, true);
assert.equal(context.checkCustomerGalleryConfig().usesWorkersDev, true);
const legacyConfiguredHTML = renderFixtureHTML();

setCustomerProperties(madeToKeepTestBase, legacyGalleryBase);
assert.equal(context.makeGalleryURL_(frontDoorToken), `${madeToKeepTestBase}?g=${frontDoorToken}`, 'Made to Keep property must be preferred for new upload responses.');
const configCheck = context.checkCustomerGalleryConfig();
assert.equal(configCheck.propertyName, 'MADE_TO_KEEP_CUSTOMER_GALLERY_BASE_URL');
assert.equal(configCheck.usesLegacyProperty, false);
assert.equal(configCheck.valid, true);
assert.equal(renderFixtureHTML(), legacyConfiguredHTML, 'Gallery rendering must not depend on the configured front door.');

setCustomerProperties(madeToKeepTestBase, undefined);
assert.equal(context.makeGalleryURL_(frontDoorToken), `${madeToKeepTestBase}?g=${frontDoorToken}`, 'Made to Keep property alone must be sufficient.');

setCustomerProperties('  ', legacyGalleryBase);
assert.equal(context.makeGalleryURL_(frontDoorToken), `${legacyGalleryBase}?g=${frontDoorToken}`, 'Blank Made to Keep property falls back to legacy.');

setCustomerProperties('https://script.google.com/macros/s/ABC/exec', legacyGalleryBase);
assert.throws(() => context.makeGalleryURL_(frontDoorToken), error => error.publicCode === 'INVALID_CUSTOMER_GALLERY_BASE_URL', 'Invalid preferred property must fail, not silently fall back.');

setCustomerProperties('http://gallery.madetokeep.test/', undefined);
assert.throws(() => context.makeGalleryURL_(frontDoorToken), error => error.publicCode === 'INVALID_CUSTOMER_GALLERY_BASE_URL', 'Preferred property must be HTTPS.');

setCustomerProperties(undefined, undefined);
assert.throws(() => context.makeGalleryURL_(frontDoorToken), error => error.publicCode === 'INVALID_CUSTOMER_GALLERY_BASE_URL', 'Missing both properties gives a clear configuration error.');
assert.equal(context.checkCustomerGalleryConfig().propertyPresent, false);

setCustomerProperties(savedCustomerProperties.preferred, savedCustomerProperties.legacy);
console.log('Made to Keep customer gallery property precedence and host-independent rendering checks passed.');

const realistic = realisticBudgetPayload();
assert.equal(context.validateUploadPayload_(realistic).ok, true);
const realisticImages = realistic.photos.concat([realistic.colorReceipt, realistic.thermalReceipt, realistic.gif]);
const realisticAssets = realisticImages.map(item => ({ filename: item.filename, base64Data: item.base64Data }));
assert.equal(context.validateGalleryRenderSize_({
  photos: realisticAssets.slice(0, 6),
  receipt: realisticAssets[6],
  thermalReceipt: realisticAssets[7],
  gif: realisticAssets[8],
}).ok, true);
const overBoundary = structuredClone(realistic);
overBoundary.gif = encodedImage('session.gif', 'image/gif', 2_400_000);
assert.equal(context.validateUploadPayload_(overBoundary).code, 'GALLERY_TOO_LARGE');
console.log('Schema-v2 QR gallery GIF HTML and render-budget checks passed.');

function galleryFixture(photoCount, schemaVersion = 2, includeGIF = schemaVersion === 2) {
  const payload = context.makeSelfTestPayload_(photoCount);
  payload.schemaVersion = schemaVersion;
  if (schemaVersion === 1) {
    payload.receipt = payload.colorReceipt;
    delete payload.colorReceipt;
    delete payload.thermalReceipt;
    delete payload.gif;
  } else if (!includeGIF) {
    delete payload.gif;
  }
  assert.equal(context.validateUploadPayload_(payload).ok, true);
  const manifest = context.makeCompleteManifest_(payload);
  const items = payload.photos.concat(schemaVersion === 2
    ? [payload.colorReceipt, payload.thermalReceipt, payload.gif].filter(Boolean)
    : [payload.receipt]);
  const filesByName = Object.fromEntries(items.map(item => [item.filename, {
    getBlob: () => ({ getBytes: () => Array.from(Buffer.from(item.base64Data, 'base64')) }),
  }]));
  return { manifest, filesByName };
}

function realisticBudgetPayload() {
  const payload = context.makeSelfTestPayload_(6);
  payload.photos = Array.from({ length: 6 }, (_, index) =>
    encodedImage(`photo-${String(index + 1).padStart(2, '0')}.jpg`, 'image/jpeg', 500_000));
  payload.colorReceipt = encodedImage('receipt-color.jpg', 'image/jpeg', 350_000);
  payload.thermalReceipt = encodedImage('receipt-bw.png', 'image/png', 650_000);
  payload.gif = encodedImage('session.gif', 'image/gif', 1_200_000);
  return payload;
}

function encodedImage(filename, mimeType, byteCount) {
  const signatures = {
    'image/jpeg': Buffer.from([0xff, 0xd8, 0xff]),
    'image/png': Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    'image/gif': Buffer.from('GIF89a'),
  };
  const bytes = Buffer.alloc(byteCount, 0x5a);
  signatures[mimeType].copy(bytes);
  return { filename, mimeType, base64Data: bytes.toString('base64') };
}

// Emit synthetic, self-contained pages for WKWebView layout/interaction regression tests.
if (process.argv.includes('--fixtures')) {
  const output = path.resolve(__dirname, '../../DerivedData/gallery-fixtures');
  fs.mkdirSync(output, { recursive: true });
  // Real PNG fixtures with the expected portrait/receipt proportions; no customer assets.
  // kind: 'color' (RGB gradient), 'gray' (smooth 8-bit grayscale, as new booths upload) or
  // 'raster' (RGB pure black/white dither, like historical receipt-bw.png printer rasters).
  function syntheticPNG(width, height, kind = 'color') {
    const zlib = require('node:zlib');
    function chunk(type, data) {
      const bytes = Buffer.concat([Buffer.from(type), data]);
      let crc = 0xffffffff;
      for (const value of bytes) {
        crc ^= value;
        for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
      }
      const length = Buffer.alloc(4); length.writeUInt32BE(data.length);
      const checksum = Buffer.alloc(4); checksum.writeUInt32BE((crc ^ 0xffffffff) >>> 0);
      return Buffer.concat([length, bytes, checksum]);
    }
    const channels = kind === 'gray' ? 1 : 3;
    const header = Buffer.alloc(13); header.writeUInt32BE(width); header.writeUInt32BE(height, 4); header[8] = 8; header[9] = kind === 'gray' ? 0 : 2;
    const pixels = Buffer.alloc(height * (width * channels + 1));
    for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) {
      const at = y * (width * channels + 1) + 1 + x * channels;
      if (kind === 'gray') { pixels[at] = 40 + Math.round(180 * x / width); continue; }
      if (kind === 'raster') { pixels[at] = pixels[at + 1] = pixels[at + 2] = (x + y) % 2 ? 255 : 0; continue; }
      pixels[at] = 160 + Math.round(60 * y / height); pixels[at + 1] = 135 + Math.round(60 * x / width); pixels[at + 2] = 125;
    }
    return Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]), chunk('IHDR', header), chunk('IDAT', zlib.deflateSync(pixels)), chunk('IEND', Buffer.alloc(0))]);
  }
  for (const count of [1, 2, 3, 4, 5, 6]) {
    const fixture = galleryFixture(count);
    for (const [name, file] of Object.entries(fixture.filesByName)) {
      const bytes = syntheticPNG(name.startsWith('receipt') ? 300 : 600, name.startsWith('receipt') ? 800 : 450, name === 'receipt-bw.png' ? 'gray' : 'color');
      file.getBlob = () => ({getBytes: () => Array.from(bytes)});
    }
    fs.writeFileSync(path.join(output, `gallery-${count}.html`), context.renderGalleryPage_(fixture, {}, Date.now()).getContent());
  }
  const orientationFixture = galleryFixture(2);
  for (const [name, file] of Object.entries(orientationFixture.filesByName)) {
    const receipt = name.startsWith('receipt');
    const landscape = name === 'photo-02.jpg';
    const bytes = syntheticPNG(receipt ? 576 : landscape ? 1408 : 1056, receipt ? 1112 : landscape ? 1056 : 1408, name === 'receipt-bw.png' ? 'gray' : 'color');
    file.getBlob = () => ({getBytes: () => Array.from(bytes)});
  }
  fs.writeFileSync(path.join(output, 'gallery-orientations.html'), context.renderGalleryPage_(orientationFixture, {}, Date.now()).getContent());
  // Historical gallery: receipt-bw.png is a 1-bit printer raster; the page derives grayscale.
  const historicalFixture = galleryFixture(2);
  for (const [name, file] of Object.entries(historicalFixture.filesByName)) {
    const receipt = name.startsWith('receipt');
    const bytes = syntheticPNG(receipt ? 576 : 1056, receipt ? 1112 : 1408, name === 'receipt-bw.png' ? 'raster' : 'color');
    file.getBlob = () => ({getBytes: () => Array.from(bytes)});
  }
  fs.writeFileSync(path.join(output, 'gallery-historical-raster.html'), context.renderGalleryPage_(historicalFixture, {}, Date.now()).getContent());
  fs.writeFileSync(path.join(output, 'legacy.html'), legacyHTML);
  fs.writeFileSync(path.join(output, 'pending.html'), pendingHTML);
  fs.writeFileSync(path.join(output, 'invalid.html'), invalidHTML);
}

// New financial/customer ownership identifiers remain accepted by the same gallery deployment.
const uniqueSession = context.makeSelfTestPayload_(1);
uniqueSession.sessionID = 'PP-20261017-233000-12345678-1234-4abc-8def-123456789abc';
assert.equal(context.validateUploadPayload_(uniqueSession).ok, true);
for (const suffix of ['-partial', '-12345678-1234-4abc-8def-123456789abc/other', '-https://example.test']) {
  const bad = context.makeSelfTestPayload_(1);
  bad.sessionID += suffix;
  assert.equal(context.validateUploadPayload_(bad).ok, false);
}

const uuidGallery = galleryFixture(2);
uuidGallery.manifest.sessionID = 'PP-20261018-131234-12345678-1234-4abc-8def-123456789abc';
const uuidHTML = context.renderGalleryPage_(uuidGallery, {}, Date.now()).getContent();
assert.match(uuidHTML, /Ref 261018-131234/);
assert.doesNotMatch(uuidHTML, /12345678-1234-4abc-8def-123456789abc/);
assert.equal((soloHTML.match(/data-collage=/g) || []).length, 1);
assert.equal((html.match(/data-collage=/g) || []).length, 2);
assert.doesNotMatch(legacyHTML, /class="receipt-card"[^>]*[\s\S]*Black &amp; White Receipt/);
console.log('Editorial collage, legacy receipt and concise UUID session reference checks passed.');
