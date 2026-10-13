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
for (const count of [1, 2, 3, 4, 6]) {
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
assert.match(html, /Your GIF/);
assert.match(html, /your moments, made to keep\./);
assert.match(html, /Relive, save, and share your photobooth memories\./);
assert.match(html, /id="motionTitle">Your GIF</);
assert.match(html, /id="motionToggle"[^>]*hidden>Play</, 'Reduced-motion still preview has an explicit Play control');
assert.match(html, /prefers-reduced-motion: reduce/);
assert.match(html, /Printed version/);
assert.match(html, /id="image-session\.gif"/);
assert.match(html, /data-open="session\.gif"/);
assert.match(html, /data-download="session\.gif">Save GIF/);
assert.match(html, /data-share="session\.gif">Share GIF/);
assert.match(html, /item\.role===\\?"gif\\?"/);
assert.match(html, /item\.filename.*item\.mimeType/);
assert.match(html, /showEmbeddedImages\(\)/);
assert.match(html, /Color Receipt/);
assert.match(html, /Thermal Receipt/);
assert.equal(context.makeCompleteManifest_(context.makeSelfTestPayload_(2)).gif, 'session.gif');

const legacyFixture = galleryFixture(2, 1);
const legacyHTML = context.renderGalleryPage_(legacyFixture, {}, Date.now()).getContent();
assert.doesNotMatch(legacyHTML, /id="motionTitle"|class="gif-section|id="motionToggle"/);
assert.match(legacyHTML, /Color Receipt/);

const soloFixture = galleryFixture(1, 2, false);
const soloHTML = context.renderGalleryPage_(soloFixture, {}, Date.now()).getContent();
assert.doesNotMatch(soloHTML, /id="motionTitle"|class="gif-section|id="motionToggle"|data-download="session\.gif"|data-share="session\.gif"/);
assert.match(soloHTML, /Save Photo/);

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
  assert.doesNotMatch(page, /@pocketpixels\.ceb|instagram\.com/i);
  assert.doesNotMatch(page, /data:image\/png;base64,/, 'No embedded bitmap logo (legacy PP monogram) in the gallery');
}
for (const page of [html, legacyHTML]) {
  assert.match(page, /data-pocket-pixels-gallery-status="complete"/);
  assert.match(page, /Photo Gallery/);
  assert.match(page, /Receipt Copy/);
  assert.match(page, /Save All Photos/);
  assert.match(page, /data-download="photo-01\.jpg">Save Photo/);
  assert.match(page, /data-share="photo-01\.jpg">Share/);
  assert.match(page, /class="footer-tagline">little moments, made to keep\.</);
  assert.match(page, /title:\\?"Made to Keep Studios\\?"/);
  assert.match(page, /alt="Made to Keep Studios photo 1"/);
}
assert.match(html, /alt="Animated Made to Keep Studios session GIF"/);
assert.match(html, /Thermal Receipt/);
assert.match(pendingHTML, /your photos are still being prepared\./);
assert.match(invalidHTML, /This gallery link cannot be opened\./);
for (const page of [html, legacyHTML, soloHTML, pendingHTML, invalidHTML, tooLargeHTML]) {
  // Self-contained: no third-party fonts, scripts, images or Google Drive links.
  assert.doesNotMatch(page, /(src|href)=["']?https?:/i, 'Gallery pages load nothing from other origins');
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
for (const count of [1, 2, 3, 4, 6]) {
  const countHTML = context.renderGalleryPage_(galleryFixture(count), {}, Date.now()).getContent();
  assert.match(countHTML, new RegExp('photo-grid photo-count-' + count + '"'));
  for (let i = 1; i <= count; i++) {
    const name = 'photo-0' + i + '\\.jpg';
    assert.match(countHTML, new RegExp('data-open="' + name + '"'));
    assert.match(countHTML, new RegExp('data-download="' + name + '">Save Photo'));
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
