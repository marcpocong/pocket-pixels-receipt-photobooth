const SCHEMA_VERSION = 2;

const ROOT_FOLDER_ID_PROPERTY = 'POCKET_PIXELS_ROOT_FOLDER_ID';

const DEVICE_TOKEN_PROPERTY = 'POCKET_PIXELS_DEVICE_TOKEN';

// Preferred Made to Keep Studios customer gallery front door. When unset or blank, the legacy
// Pocket Pixels property is used so existing deployments keep working without a migration.
// Gallery lookup is by token only, so either front door opens the same gallery.
const CUSTOMER_GALLERY_BASE_URL_PROPERTY = 'MADE_TO_KEEP_CUSTOMER_GALLERY_BASE_URL';

const LEGACY_CUSTOMER_GALLERY_BASE_URL_PROPERTY = 'POCKET_PIXELS_CUSTOMER_GALLERY_BASE_URL';

const GALLERY_FOLDER_INDEX_PREFIX = 'POCKET_PIXELS_GALLERY_FOLDER_';

const MIN_PHOTO_COUNT = 1;

const MAX_PHOTO_COUNT = 6;

const MAX_IMAGE_DECODED_BYTES = 6 * 1024 * 1024;

const GALLERY_TOKEN_PATTERN = /^[a-f0-9]{64}$/;

// Legacy receipts stay valid; new customer ownership adds a UUID for safe checkout handoff.
const SAFE_SESSION_ID_PATTERN = /^PP-[0-9]{8}-[0-9]{6}(?:-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?$/;

const RFC3339_UTC_SECONDS_PATTERN = /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/;

const RECEIPT_FILENAME = 'receipt-color.jpg';
const THERMAL_RECEIPT_FILENAME = 'receipt-bw.png';
const SHARE_RECEIPT_FILENAME = 'receipt-share-color.jpg';
const GIF_FILENAME = 'session.gif';

const MANIFEST_FILENAME = 'manifest.json';

const MAX_REQUEST_BYTES = 9 * 1024 * 1024;

const MAX_GALLERY_DECODED_BYTES = 6 * 1024 * 1024;

const MAX_GALLERY_BASE64_CHARS = 9 * 1024 * 1024;

const BACKEND_VERSION = 'made-to-keep-gallery-v11-progressive-20261111';

// Customer-visible Made to Keep Studios identity. Script Property names, the completed-gallery
// marker and self-test entry points keep their legacy Pocket Pixels identifiers for compatibility.
const MADE_TO_KEEP_BRAND = Object.freeze({
  fullName: 'Made to Keep Studios',
  wordmark: 'made to keep',
  secondary: 'studios',
  descriptor: 'Receipt Photobooth',
  tagline: 'little moments, made to keep.',
  galleryTitle: 'Made to Keep Studios Gallery'
});

function doPost(e) {
  const requestStartedAt = Date.now();
  const serverTiming = {};
  let stage = 'START';
  let lock = null;
  let lockHeld = false;

  try {
    stage = 'PARSE_JSON';
    const body = parseJSONBody_(e);

    if (body && body.transport === 'drive-resumable-v1') return resumableGalleryPost_(body);

    stage = 'LOG_REQUEST';
    logSanitizedRequest_(body, e.postData.contents.length);

    stage = 'AUTHENTICATE';
    const authError = validateUploadToken_(body.deviceToken);
    if (authError) {
      return jsonResponse(401, {
        ok: false,
        schemaVersion: SCHEMA_VERSION,
        errorCode: authError.code,
        error: authError.message,
        status: 'rejected'
      });
    }

    stage = 'VALIDATE_PAYLOAD';
    const validationStartedAt = Date.now();
    const validation = validateUploadPayload_(body);
    serverTiming.validationMs = Date.now() - validationStartedAt;
    if (!validation.ok) {
      console.log('Upload validation failed: ' + validation.code + ' field=' + validation.field);
      return jsonResponse(400, {
        ok: false,
        schemaVersion: SCHEMA_VERSION,
        errorCode: validation.code,
        error: validation.message,
        field: validation.field,
        status: 'rejected'
      });
    }

    // Read-only lookup does not need the global mutation lock.
    stage = 'GET_ROOT_FOLDER';
    const root = measureGalleryOperation_(serverTiming, 'rootFolderLookupMs', function() { return getRootFolder_(); });

    // Serialize only the Drive/idempotency mutation section.
    stage = 'ACQUIRE_GALLERY_LOCK';
    const lockStartedAt = Date.now();
    lock = LockService.getScriptLock();
    if (!lock.tryLock(20000)) {
      serverTiming.lockWaitMs = Date.now() - lockStartedAt;
      return jsonResponse(429, {
        ok: false,
        schemaVersion: SCHEMA_VERSION,
        errorCode: 'UPLOAD_SERVICE_BUSY',
        error: 'Upload service is busy. Try again later.',
        status: 'retryable',
        stage: stage
      });
    }
    lockHeld = true;
    serverTiming.lockWaitMs = Date.now() - lockStartedAt;

    stage = 'CREATE_OR_RETURN_GALLERY';
    const result = measureGalleryOperation_(serverTiming, 'driveWriteMs', function() { return createOrReturnGallery_(root, body, serverTiming); });

    // Release before URL construction/response work so a configuration
    // error cannot unnecessarily block the next upload.
    lock.releaseLock();
    lockHeld = false;

    stage = 'MAKE_SUCCESS_RESPONSE';
    serverTiming.totalMs = Date.now() - requestStartedAt;
    return jsonResponse(200, {
      ok: true,
      schemaVersion: body.schemaVersion,
      galleryToken: body.galleryToken,
      galleryURL: makeGalleryURL_(body.galleryToken),
      fileCount: result.fileCount,
      serverTiming: serverTiming,
      status: result.status
    });
  } catch (error) {
    const safeError = classifyUnexpectedError_(error, stage);
    logUnexpectedError_(error, safeError, stage);
    return jsonResponse(safeError.statusCode, {
      ok: false,
      schemaVersion: SCHEMA_VERSION,
      errorCode: safeError.code,
      error: safeError.message,
      status: safeError.status,
      stage: safeError.stage,
      detail: safeError.detail
    });
  } finally {
    serverTiming.totalMs = Date.now() - requestStartedAt;
    console.log('Gallery upload performance: ' + JSON.stringify(serverTiming));
    if (lockHeld && lock) {
      try {
        lock.releaseLock();
      } catch (releaseError) {
        console.error('Gallery upload lock release failed.');
      }
    }
  }
}

function doGet(e) {
  if (e && e.parameter && e.parameter.galleryStatus === '1') return galleryStatusResponse_(e);

  if (e && e.parameter && (e.parameter.diagnostic === 'phase6c' || e.parameter.diagnostic === 'phase6b')) {

    return jsonResponse(200, {

      ok: true,

      schemaVersion: SCHEMA_VERSION,

      backendVersion: BACKEND_VERSION,

      uploadTransports: typeof resumableUploadsEnabled_ === 'function' && resumableUploadsEnabled_()
        ? ['base64-json', 'drive-resumable-v1'] : ['base64-json'],

      galleryTokenPattern: 'lowercase-hex-64',

      canonicalURLPolicy: true,

      accountScopedPathAllowed: false,

      rawProxyRoute: true,

      status: 'diagnostic'

    });

  }

  // Cloudflare must receive the raw gallery document, not Google's
  // HtmlService iframe wrapper. ContentService serves this as plain text;
  // the Worker changes only the outward MIME type to text/html.
  if (e && e.parameter && e.parameter.proxy === 'raw') {

    return renderRawGalleryResponse_(e);

  }

  const startedAt = Date.now();

  const timings = {};

  const token = String((e && e.parameter && e.parameter.g) || '');

  if (!GALLERY_TOKEN_PATTERN.test(token)) {

    return renderInvalidGalleryPage_();

  }

  const gallery = findCompleteGalleryByToken_(token, timings);

  if (!gallery) {

    return renderPendingGalleryPage_();

  }

  return renderGalleryPage_(gallery, timings, startedAt);

}

function renderRawGalleryResponse_(e) {

  const startedAt = Date.now();

  const timings = {};

  const token = String((e && e.parameter && e.parameter.g) || '');

  let htmlOutput;

  if (!GALLERY_TOKEN_PATTERN.test(token)) {

    htmlOutput = renderInvalidGalleryPage_();

  } else {

    const gallery = findCompleteGalleryByToken_(token, timings);

    if (!gallery) {

      htmlOutput = renderPendingGalleryPage_();

    } else {

      htmlOutput = renderGalleryPage_(gallery, timings, startedAt, true);

    }

  }

  const rawHTML = htmlOutput.getContent();

  console.log('Gallery raw response: htmlCharacters=' + rawHTML.length + ' elapsedMs=' + (Date.now() - startedAt));

  return ContentService
    .createTextOutput(rawHTML)
    .setMimeType(ContentService.MimeType.TEXT);

}

function runPocketPixelsSelfTest() {

  assert_(validateUploadToken_('').code === 'MISSING_DEVICE_TOKEN', 'Missing token should fail.');

  assert_(validateUploadToken_('wrong').code === 'INVALID_DEVICE_TOKEN', 'Incorrect token should have a specific auth error.');

  assert_(!GALLERY_TOKEN_PATTERN.test('../bad'), 'Invalid token format should fail.');

  assert_(!GALLERY_TOKEN_PATTERN.test('A'.repeat(64)), 'Uppercase token should fail.');

  assert_(GALLERY_TOKEN_PATTERN.test('a'.repeat(64)), 'Lowercase 64-character hex token should pass.');

  const validPayload = makeSelfTestPayload_();

  const missingToken = JSON.parse(JSON.stringify(validPayload));

  delete missingToken.galleryToken;

  assert_(!validateUploadPayload_(missingToken).ok, 'Older non-idempotent requests should fail.');

  const wrongCount = JSON.parse(JSON.stringify(validPayload));

  wrongCount.photos = [];

  assert_(!validateUploadPayload_(wrongCount).ok, 'Wrong photo count should fail.');

  const invalidMime = JSON.parse(JSON.stringify(validPayload));

  invalidMime.photos[0].mimeType = 'image/png';

  assert_(!validateUploadPayload_(invalidMime).ok, 'Invalid MIME type should fail.');

  const oversized = JSON.parse(JSON.stringify(validPayload));

  oversized.photos[0].base64Data = 'A'.repeat(Math.ceil((MAX_IMAGE_DECODED_BYTES + 4) / 3) * 4);

  assert_(!validateUploadPayload_(oversized).ok, 'Oversized decoded image should fail.');

  const badFilename = JSON.parse(JSON.stringify(validPayload));

  badFilename.photos[0].filename = '../photo.jpg';

  assert_(!validateUploadPayload_(badFilename).ok, 'Unexpected filename should fail.');

  const badJpeg = JSON.parse(JSON.stringify(validPayload));

  badJpeg.photos[0].base64Data = Utilities.base64Encode([0x89, 0x50, 0x4e, 0x47]);

  assert_(!validateUploadPayload_(badJpeg).ok, 'Invalid JPEG signature should fail.');

  assert_(validateUploadPayload_(validPayload).ok, 'Valid payload should pass validation.');

  const withoutGIF = JSON.parse(JSON.stringify(validPayload));
  delete withoutGIF.gif;
  assert_(validateUploadPayload_(withoutGIF).ok, 'Schema-v2 payload should remain valid when optional GIF creation fails.');
  const withoutGIFManifest = makeCompleteManifest_(withoutGIF);
  assert_(withoutGIFManifest.gif === undefined, 'Degraded schema-v2 manifest must omit the GIF.');
  assert_(manifestHasExpectedFiles_(withoutGIFManifest, withoutGIF.photos.length), 'Schema-v2 manifest without GIF should remain renderable.');

  for (let count = MIN_PHOTO_COUNT; count <= MAX_PHOTO_COUNT; count++) {

    assert_(validateUploadPayload_(makeSelfTestPayload_(count)).ok, count + '-photo payload should pass validation.');

  }

  const manifest = makeCompleteManifest_(validPayload);

  assert_(Object.keys(manifest).join(',') === 'schemaVersion,galleryToken,sessionID,createdAt,photos,colorReceipt,thermalReceipt,gif,status', 'Manifest keys changed.');

  assert_(Object.keys(manifest).indexOf('deviceToken') === -1, 'Manifest must not include device token.');

  assert_(Object.keys(manifest).indexOf('rootFolderID') === -1, 'Manifest must not include root folder ID.');

  assert_(Object.keys(manifest).indexOf('printerIP') === -1, 'Manifest must not include printer IP.');

  console.log('Pocket Pixels Apps Script self-test passed.');

}

function runPhase6CBackendSelfChecks() {

  const validPayload = makeSelfTestPayload_();

  assertValidationCode_(validPayload, null);

  const malformedJSONError = captureError_(function() {

    parseJSONBody_({ postData: { contents: '{not-json' } });

  });

  assert_(malformedJSONError.publicCode === 'MALFORMED_JSON', 'Malformed JSON should report MALFORMED_JSON.');

  const missingField = JSON.parse(JSON.stringify(validPayload));

  delete missingField.galleryToken;

  assertValidationCode_(missingField, 'MISSING_FIELD');

  const wrongType = JSON.parse(JSON.stringify(validPayload));

  wrongType.schemaVersion = '1';

  assertValidationCode_(wrongType, 'INVALID_FIELD_TYPE');

  const wrongSchema = JSON.parse(JSON.stringify(validPayload));

  wrongSchema.schemaVersion = 5;

  assertValidationCode_(wrongSchema, 'INVALID_SCHEMA_VERSION');

  const badToken = JSON.parse(JSON.stringify(validPayload));

  badToken.galleryToken = 'A'.repeat(64);

  assertValidationCode_(badToken, 'INVALID_GALLERY_TOKEN');

  const badSession = JSON.parse(JSON.stringify(validPayload));

  badSession.sessionID = 'PP-20260831';

  assertValidationCode_(badSession, 'INVALID_SESSION_ID');

  const mismatch = JSON.parse(JSON.stringify(validPayload));

  mismatch.sessionID = 'PP-20260831-014415';

  mismatch.createdAt = '2026-08-30T17:44:15Z';

  assertValidationCode_(mismatch, null);

  const badCreatedAt = JSON.parse(JSON.stringify(validPayload));

  badCreatedAt.createdAt = '2026-08-30T17:44:15.000Z';

  assertValidationCode_(badCreatedAt, 'INVALID_CREATED_AT');

  const badCount = JSON.parse(JSON.stringify(validPayload));

  badCount.photos = [];

  assertValidationCode_(badCount, 'INVALID_PHOTO_COUNT');

  const tooMany = makeSelfTestPayload_(7);

  assertValidationCode_(tooMany, 'INVALID_PHOTO_COUNT');

  const badFilename = JSON.parse(JSON.stringify(validPayload));

  badFilename.photos[0].filename = 'photo-99.jpg';

  assertValidationCode_(badFilename, 'INVALID_PHOTO_FILENAME');

  const gapFilename = makeSelfTestPayload_(3);

  gapFilename.photos[1].filename = 'photo-03.jpg';

  assertValidationCode_(gapFilename, 'INVALID_PHOTO_FILENAME');

  const badMime = JSON.parse(JSON.stringify(validPayload));

  badMime.photos[0].mimeType = 'image/png';

  assertValidationCode_(badMime, 'INVALID_PHOTO_MIME_TYPE');

  const badBase64 = JSON.parse(JSON.stringify(validPayload));

  badBase64.photos[0].base64Data = '*not-base64*';

  assertValidationCode_(badBase64, 'INVALID_PHOTO_BASE64');

  const oversized = JSON.parse(JSON.stringify(validPayload));

  oversized.photos[0].base64Data = 'A'.repeat(Math.ceil((MAX_IMAGE_DECODED_BYTES + 4) / 3) * 4);

  assertValidationCode_(oversized, 'IMAGE_TOO_LARGE');

  const badReceipt = JSON.parse(JSON.stringify(validPayload));

  badReceipt.colorReceipt.filename = 'receipt.png';

  assertValidationCode_(badReceipt, 'INVALID_PHOTO_FILENAME');

  const driveError = classifyUnexpectedError_(new Error('Exception: Unexpected error while getting the method or property getFolderById on object DriveApp.'));

  assert_(driveError.code === 'DRIVE_RUNTIME_ERROR', 'Drive runtime error should be classified.');

  runCanonicalGalleryURLSelfChecks_();

  runCustomerGalleryPropertyPrecedenceSelfChecks_();

  runFastGalleryRenderSelfChecks_();

  console.log('Pocket Pixels Phase 6C backend self-checks passed.');

}

function runCanonicalGalleryURLSelfChecks_() {

  const token = 'b'.repeat(64);

  const expected = 'https://pocket-pixels-gallery.pocketpixels-ceb.workers.dev/?g=' + token;

  assert_(makeGalleryURLFromCustomerBaseURL_('https://pocket-pixels-gallery.pocketpixels-ceb.workers.dev/', token) === expected, 'Generated customer gallery URL should use Worker front door.');

  assert_(makeGalleryURLFromCustomerBaseURL_('https://gallery.example.com/', token) === 'https://gallery.example.com/?g=' + token, 'Example customer gallery URL should preserve root slash.');

  assert_(makeGalleryURLFromCustomerBaseURL_(' https://gallery.example.com/path/ ', token) === 'https://gallery.example.com/path?g=' + token, 'Generated customer gallery URL should trim and canonicalize configured base URL.');

  assert_(makeGalleryURLFromCustomerBaseURL_('https://gallery.example.com/?old=1#frag', token) === 'https://gallery.example.com/?g=' + token, 'Generated customer gallery URL should replace query and fragment.');

  assert_(captureError_(function() { makeGalleryURLFromCustomerBaseURL_('https://script.google.com/macros/s/ABC/exec', token); }).publicCode === 'INVALID_CUSTOMER_GALLERY_BASE_URL', 'Customer gallery base URL must reject script.google.com.');

  assert_(captureError_(function() { makeGalleryURLFromCustomerBaseURL_('http://gallery.example.com/', token); }).publicCode === 'INVALID_CUSTOMER_GALLERY_BASE_URL', 'Customer gallery base URL must require HTTPS.');

  assert_(expected.indexOf('/macros/u/') === -1, 'Generated gallery URL must not contain account-scoped path.');

  assert_(expected.indexOf('authuser=') === -1, 'Generated gallery URL must not include Google account selectors.');

  assert_((expected.match(new RegExp(token, 'g')) || []).length === 1, 'Generated gallery URL should contain exactly one gallery token.');

  assert_(expected.indexOf('POCKET_PIXELS_DEVICE_TOKEN') === -1 && expected.indexOf('POCKET_PIXELS_ROOT_FOLDER_ID') === -1, 'Generated gallery URL must not contain credentials or Drive configuration.');

  const canonical = 'https://script.google.com/macros/s/ABC/exec';

  assert_(canonicalizeWebAppURL_(canonical) === canonical, 'Canonical URL should remain canonical.');

  assert_(canonicalizeWebAppURL_('https://script.google.com/macros/u/0/s/ABC/exec') === canonical, '/u/0/ URL should normalize.');

  assert_(canonicalizeWebAppURL_('https://script.google.com/macros/u/1/s/ABC/exec') === canonical, '/u/1/ URL should normalize.');

  assert_(canonicalizeWebAppURL_('https://script.google.com/macros/u/2/s/ABC/exec') === canonical, '/u/2/ URL should normalize.');

  assert_(canonicalizeWebAppURL_('https://script.google.com/macros/u/10/s/ABC/exec') === canonical, '/u/10/ URL should normalize.');

}

function runFastGalleryRenderSelfChecks_() {

  const script = galleryClientScript_();

  assert_(script.indexOf('realFileCache') !== -1, 'Gallery client should cache real File objects lazily.');

  assert_(script.indexOf('new File([new Uint8Array([1])],') !== -1, 'Share support check should use synthetic files.');

  assert_(script.indexOf('URL.createObjectURL(fileForItem(item))') !== -1, 'Gallery client should open full-size images via object URLs.');

  assert_(script.indexOf('window.open(dataURL') === -1, 'Open Full Size should not open embedded base64 data URLs directly.');

  assert_(script.indexOf('google.script.run') === -1, 'Gallery client should remain self-contained without per-image script calls.');

  assert_(script.indexOf('requestIdleCallback') !== -1, 'Gallery client should defer non-critical image initialization.');

  assert_(script.indexOf('new File([bytes],item.filename,{type:item.mimeType})') !== -1, 'Downloads and shares must preserve the original filename and MIME type.');

  // Canvas is used only to derive the historical black & white receipt from the color receipt.
  // Photos, GIFs and stored receipts are never re-encoded.
  const deriveStart = script.indexOf('function deriveMonochrome(');
  const deriveEnd = script.indexOf('\nfunction ', deriveStart + 1);
  const canvasAt = script.indexOf('createElement("canvas")');
  assert_(script.split('createElement("canvas")').length === 2 && canvasAt > deriveStart && canvasAt < deriveEnd,
    'Gallery client must not flatten photos or animated GIFs through canvas conversion.');
  assert_(script.indexOf('needsDerivation(item)){throw') !== -1, 'Derived receipts must never fall back to stored raster bytes.');

}

function getGalleryImage(token, filename) {

  if (!GALLERY_TOKEN_PATTERN.test(String(token || ''))) {

    throw new Error('Gallery not found.');

  }

  if (expectedFilenames_(MAX_PHOTO_COUNT, 3, true, true).indexOf(String(filename || '')) === -1) {

    throw new Error('Image not found.');

  }

  const gallery = findCompleteGalleryByToken_(token);

  if (!gallery) {

    throw new Error('Gallery not found.');

  }

  const file = gallery.filesByName && gallery.filesByName[filename];

  if (!file) {

    throw new Error('Image not found.');

  }

  return 'data:' + (filename.endsWith('.png') ? 'image/png' : filename.endsWith('.gif') ? 'image/gif' : 'image/jpeg') + ';base64,' + Utilities.base64Encode(file.getBlob().getBytes());

}

function parseJSONBody_(e) {

  if (!e || !e.postData || !e.postData.contents) {

    throw publicError_(400, 'Missing JSON body.', 'rejected', 'MISSING_FIELD');

  }

  if (e.postData.contents.length > MAX_REQUEST_BYTES) {

    throw publicError_(400, 'Request body is too large.', 'rejected', 'REQUEST_TOO_LARGE');

  }

  try {

    return JSON.parse(e.postData.contents);

  } catch (error) {

    throw publicError_(400, 'Request body is not valid JSON.', 'rejected', 'MALFORMED_JSON');

  }

}

function validateUploadToken_(suppliedToken) {

  const expectedToken = PropertiesService.getScriptProperties().getProperty(DEVICE_TOKEN_PROPERTY);

  if (!expectedToken) {

    return { code: 'SERVER_NOT_CONFIGURED', message: 'Upload service is not configured.' };

  }

  if (!suppliedToken) {

    return { code: 'MISSING_DEVICE_TOKEN', message: 'Upload is not authorized.' };

  }

  if (suppliedToken !== expectedToken) {

    return { code: 'INVALID_DEVICE_TOKEN', message: 'Upload is not authorized.' };

  }

  return null;

}

function validateUploadPayload_(body) {

  const requiredFields = ['schemaVersion', 'deviceToken', 'galleryToken', 'sessionID', 'createdAt', 'photos'];

  for (let i = 0; i < requiredFields.length; i++) {

    if (!body || !Object.prototype.hasOwnProperty.call(body, requiredFields[i])) {

      return validationError_('MISSING_FIELD', 'Missing required field.', requiredFields[i]);

    }

  }

  if (typeof body.schemaVersion !== 'number') {

    return validationError_('INVALID_FIELD_TYPE', 'schemaVersion must be a number.', 'schemaVersion');

  }

  if (body.schemaVersion !== 1 && body.schemaVersion !== 2 && body.schemaVersion !== 3 && body.schemaVersion !== 4) {

    return validationError_('INVALID_SCHEMA_VERSION', 'Unsupported schema version.', 'schemaVersion');

  }

  if (body.schemaVersion >= 3) {
    if (!validReceiptVariants_(body.receiptVariants)) return validationError_('INVALID_RECEIPT_VARIANTS', 'Invalid receipt styles.', 'receiptVariants');
    const hasAlternative = body.receiptVariants.originalFooterStyle !== 'decorativeBarcodeOnly';
    if (hasAlternative !== !!body.shareColorReceipt) return validationError_('INVALID_RECEIPT_VARIANTS', 'Receipt alternative does not match physical footer.', 'shareColorReceipt');
  } else if (body.receiptVariants !== undefined || body.shareColorReceipt !== undefined) {
    return validationError_('INVALID_RECEIPT_VARIANTS', 'Receipt styles require schema 3 or 4.', 'receiptVariants');
  }
  const versionFields = body.schemaVersion === 1 ? ['receipt'] : body.schemaVersion === 4 ? ['colorReceipt'] : ['colorReceipt', 'thermalReceipt'];
  if (body.schemaVersion === 4 && body.thermalReceipt !== undefined) return validationError_('INVALID_RECEIPT_VARIANTS', 'Schema 4 derives the black and white receipt.', 'thermalReceipt');
  for (let i = 0; i < versionFields.length; i++) {
    if (!Object.prototype.hasOwnProperty.call(body, versionFields[i])) {
      return validationError_('MISSING_FIELD', 'Missing required field.', versionFields[i]);
    }
  }

  if (typeof body.deviceToken !== 'string') {

    return validationError_('INVALID_FIELD_TYPE', 'deviceToken must be a string.', 'deviceToken');

  }

  if (typeof body.galleryToken !== 'string') {

    return validationError_('INVALID_FIELD_TYPE', 'galleryToken must be a string.', 'galleryToken');

  }

  if (typeof body.sessionID !== 'string') {

    return validationError_('INVALID_FIELD_TYPE', 'sessionID must be a string.', 'sessionID');

  }

  if (typeof body.createdAt !== 'string') {

    return validationError_('INVALID_FIELD_TYPE', 'createdAt must be a string.', 'createdAt');

  }

  if (!GALLERY_TOKEN_PATTERN.test(String(body.galleryToken || ''))) {

    return validationError_('INVALID_GALLERY_TOKEN', 'Invalid gallery token.', 'galleryToken');

  }

  if (!SAFE_SESSION_ID_PATTERN.test(String(body.sessionID || ''))) {

    return validationError_('INVALID_SESSION_ID', 'Invalid session ID.', 'sessionID');

  }

  if (!isValidCreatedAt_(body.createdAt)) {

    return validationError_('INVALID_CREATED_AT', 'Invalid creation date.', 'createdAt');

  }

  if (!Array.isArray(body.photos) || body.photos.length < MIN_PHOTO_COUNT || body.photos.length > MAX_PHOTO_COUNT) {

    return validationError_('INVALID_PHOTO_COUNT', 'Upload requires 1 to 6 photos.', 'photos');

  }

  const validatedImages = [];
  const photoFilenames = expectedPhotoFilenames_(body.photos.length);

  for (let i = 0; i < body.photos.length; i++) {

    const error = validateImage_(body.photos[i], photoFilenames[i], 'photos[' + i + ']');

    if (!error.ok) {

      return error;

    }

    validatedImages.push(error.image);

  }

  if (body.schemaVersion === 1) {
    const receiptError = validateImage_(body.receipt, RECEIPT_FILENAME, 'receipt');
    if (!receiptError.ok) return receiptError;
    validatedImages.push(receiptError.image);
  }

  if (body.schemaVersion >= 2) {
    const colorError = validateImage_(body.colorReceipt, RECEIPT_FILENAME, 'colorReceipt', 'image/jpeg');
    if (!colorError.ok) return colorError;
    validatedImages.push(colorError.image);
    if (body.schemaVersion !== 4) {
      const thermalError = validateImage_(body.thermalReceipt, THERMAL_RECEIPT_FILENAME, 'thermalReceipt', 'image/png');
      if (!thermalError.ok) return thermalError;
      validatedImages.push(thermalError.image);
    }
    if (body.gif !== undefined && body.gif !== null) {
      const gifError = validateImage_(body.gif, GIF_FILENAME, 'gif', 'image/gif');
      if (!gifError.ok) return gifError;
      validatedImages.push(gifError.image);
    }
  }

  if (body.schemaVersion >= 3 && body.shareColorReceipt) {
    const shareError = validateImage_(body.shareColorReceipt, SHARE_RECEIPT_FILENAME, 'shareColorReceipt', 'image/jpeg');
    if (!shareError.ok) return shareError;
    validatedImages.push(shareError.image);
  }
  const renderBudget = validateUploadGalleryBudget_(validatedImages, body);
  if (!renderBudget.ok) return renderBudget;

  Object.defineProperty(body, '_validatedImages', {

    value: validatedImages,

    enumerable: false,

    configurable: false,

    writable: false

  });

  Object.defineProperty(body, '_expectedPhotoFilenames', {

    value: photoFilenames,

    enumerable: false,

    configurable: false,

    writable: false

  });

  return { ok: true };

}

function validateUploadGalleryBudget_(validatedImages, body) {
  let decodedBytes = 0;
  let base64Chars = 0;
  for (let i = 0; i < validatedImages.length; i++) decodedBytes += validatedImages[i].bytes.length;
  const wireImages = body.photos.concat(body.schemaVersion >= 2
    ? [body.colorReceipt].concat(body.schemaVersion === 4 ? [] : [body.thermalReceipt]).concat(body.gif ? [body.gif] : []).concat(body.shareColorReceipt ? [body.shareColorReceipt] : [])
    : [body.receipt]);
  for (let i = 0; i < wireImages.length; i++) base64Chars += String(wireImages[i].base64Data || '').length;
  if (decodedBytes > MAX_GALLERY_DECODED_BYTES || base64Chars > MAX_GALLERY_BASE64_CHARS) {
    return validationError_('GALLERY_TOO_LARGE', 'Gallery assets exceed the customer render budget.', 'photos');
  }
  return { ok: true, decodedBytes: decodedBytes, base64Chars: base64Chars };
}

function validateImage_(image, expectedFilename, field, expectedMimeType) {

  expectedMimeType = expectedMimeType || 'image/jpeg';

  if (!image || typeof image !== 'object') {

    return validationError_(field === 'receipt' ? 'INVALID_RECEIPT' : 'INVALID_FIELD_TYPE', 'Image must be an object.', field);

  }

  if (typeof image.filename !== 'string' || typeof image.mimeType !== 'string' || typeof image.base64Data !== 'string') {

    return validationError_(field === 'receipt' ? 'INVALID_RECEIPT' : 'INVALID_FIELD_TYPE', 'Image fields must be strings.', field);

  }

  if (!image || image.filename !== expectedFilename) {

    return validationError_(field === 'receipt' ? 'INVALID_RECEIPT' : 'INVALID_PHOTO_FILENAME', 'Unexpected image filename.', field + '.filename');

  }

  if (image.mimeType !== expectedMimeType) {

    return validationError_(field === 'receipt' ? 'INVALID_RECEIPT' : 'INVALID_PHOTO_MIME_TYPE', 'Unsupported image MIME type.', field + '.mimeType');

  }

  if (!image.base64Data || typeof image.base64Data !== 'string') {

    return validationError_(field === 'receipt' ? 'INVALID_RECEIPT' : 'INVALID_PHOTO_BASE64', 'Missing image data.', field + '.base64Data');

  }

  if (!/^[A-Za-z0-9+/=]+$/.test(image.base64Data)) {

    return validationError_(field === 'receipt' ? 'INVALID_RECEIPT' : 'INVALID_PHOTO_BASE64', 'Image data is not valid base64.', field + '.base64Data');

  }

  let bytes;

  try {

    bytes = Utilities.base64Decode(image.base64Data);

  } catch (error) {

    return validationError_(field === 'receipt' ? 'INVALID_RECEIPT' : 'INVALID_PHOTO_BASE64', 'Image data is not valid base64.', field + '.base64Data');

  }

  if (bytes.length > MAX_IMAGE_DECODED_BYTES) {

    return validationError_('IMAGE_TOO_LARGE', 'Image is too large.', field + '.base64Data');

  }

  const signatureOK = expectedMimeType === 'image/jpeg' ? hasJpegSignature_(bytes) :
    expectedMimeType === 'image/png' ? hasPngSignature_(bytes) : hasGifSignature_(bytes);

  if (!signatureOK) {

    return validationError_(field === 'receipt' ? 'INVALID_RECEIPT' : 'INVALID_PHOTO_BASE64', 'Image data is not JPEG.', field + '.base64Data');

  }

  return {

    ok: true,

    image: {

      filename: image.filename,

      mimeType: image.mimeType,

      bytes: bytes

    }

  };

}

function createOrReturnGallery_(root, body, timings) {

  // An older client/rollback must not race reserved resumable IDs by creating
  // replacement files. A completed public gallery remains readable normally.
  if (typeof guardLegacyResumableMutation_ === 'function') guardLegacyResumableMutation_(body.galleryToken);

  const folderName = 'gallery-' + body.galleryToken;
  const expected = expectedFilenames_(body.photos.length, body.schemaVersion, !!body.gif, !!body.shareColorReceipt);
  const expectedFileCount = expected.length + 1;

  const folders = measureGalleryOperation_(timings, 'folderLookupMs', function() { return collectFoldersByName_(root, folderName); });

  if (folders.length > 1) {

    console.error('Multiple gallery folders require manual inspection.');

    throw publicError_(409, 'Multiple matching galleries require manual inspection.', 'manualInspectionRequired', 'MANUAL_INSPECTION_REQUIRED');

  }

  if (folders.length === 0) {

    const folder = measureGalleryOperation_(timings, 'folderCreateMs', function() { return createGalleryFolder_(root, folderName); });

    saveExpectedImages_(folder, body, {}, timings);

    const inspection = inspectGalleryFolder_(folder, expected, timings);

    if (!inspection.safe || !hasExactlyExpectedImages_(inspection, expected)) {

      throw publicError_(500, 'Gallery could not be completed. Manual inspection required.', 'manualInspectionRequired', 'MANUAL_INSPECTION_REQUIRED');

    }

    createManifestFile_(folder, body, timings);

    saveGalleryFolderIndex_(body.galleryToken, folder.getId());


    return { status: 'created', fileCount: expectedFileCount };

  }

  const folder = folders[0];

  const inspection = inspectGalleryFolder_(folder, expected, timings);

  if (!inspection.safe) {

    console.error('Conflicting gallery files require manual inspection.');

    throw publicError_(409, 'Conflicting gallery files require manual inspection.', 'manualInspectionRequired', 'MANUAL_INSPECTION_REQUIRED');

  }

  if (inspection.manifests.length > 1) {

    throw publicError_(409, 'Duplicate manifests require manual inspection.', 'manualInspectionRequired', 'MANUAL_INSPECTION_REQUIRED');

  }

  const existingManifest = inspection.manifests.length === 1 ? readManifest_(inspection.manifests[0], timings) : null;
  if (existingManifest) {

    const manifest = existingManifest;

    if (manifest.status === 'complete') {

      if (manifest.galleryToken === body.galleryToken && manifest.sessionID === body.sessionID && manifest.schemaVersion === body.schemaVersion && (body.schemaVersion < 3 || (manifest.receiptVariants && manifest.receiptVariants.originalFooterStyle === body.receiptVariants.originalFooterStyle && manifest.receiptVariants.defaultStyle === body.receiptVariants.defaultStyle)) && manifestHasExpectedFiles_(manifest, body.photos.length) && hasExactlyExpectedImages_(inspection, expected)) {


        saveGalleryFolderIndex_(body.galleryToken, folder.getId());

        return { status: 'existingComplete', fileCount: expectedFileCount };

      }

      throw publicError_(409, 'Gallery token belongs to a different or conflicting session.', 'conflict', 'CONFLICT');

    }

  }

  if (inspection.manifests.length === 1) {

    const manifest = existingManifest;

    if (manifest.galleryToken && manifest.galleryToken !== body.galleryToken) {

      throw publicError_(409, 'Gallery token belongs to a different session.', 'conflict', 'CONFLICT');

    }

    if (manifest.sessionID && manifest.sessionID !== body.sessionID) {

      throw publicError_(409, 'Gallery token belongs to a different session.', 'conflict', 'CONFLICT');

    }

  }

  saveExpectedImages_(folder, body, inspection.fileCounts, timings);

  const repairedInspection = inspectGalleryFolder_(folder, expected, timings);

  if (!repairedInspection.safe || !hasExactlyExpectedImages_(repairedInspection, expected) || repairedInspection.manifests.length > 1) {

    throw publicError_(409, 'Incomplete gallery requires manual inspection.', 'manualInspectionRequired', 'MANUAL_INSPECTION_REQUIRED');

  }

  if (repairedInspection.manifests.length === 0) {

    createManifestFile_(folder, body, timings);

  } else {

    const manifest = readManifest_(repairedInspection.manifests[0], timings);

    if (manifest.status !== 'complete') {

      throw publicError_(409, 'Incomplete manifest requires manual inspection.', 'manualInspectionRequired', 'MANUAL_INSPECTION_REQUIRED');

    }

  }


  saveGalleryFolderIndex_(body.galleryToken, folder.getId());

  return { status: 'completedIncomplete', fileCount: expectedFileCount };

}

function saveExpectedImages_(folder, body, existingCounts, timings) {

  const images = body.schemaVersion >= 2
    ? body.photos.concat([body.colorReceipt].concat(body.schemaVersion === 4 ? [] : [body.thermalReceipt])).concat(body.gif ? [body.gif] : []).concat(body.shareColorReceipt ? [body.shareColorReceipt] : [])
    : body.photos.concat([body.receipt]);

  const validatedImages = body._validatedImages || [];

  for (let i = 0; i < images.length; i++) {

    const image = images[i];

    const count = existingCounts[image.filename] || 0;

    if (count > 1) {

      throw publicError_(409, 'Duplicate gallery files require manual inspection.', 'manualInspectionRequired', 'MANUAL_INSPECTION_REQUIRED');

    }

    if (count === 0) {

      measureGalleryOperation_(timings, 'imageCreate' + i + 'Ms', function() { return createImageFile_(folder, validatedImages[i] || image); });

    }

  }

}

function createGalleryFolder_(root, folderName) {

  try {

    return root.createFolder(folderName);

  } catch (error) {

    throw driveRuntimeError_('CREATE_FOLDER', error);

  }

}

function createImageFile_(folder, image) {

  try {

    const bytes = image.bytes || Utilities.base64Decode(image.base64Data);

    folder.createFile(Utilities.newBlob(bytes, image.mimeType, image.filename));

  } catch (error) {

    throw driveRuntimeError_('CREATE_IMAGE_FILE_' + String(image && image.filename || 'unknown'), error);

  }

}

function createManifestFile_(folder, body, timings) {

  try {

    measureGalleryOperation_(timings, 'manifestCreateMs', function() { return folder.createFile(MANIFEST_FILENAME, JSON.stringify(makeCompleteManifest_(body), null, 2), 'application/json'); });

  } catch (error) {

    throw driveRuntimeError_('CREATE_MANIFEST_FILE', error);

  }

}

function inspectGalleryFolder_(folder, expected, timings) {
  const started = Date.now();
  try { return inspectGalleryFolderContents_(folder, expected); }
  finally { addGalleryTiming_(timings, 'folderInspectionMs', Date.now() - started); }
}

function inspectGalleryFolderContents_(folder, expected) {

  expected = expected || expectedFilenames_(3);

  const fileCounts = {};

  const filesByName = {};

  const manifests = [];

  let safe = true;

  for (let i = 0; i < expected.length; i++) {

    fileCounts[expected[i]] = 0;

  }

  const files = folder.getFiles();

  while (files.hasNext()) {

    const file = files.next();

    const name = file.getName();

    if (name === MANIFEST_FILENAME) {

      manifests.push(file);

    } else if (expected.indexOf(name) !== -1) {

      fileCounts[name] += 1;

      if (fileCounts[name] === 1) {

        filesByName[name] = file;

      } else {

        delete filesByName[name];

      }

    } else {

      safe = false;

    }

  }

  for (let j = 0; j < expected.length; j++) {

    if (fileCounts[expected[j]] > 1) {

      safe = false;

    }

  }

  return { safe: safe, fileCounts: fileCounts, filesByName: filesByName, manifests: manifests };

}

function hasExactlyExpectedImages_(inspection, expected) {

  expected = expected || expectedFilenames_(3);

  for (let i = 0; i < expected.length; i++) {

    if (inspection.fileCounts[expected[i]] !== 1) {

      return false;

    }

  }

  return true;

}

function readManifest_(file, timings) {
  const started = Date.now();

  try {

    return JSON.parse(file.getBlob().getDataAsString());

  } catch (error) {

    throw publicError_(409, 'Manifest requires manual inspection.', 'manualInspectionRequired', 'MANUAL_INSPECTION_REQUIRED');

  } finally { addGalleryTiming_(timings, 'manifestReadMs', Date.now() - started); }

}

function manifestHasExpectedFiles_(manifest, expectedPhotoCount) {

  const count = Number(expectedPhotoCount || (Array.isArray(manifest.photos) ? manifest.photos.length : 0));
  const photoFilenames = expectedPhotoFilenames_(count);

  const rolesOK = manifest.schemaVersion === 1
    ? manifest.receipt === RECEIPT_FILENAME
    : [2,3,4].indexOf(manifest.schemaVersion) !== -1 && manifest.colorReceipt === RECEIPT_FILENAME &&
      (manifest.schemaVersion === 4 ? manifest.thermalReceipt === undefined && manifest.thermalReceiptDerivedFrom === RECEIPT_FILENAME : manifest.thermalReceipt === THERMAL_RECEIPT_FILENAME && manifest.thermalReceiptDerivedFrom === undefined) &&
      (manifest.gif === undefined || manifest.gif === null || manifest.gif === GIF_FILENAME);

  const variantsOK = manifest.schemaVersion >= 3
    ? validReceiptVariants_(manifest.receiptVariants) &&
      (manifest.receiptVariants.originalFooterStyle === 'decorativeBarcodeOnly'
        ? manifest.shareColorReceipt === undefined || manifest.shareColorReceipt === null
        : manifest.shareColorReceipt === SHARE_RECEIPT_FILENAME)
    : manifest.receiptVariants === undefined && manifest.shareColorReceipt === undefined;
  return rolesOK && variantsOK &&

    GALLERY_TOKEN_PATTERN.test(String(manifest.galleryToken || '')) &&

    SAFE_SESSION_ID_PATTERN.test(String(manifest.sessionID || '')) &&

    isValidCreatedAt_(manifest.createdAt) &&

    Array.isArray(manifest.photos) &&

    count >= MIN_PHOTO_COUNT &&

    count <= MAX_PHOTO_COUNT &&

    photoFilenames.length === count &&

    manifest.photos.join('|') === photoFilenames.join('|') &&

    manifest.status === 'complete';

}

function findCompleteGalleryByToken_(token, timings) {

  if (!GALLERY_TOKEN_PATTERN.test(String(token || ''))) {

    return null;

  }

  const rootStartedAt = Date.now();

  const root = getRootFolder_();

  if (timings) {

    timings.rootFolderLookupMs = Date.now() - rootStartedAt;

  }

  const folderStartedAt = Date.now();

  const indexedFolder = loadIndexedGalleryFolder_(token);
  const folders = indexedFolder ? [indexedFolder] : collectFoldersByName_(root, 'gallery-' + token);

  if (timings) {

    timings.galleryFolderLookupMs = Date.now() - folderStartedAt;

  }

  if (folders.length !== 1) {

    return null;

  }

  const folder = folders[0];

  const inspectionStartedAt = Date.now();

  const inspection = inspectGalleryFolder_(folder, expectedFilenames_(MAX_PHOTO_COUNT, 3, true, true));

  if (timings) {

    timings.folderInspectionMs = Date.now() - inspectionStartedAt;

  }

  if (!inspection.safe || inspection.manifests.length !== 1) {

    if (indexedFolder) {
      removeGalleryFolderIndex_(token);
      return findCompleteGalleryByNameFallback_(root, token, timings);
    }

    return null;

  }

  const manifestStartedAt = Date.now();

  const manifest = readManifest_(inspection.manifests[0]);

  if (timings) {

    timings.manifestReadValidationMs = Date.now() - manifestStartedAt;

  }

  if (manifest.galleryToken !== token || manifest.status !== 'complete' || !manifestHasExpectedFiles_(manifest)) {

    if (indexedFolder) {
      removeGalleryFolderIndex_(token);
      return findCompleteGalleryByNameFallback_(root, token, timings);
    }

    return null;

  }

  const expected = expectedFilenames_(manifest.photos.length, manifest.schemaVersion, !!manifest.gif, !!manifest.shareColorReceipt);
  const exactInspection = restrictGalleryInspection_(inspection, expected);

  if (!exactInspection.safe || !hasExactlyExpectedImages_(exactInspection, expected) || exactInspection.manifests.length !== 1) {

    if (indexedFolder) {
      removeGalleryFolderIndex_(token);
      return findCompleteGalleryByNameFallback_(root, token, timings);
    }

    return null;

  }

  if (!indexedFolder) saveGalleryFolderIndex_(token, folder.getId());

  return { folder: folder, manifest: manifest, filesByName: exactInspection.filesByName };

}

function restrictGalleryInspection_(inspection, expected) {
  const safe = inspection.safe && Object.keys(inspection.fileCounts).every(function(name) {
    return expected.indexOf(name) !== -1 || inspection.fileCounts[name] === 0;
  });
  return {safe: safe, fileCounts: inspection.fileCounts, filesByName: inspection.filesByName, manifests: inspection.manifests};
}

function galleryStatusResponse_(e) {
  const startedAt = Date.now();
  const timings = {};
  try {
  const token = String((e && e.parameter && e.parameter.g) || '');
  if (!GALLERY_TOKEN_PATTERN.test(token)) return jsonResponse(200, {ok:false, status:'invalid', statusVersion:1});
  const gallery = findCompleteGalleryByToken_(token, timings);
  if (!gallery) return jsonResponse(200, {ok:false, status:'pending', statusVersion:1});
  let decodedBytes = 0, base64Chars = 0;
  const names = expectedFilenames_(gallery.manifest.photos.length, gallery.manifest.schemaVersion, !!gallery.manifest.gif, !!gallery.manifest.shareColorReceipt);
  for (let i = 0; i < names.length; i++) {
    const bytes = measureGalleryOperation_(timings, 'fileSize' + i + 'Ms', function() { return gallery.filesByName[names[i]].getSize(); });
    if (bytes <= 0 || bytes > MAX_IMAGE_DECODED_BYTES) return jsonResponse(200, {ok:false, status:'unavailable', statusVersion:1});
    decodedBytes += bytes; base64Chars += Math.ceil(bytes / 3) * 4;
  }
  if (decodedBytes > MAX_GALLERY_DECODED_BYTES || base64Chars > MAX_GALLERY_BASE64_CHARS) return jsonResponse(200, {ok:false, status:'unavailable', statusVersion:1});
  return jsonResponse(200, {ok:true, status:'complete', statusVersion:1, galleryToken:token, sessionID:gallery.manifest.sessionID, schemaVersion:gallery.manifest.schemaVersion, fileCount:names.length+1, verificationMs:Date.now()-startedAt});
  } finally {
    console.log('Gallery verification performance: ' + JSON.stringify(timings) + ' totalMs=' + (Date.now() - startedAt));
  }
}

function galleryFolderIndexKey_(token) {
  return GALLERY_FOLDER_INDEX_PREFIX + token;
}

// This is a disposable acceleration index. Drive folder names and manifests remain authoritative.
// New galleries never consume permanent Script Properties space. Legacy entries stay readable.
function galleryFolderCache_() {
  try { return CacheService.getScriptCache(); } catch (_) { return null; }
}

function saveGalleryFolderIndex_(token, folderID) {
  if (!GALLERY_TOKEN_PATTERN.test(String(token || '')) || !folderID) return;
  const cache = galleryFolderCache_();
  if (!cache) return;
  try {
    const key = galleryFolderIndexKey_(token);
    if (cache.get(key) !== String(folderID)) cache.put(key, String(folderID), 21600);
  } catch (_) { console.log('Gallery lookup cache write deferred.'); }
}

function removeGalleryFolderIndex_(token) {
  const cache = galleryFolderCache_();
  if (cache) { try { cache.remove(galleryFolderIndexKey_(token)); } catch (_) {} }
  // Only obsolete acceleration entries are removed; gallery/media/configuration are never touched.
  PropertiesService.getScriptProperties().deleteProperty(galleryFolderIndexKey_(token));
}

function loadIndexedGalleryFolder_(token) {
  const cache = galleryFolderCache_();
  let cached = null;
  if (cache) { try { cached = cache.get(galleryFolderIndexKey_(token)); } catch (_) {} }
  const folderID = cached || PropertiesService.getScriptProperties().getProperty(galleryFolderIndexKey_(token));
  if (!folderID) return null;
  try {
    const folder = DriveApp.getFolderById(folderID);
    if (!cached) saveGalleryFolderIndex_(token, folderID);
    return folder;
  } catch (_) {
    removeGalleryFolderIndex_(token);
    return null;
  }
}

function findCompleteGalleryByNameFallback_(root, token, timings) {
  const folders = collectFoldersByName_(root, 'gallery-' + token);
  if (folders.length !== 1) {
    return null;
  }

  const folder = folders[0];
  const inspection = inspectGalleryFolder_(folder, expectedFilenames_(MAX_PHOTO_COUNT, 3, true, true));
  if (!inspection.safe || inspection.manifests.length !== 1) {
    return null;
  }

  const manifest = readManifest_(inspection.manifests[0]);
  if (manifest.galleryToken !== token || manifest.status !== 'complete' || !manifestHasExpectedFiles_(manifest)) {
    return null;
  }

  const expected = expectedFilenames_(manifest.photos.length, manifest.schemaVersion, !!manifest.gif, !!manifest.shareColorReceipt);
  const exactInspection = restrictGalleryInspection_(inspection, expected);
  if (!exactInspection.safe || !hasExactlyExpectedImages_(exactInspection, expected) || exactInspection.manifests.length !== 1) {
    return null;
  }

  saveGalleryFolderIndex_(token, folder.getId());
  if (timings) {
    timings.galleryFolderIndexSelfHealed = true;
  }
  return { folder: folder, manifest: manifest, filesByName: exactInspection.filesByName };
}

function loadGalleryAssets_(filesByName, manifest, includeGIF, timings, parallel) {
  const names = manifest.photos.concat([manifest.schemaVersion >= 2 ? manifest.colorReceipt : manifest.receipt]);
  if (manifest.schemaVersion >= 2 && manifest.schemaVersion < 4) names.push(manifest.thermalReceipt);
  if (manifest.schemaVersion >= 3 && manifest.shareColorReceipt) names.push(manifest.shareColorReceipt);
  if (includeGIF !== false && manifest.schemaVersion >= 2 && manifest.gif) names.push(manifest.gif);
  const preloaded = parallel ? preloadGalleryMedia_(filesByName, names, timings) : {};
  let assetIndex = 0;
  function load(filename, role) {
    const index = assetIndex++;
    return measureGalleryOperation_(timings, 'assetReadBase64' + index + 'Ms', function() { return loadGalleryAsset_(filesByName, filename, role, timings, index, preloaded, parallel); });
  }

  const photos = [];

  for (let i = 0; i < manifest.photos.length; i++) {

    photos.push(load(manifest.photos[i], 'photo'));

  }

  return {

    photos: photos,

    receipt: load(manifest.schemaVersion >= 2 ? manifest.colorReceipt : manifest.receipt, 'colorReceipt'),
    thermalReceipt: manifest.schemaVersion === 4 ? {filename: THERMAL_RECEIPT_FILENAME, role: 'thermalReceipt', mimeType: 'image/png', deriveFrom: manifest.colorReceipt} : manifest.schemaVersion >= 2 ? load(manifest.thermalReceipt, 'thermalReceipt') : null,
    shareColorReceipt: manifest.schemaVersion >= 3 && manifest.shareColorReceipt ? load(manifest.shareColorReceipt, 'colorReceipt') : null,
    gif: includeGIF !== false && manifest.schemaVersion >= 2 && manifest.gif ? load(manifest.gif, 'gif') : null

  };

}

// The `thermalReceipt` slot (receipt-bw.png) holds the customer black & white receipt. Booth builds
// from October 18, 2026 store a smooth 8-bit grayscale PNG there (IHDR color type 0). Earlier
// galleries and queued uploads stored the 1-bit printer raster (an RGB/RGBA PNG). For those, the raw
// raster is not sent to the page; the browser derives a grayscale copy from the stored, already
// privacy-safe color receipt. Stored Drive files and manifests are never rewritten.
function isSmoothMonochromeReceiptPNG_(base64Data) {
  const head = String(base64Data || '').slice(0, 44);
  if (head.length < 44) return false;
  let bytes;
  try {
    bytes = Utilities.base64Decode(head);
  } catch (error) {
    return false;
  }
  const signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52];
  for (let i = 0; i < signature.length; i++) {
    if ((bytes[i] & 0xff) !== signature[i]) return false;
  }
  return (bytes[24] & 0xff) === 8 && (bytes[25] & 0xff) === 0;
}

function customerMonochromeReceipt_(thermalReceipt, colorReceipt) {
  if (!thermalReceipt || !colorReceipt || isSmoothMonochromeReceiptPNG_(thermalReceipt.base64Data)) {
    return thermalReceipt;
  }
  return {
    filename: thermalReceipt.filename,
    role: thermalReceipt.role,
    mimeType: 'image/png',
    deriveFrom: colorReceipt.filename
  };
}

function loadGalleryAsset_(filesByName, filename, role, timings, index, preloaded, fastEncoding) {

  const file = filesByName && filesByName[filename];

  if (!file) {

    throw publicError_(404, 'Gallery unavailable.', 'rejected', 'GALLERY_NOT_FOUND');

  }

  const bytes = measureGalleryOperation_(timings, 'assetBytes' + index + 'Ms', function() { return (preloaded && preloaded[filename]) || file.getBlob().getBytes(); });
  const base64Data = measureGalleryOperation_(timings, 'assetBase64' + index + 'Ms', function() { return fastEncoding ? encodeGalleryBytes_(bytes) : Utilities.base64Encode(bytes); });

  return {

    filename: filename,

    role: role,

    mimeType: filename.endsWith('.png') ? 'image/png' : (filename.endsWith('.gif') ? 'image/gif' : 'image/jpeg'),

    base64Data: base64Data

  };

}

function validateGalleryRenderSize_(assets) {

  const items = assets.photos.concat([assets.receipt, assets.thermalReceipt, assets.gif, assets.shareColorReceipt].filter(Boolean));

  let base64Chars = 0;

  let decodedBytes = 0;

  for (let i = 0; i < items.length; i++) {

    base64Chars += String(items[i].base64Data || '').length;

    decodedBytes += estimatedDecodedBytesFromBase64_(items[i].base64Data);

  }

  console.log('Gallery render payload size. decodedBytes=' + decodedBytes + ' base64Chars=' + base64Chars);

  return {

    ok: decodedBytes <= MAX_GALLERY_DECODED_BYTES && base64Chars <= MAX_GALLERY_BASE64_CHARS,

    decodedBytes: decodedBytes,

    base64Chars: base64Chars

  };

}

function estimatedDecodedBytesFromBase64_(base64Data) {

  const value = String(base64Data || '');

  if (!value) {

    return 0;

  }

  let padding = 0;

  if (value.endsWith('==')) {

    padding = 2;

  } else if (value.endsWith('=')) {

    padding = 1;

  }

  return Math.floor(value.length * 3 / 4) - padding;

}

function formatManilaDate_(createdAt) {

  const date = new Date(String(createdAt || ''));

  if (Number.isNaN(date.getTime())) {

    return '';

  }

  return Utilities.formatDate(date, 'Asia/Manila', 'MMMM d, yyyy · h:mm a');

}

function makeCompleteManifest_(body) {
  if (body.schemaVersion === 1) return {
    schemaVersion: 1,

    galleryToken: body.galleryToken,

    sessionID: body.sessionID,

    createdAt: body.createdAt,

    photos: body._expectedPhotoFilenames || expectedPhotoFilenames_(body.photos.length),

    receipt: RECEIPT_FILENAME,

    status: 'complete'

  };

  return {
    schemaVersion: body.schemaVersion,
    galleryToken: body.galleryToken,
    sessionID: body.sessionID,
    createdAt: body.createdAt,
    photos: body._expectedPhotoFilenames || expectedPhotoFilenames_(body.photos.length),
    colorReceipt: RECEIPT_FILENAME,
    ...(body.schemaVersion === 4 ? {thermalReceiptDerivedFrom: RECEIPT_FILENAME} : {thermalReceipt: THERMAL_RECEIPT_FILENAME}),
    ...(body.schemaVersion >= 3 ? {receiptVariants: body.receiptVariants,
      ...(body.shareColorReceipt ? {shareColorReceipt: SHARE_RECEIPT_FILENAME} : {})} : {}),
    gif: body.gif ? GIF_FILENAME : undefined,
    status: 'complete'
  };

}

function runCustomerGalleryPropertyPrecedenceSelfChecks_() {

  const legacyBase = 'https://pocket-pixels-gallery.pocketpixels-ceb.workers.dev/';

  const preferredBase = 'https://gallery.madetokeep.test/';

  function fakeProperties(values) {

    return { getProperty: function(key) { return Object.prototype.hasOwnProperty.call(values, key) ? values[key] : null; } };

  }

  const both = {};

  both[CUSTOMER_GALLERY_BASE_URL_PROPERTY] = preferredBase;

  both[LEGACY_CUSTOMER_GALLERY_BASE_URL_PROPERTY] = legacyBase;

  assert_(resolveCustomerGalleryBaseURLProperty_(fakeProperties(both)).value === preferredBase, 'Made to Keep customer gallery property should be preferred when present.');

  const legacyOnly = {};

  legacyOnly[LEGACY_CUSTOMER_GALLERY_BASE_URL_PROPERTY] = legacyBase;

  assert_(resolveCustomerGalleryBaseURLProperty_(fakeProperties(legacyOnly)).value === legacyBase, 'Legacy Pocket Pixels customer gallery property should remain a valid fallback.');

  const blankPreferred = {};

  blankPreferred[CUSTOMER_GALLERY_BASE_URL_PROPERTY] = '   ';

  blankPreferred[LEGACY_CUSTOMER_GALLERY_BASE_URL_PROPERTY] = legacyBase;

  assert_(resolveCustomerGalleryBaseURLProperty_(fakeProperties(blankPreferred)).propertyName === LEGACY_CUSTOMER_GALLERY_BASE_URL_PROPERTY, 'Blank Made to Keep property should fall back to the legacy property.');

  assert_(resolveCustomerGalleryBaseURLProperty_(fakeProperties({})).value === null, 'Missing customer gallery properties should resolve to no value.');

}

function makeGalleryURL_(galleryToken) {

  if (!GALLERY_TOKEN_PATTERN.test(String(galleryToken || ''))) {

    throw publicError_(400, 'Invalid gallery token.', 'rejected', 'INVALID_GALLERY_TOKEN');

  }

  const customerGalleryBaseURL = resolveCustomerGalleryBaseURLProperty_(PropertiesService.getScriptProperties()).value;

  return makeGalleryURLFromCustomerBaseURL_(customerGalleryBaseURL, galleryToken);

}

// Returns the configured customer gallery base URL: the Made to Keep property when it is set to a
// non-blank value, otherwise the legacy Pocket Pixels property. A present-but-invalid preferred
// value is not silently skipped; it fails validation so misconfiguration is visible.
function resolveCustomerGalleryBaseURLProperty_(properties) {

  const preferred = properties.getProperty(CUSTOMER_GALLERY_BASE_URL_PROPERTY);

  if (typeof preferred === 'string' && preferred.trim().length > 0) {

    return { propertyName: CUSTOMER_GALLERY_BASE_URL_PROPERTY, value: preferred };

  }

  const legacy = properties.getProperty(LEGACY_CUSTOMER_GALLERY_BASE_URL_PROPERTY);

  if (typeof legacy === 'string' && legacy.trim().length > 0) {

    return { propertyName: LEGACY_CUSTOMER_GALLERY_BASE_URL_PROPERTY, value: legacy };

  }

  return { propertyName: '', value: null };

}

function makeGalleryURLFromCustomerBaseURL_(customerGalleryBaseURL, galleryToken) {

  if (!GALLERY_TOKEN_PATTERN.test(String(galleryToken || ''))) {

    throw publicError_(400, 'Invalid gallery token.', 'rejected', 'INVALID_GALLERY_TOKEN');

  }

  const baseURL = canonicalizeCustomerGalleryBaseURL_(customerGalleryBaseURL);

  return baseURL + '?g=' + encodeURIComponent(galleryToken);

}

function canonicalizeCustomerGalleryBaseURL_(baseURL) {
  const value = String(baseURL || '').trim();

  // Apps Script V8 is not a browser environment and does not expose
  // the WHATWG URL / URLSearchParams Web APIs. Validate this HTTPS base
  // URL using only ECMAScript primitives supported by Apps Script.
  if (!value || /\s/.test(value)) {
    throw publicError_(500, 'Customer gallery base URL is not configured.', 'rejected', 'INVALID_CUSTOMER_GALLERY_BASE_URL');
  }

  const match = value.match(/^https:\/\/([A-Za-z0-9.-]+)(?::([0-9]{1,5}))?(\/[^?#]*)?(?:\?[^#]*)?(?:#.*)?$/i);
  if (!match) {
    throw publicError_(500, 'Customer gallery base URL is not configured.', 'rejected', 'INVALID_CUSTOMER_GALLERY_BASE_URL');
  }

  const hostname = String(match[1] || '').toLowerCase();
  const port = String(match[2] || '');
  let pathname = String(match[3] || '/');

  if (!hostname || hostname === 'script.google.com' || hostname.indexOf('..') !== -1 ||
      hostname.charAt(0) === '.' || hostname.charAt(hostname.length - 1) === '.') {
    throw publicError_(500, 'Customer gallery base URL is not configured.', 'rejected', 'INVALID_CUSTOMER_GALLERY_BASE_URL');
  }

  // Remove query/fragment by construction. Keep root as "/" and remove
  // trailing slashes from non-root paths for deterministic URL generation.
  if (!pathname) {
    pathname = '/';
  }
  if (pathname !== '/') {
    pathname = pathname.replace(/\/+$/, '');
    if (!pathname) {
      pathname = '/';
    }
  }

  return 'https://' + hostname + (port ? ':' + port : '') + pathname;
}

function checkCustomerGalleryConfig() {
  const resolved = resolveCustomerGalleryBaseURLProperty_(PropertiesService.getScriptProperties());
  const raw = resolved.value;
  const result = {
    propertyName: resolved.propertyName || CUSTOMER_GALLERY_BASE_URL_PROPERTY,
    usesLegacyProperty: resolved.propertyName === LEGACY_CUSTOMER_GALLERY_BASE_URL_PROPERTY,
    propertyPresent: typeof raw === 'string' && raw.trim().length > 0,
    propertyLength: typeof raw === 'string' ? raw.trim().length : 0,
    valid: false,
    usesHTTPS: false,
    usesWorkersDev: false
  };

  if (result.propertyPresent) {
    try {
      const canonical = canonicalizeCustomerGalleryBaseURL_(raw);
      result.valid = true;
      result.usesHTTPS = canonical.indexOf('https://') === 0;
      result.usesWorkersDev = /\.workers\.dev(?:\/|$)/i.test(canonical);
    } catch (error) {
      result.valid = false;
    }
  }

  console.log('Customer gallery config check: ' + JSON.stringify(result));
  return result;
}

function canonicalizeWebAppURL_(url) {

  return String(url || '')

    .replace(/\/macros\/u\/[0-9]+\/s\//, '/macros/s/')

    .replace(/\/+$/, '');

}

function getRootFolder_() {

  const rootFolderID = PropertiesService.getScriptProperties().getProperty(ROOT_FOLDER_ID_PROPERTY);

  if (!rootFolderID) {

    throw publicError_(500, 'Upload service root folder is not configured.', 'rejected', 'DRIVE_RUNTIME_ERROR', 'GET_ROOT_FOLDER: missing script property');

  }

  try {

    return DriveApp.getFolderById(rootFolderID);

  } catch (error) {

    throw driveRuntimeError_('GET_ROOT_FOLDER', error);

  }

}

function collectFoldersByName_(root, folderName) {

  const folders = root.getFoldersByName(folderName);

  const result = [];

  while (folders.hasNext()) {

    result.push(folders.next());

  }

  return result;

}

function expectedPhotoFilenames_(photoCount) {

  const count = Number(photoCount || 0);
  if (count < MIN_PHOTO_COUNT || count > MAX_PHOTO_COUNT) {
    return [];
  }
  const filenames = [];
  for (let i = 1; i <= count; i++) {
    filenames.push('photo-' + String(i).padStart(2, '0') + '.jpg');
  }
  return filenames;

}

function expectedFilenames_(photoCount, schemaVersion, hasGIF, hasShareReceipt) {

  return expectedPhotoFilenames_(photoCount).concat(schemaVersion >= 2
    ? [RECEIPT_FILENAME].concat(schemaVersion === 4 ? [] : [THERMAL_RECEIPT_FILENAME]).concat(hasGIF === false ? [] : [GIF_FILENAME]).concat(schemaVersion >= 3 && hasShareReceipt ? [SHARE_RECEIPT_FILENAME] : [])
    : [RECEIPT_FILENAME]);

}

function isValidCreatedAt_(value) {

  const stringValue = String(value || '');

  if (!RFC3339_UTC_SECONDS_PATTERN.test(stringValue)) {

    return false;

  }

  const parsed = new Date(stringValue);

  if (Number.isNaN(parsed.getTime())) {

    return false;

  }

  return parsed.toISOString().replace('.000', '') === stringValue;

}

function hasJpegSignature_(bytes) {

  return bytes.length >= 3 &&

    normalizeByte_(bytes[0]) === 0xff &&

    normalizeByte_(bytes[1]) === 0xd8 &&

    normalizeByte_(bytes[2]) === 0xff;

}

function hasPngSignature_(bytes) {
  const expected = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
  return bytes.length >= expected.length && expected.every(function(value, index) {
    return normalizeByte_(bytes[index]) === value;
  });
}

function hasGifSignature_(bytes) {
  if (bytes.length < 6) return false;
  const signature = bytes.slice(0, 6).map(function(value) { return String.fromCharCode(normalizeByte_(value)); }).join('');
  return signature === 'GIF87a' || signature === 'GIF89a';
}

function normalizeByte_(byteValue) {

  return byteValue < 0 ? byteValue + 256 : byteValue;

}

function jsonResponse(statusCode, body) {

  const output = ContentService

    .createTextOutput(JSON.stringify(body))

    .setMimeType(ContentService.MimeType.JSON);

  return output;

}

function logSanitizedRequest_(body, bodyCharacterCount) {
  console.log('Gallery request sizes: ' + JSON.stringify({
    bodyCharacters: bodyCharacterCount,
    photoCount: Array.isArray(body && body.photos) ? body.photos.length : 0,
    supportedSchema: !!body && [1,2,3,4].indexOf(body.schemaVersion) !== -1
  }));
}

function addGalleryTiming_(timings, key, elapsed) {
  if (!timings) return;
  timings[key] = (timings[key] || 0) + Math.max(0, elapsed);
  timings[key + 'Count'] = (timings[key + 'Count'] || 0) + 1;
}

function measureGalleryOperation_(timings, key, operation) {
  const started = Date.now();
  try { return operation(); }
  finally { addGalleryTiming_(timings, key, Date.now() - started); }
}

function topLevelTypes_(body) {

  const result = {};

  const keys = Object.keys(body || {});

  for (let i = 0; i < keys.length; i++) {

    const value = body[keys[i]];

    result[keys[i]] = Array.isArray(value) ? 'array' : typeof value;

  }

  return result;

}

function validationError_(code, message, field) {

  return { ok: false, code: code, message: message, field: field };

}

function publicError_(statusCode, message, status, code, detail) {

  const error = new Error(message);

  error.statusCode = statusCode;

  error.publicMessage = message;

  error.publicStatus = status;

  error.publicCode = code || 'INTERNAL_SERVER_ERROR';

  error.publicDetail = detail || '';

  return error;

}

function driveRuntimeError_(operation, originalError) {

  const detail = operation + ': ' + sanitizeExceptionDetail_(originalError);

  return publicError_(500, 'Google Drive operation failed.', 'rejected', 'DRIVE_RUNTIME_ERROR', detail);

}

function classifyUnexpectedError_(error, stage) {

  if (error && error.publicCode) {

    return {

      statusCode: error.statusCode || 400,

      code: error.publicCode,

      message: error.publicMessage || 'Upload request failed.',

      status: error.publicStatus || 'rejected',

      stage: stage || 'UNKNOWN',

      detail: String(error.publicDetail || '').slice(0, 500)

    };

  }

  const message = safeErrorMessage_(error);

  const driveStages = ['GET_ROOT_FOLDER', 'CREATE_OR_RETURN_GALLERY'];

  const isDriveStage = driveStages.indexOf(stage) !== -1;

  const isDriveError = isDriveStage || /DriveApp|Folder|File|Blob|createFile|getFolderById|Service invoked too many times|Limit Exceeded/i.test(message);

  return {

    statusCode: 500,

    code: isDriveError ? 'DRIVE_RUNTIME_ERROR' : 'INTERNAL_SERVER_ERROR',

    message: isDriveError ? 'Google Drive operation failed.' : 'Internal server error.',

    status: 'rejected',

    stage: stage || 'UNKNOWN',

    detail: sanitizeExceptionDetail_(error)

  };

}

function logUnexpectedError_(error, safeError, stage) {
  console.error('Gallery upload failed: code=' + safeError.code + ' stage=' + (stage || 'UNKNOWN'));
}

function sanitizeExceptionDetail_(error) {

  const name = String((error && error.name) || 'Error');

  const message = safeErrorMessage_(error);

  return (name + ': ' + message).slice(0, 500);

}

function safeErrorMessage_(error) {

  return String((error && error.message) || error || '').replace(/[a-f0-9]{64}/g, function(token) {

    return redactToken_(token);

  });

}

function captureError_(operation) {

  try {

    operation();

  } catch (error) {

    return error;

  }

  throw new Error('Expected operation to throw.');

}

function assertValidationCode_(payload, expectedCode) {

  const validation = validateUploadPayload_(payload);

  if (expectedCode === null) {

    assert_(validation.ok, 'Expected payload to pass validation.');

    return;

  }

  assert_(!validation.ok && validation.code === expectedCode, 'Expected validation code ' + expectedCode + ', got ' + validation.code + '.');

}

function redactToken_(token) {

  const value = String(token || '');

  if (value.length <= 12) {

    return '<redacted>';

  }

  return value.slice(0, 6) + '...' + value.slice(-6);

}

function escapeHTML(value) {

  return String(value || '')

    .replace(/&/g, '&amp;')

    .replace(/</g, '&lt;')

    .replace(/>/g, '&gt;')

    .replace(/"/g, '&quot;')

    .replace(/'/g, '&#39;');

}

function makeSelfTestPayload_(photoCount) {

  const count = Number(photoCount || 3);
  const photos = [];
  for (let i = 1; i <= count; i++) {
    photos.push({
      filename: 'photo-' + String(i).padStart(2, '0') + '.jpg',
      mimeType: 'image/jpeg',
      base64Data: '/9j/4AAQSkZJRg=='
    });
  }

  return {

    schemaVersion: SCHEMA_VERSION,

    deviceToken: 'self-test-token',

    galleryToken: 'a'.repeat(64),

    sessionID: 'PP-20260830-120000',

    createdAt: '2026-08-30T12:00:00Z',

    photos: photos,

    colorReceipt: { filename: 'receipt-color.jpg', mimeType: 'image/jpeg', base64Data: '/9j/4AAQSkZJRg==' },
    thermalReceipt: { filename: 'receipt-bw.png', mimeType: 'image/png', base64Data: 'iVBORw0KGgo=' },
    gif: { filename: 'session.gif', mimeType: 'image/gif', base64Data: 'R0lGODlh' }

  };

}

function assert_(condition, message) {

  if (!condition) {

    throw new Error(message);

  }

}
