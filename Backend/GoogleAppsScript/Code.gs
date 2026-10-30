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

const BACKEND_VERSION = 'made-to-keep-gallery-v9-instrumented-20261030';

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

      htmlOutput = renderGalleryPage_(gallery, timings, startedAt);

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

function madeToKeepBrandLockupHTML_(size) {

  // Pure HTML/CSS typographic lockup; no bitmap logo or web font is downloaded.
  return '<div class="brand-lockup' + (size ? ' brand-lockup-' + size : '') + '" role="img" aria-label="' + MADE_TO_KEEP_BRAND.fullName + '"><span class="brand-descriptor">' + MADE_TO_KEEP_BRAND.descriptor + '</span><span class="brand-rule" aria-hidden="true"></span><span class="brand-wordmark">' + MADE_TO_KEEP_BRAND.wordmark + '</span><span class="brand-secondary">' + MADE_TO_KEEP_BRAND.secondary + '</span></div>';

}

function galleryNoticePage_(options) {

  // One branded layout for every non-gallery state. `options.state` is a fixed internal value.
  return pageShell_(

    '<main class="center-page" data-gallery-state="' + options.state + '"><section class="notice">' + madeToKeepBrandLockupHTML_('compact') +
    '<h1>' + options.title + '</h1>' +
    (options.loader ? '<div class="loader" aria-hidden="true"></div>' : '') +
    '<p id="noticeText">' + options.message + '</p>' +
    (options.button ? '<button type="button" class="btn" id="noticeAction" onclick="window.location.reload()">' + options.button + '</button>' : '') +
    (options.footnote ? '<p class="notice-footnote" id="noticeFootnote">' + options.footnote + '</p>' : '') +
    '</section></main>',

    options.script || ''

  );

}

function renderInvalidGalleryPage_() {

  // A malformed token can never become a gallery, so this page never polls or promises photos.
  return makeHTML_(galleryNoticePage_({

    state: 'invalid',
    title: 'this link doesn’t look quite right.',
    message: 'This gallery link cannot be opened. Please scan the QR code on your receipt again, or ask the booth team for help.'

  }));

}

function renderPendingGalleryPage_() {

  // Gentle, bounded checking: 6, 10, 15, 20, 30 and 45 seconds apart (about two minutes), counted
  // across reloads in sessionStorage so the limit survives each refresh. Then it stops and waits
  // for the guest. Nothing about the stored gallery changes when this page reloads.
  const script = [
    '(function(){var delays=[6,10,15,20,30,45];var key="mtk-pending-checks";var count=0;',
    'try{count=parseInt(sessionStorage.getItem(key)||"0",10)||0;}catch(e){}',
    'var text=document.getElementById("noticeText");var foot=document.getElementById("noticeFootnote");var action=document.getElementById("noticeAction");',
    'if(action){action.onclick=function(){try{sessionStorage.setItem(key,"0");}catch(e){}window.location.reload();};}',
    'if(count>=delays.length){if(text){text.textContent="This is taking a little longer than usual. Your photos are safe with us — please check again in a few minutes.";}if(foot){foot.textContent="Automatic checking has paused.";}var loader=document.querySelector(".loader");if(loader){loader.remove();}return;}',
    'setTimeout(function(){try{sessionStorage.setItem(key,String(count+1));}catch(e){}window.location.reload();},delays[count]*1000);})();'
  ].join('');

  return makeHTML_(galleryNoticePage_({

    state: 'pending',
    title: 'your photos are still being prepared.',
    message: 'Your gallery is on its way from the booth. This page checks again automatically.',
    loader: true,
    button: 'Check Again',
    footnote: 'You can keep this page open or come back to the same link later.',
    script: script

  }));

}

function renderGalleryTooLargePage_() {

  return makeHTML_(galleryNoticePage_({

    state: 'unavailable',
    title: 'gallery temporarily unavailable.',
    message: 'Your photos are saved, but this gallery cannot be shown right now. Please try again later or ask the booth team for help.',
    button: 'Try Again'

  }));

}

// Icons are local SVG markup. No icon service, fonts or external image requests.
function galleryIcon_(name) {
  const paths = {
    download: '<path d="M12 3v12m-4-4 4 4 4-4M5 16v4h14v-4"/>',
    share: '<circle cx="18" cy="5" r="3"/><circle cx="6" cy="12" r="3"/><circle cx="18" cy="19" r="3"/><path d="m9 10 6-4M9 14l6 4"/>',
    lock: '<rect x="5" y="10" width="14" height="11" rx="2"/><path d="M8 10V6a4 4 0 0 1 8 0v4m-4 5v2"/>',
    receipt: '<path d="M6 2h9l4 4v16l-3-2-4 2-3-2-3 2V2Zm8 0v6h5M9 12h7m-7 4h7"/>',
    instagram: '<rect x="3" y="3" width="18" height="18" rx="5"/><circle cx="12" cy="12" r="4"/><path d="M17.5 6.5h.01"/>',
    arrow: '<path d="M4 12h16m-6-6 6 6-6 6"/>',
    calendar: '<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M7 2v6m10-6v6M3 11h18"/>',
    menu: '<path d="M4 6h16M4 12h16M4 18h16"/>',
    heart: '<path d="M12 21 3 12C-3 5 6-1 12 6c6-7 15-1 9 6Z"/>'
  };
  return '<svg class="icon icon-' + name + '" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + (paths[name] || '') + '</svg>';
}

function galleryInstagramLink_(className, label) {
  // Approved outbound navigation only. Never include gallery data in this destination.
  return '<a class="' + className + '" href="https://www.instagram.com/madetokeep.studios/" target="_blank" rel="noopener noreferrer" referrerpolicy="no-referrer">' + label + '</a>';
}

function galleryPhotoCardHTML_(item, index, total, createdAt) {
  const name = escapeHTML(item.filename);
  return '<figure class="shot"><button type="button" class="shot-frame image-button" data-open="' + name + '" aria-label="View photo ' + (index + 1) + ' of ' + total + ' larger">' +
    '<div class="image-placeholder" id="placeholder-' + name + '"><span>developing…</span></div>' +
    '<img hidden decoding="async" loading="' + (index === 0 ? 'eager' : 'lazy') + '" id="image-' + name + '" alt="Made to Keep Studios photo ' + (index + 1) + '"></button>' +
    '<figcaption class="shot-actions"><div class="shot-meta"><span class="shot-label">Photo ' + (index + 1) + '</span><span class="shot-date">' + escapeHTML(createdAt) + '</span></div><span class="shot-buttons">' +
    '<button type="button" class="btn-small" data-download="' + name + '">' + galleryIcon_('download') + 'Save</button>' +
    '<button type="button" class="btn-small" data-share="' + name + '">' + galleryIcon_('share') + 'Share</button></span></figcaption></figure>';
}

// `thermal` is the legacy name of the manifest slot. Customers always see a smooth black & white
// digital preview there, never the 1-bit printer raster (see customerMonochromeReceipt_).
function validReceiptVariants_(value) {
  return !!value && typeof value === 'object' && !Array.isArray(value) &&
    Object.keys(value).sort().join(',') === 'defaultStyle,originalFooterStyle' &&
    ['integratedGalleryQR','classicBarcodeAndGalleryQR','decorativeBarcodeOnly'].indexOf(value.originalFooterStyle) !== -1 &&
    ['shareFriendly','asPrinted'].indexOf(value.defaultStyle) !== -1;
}

function galleryReceiptStyleHTML_(manifest) {
  if (manifest.schemaVersion < 3 || !manifest.shareColorReceipt) return '';
  return '<div class="receipt-style" role="group" aria-label="Receipt style">' +
    '<button type="button" class="btn-small" data-receipt-style="shareFriendly" aria-pressed="false">Share-Friendly</button>' +
    '<button type="button" class="btn-small" data-receipt-style="asPrinted" aria-pressed="false">As Printed</button></div>' +
    '<p id="receiptPrivacy" class="receipt-privacy" hidden>This receipt includes your gallery QR. Anyone who scans it can view your photos. Choose Share-Friendly for public posts.</p>' +
    '<p id="receiptStyleStatus" class="receipt-style-status" role="status" aria-live="polite"></p>';
}

function galleryReceiptCardHTML_(item, thermal) {
  const name = escapeHTML(item.filename);
  const title = thermal ? 'Black &amp; White Receipt' : 'Color Receipt';
  return '<article class="receipt-card"><div class="receipt-copy"><h3>' + title + '</h3><p>' +
    (thermal ? 'A digital preview of your printed keepsake.' : 'A full-color keepsake of your photobooth session.') + '</p><div class="receipt-actions">' +
    '<button type="button" class="btn-small primary" data-download="' + name + '">' + galleryIcon_('download') + '<span>Save<span class="receipt-save-label"> receipt</span></span></button>' +
    '<button type="button" class="btn-small" data-share="' + name + '">' + galleryIcon_('share') + 'Share</button></div></div>' +
    '<button type="button" class="receipt-frame image-button" data-open="' + name + '" aria-label="View ' + (thermal ? 'black and white' : 'color') + ' receipt larger"><div class="image-placeholder receipt-placeholder" id="placeholder-' + name + '"><span>developing…</span></div><img hidden decoding="async" loading="lazy" id="image-' + name + '" alt="Made to Keep Studios ' + (thermal ? 'black and white' : 'color') + ' receipt"></button></article>';
}

function galleryCollageHTML_(photos) {
  let html = '<div class="hero-collage collage-count-' + Math.min(photos.length, 2) + '" aria-hidden="true"><div class="paper-strip"><i></i><i></i><i></i></div><span class="tape tape-one"></span><span class="tape tape-two"></span>';
  // References only: each original base64 payload occurs once in galleryData.
  photos.slice(0, 2).forEach(function(item, index) {
    html += '<figure class="polaroid polaroid-' + index + '"><img data-collage="' + escapeHTML(item.filename) + '" alt="" decoding="async"></figure>';
  });
  html += '<svg class="botanical" viewBox="0 0 120 250" fill="none" stroke="currentColor" stroke-width="1.2"><path d="M20 245Q55 160 70 55M35 206Q45 148 24 98M47 166Q75 130 105 111M59 115Q84 70 102 35M64 88Q44 49 47 18M70 63Q82 30 75 9"/><g fill="currentColor" stroke="none"><ellipse cx="24" cy="97" rx="3" ry="7" transform="rotate(-25 24 97)"/><ellipse cx="48" cy="23" rx="3" ry="6"/><ellipse cx="75" cy="11" rx="3" ry="6"/><ellipse cx="101" cy="36" rx="3" ry="6" transform="rotate(30 101 36)"/><ellipse cx="104" cy="110" rx="3" ry="6" transform="rotate(55 104 110)"/><ellipse cx="95" cy="119" rx="3" ry="6" transform="rotate(70 95 119)"/><ellipse cx="52" cy="54" rx="3" ry="6" transform="rotate(-25 52 54)"/><ellipse cx="89" cy="61" rx="3" ry="6" transform="rotate(40 89 61)"/></g></svg></div>';
  return html;
}

function renderGalleryPage_(gallery, timings, startedAt) {

  const assetStartedAt = Date.now();

  const assets = loadGalleryAssets_(gallery.filesByName, gallery.manifest, false, timings);
  assets.thermalReceipt = customerMonochromeReceipt_(assets.thermalReceipt, assets.receipt);

  if (timings) {

    timings.jpegBlobReadBase64Ms = Date.now() - assetStartedAt;

  }

  const sizeCheck = validateGalleryRenderSize_(assets);

  if (!sizeCheck.ok) {

    console.error('Gallery render size rejected. decodedBytes=' + sizeCheck.decodedBytes + ' base64Chars=' + sizeCheck.base64Chars);

    return renderGalleryTooLargePage_();

  }

  const createdAt = formatManilaDate_(gallery.manifest.createdAt);

  // Keep the date/time portion meaningful for both legacy and UUID-suffixed IDs.
  const sessionID = String(gallery.manifest.sessionID || '');
  const reference = /^PP-[0-9]{8}-[0-9]{6}/.test(sessionID) ? sessionID.slice(5, 18) : sessionID.slice(-13);

  const dataJSON = JSON.stringify({

    createdAt: createdAt,

    reference: reference,

    photos: assets.photos,

    receipt: assets.receipt,
    thermalReceipt: assets.thermalReceipt,
    shareColorReceipt: assets.shareColorReceipt,
    receiptVariants: gallery.manifest.schemaVersion >= 3 ? gallery.manifest.receiptVariants : null

  }).replace(/</g, '\\u003c');

  const photoCount = assets.photos.length;

  let body = '';

  body += '<header class="site-header"><div class="header-inner">' + madeToKeepBrandLockupHTML_('compact') + '<span class="header-divider" aria-hidden="true"></span><span class="header-label">Private Gallery</span><div class="header-privacy">' + galleryIcon_('lock') + '<p><strong>This gallery is private</strong><span>Only accessible with this receipt link.</span></p></div>' +
    '<button type="button" class="btn header-share" data-share-gallery>' + galleryIcon_('share') + 'Share Gallery</button><button type="button" class="menu-toggle" id="menuToggle" aria-expanded="false" aria-controls="galleryMenu" aria-label="Open gallery menu">' + galleryIcon_('menu') + '</button>' +
    '<nav class="gallery-menu" id="galleryMenu" aria-label="Gallery navigation" hidden><a href="#photos">Photo Gallery</a><a href="#receipts">Receipt Copy</a><button type="button" data-share-gallery>Share Gallery</button>' + galleryInstagramLink_('menu-instagram', 'Instagram') + '</nav></div></header>';
  body += '<main class="gallery-shell" data-pocket-pixels-gallery-status="complete">';
  body += '<section class="intro" aria-labelledby="heroTitle"><div class="gallery-hero"><p class="eyebrow">Receipt Photobooth</p><h1 id="heroTitle">your moments,<br><em>made to keep.</em></h1><p class="lede">View, save and share the photographs from your session.</p>' +
    '<div class="hero-actions"><button type="button" class="btn primary" id="shareAll" aria-describedby="allHint">' + galleryIcon_('download') + 'Download all photos</button><div class="secondary-actions"><button type="button" class="btn" data-share-gallery>' + galleryIcon_('share') + 'Share gallery</button><a class="btn receipt-jump" href="#receipts">' + galleryIcon_('receipt') + 'View receipt copy</a></div><p id="allHint" class="action-hint"></p></div></div>' + galleryCollageHTML_(assets.photos) + '</section>';
  body += '<section class="photos" id="photos" aria-labelledby="photosTitle"><div class="section-heading"><h2 id="photosTitle">Photo Gallery</h2><p>' + photoCount + (photoCount === 1 ? ' photo' : ' photos') + '</p></div><div class="photo-grid photo-count-' + photoCount + '" aria-label="Made to Keep Studios photo gallery">';
  for (let i = 0; i < photoCount; i++) {
    body += galleryPhotoCardHTML_(assets.photos[i], i, photoCount, createdAt);
  }
  body += '</div></section>';
  body += '<section class="receipt-section" id="receipts" aria-labelledby="receiptTitle"><div class="section-heading"><h2 id="receiptTitle">Receipt Copy</h2><p>Your keepsake</p></div>' + galleryReceiptStyleHTML_(gallery.manifest) + '<div class="receipt-layout' + (assets.thermalReceipt ? '' : ' receipt-layout-single') + '">' + galleryReceiptCardHTML_(assets.receipt, false);
  if (assets.thermalReceipt) { body += galleryReceiptCardHTML_(assets.thermalReceipt, true); }
  body += '</div></section>';
  body += '<aside class="instagram-card" aria-labelledby="instagramTitle"><div class="instagram-emblem">' + galleryIcon_('instagram') + '</div><div class="instagram-copy"><p class="eyebrow">A little more of us</p><h2 id="instagramTitle">the moments continue.</h2><p>Tag us in your favorites, or stay for more little moments.</p></div>' + galleryInstagramLink_('btn instagram-cta', galleryIcon_('instagram') + '<span>Find us on Instagram</span>' + galleryIcon_('arrow')) + '</aside>';
  body += '<div class="information-strip"><div>' + galleryIcon_('calendar') + '<p><span>Captured on</span><strong>' + escapeHTML(createdAt) + '</strong></p></div><div>' + galleryIcon_('lock') + '<p><strong>This gallery is private</strong><span>Anyone with the link on your receipt can view it.<br>Save your favourites before closing this page.</span></p></div></div>';
  body += '</main><footer class="site-footer"><div class="footer-inner">' + madeToKeepBrandLockupHTML_('small') + '<span class="footer-tagline">little moments, made to keep.</span><span class="reference">Ref ' + escapeHTML(reference) + '</span>' + galleryIcon_('heart') + '</div></footer>';

  body += '<div class="lightbox" id="lightbox" role="dialog" aria-modal="true" aria-label="Full-size view" hidden>' +
    '<div class="lightbox-bar"><span id="lightboxCount" aria-live="polite"></span><button type="button" class="lightbox-close" id="lightboxClose">Close</button></div>' +
    '<div class="lightbox-stage"><button type="button" class="lightbox-nav" id="lightboxPrev" aria-label="Previous photo">‹</button><img id="lightboxImage" alt=""><button type="button" class="lightbox-nav" id="lightboxNext" aria-label="Next photo">›</button></div>' +
    '<div class="lightbox-bar lightbox-actions"><button type="button" class="lightbox-save" id="lightboxSave">Save Photo</button><button type="button" class="lightbox-share" id="lightboxShare">Share</button></div></div>';

  body += '<p id="message" class="toast" role="status" aria-live="polite"></p>';



  const script = 'const galleryData=' + dataJSON + ';' + galleryClientScript_();

  const html = pageShell_(body, script);

  if (timings) {

    timings.generatedHTMLCharacters = html.length;

    timings.totalDoGetRenderMs = Date.now() - startedAt;

    console.log('Gallery render timings: ' + JSON.stringify(timings) + ' decodedBytes=' + sizeCheck.decodedBytes + ' base64Chars=' + sizeCheck.base64Chars);

  }

  return makeHTML_(html);

}

function makeHTML_(html) {

  return HtmlService.createHtmlOutput(html)

    .setTitle(MADE_TO_KEEP_BRAND.galleryTitle)

    .setXFrameOptionsMode(HtmlService.XFrameOptionsMode.ALLOWALL);

}

function pageShell_(body, script) {

  return '<!doctype html><html lang="en"><head><meta charset="utf-8">' +

    '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">' +

    '<meta name="robots" content="noindex,nofollow"><meta name="referrer" content="no-referrer"><meta name="format-detection" content="telephone=no"><meta name="theme-color" content="#F7F1E9"><base target="_top">' +

    '<title>' + MADE_TO_KEEP_BRAND.galleryTitle + '</title><style>' + galleryCSS_() + '</style></head><body>' +

    body + '<script>' + script + '</script></body></html>';

}

function loadGalleryAssets_(filesByName, manifest, includeGIF, timings) {
  let assetIndex = 0;
  function load(filename, role) {
    return measureGalleryOperation_(timings, 'assetReadBase64' + (assetIndex++) + 'Ms', function() { return loadGalleryAsset_(filesByName, filename, role); });
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

function loadGalleryAsset_(filesByName, filename, role) {

  const file = filesByName && filesByName[filename];

  if (!file) {

    throw publicError_(404, 'Gallery unavailable.', 'rejected', 'GALLERY_NOT_FOUND');

  }

  const blob = file.getBlob();

  return {

    filename: filename,

    role: role,

    mimeType: filename.endsWith('.png') ? 'image/png' : (filename.endsWith('.gif') ? 'image/gif' : 'image/jpeg'),

    base64Data: Utilities.base64Encode(blob.getBytes())

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

function galleryCSS_() {
  // Self-contained editorial paper design; system fonts and local SVG ornaments only.
  return `
:root{color-scheme:light;--paper:#faf6f0;--surface:#fdfaf6;--accent:#74151b;--muted:#78756c;--line:#dfcfc7;--serif:"Bodoni 72",Didot,"Times New Roman",Georgia,serif;--sans:-apple-system,BlinkMacSystemFont,"Segoe UI",Arial,sans-serif;--shadow:0 5px 22px #66503d0c;--gutter:max(20px,env(safe-area-inset-left),env(safe-area-inset-right))}
*{box-sizing:border-box}html{background:var(--paper);-webkit-text-size-adjust:100%;scroll-behavior:smooth;scroll-padding-top:20px}body{margin:0;color:var(--accent);font:15px/1.45 var(--sans);background:radial-gradient(ellipse at 78% 18%,#e7daca66,transparent 36%),radial-gradient(ellipse at 15% 58%,#eee3d54d,transparent 45%),var(--paper);-webkit-font-smoothing:antialiased}p,h1,h2,h3,figure{margin:0}p{color:var(--muted)}button,a{-webkit-tap-highlight-color:transparent}button{font:inherit;color:inherit;cursor:pointer}a{color:inherit;text-decoration:none}img{display:block;max-width:100%}[hidden]{display:none!important}:focus-visible{outline:2px solid var(--accent);outline-offset:4px}.icon{width:19px;height:19px;flex-shrink:0;vertical-align:middle}.btn,.btn-small{display:inline-flex;align-items:center;justify-content:center;gap:9px;min-height:44px;padding:8px 21px;border:1px solid #af8185;border-radius:99px;background:transparent;color:var(--accent);font:500 13px/1.2 var(--sans);text-align:center;cursor:pointer}.primary{background:linear-gradient(145deg,#80151a,#690b10);border-color:var(--accent);color:#fff9f3;box-shadow:0 3px 9px #74151b20}.btn-small{font-size:12px;gap:7px;padding:7px 14px}.btn-small .icon{width:16px;height:16px}.btn:hover,.btn-small:hover{background:#74151b0a}.primary:hover{background:#611017}.image-button{min-height:44px;border:0;padding:0;background:transparent;display:block;min-width:0;cursor:zoom-in}.eyebrow{text-transform:uppercase;letter-spacing:.25em;color:#91585d;font-size:10px;font-weight:600}.brand-lockup{display:inline-grid;justify-items:center;flex-shrink:0;color:var(--accent);line-height:1}.brand-descriptor,.brand-rule{display:none}.brand-wordmark{font:italic 34px/.95 var(--serif);letter-spacing:-.055em;white-space:nowrap}.brand-secondary{font:500 8px/1.8 var(--serif);letter-spacing:.5em;padding-left:.5em}.site-header{border-bottom:1px solid #dfcfc766;background:#fdfaf68c;padding:16px var(--gutter)}.header-inner{position:relative;max-width:1200px;margin:auto;display:flex;align-items:center;gap:28px}.header-divider{height:33px;width:1px;background:var(--line)}.header-label{font-size:10px;letter-spacing:.2em;white-space:nowrap}.header-privacy{display:flex;align-items:center;gap:12px;margin-left:auto}.header-privacy p{font-size:10px;line-height:1.4}.header-privacy strong,.header-privacy span{display:block}.header-privacy strong{color:var(--accent);font-weight:500}.header-share{font-size:12px;padding-inline:18px}.menu-toggle{display:none;border:0;background:transparent;width:44px;height:44px;padding:10px}.gallery-menu{position:absolute;right:0;top:calc(100% + 14px);z-index:10;min-width:220px;padding:10px;background:var(--surface);border:1px solid var(--line);border-radius:10px;box-shadow:0 10px 35px #4b332020}.gallery-menu a,.gallery-menu button{display:flex;align-items:center;text-align:left;width:100%;min-height:44px;padding:10px 14px;border:0;border-radius:5px;background:transparent;font:14px var(--sans)}.gallery-menu a:hover,.gallery-menu button:hover{background:#74151b08}
.gallery-shell{max-width:1100px;margin:auto;padding:0 var(--gutter) 0}.intro{display:grid;grid-template-columns:1fr 1fr;position:relative;min-height:465px;align-items:center;gap:10px;padding:38px 0 32px}.gallery-hero{position:relative;z-index:2;max-width:530px}.gallery-hero h1{font:400 clamp(46px,5.3vw,70px)/.92 var(--serif);letter-spacing:-.055em;margin:23px 0 18px}.gallery-hero h1 em{font-weight:400}.lede{max-width:335px;font-size:17px;letter-spacing:.01em;line-height:1.45}.hero-actions{margin-top:26px;display:grid;justify-items:start;gap:12px}.hero-actions>.primary{min-width:294px;font-size:15px;gap:16px;min-height:48px}.secondary-actions{display:flex;gap:10px}.secondary-actions .btn{font-size:12px;padding-inline:20px}.action-hint{font-size:11px;max-width:340px;line-height:1.5;min-height:0}.action-hint:empty{display:none}
.hero-collage{position:relative;height:400px;width:100%;min-width:0;align-self:center;pointer-events:none}.polaroid{position:absolute;background:#fffdf8;padding:11px 11px 32px;box-shadow:0 8px 20px #5d422423;width:220px;height:304px;z-index:2}.polaroid img{width:100%;height:100%;object-fit:cover;background:#e7ded1}.polaroid-0{left:5px;top:-6px;transform:rotate(-10deg)}.polaroid-1{left:186px;top:112px;width:208px;height:278px;transform:rotate(10deg);z-index:3}.paper-strip{position:absolute;right:35px;top:18px;display:grid;gap:6px;width:116px;padding:22px 10px 12px;background:#fffdf8;box-shadow:0 7px 20px #5d42241c;transform:rotate(13deg)}.paper-strip i{height:82px;background:linear-gradient(145deg,#ac9785,#e7ded3 55%,#b6a390)}.tape{position:absolute;width:82px;height:26px;background:#dec8a382;clip-path:polygon(4% 0,96% 3%,100% 95%,0 100%);z-index:1}.tape-one{top:64px;left:225px;transform:rotate(35deg)}.tape-two{top:305px;left:308px;transform:rotate(36deg)}.botanical{position:absolute;right:-18px;top:110px;width:110px;height:230px;color:#ad8d5c;transform:rotate(8deg)}.collage-count-1 .polaroid-0{left:70px;top:35px;width:230px;height:310px;transform:rotate(-7deg)}
.section-heading{display:flex;gap:16px;align-items:center;margin:0 0 14px;min-width:0}.section-heading:after{content:"";height:1px;background:#bb8f926e;flex:1;margin-left:5px}.section-heading h2{font:400 23px/1 var(--serif);letter-spacing:-.035em;text-transform:uppercase;white-space:nowrap}.section-heading p{font-size:9px;letter-spacing:.2em;text-transform:uppercase;white-space:nowrap}.photo-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:22px}.photo-count-1{max-width:650px;margin:auto}.photo-count-1{grid-template-columns:1fr}.shot{min-width:0;padding:9px 9px 4px;background:#fffdf8cc;border:1px solid #eee6dd;border-radius:8px;box-shadow:var(--shadow)}.shot-frame{width:100%;border-radius:4px;overflow:hidden;background:#eee5d9}.shot-frame img{width:100%;height:auto;max-height:480px;object-fit:contain}.image-placeholder{display:grid;place-items:center;aspect-ratio:4/3;background:linear-gradient(110deg,#eee4d8 30%,#faf5ec 50%,#eee4d8 70%);background-size:220% 100%;animation:shimmer 1.6s ease-in-out infinite;color:#9a8976;font:italic 17px var(--serif)}.shot-actions{display:flex;align-items:center;justify-content:space-between;gap:8px;min-height:55px;padding:3px 2px}.shot-meta{display:grid;gap:3px;min-width:0}.shot-label{font-size:10px;letter-spacing:.18em;text-transform:uppercase;font-weight:600}.shot-date{font-size:8px;letter-spacing:.08em;text-transform:uppercase;color:var(--muted)}.shot-buttons{display:flex;gap:7px;flex-shrink:0}.shot-buttons .btn-small{padding-inline:15px}.receipt-style-status{position:absolute;width:1px;height:1px;padding:0;overflow:hidden;clip-path:inset(50%);white-space:nowrap}.receipt-style{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:14px}.receipt-style button{min-height:44px}.receipt-style [aria-pressed="true"]{background:var(--accent);color:#fffdf8}.receipt-privacy{font-size:12px;line-height:1.5;margin:0 0 14px;color:var(--muted)}.receipt-section{margin-top:26px}.receipt-layout{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px}.receipt-layout-single{grid-template-columns:1fr;max-width:540px}.receipt-card{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,44%);align-items:center;gap:16px;padding:10px 16px 10px 24px;min-width:0;border:1px solid #eee5dd;border-radius:7px;background:#fbf7f16b}.receipt-copy h3{font:400 26px/1.05 var(--serif);letter-spacing:-.04em;margin-bottom:12px}.receipt-copy>p{font-size:12px;max-width:190px;line-height:1.5}.receipt-actions{display:flex;gap:7px;margin-top:20px;flex-wrap:wrap}.receipt-actions .btn-small{padding-inline:13px;font-size:11px;gap:6px}.receipt-frame{justify-self:end;max-width:200px;box-shadow:0 5px 20px #5d42241a;background:white}.receipt-frame img{width:100%;max-height:270px;object-fit:contain}.receipt-frame img.mono-fallback{filter:grayscale(1)}.receipt-placeholder{aspect-ratio:3/5}
.instagram-card{display:flex;align-items:center;gap:22px;margin-top:16px;padding:18px 25px;border:1px solid #d9c4bc;border-radius:9px;background:#f6ece65c}.instagram-emblem{border-right:1px solid #dac6be;padding:2px 23px 2px 7px}.instagram-emblem .icon{width:48px;height:48px;stroke-width:1.5}.instagram-copy{min-width:0}.instagram-copy .eyebrow{font-size:9px}.instagram-copy h2{font:italic 40px/1.05 var(--serif);letter-spacing:-.045em}.instagram-copy>p:last-child{font-size:12px;margin-top:2px}.instagram-cta{margin-left:auto;flex-shrink:0;gap:11px;min-height:44px;padding-inline:22px}.instagram-cta .icon-instagram{display:none}.instagram-cta .icon-arrow{width:16px}.information-strip{display:grid;grid-template-columns:1fr 1fr;gap:28px;padding:15px 45px;margin-top:8px;background:#eee4d855;border-radius:8px}.information-strip>div{display:flex;align-items:center;gap:22px}.information-strip>div+div{border-left:1px solid #bd9895;padding-left:45px}.information-strip .icon{width:25px;height:25px}.information-strip p{font-size:10px;line-height:1.5}.information-strip span,.information-strip strong{display:block}.information-strip strong{color:#905357;font-weight:500}.site-footer{margin-top:0;border-top:1px solid #dfcfc766;padding:16px var(--gutter) calc(16px + env(safe-area-inset-bottom))}.footer-inner{max-width:1200px;margin:auto;display:flex;align-items:center;gap:24px}.site-footer .brand-wordmark{font-size:27px}.site-footer .brand-secondary{font-size:6px}.footer-tagline{border-left:1px solid #c7a6a3;padding-left:24px;font:500 10px var(--serif);letter-spacing:.09em}.reference{margin-left:auto;font-size:8px;letter-spacing:.08em;color:#a19b90}.site-footer .icon-heart{width:13px;height:13px;fill:var(--accent);stroke:0}
.toast{position:fixed;bottom:calc(20px + env(safe-area-inset-bottom));left:50%;transform:translate(-50%,12px);z-index:50;width:max-content;max-width:calc(100% - 32px);padding:14px 20px;border-radius:12px;background:#fffdf8;color:var(--accent);box-shadow:0 5px 30px #3d261b33;font-size:14px;opacity:0;pointer-events:none;transition:opacity .2s,transform .2s}.toast.visible{opacity:1;transform:translate(-50%,0)}.lightbox{position:fixed;inset:0;width:100%;z-index:40;background:#271c19f5;color:#fff9f3;padding:calc(12px + env(safe-area-inset-top)) var(--gutter) calc(18px + env(safe-area-inset-bottom));display:grid;grid-template-rows:auto minmax(0,1fr) auto;gap:12px}.lightbox-bar{display:flex;align-items:center;justify-content:space-between;gap:16px;min-height:48px;font-size:13px}.lightbox-bar button{min-height:44px;padding:8px 20px;border:1px solid #fff9f388;border-radius:99px;color:inherit;background:transparent}.lightbox-actions{justify-content:center}.lightbox-stage{position:relative;min-width:0;min-height:0;overflow:hidden}.lightbox-stage img{position:absolute;inset:0;width:100%;height:100%;min-width:0;min-height:0;object-fit:contain;object-position:center}.lightbox-nav{position:absolute;z-index:1;top:50%;transform:translateY(-50%);width:48px;height:64px;border:0;border-radius:99px;background:#fff9f324;color:inherit;font-size:34px}#lightboxPrev{left:0}#lightboxNext{right:0}.center-page{min-height:100vh;display:grid;place-items:center;padding:var(--gutter)}.notice{max-width:460px;display:grid;justify-items:center;gap:18px;text-align:center;padding:38px 26px;background:#fffaf4;border:1px solid var(--line);border-radius:8px}.notice h1{font:italic 38px/1.05 var(--serif)}.notice-footnote{font-size:13px}.loader{width:30px;height:30px;border:2px solid var(--line);border-top-color:var(--accent);border-radius:50%;animation:spin 1s linear infinite}@keyframes spin{to{transform:rotate(360deg)}}@keyframes shimmer{from{background-position:120% 0}to{background-position:-120% 0}}
@media(min-width:1200px){.photo-count-3,.photo-count-6{grid-template-columns:repeat(3,minmax(0,1fr))}.photo-count-3 .shot-actions,.photo-count-6 .shot-actions{flex-wrap:wrap}.photo-count-3 .shot-buttons,.photo-count-6 .shot-buttons{margin-left:auto}}
@media(max-width:1050px) and (min-width:701px){.header-inner{gap:18px}.intro{min-height:430px}.hero-collage{transform:scale(.82);transform-origin:30% 50%}.gallery-hero h1{font-size:57px}.instagram-copy h2{font-size:34px}.instagram-card{gap:16px;padding:16px}.instagram-emblem{padding-right:16px}.instagram-cta{font-size:12px;padding-inline:16px}.receipt-card{padding-left:18px;gap:10px}.receipt-copy h3{font-size:24px}.receipt-actions{margin-top:14px}}
@media(max-width:700px){:root{--gutter:max(20px,env(safe-area-inset-left),env(safe-area-inset-right))}.site-header{padding-top:calc(13px + env(safe-area-inset-top));padding-bottom:13px}.header-inner{gap:17px}.brand-wordmark{font-size:29px}.brand-secondary{font-size:7px}.header-divider{height:30px}.header-label{display:none}.header-privacy{gap:9px;margin-left:auto}.header-privacy .icon{width:18px}.header-privacy p{font-size:8px;max-width:125px}.header-privacy strong{font-size:10px}.header-privacy strong{font-size:0}.header-privacy strong:after{content:"Private Gallery";font-size:10px}.header-share{display:none}.menu-toggle{display:block;margin-right:-10px;flex-shrink:0}.intro{display:block;min-height:330px;padding:30px 0 24px}.gallery-hero{max-width:none}.gallery-hero>.eyebrow{font-size:8px;letter-spacing:.22em}.gallery-hero h1{font-size:clamp(32px,8.5vw,48px);margin:14px 0 10px;width:66%;line-height:.97}.lede{font-size:13px;width:58%;max-width:270px;line-height:1.45}.hero-actions{margin-top:20px;width:57%;gap:9px}.hero-actions>.primary{width:100%;min-width:0;min-height:44px;font-size:12px;padding-inline:10px;gap:9px}.secondary-actions{width:100%}.secondary-actions .btn{width:100%;font-size:12px;padding-inline:8px}.receipt-jump{display:none}.action-hint{font-size:10px;line-height:1.4}.hero-collage{position:absolute;width:40%;height:260px;right:-4px;top:6px;z-index:1}.polaroid{padding:6px 6px 22px;width:112px;height:157px}.polaroid-0{left:-10px;top:0;transform:rotate(-11deg)}.polaroid-1{width:112px;height:150px;left:22px;top:90px;transform:rotate(12deg)}.paper-strip{right:12px;top:25px;width:65px;padding:13px 6px 6px;gap:4px}.paper-strip i{height:39px}.tape{width:42px;height:17px}.tape-one{left:90px;top:34px}.tape-two{left:38px;top:205px}.botanical{right:0;top:0;width:60px;height:125px}.collage-count-1 .polaroid-0{left:5px;top:22px;width:128px;height:182px}.section-heading{gap:12px;margin-bottom:11px}.section-heading h2{font-size:19px}.section-heading p{font-size:8px;letter-spacing:.16em}.section-heading:after{margin-left:0}.photo-grid{grid-template-columns:1fr;gap:12px}.shot{padding:6px 6px 2px;border-radius:7px}.shot-frame img{max-height:440px}.shot-actions{min-height:52px;padding-inline:4px;gap:5px}.shot-label{font-size:9px}.shot-date{font-size:8px;letter-spacing:.02em}.shot-buttons{gap:5px}.shot-buttons .btn-small{font-size:10px;padding-inline:11px;gap:6px}.shot-buttons .icon{width:15px}.receipt-section{margin-top:22px}.receipt-layout{gap:9px}.receipt-card{padding:10px 8px;gap:7px;grid-template-columns:minmax(0,1fr) minmax(0,43%);align-items:center}.receipt-copy h3{font-size:19px;margin-bottom:8px;line-height:1.05}.receipt-copy>p{font-size:10px;line-height:1.45}.receipt-actions{flex-direction:column;gap:5px;margin-top:10px;align-items:flex-start}.receipt-actions .btn-small{font-size:10px;padding:6px 10px;gap:6px;min-width:84px}.receipt-save-label{display:none}.receipt-frame img{max-height:210px}.instagram-card{display:grid;grid-template-columns:44px minmax(0,1fr);gap:6px 12px;padding:14px 12px;margin-top:12px;background:#f6e9e36b}.instagram-emblem{grid-row:1/3;border:0;padding:8px;background:#fffaf5;border-radius:50%;display:grid;place-items:center;width:44px;height:44px;align-self:start}.instagram-emblem .icon{width:30px;height:30px}.instagram-copy .eyebrow{font-size:7px}.instagram-copy h2{font-size:28px;line-height:1.1}.instagram-copy>p:last-child{font-size:10px;margin-top:3px}.instagram-cta{grid-column:2;justify-self:start;margin:5px 0 0;padding:7px 13px;font-size:11px;gap:7px}.instagram-cta .icon-instagram{display:block;width:15px}.instagram-cta .icon-arrow{width:13px}.information-strip{gap:12px;padding:13px 12px;margin-top:8px;grid-template-columns:.95fr 1.05fr}.information-strip>div{align-items:flex-start;gap:11px}.information-strip>div+div{padding-left:14px}.information-strip .icon{width:20px;height:20px}.information-strip p{font-size:8px;line-height:1.45}.information-strip strong{font-size:9px}.site-footer{padding-top:12px;padding-bottom:calc(12px + env(safe-area-inset-bottom))}.footer-inner{gap:12px;flex-wrap:wrap}.site-footer .brand-wordmark{font-size:22px}.site-footer .brand-secondary{font-size:5px}.footer-tagline{font-size:7px;padding-left:12px;letter-spacing:.06em}.reference{font-size:6px}.site-footer .icon-heart{width:10px}.toast{font-size:12px}}
@media(min-width:480px) and (max-width:700px){.intro{min-height:345px}.hero-collage{right:12px;top:15px;transform:scale(1.16);transform-origin:70% 0}.gallery-hero h1{font-size:46px}.lede{font-size:15px}.hero-actions .btn{font-size:14px}.instagram-card{grid-template-columns:48px minmax(0,1fr) auto;align-items:center}.instagram-emblem{grid-row:1}.instagram-cta{grid-column:3;margin:0}.instagram-copy h2{font-size:28px}.instagram-copy>p:last-child{max-width:230px}.instagram-cta .icon-instagram{display:none}}
@media(max-width:399px){.receipt-layout{grid-template-columns:1fr}.receipt-card{padding:14px 18px;grid-template-columns:1fr 40%;gap:18px}.receipt-copy h3{font-size:25px}.receipt-copy>p{font-size:12px}.receipt-actions{flex-direction:row;flex-wrap:wrap}.receipt-frame img{max-height:210px}}
@media(max-width:374px){.polaroid-1{left:8px}.collage-count-1 .polaroid-0{left:-3px}:root{--gutter:max(14px,env(safe-area-inset-left),env(safe-area-inset-right))}.header-inner{gap:10px}.brand-wordmark{font-size:25px}.header-privacy p{max-width:100px}.header-privacy span{font-size:7px}.intro{padding-top:26px;min-height:325px}.hero-collage{transform:scale(.83);transform-origin:60% 0}.gallery-hero h1{font-size:30px;width:70%}.hero-actions{width:62%;margin-top:16px}.lede{width:60%;font-size:12px}.hero-actions>.primary{font-size:11px;gap:6px}.receipt-layout{grid-template-columns:1fr}.receipt-card{padding:12px 16px;grid-template-columns:1fr 40%;gap:18px}.receipt-copy h3{font-size:25px}.receipt-copy>p{font-size:12px}.receipt-actions{flex-direction:row;flex-wrap:wrap}.receipt-frame img{max-height:210px}.shot-date{font-size:8px;max-width:118px}.shot-buttons .btn-small{padding-inline:9px}.footer-tagline{font-size:6px}.footer-inner{display:grid;grid-template-columns:auto minmax(0,1fr) 10px;gap:6px 12px}.site-footer .brand-lockup{grid-row:1/3}.footer-tagline{grid-column:2/4}.reference{grid-column:2;justify-self:end;margin-left:0}.site-footer .icon-heart{grid-column:3}.information-strip{grid-template-columns:1fr;gap:10px}.information-strip>div+div{border-left:0;border-top:1px solid #dfcfc7;padding:10px 0 0}.information-strip p,.information-strip strong{font-size:10px}}
@media(prefers-reduced-motion:reduce){*,*:before,*:after{animation:none!important;transition:none!important;scroll-behavior:auto!important}}
`;
}

function galleryClientScript_() {
  // Everything is embedded in the page: no Drive links (so never a Google sign-in), no per-image
  // script calls and no third-party requests. Files keep their original names and MIME types, so
  // saves retain original image bytes. Unsupported browser features get honest, actionable fallbacks.
  return `
const startedAt=performance.now();
const files=[...galleryData.photos,galleryData.receipt,galleryData.thermalReceipt,galleryData.shareColorReceipt].filter(Boolean);
const assetMap=new Map(files.map(function(item){return [item.filename,item];}));
const shareBW=galleryData.shareColorReceipt?{filename:"receipt-share-bw.png",mimeType:"image/png",role:"thermalReceipt",deriveFrom:galleryData.shareColorReceipt.filename}:null;
if(shareBW){assetMap.set(shareBW.filename,shareBW);}
let receiptSelectionRevision=0;
const realFileCache=new Map();
const photoItems=galleryData.photos.slice();
const ua=navigator.userAgent||"";
const isIOS=/iPad|iPhone|iPod/.test(ua)||(navigator.platform==="MacIntel"&&navigator.maxTouchPoints>1);
const isAndroid=/Android/i.test(ua);
const prefersReducedMotion=!!(window.matchMedia&&window.matchMedia("(prefers-reduced-motion: reduce)").matches);
const message=document.getElementById("message");
let toastTimer=null;let activeLightboxURL="";let lightboxItems=[];let lightboxIndex=0;let lastFocus=null;let touchStartX=null;
function setMessage(text){if(!message){return;}clearTimeout(toastTimer);message.textContent=text||"";message.classList.toggle("visible",!!text);if(text){toastTimer=setTimeout(function(){message.classList.remove("visible");},7000);}}
function dataURL(item){return "data:"+item.mimeType+";base64,"+item.base64Data;}
// Historical galleries: a smooth black & white PNG derived on this device from the color receipt,
// using the booth's luma weights and tone curve. The legacy printer raster never reaches the page.
const monoCurve=(function(){const curve=new Uint8ClampedArray(256);for(let v=0;v<256;v++){curve[v]=Math.round((v-127.5)*1.05+127.5);}return curve;})();
const derivedFiles=new Map();
const receiptPreviewURLs=new Map();
function receiptPreviewURL(item,file){if(!receiptPreviewURLs.has(item.filename)){receiptPreviewURLs.set(item.filename,URL.createObjectURL(file));}return receiptPreviewURLs.get(item.filename);}
window.addEventListener("pagehide",function(){receiptPreviewURLs.forEach(function(url){URL.revokeObjectURL(url);});receiptPreviewURLs.clear();});
function needsDerivation(item){return !!(item&&item.deriveFrom&&!item.base64Data);}
function isReady(item){return !needsDerivation(item)||realFileCache.has(item.filename);}
function deriveMonochrome(item){if(derivedFiles.has(item.filename)){return derivedFiles.get(item.filename);}const source=findItem(item.deriveFrom);const promise=new Promise(function(resolve,reject){if(!source||!source.base64Data){reject(new Error("Color receipt unavailable"));return;}const image=new Image();image.onload=function(){try{const width=image.naturalWidth;const height=image.naturalHeight;const canvas=document.createElement("canvas");canvas.width=width;canvas.height=height;const context=canvas.getContext("2d",{willReadFrequently:true});context.fillStyle="#fff";context.fillRect(0,0,width,height);context.drawImage(image,0,0);const pixels=context.getImageData(0,0,width,height);const data=pixels.data;for(let i=0;i<data.length;i+=4){const gray=monoCurve[Math.min(255,(54*data[i]+183*data[i+1]+19*data[i+2]+128)>>8)];data[i]=gray;data[i+1]=gray;data[i+2]=gray;data[i+3]=255;}context.putImageData(pixels,0,0);canvas.toBlob(function(blob){canvas.width=0;canvas.height=0;if(!blob){reject(new Error("PNG encoding failed"));return;}const file=new File([blob],item.filename,{type:"image/png"});realFileCache.set(item.filename,file);resolve(file);},"image/png");}catch(error){reject(error);}};image.onerror=function(){reject(new Error("Color receipt decode failed"));};image.src=dataURL(source);});derivedFiles.set(item.filename,promise);return promise;}
function whenReady(item,action){const revision=receiptSelectionRevision;const originalAction=action;action=function(){if(item.role==="photo"||revision===receiptSelectionRevision){originalAction();}};if(isReady(item)){action();return;}if(item.unavailable){setMessage("The black & white receipt couldn’t be prepared on this device. Please save the color receipt instead.");return;}setMessage("Preparing your black & white receipt…");deriveMonochrome(item).then(function(){setMessage("");action();},function(){setMessage("The black & white receipt couldn’t be prepared on this device. Please save the color receipt instead.");});}
// Keep the measured placeholder until the actual image loads. A data/blob URL is still
// decoded asynchronously; removing the placeholder on src assignment collapses touch targets.
function showLoadedImage(image,placeholder,source){let shown=false;function show(){if(shown){return;}shown=true;image.hidden=false;if(placeholder){placeholder.remove();}}image.addEventListener("load",show,{once:true});image.addEventListener("error",function(){if(placeholder){placeholder.textContent="Preview unavailable — use Save.";}},{once:true});image.loading="eager";image.src=source;if(image.complete&&image.naturalWidth>0){show();}}
function revealDerived(item,image,placeholder){deriveMonochrome(item).then(function(file){showLoadedImage(image,placeholder,receiptPreviewURL(item,file));},function(){item.unavailable=true;const source=findItem(item.deriveFrom);if(source&&source.base64Data){image.classList.add("mono-fallback");showLoadedImage(image,placeholder,dataURL(source));}document.querySelectorAll('[data-download="'+item.filename+'"],[data-share="'+item.filename+'"]').forEach(function(button){button.hidden=true;});});}
function fileForItem(item){if(realFileCache.has(item.filename)){return realFileCache.get(item.filename);}if(needsDerivation(item)){throw new Error("Black & white receipt is still being prepared");}const binary=atob(item.base64Data);const bytes=new Uint8Array(binary.length);for(let i=0;i<binary.length;i++){bytes[i]=binary.charCodeAt(i);}const file=new File([bytes],item.filename,{type:item.mimeType});realFileCache.set(item.filename,file);return file;}
function objectURLFor(item){return URL.createObjectURL(fileForItem(item));}
function findItem(filename){return assetMap.get(filename);}
function roleText(item){if(item.role==="colorReceipt"){return {name:"color receipt",alt:"Made to Keep Studios color receipt",save:"Save Receipt"};}if(item.role==="thermalReceipt"){return {name:"black & white receipt",alt:"Made to Keep Studios black and white receipt",save:"Save Receipt"};}return {name:"photo",alt:"Made to Keep Studios photo",save:"Save Photo"};}
function revealItem(item){const image=document.getElementById("image-"+item.filename);const placeholder=document.getElementById("placeholder-"+item.filename);if(image&&needsDerivation(item)){if(!image.getAttribute("src")){revealDerived(item,image,placeholder);}return;}if(image&&!image.getAttribute("src")){showLoadedImage(image,placeholder,dataURL(item));document.querySelectorAll("[data-collage]").forEach(function(copy){if(copy.getAttribute("data-collage")===item.filename){copy.src=image.src;}});}}
function supportsFileShare(item){if(!navigator.share||!navigator.canShare||!item){return false;}try{return navigator.canShare({files:[new File([new Uint8Array([1])],item.filename,{type:item.mimeType})]});}catch(error){return false;}}
function supportsMultipleFileShare(){if(!navigator.share||!navigator.canShare){return false;}try{return navigator.canShare({files:[new File([new Uint8Array([1])],"photo-01.jpg",{type:"image/jpeg"}),new File([new Uint8Array([2])],"photo-02.jpg",{type:"image/jpeg"})]});}catch(error){return false;}}
function downloadItem(item,quiet){try{const url=objectURLFor(item);const a=document.createElement("a");a.href=url;a.download=item.filename;a.rel="noopener";document.body.appendChild(a);a.click();a.remove();setTimeout(function(){URL.revokeObjectURL(url);},30000);if(!quiet){setMessage(isIOS?"Downloading to Files › Downloads. To add it to Photos, use Share and choose Save Image.":"Download started: "+item.filename);}return true;}catch(error){setMessage("We couldn’t start that download. Please try again.");return false;}}
async function shareFiles(items,intentMessage){try{await navigator.share({files:items.map(fileForItem),title:"Made to Keep Studios"});if(intentMessage){setMessage("");}}catch(error){if(error&&error.name==="AbortError"){setMessage("");return;}if(items.length===1){downloadItem(items[0]);}else{setMessage("Sharing didn’t work here. Please save each photo below.");}}}
function shareItem(item){if(!supportsFileShare(item)){downloadItem(item);return;}shareFiles([item]);}
function saveItem(item){if(isIOS&&supportsFileShare(item)){setMessage("Choose Save Image to add it to Photos.");shareFiles([item],true);return;}downloadItem(item);}
function showLightboxItem(){const item=lightboxItems[lightboxIndex];if(!item){return;}const image=document.getElementById("lightboxImage");const save=document.getElementById("lightboxSave");const share=document.getElementById("lightboxShare");const count=document.getElementById("lightboxCount");const text=roleText(item);if(activeLightboxURL){URL.revokeObjectURL(activeLightboxURL);}activeLightboxURL=URL.createObjectURL(fileForItem(item));image.src=activeLightboxURL;image.alt=text.alt+(item.role==="photo"?" "+(lightboxIndex+1):"");save.textContent=text.save;share.hidden=false;count.textContent=lightboxItems.length>1?(lightboxIndex+1)+" / "+lightboxItems.length:text.name;document.getElementById("lightboxPrev").hidden=lightboxItems.length<2;document.getElementById("lightboxNext").hidden=lightboxItems.length<2;}
function fitLightboxViewport(){const lightbox=document.getElementById("lightbox");if(!lightbox||lightbox.hidden){return;}const viewport=window.visualViewport;const height=viewport&&viewport.height>0?Math.min(window.innerHeight,viewport.height):window.innerHeight;lightbox.style.height=Math.floor(height)+"px";}
function openFullSize(item){try{const lightbox=document.getElementById("lightbox");if(!lightbox){const url=objectURLFor(item);window.open(url,"_blank","noopener");setTimeout(function(){URL.revokeObjectURL(url);},30000);return;}lastFocus=document.activeElement;lightboxItems=item.role==="photo"?photoItems:[item];lightboxIndex=Math.max(0,lightboxItems.indexOf(item));showLightboxItem();lightbox.hidden=false;fitLightboxViewport();document.querySelectorAll(".site-header,.gallery-shell,.site-footer").forEach(function(el){el.inert=true;});document.body.style.overflow="hidden";document.getElementById("lightboxClose").focus();}catch(error){setMessage("We couldn’t open the full-size image. Please use Save instead.");}}
function stepLightbox(offset){if(lightboxItems.length<2){return;}lightboxIndex=(lightboxIndex+offset+lightboxItems.length)%lightboxItems.length;showLightboxItem();}
function closeLightbox(){const lightbox=document.getElementById("lightbox");const image=document.getElementById("lightboxImage");if(!lightbox||lightbox.hidden){return;}lightbox.hidden=true;document.querySelectorAll(".site-header,.gallery-shell,.site-footer").forEach(function(el){el.inert=false;});if(image){image.removeAttribute("src");}document.body.style.overflow="";if(activeLightboxURL){URL.revokeObjectURL(activeLightboxURL);activeLightboxURL="";}lightboxItems=[];if(lastFocus&&lastFocus.focus){lastFocus.focus();}}
function wireLightbox(){const lightbox=document.getElementById("lightbox");if(!lightbox){return;}window.addEventListener("resize",fitLightboxViewport);if(window.visualViewport){window.visualViewport.addEventListener("resize",fitLightboxViewport);}document.getElementById("lightboxClose").addEventListener("click",closeLightbox);document.getElementById("lightboxPrev").addEventListener("click",function(){stepLightbox(-1);});document.getElementById("lightboxNext").addEventListener("click",function(){stepLightbox(1);});document.getElementById("lightboxSave").addEventListener("click",function(){const item=lightboxItems[lightboxIndex];if(item){saveItem(item);}});document.getElementById("lightboxShare").addEventListener("click",function(){const item=lightboxItems[lightboxIndex];if(item){shareItem(item);}});lightbox.addEventListener("click",function(event){if(event.target===lightbox||event.target.classList.contains("lightbox-stage")){closeLightbox();}});lightbox.addEventListener("touchstart",function(event){touchStartX=event.touches[0].clientX;},{passive:true});lightbox.addEventListener("touchend",function(event){if(touchStartX===null){return;}const dx=event.changedTouches[0].clientX-touchStartX;touchStartX=null;if(Math.abs(dx)>50){stepLightbox(dx<0?1:-1);}},{passive:true});document.addEventListener("keydown",function(event){if(lightbox.hidden){return;}if(event.key==="Tab"){const controls=Array.from(lightbox.querySelectorAll("button:not([hidden])")).filter(function(b){return b.getBoundingClientRect().width>0;});const first=controls[0];const last=controls[controls.length-1];if(event.shiftKey&&document.activeElement===first){event.preventDefault();last.focus();}else if(!event.shiftKey&&document.activeElement===last){event.preventDefault();first.focus();}}else if(event.key==="Escape"){closeLightbox();}else if(event.key==="ArrowLeft"){stepLightbox(-1);}else if(event.key==="ArrowRight"){stepLightbox(1);}});}
function wireOpenButtons(){document.querySelectorAll("[data-open]").forEach(function(button){button.addEventListener("click",function(){const item=findItem(button.getAttribute("data-open"));if(item){whenReady(item,function(){openFullSize(item);});}});});}
function wireSaveButtons(){document.querySelectorAll("[data-download]").forEach(function(button){button.addEventListener("click",function(){const item=findItem(button.getAttribute("data-download"));if(item){whenReady(item,function(){saveItem(item);});}});});}
function wireShareButtons(){document.querySelectorAll("[data-share]").forEach(function(button){const item=findItem(button.getAttribute("data-share"));if(!item){button.hidden=true;return;}button.addEventListener("click",function(){const selected=findItem(button.getAttribute("data-share"));whenReady(selected,function(){shareItem(selected);});});});}
function wireShareAll(){const shareAll=document.getElementById("shareAll");const allHint=document.getElementById("allHint");if(!shareAll){return;}const photos=photoItems.map(function(file){return findItem(file.filename);}).filter(Boolean);const count=photos.length;if(count===1){shareAll.addEventListener("click",function(){saveItem(photos[0]);});return;}if(count<1){shareAll.hidden=true;return;}if((isIOS||isAndroid)&&supportsMultipleFileShare()){if(allHint){allHint.textContent=isIOS?"Opens the share sheet. Choose Save "+count+" Images to add them to Photos.":"Opens the share sheet to save or send all "+count+" photos.";}shareAll.addEventListener("click",function(){shareFiles(photos,true);});return;}if(!isIOS){if(allHint){allHint.textContent="Downloads all "+count+" photos to this device.";}shareAll.addEventListener("click",function(){setMessage("Downloading "+count+" photos. Your browser may ask to allow multiple downloads.");photos.forEach(function(item,index){setTimeout(function(){downloadItem(item,true);},index*450);});});return;}if(allHint){allHint.textContent="Use Save under each photo to add it to Photos.";}shareAll.addEventListener("click",function(){document.getElementById("photos").scrollIntoView({behavior:prefersReducedMotion?"auto":"smooth"});const first=document.querySelector("[data-download]");if(first){first.focus({preventScroll:true});}setMessage("This browser saves one photo at a time. Use Save under each photo.");});}


function currentGalleryURL(){const url=new URL(window.location.href);const token=url.searchParams.get("g");url.search="";url.hash="";if(token&&/^[a-f0-9]{64}$/.test(token)){url.searchParams.set("g",token);}return url.href;}
async function shareGallery(){const url=currentGalleryURL();const privacy="Anyone with this link can view your gallery.";if(navigator.share){try{await navigator.share({title:"Made to Keep Studios",text:privacy,url:url});return;}catch(error){if(error&&error.name==="AbortError"){return;}}}try{if(!navigator.clipboard||!navigator.clipboard.writeText){throw new Error("Clipboard unavailable");}await navigator.clipboard.writeText(url);setMessage("Gallery link copied. "+privacy);}catch(error){window.prompt("Copy your gallery link. "+privacy,url);}}
function wireGalleryNavigation(){const toggle=document.getElementById("menuToggle");const menu=document.getElementById("galleryMenu");function closeMenu(returnFocus){if(!toggle||!menu){return;}menu.hidden=true;toggle.setAttribute("aria-expanded","false");toggle.setAttribute("aria-label","Open gallery menu");if(returnFocus){toggle.focus();}}if(toggle&&menu){toggle.addEventListener("click",function(){const open=menu.hidden;menu.hidden=!open;toggle.setAttribute("aria-expanded",String(open));toggle.setAttribute("aria-label",open?"Close gallery menu":"Open gallery menu");if(open){menu.querySelector("a").focus();}});menu.addEventListener("click",function(event){if(event.target.closest("a,button")){closeMenu(false);}});document.addEventListener("click",function(event){if(!menu.hidden&&!menu.contains(event.target)&&!toggle.contains(event.target)){closeMenu(false);}});document.addEventListener("keydown",function(event){if(event.key==="Escape"&&!menu.hidden){event.preventDefault();closeMenu(true);}});document.addEventListener("focusin",function(event){if(!menu.hidden&&!menu.contains(event.target)&&!toggle.contains(event.target)){closeMenu(false);}});}document.querySelectorAll("[data-share-gallery]").forEach(function(button){button.addEventListener("click",shareGallery);});}

function wireReceiptStyles(){
 if(!galleryData.receiptVariants){return;}
 const cards=Array.from(document.querySelectorAll(".receipt-layout article"));
 const slots=cards.map(function(card){return {card:card,placeholder:card.querySelector(".image-placeholder").cloneNode(true)};});
 const buttons=Array.from(document.querySelectorAll("[data-receipt-style]"));
 async function select(style){
  const revision=++receiptSelectionRevision;
  const useShare=style==="shareFriendly"&&!!galleryData.shareColorReceipt;
  const items=useShare?[galleryData.shareColorReceipt,shareBW]:[galleryData.receipt,galleryData.thermalReceipt];
  buttons.forEach(function(button){button.setAttribute("aria-pressed",String(button.dataset.receiptStyle===style));});
  const privacy=document.getElementById("receiptPrivacy");if(privacy){privacy.hidden=useShare;}
  const status=document.getElementById("receiptStyleStatus");if(status){status.textContent="Preparing receipt previews…";}
  slots.forEach(function(slot,index){
   const item=items[index];if(!item){return;}
   const old=slot.card.querySelector("img");const image=old.cloneNode(false);image.removeAttribute("src");image.hidden=true;image.id="image-"+item.filename;old.replaceWith(image);
   const existing=slot.card.querySelector(".image-placeholder");if(existing){existing.remove();}
   const placeholder=slot.placeholder.cloneNode(true);placeholder.id="placeholder-"+item.filename;image.before(placeholder);
   slot.card.querySelectorAll("[data-open],[data-download],[data-share]").forEach(function(button){["data-open","data-download","data-share"].forEach(function(key){if(button.hasAttribute(key)){button.setAttribute(key,item.filename);}});button.disabled=true;});
  });
  try{
   await Promise.all(items.filter(Boolean).map(function(item){return needsDerivation(item)?deriveMonochrome(item):Promise.resolve(fileForItem(item));}));
   if(revision!==receiptSelectionRevision){return;}
   await Promise.all(items.filter(Boolean).map(function(item){return new Promise(function(resolve,reject){const preview=new Image();preview.onload=resolve;preview.onerror=reject;preview.src=needsDerivation(item)?URL.createObjectURL(fileForItem(item)):dataURL(item);preview.addEventListener("load",function(){if(needsDerivation(item)){URL.revokeObjectURL(preview.src);}}, {once:true});});}));
   if(revision!==receiptSelectionRevision){return;}
   items.forEach(function(item){if(item){revealItem(item);}});
   slots.forEach(function(slot){slot.card.querySelectorAll("button").forEach(function(button){button.disabled=false;});});
   if(status){status.textContent=(useShare?"Share-Friendly":"As Printed")+" receipts selected.";}
  }catch(error){if(revision!==receiptSelectionRevision){return;}slots.forEach(function(slot){const placeholder=slot.card.querySelector(".image-placeholder");if(placeholder){placeholder.textContent="This receipt preview is unavailable. Try selecting the style again.";}});if(status){status.textContent="Receipt unavailable. Please try again.";}}
 }
 buttons.forEach(function(button){button.addEventListener("click",function(){select(button.dataset.receiptStyle);});});
 select(galleryData.receiptVariants.defaultStyle);
}

function showEmbeddedImages(){try{const ordered=photoItems.concat(galleryData.receiptVariants?[]:[galleryData.receipt,galleryData.thermalReceipt].filter(Boolean));if(ordered.length){revealItem(ordered[0]);}const remaining=ordered.slice(1);const reveal=function(){remaining.forEach(revealItem);};if("requestIdleCallback" in window){requestIdleCallback(reveal,{timeout:1200});}else{setTimeout(reveal,40);}wireOpenButtons();wireSaveButtons();wireShareButtons();wireShareAll();wireLightbox();wireGalleryNavigation();wireReceiptStyles();logSafeBrowserTiming();}catch(error){setMessage("Some images didn’t load. Refresh this page to try again.");}}
function logSafeBrowserTiming(){setTimeout(function(){console.log("Made to Keep gallery timing: imageInitializationMs="+Math.round(performance.now()-startedAt)+" webShare="+!!navigator.share+" singleFileShare="+supportsFileShare(photoItems[0])+" multiFileShare="+supportsMultipleFileShare()+" realFileConversionsAtInit=0");},0);}
showEmbeddedImages();
`;
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
