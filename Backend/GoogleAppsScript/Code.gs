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
const GIF_FILENAME = 'session.gif';

const MANIFEST_FILENAME = 'manifest.json';

const MAX_REQUEST_BYTES = 9 * 1024 * 1024;

const MAX_GALLERY_DECODED_BYTES = 6 * 1024 * 1024;

const MAX_GALLERY_BASE64_CHARS = 9 * 1024 * 1024;

const BACKEND_VERSION = 'made-to-keep-gallery-v3-stills-20261016';

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
    const validation = validateUploadPayload_(body);
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
    const root = getRootFolder_();

    // Serialize only the Drive/idempotency mutation section.
    stage = 'ACQUIRE_GALLERY_LOCK';
    lock = LockService.getScriptLock();
    if (!lock.tryLock(20000)) {
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

    stage = 'CREATE_OR_RETURN_GALLERY';
    const result = createOrReturnGallery_(root, body);

    // Release before URL construction/response work so a configuration
    // error cannot unnecessarily block the next upload.
    lock.releaseLock();
    lockHeld = false;

    stage = 'MAKE_SUCCESS_RESPONSE';
    return jsonResponse(200, {
      ok: true,
      schemaVersion: body.schemaVersion,
      galleryToken: body.galleryToken,
      galleryURL: makeGalleryURL_(body.galleryToken),
      fileCount: result.fileCount,
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
    if (lockHeld && lock) {
      try {
        lock.releaseLock();
      } catch (releaseError) {
        console.error('Failed to release upload lock: ' + safeErrorMessage_(releaseError));
      }
    }
  }
}

function doGet(e) {

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

  console.log('Raw gallery proxy response generated. token=' +
    redactToken_(token) +
    ' htmlCharacters=' + rawHTML.length);

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

  wrongSchema.schemaVersion = 3;

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

  assert_(script.indexOf('canvas') === -1, 'Gallery client must not flatten animated GIFs through canvas conversion.');

}

function getGalleryImage(token, filename) {

  if (!GALLERY_TOKEN_PATTERN.test(String(token || ''))) {

    throw new Error('Gallery not found.');

  }

  if (expectedFilenames_(MAX_PHOTO_COUNT, 2).indexOf(String(filename || '')) === -1) {

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

  return 'data:image/jpeg;base64,' + Utilities.base64Encode(file.getBlob().getBytes());

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

  if (body.schemaVersion !== 1 && body.schemaVersion !== 2) {

    return validationError_('INVALID_SCHEMA_VERSION', 'Unsupported schema version.', 'schemaVersion');

  }

  const versionFields = body.schemaVersion === 1 ? ['receipt'] : ['colorReceipt', 'thermalReceipt'];
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

  if (body.schemaVersion === 2) {
    const colorError = validateImage_(body.colorReceipt, RECEIPT_FILENAME, 'colorReceipt', 'image/jpeg');
    if (!colorError.ok) return colorError;
    const thermalError = validateImage_(body.thermalReceipt, THERMAL_RECEIPT_FILENAME, 'thermalReceipt', 'image/png');
    if (!thermalError.ok) return thermalError;
    validatedImages.push(colorError.image, thermalError.image);
    if (body.gif !== undefined && body.gif !== null) {
      const gifError = validateImage_(body.gif, GIF_FILENAME, 'gif', 'image/gif');
      if (!gifError.ok) return gifError;
      validatedImages.push(gifError.image);
    }
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
  const wireImages = body.photos.concat(body.schemaVersion === 2
    ? [body.colorReceipt, body.thermalReceipt].concat(body.gif ? [body.gif] : [])
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

function createOrReturnGallery_(root, body) {

  const folderName = 'gallery-' + body.galleryToken;
  const expected = expectedFilenames_(body.photos.length, body.schemaVersion, !!body.gif);
  const expectedFileCount = expected.length + 1;

  const folders = collectFoldersByName_(root, folderName);

  if (folders.length > 1) {

    console.error('Multiple gallery folders found for token ' + redactToken_(body.galleryToken) + '. Manual inspection required.');

    throw publicError_(409, 'Multiple matching galleries require manual inspection.', 'manualInspectionRequired', 'MANUAL_INSPECTION_REQUIRED');

  }

  if (folders.length === 0) {

    const folder = createGalleryFolder_(root, folderName);

    saveExpectedImages_(folder, body, {});

    const inspection = inspectGalleryFolder_(folder, expected);

    if (!inspection.safe || !hasExactlyExpectedImages_(inspection, expected)) {

      throw publicError_(500, 'Gallery could not be completed. Manual inspection required.', 'manualInspectionRequired', 'MANUAL_INSPECTION_REQUIRED');

    }

    createManifestFile_(folder, body);

    saveGalleryFolderIndex_(body.galleryToken, folder.getId());

    console.log('Created Pocket Pixels gallery for session ' + body.sessionID + ' with token ' + redactToken_(body.galleryToken));

    return { status: 'created', fileCount: expectedFileCount };

  }

  const folder = folders[0];

  const inspection = inspectGalleryFolder_(folder, expected);

  if (!inspection.safe) {

    console.error('Conflicting files found for token ' + redactToken_(body.galleryToken) + '. Manual inspection required.');

    throw publicError_(409, 'Conflicting gallery files require manual inspection.', 'manualInspectionRequired', 'MANUAL_INSPECTION_REQUIRED');

  }

  if (inspection.manifests.length > 1) {

    throw publicError_(409, 'Duplicate manifests require manual inspection.', 'manualInspectionRequired', 'MANUAL_INSPECTION_REQUIRED');

  }

  if (inspection.manifests.length === 1) {

    const manifest = readManifest_(inspection.manifests[0]);

    if (manifest.status === 'complete') {

      if (manifest.galleryToken === body.galleryToken && manifest.sessionID === body.sessionID && manifestHasExpectedFiles_(manifest, body.photos.length) && hasExactlyExpectedImages_(inspection, expected)) {

        console.log('Returned existing Pocket Pixels gallery for session ' + body.sessionID + ' with token ' + redactToken_(body.galleryToken));

        saveGalleryFolderIndex_(body.galleryToken, folder.getId());

        return { status: 'existingComplete', fileCount: expectedFileCount };

      }

      throw publicError_(409, 'Gallery token belongs to a different or conflicting session.', 'conflict', 'CONFLICT');

    }

  }

  if (inspection.manifests.length === 1) {

    const manifest = readManifest_(inspection.manifests[0]);

    if (manifest.galleryToken && manifest.galleryToken !== body.galleryToken) {

      throw publicError_(409, 'Gallery token belongs to a different session.', 'conflict', 'CONFLICT');

    }

    if (manifest.sessionID && manifest.sessionID !== body.sessionID) {

      throw publicError_(409, 'Gallery token belongs to a different session.', 'conflict', 'CONFLICT');

    }

  }

  saveExpectedImages_(folder, body, inspection.fileCounts);

  const repairedInspection = inspectGalleryFolder_(folder, expected);

  if (!repairedInspection.safe || !hasExactlyExpectedImages_(repairedInspection, expected) || repairedInspection.manifests.length > 1) {

    throw publicError_(409, 'Incomplete gallery requires manual inspection.', 'manualInspectionRequired', 'MANUAL_INSPECTION_REQUIRED');

  }

  if (repairedInspection.manifests.length === 0) {

    createManifestFile_(folder, body);

  } else {

    const manifest = readManifest_(repairedInspection.manifests[0]);

    if (manifest.status !== 'complete') {

      throw publicError_(409, 'Incomplete manifest requires manual inspection.', 'manualInspectionRequired', 'MANUAL_INSPECTION_REQUIRED');

    }

  }

  console.log('Completed pending Pocket Pixels gallery for session ' + body.sessionID + ' with token ' + redactToken_(body.galleryToken));

  saveGalleryFolderIndex_(body.galleryToken, folder.getId());

  return { status: 'completedIncomplete', fileCount: expectedFileCount };

}

function saveExpectedImages_(folder, body, existingCounts) {

  const images = body.schemaVersion === 2
    ? body.photos.concat([body.colorReceipt, body.thermalReceipt]).concat(body.gif ? [body.gif] : [])
    : body.photos.concat([body.receipt]);

  const validatedImages = body._validatedImages || [];

  for (let i = 0; i < images.length; i++) {

    const image = images[i];

    const count = existingCounts[image.filename] || 0;

    if (count > 1) {

      throw publicError_(409, 'Duplicate gallery files require manual inspection.', 'manualInspectionRequired', 'MANUAL_INSPECTION_REQUIRED');

    }

    if (count === 0) {

      createImageFile_(folder, validatedImages[i] || image);

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

function createManifestFile_(folder, body) {

  try {

    folder.createFile(MANIFEST_FILENAME, JSON.stringify(makeCompleteManifest_(body), null, 2), 'application/json');

  } catch (error) {

    throw driveRuntimeError_('CREATE_MANIFEST_FILE', error);

  }

}

function inspectGalleryFolder_(folder, expected) {

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

function readManifest_(file) {

  try {

    return JSON.parse(file.getBlob().getDataAsString());

  } catch (error) {

    throw publicError_(409, 'Manifest requires manual inspection.', 'manualInspectionRequired', 'MANUAL_INSPECTION_REQUIRED');

  }

}

function manifestHasExpectedFiles_(manifest, expectedPhotoCount) {

  const count = Number(expectedPhotoCount || (Array.isArray(manifest.photos) ? manifest.photos.length : 0));
  const photoFilenames = expectedPhotoFilenames_(count);

  const rolesOK = manifest.schemaVersion === 1
    ? manifest.receipt === RECEIPT_FILENAME
    : manifest.schemaVersion === 2 && manifest.colorReceipt === RECEIPT_FILENAME &&
      manifest.thermalReceipt === THERMAL_RECEIPT_FILENAME &&
      (manifest.gif === undefined || manifest.gif === null || manifest.gif === GIF_FILENAME);

  return rolesOK &&

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

  const inspection = inspectGalleryFolder_(folder, expectedFilenames_(MAX_PHOTO_COUNT, 2));

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

  const expected = expectedFilenames_(manifest.photos.length, manifest.schemaVersion, !!manifest.gif);
  const exactInspection = inspectGalleryFolder_(folder, expected);

  if (!exactInspection.safe || !hasExactlyExpectedImages_(exactInspection, expected) || exactInspection.manifests.length !== 1) {

    if (indexedFolder) {
      removeGalleryFolderIndex_(token);
      return findCompleteGalleryByNameFallback_(root, token, timings);
    }

    return null;

  }

  saveGalleryFolderIndex_(token, folder.getId());

  return { folder: folder, manifest: manifest, filesByName: exactInspection.filesByName };

}

function galleryFolderIndexKey_(token) {
  return GALLERY_FOLDER_INDEX_PREFIX + token;
}

function saveGalleryFolderIndex_(token, folderID) {
  if (GALLERY_TOKEN_PATTERN.test(String(token || '')) && folderID) {
    PropertiesService.getScriptProperties().setProperty(galleryFolderIndexKey_(token), String(folderID));
  }
}

function removeGalleryFolderIndex_(token) {
  PropertiesService.getScriptProperties().deleteProperty(galleryFolderIndexKey_(token));
}

function loadIndexedGalleryFolder_(token) {
  const folderID = PropertiesService.getScriptProperties().getProperty(galleryFolderIndexKey_(token));
  if (!folderID) {
    return null;
  }

  try {
    return DriveApp.getFolderById(folderID);
  } catch (error) {
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
  const inspection = inspectGalleryFolder_(folder, expectedFilenames_(MAX_PHOTO_COUNT, 2));
  if (!inspection.safe || inspection.manifests.length !== 1) {
    return null;
  }

  const manifest = readManifest_(inspection.manifests[0]);
  if (manifest.galleryToken !== token || manifest.status !== 'complete' || !manifestHasExpectedFiles_(manifest)) {
    return null;
  }

  const expected = expectedFilenames_(manifest.photos.length, manifest.schemaVersion, !!manifest.gif);
  const exactInspection = inspectGalleryFolder_(folder, expected);
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

function galleryPhotoCardHTML_(item, index, total) {

  const name = escapeHTML(item.filename);
  const loading = index === 0 ? 'eager' : 'lazy';

  return '<figure class="shot"><button type="button" class="shot-frame image-button" data-open="' + name + '" aria-label="View photo ' + (index + 1) + ' of ' + total + ' larger">' +
    '<div class="image-placeholder" id="placeholder-' + name + '"><span>developing…</span></div>' +
    '<img hidden decoding="async" loading="' + loading + '" id="image-' + name + '" alt="Made to Keep Studios photo ' + (index + 1) + '"></button>' +
    '<figcaption class="shot-actions"><span class="shot-label">Photo ' + (index + 1) + '</span><span class="shot-buttons">' +
    '<button type="button" class="btn-small" data-download="' + name + '">Save Photo</button>' +
    '<button type="button" class="btn-small ghost" data-share="' + name + '">Share</button>' +
    '</span></figcaption></figure>';

}

function renderGalleryPage_(gallery, timings, startedAt) {

  const assetStartedAt = Date.now();

  const assets = loadGalleryAssets_(gallery.filesByName, gallery.manifest, false);

  if (timings) {

    timings.jpegBlobReadBase64Ms = Date.now() - assetStartedAt;

  }

  const sizeCheck = validateGalleryRenderSize_(assets);

  if (!sizeCheck.ok) {

    console.error('Gallery render size rejected. decodedBytes=' + sizeCheck.decodedBytes + ' base64Chars=' + sizeCheck.base64Chars);

    return renderGalleryTooLargePage_();

  }

  const createdAt = formatManilaDate_(gallery.manifest.createdAt);

  const reference = String(gallery.manifest.sessionID || '').slice(-13);

  const dataJSON = JSON.stringify({

    createdAt: createdAt,

    reference: reference,

    photos: assets.photos,

    receipt: assets.receipt,
    thermalReceipt: assets.thermalReceipt

  }).replace(/</g, '\\u003c');

  const photoCount = assets.photos.length;

  let body = '';

  body += '<main class="gallery-shell" data-pocket-pixels-gallery-status="complete">';

  // Static paper ornaments contain no customer imagery and disappear on phones.
  body += '<div class="paper-strip paper-strip-left" aria-hidden="true"><i></i><i></i><i></i><i></i></div><div class="paper-strip paper-strip-right" aria-hidden="true"><i></i><i></i><i></i><i></i></div>';
  body += '<section class="intro"><header class="gallery-hero">' + madeToKeepBrandLockupHTML_('compact') +
    '<h1>your moments,<br>made to keep.</h1>' +
    '<p class="lede">View, save and share the photographs from your session.</p>' +
    '<div class="save-all"><button type="button" class="btn primary" id="shareAll">SAVE ALL PHOTOS <span aria-hidden="true">→</span></button><p>Save your photos before closing this page.</p><p id="allHint"></p></div>' +
    (createdAt ? '<p class="session-date"><span>Captured</span> ' + escapeHTML(createdAt) + '</p>' : '') +
    '</header></section>';

  // C. Photographs, laid out by photo count; every photo opens, saves and shares on its own.
  body += '<section class="photos" aria-labelledby="photosTitle"><div class="section-heading section-heading-actions"><div><h2 id="photosTitle">Photo Gallery</h2><p>' + photoCount + (photoCount === 1 ? ' photo' : ' photos') + '</p></div>' +
    '</div>';

  body += '<div class="photo-grid photo-count-' + photoCount + '" aria-label="Made to Keep Studios photo gallery">';

  for (let i = 0; i < photoCount; i++) {

    body += galleryPhotoCardHTML_(assets.photos[i], i, photoCount);

  }

  body += '</div></section>';

  // D. Receipt: the color keepsake first, the printed black-and-white version as a quiet extra.
  const receiptName = escapeHTML(assets.receipt.filename);

  body += '<section class="receipt-section" aria-labelledby="receiptTitle"><div class="section-heading"><h2 id="receiptTitle">Receipt Copy</h2><p>your keepsake</p></div><div class="receipt-layout">' +
    '<figure class="receipt-item"><button type="button" class="receipt-frame image-button" data-open="' + receiptName + '" aria-label="View color receipt larger"><div class="image-placeholder receipt-placeholder" id="placeholder-' + receiptName + '"><span>developing…</span></div><img hidden decoding="async" loading="lazy" id="image-' + receiptName + '" alt="Made to Keep Studios color receipt"></button>' +
    '<figcaption class="shot-actions"><span class="shot-label">Color Receipt</span><span class="shot-buttons"><button type="button" class="btn-small" data-download="' + receiptName + '">Save Receipt</button><button type="button" class="btn-small ghost" data-share="' + receiptName + '">Share</button></span></figcaption></figure>';

  if (assets.thermalReceipt) {

    const thermalName = escapeHTML(assets.thermalReceipt.filename);

    body += '<details class="printed-version"><summary>Printed version <span>black &amp; white, as it came out of the booth</span></summary>' +
      '<figure class="receipt-item receipt-item-printed"><button type="button" class="receipt-frame image-button" data-open="' + thermalName + '" aria-label="View printed receipt larger"><div class="image-placeholder receipt-placeholder" id="placeholder-' + thermalName + '"><span>developing…</span></div><img hidden decoding="async" loading="lazy" id="image-' + thermalName + '" alt="Made to Keep Studios thermal receipt"></button>' +
      '<figcaption class="shot-actions"><span class="shot-label">Thermal Receipt</span><span class="shot-buttons"><button type="button" class="btn-small" data-download="' + thermalName + '">Save Receipt</button><button type="button" class="btn-small ghost" data-share="' + thermalName + '">Share</button></span></figcaption></figure></details>';

  }

  body += '</div></section>';

  // E. Quiet footer with a privacy reminder and the support reference.
  body += '<footer>' + '<span class="footer-descriptor">' + MADE_TO_KEEP_BRAND.descriptor + '</span><span class="brand-rule" aria-hidden="true"></span><strong class="footer-wordmark">' + MADE_TO_KEEP_BRAND.wordmark + '</strong><span class="footer-secondary">' + MADE_TO_KEEP_BRAND.secondary + '</span><em class="footer-tagline">' + MADE_TO_KEEP_BRAND.tagline + '</em>' +
    '<p class="privacy-note">This gallery is private to the link on your receipt. Save your favourites to keep them close.</p>' +
    (reference ? '<p class="reference">Ref ' + escapeHTML(reference) + '</p>' : '') + '</footer>';

  body += '<div class="lightbox" id="lightbox" role="dialog" aria-modal="true" aria-label="Full-size view" hidden>' +
    '<div class="lightbox-bar"><span id="lightboxCount" aria-live="polite"></span><button type="button" class="lightbox-close" id="lightboxClose">Close</button></div>' +
    '<div class="lightbox-stage"><button type="button" class="lightbox-nav" id="lightboxPrev" aria-label="Previous photo">‹</button><img id="lightboxImage" alt=""><button type="button" class="lightbox-nav" id="lightboxNext" aria-label="Next photo">›</button></div>' +
    '<div class="lightbox-bar lightbox-actions"><button type="button" class="lightbox-save" id="lightboxSave">Save Photo</button><button type="button" class="lightbox-share" id="lightboxShare">Share</button></div></div>';

  body += '<p id="message" class="toast" role="status" aria-live="polite"></p>';

  body += '</main>';

  const script = 'const galleryData=' + dataJSON + ';' + galleryClientScript_();

  const html = pageShell_(body, script);

  if (timings) {

    timings.generatedHTMLCharacters = html.length;

    timings.totalDoGetRenderMs = Date.now() - startedAt;

    console.log('Gallery render timings for token ' + redactToken_(gallery.manifest.galleryToken) + ': ' + JSON.stringify(timings) + ' decodedBytes=' + sizeCheck.decodedBytes + ' base64Chars=' + sizeCheck.base64Chars);

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

function loadGalleryAssets_(filesByName, manifest, includeGIF) {

  const photos = [];

  for (let i = 0; i < manifest.photos.length; i++) {

    photos.push(loadGalleryAsset_(filesByName, manifest.photos[i], 'photo'));

  }

  return {

    photos: photos,

    receipt: loadGalleryAsset_(filesByName, manifest.schemaVersion === 2 ? manifest.colorReceipt : manifest.receipt, 'colorReceipt'),
    thermalReceipt: manifest.schemaVersion === 2 ? loadGalleryAsset_(filesByName, manifest.thermalReceipt, 'thermalReceipt') : null,
    gif: includeGIF !== false && manifest.schemaVersion === 2 && manifest.gif ? loadGalleryAsset_(filesByName, manifest.gif, 'gif') : null

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

  const items = assets.photos.concat([assets.receipt, assets.thermalReceipt, assets.gif].filter(Boolean));

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
  // Made to Keep Studios: warm ivory paper, deep oxblood type, editorial serif headings and clean
  // sans-serif support text, matching the iPad guest screens. System fonts only, so the gallery
  // makes no third-party requests and the photographs stay the focus.
  return `
:root{color-scheme:light;--paper:#f7f1e9;--paper-deep:#efe6da;--surface:#fbf7f1;--ink:#2b2422;--muted:#6b5f57;--taupe:#958a80;--line:#ddd0c3;--accent:#70060b;--accent-hover:#5a0409;--on-accent:#fbf7f1;--shadow:0 1px 2px rgba(80,60,45,.06),0 10px 28px rgba(110,90,72,.12);--serif:"Bodoni 72","Bodoni Moda",Didot,"Playfair Display",Georgia,"Times New Roman",serif;--sans:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;--gutter:max(16px,env(safe-area-inset-left),env(safe-area-inset-right));}
*{box-sizing:border-box;}
html{background:var(--paper);-webkit-text-size-adjust:100%;}
body{margin:0;min-height:100vh;font-family:var(--sans);font-size:16px;line-height:1.5;color:var(--ink);background:radial-gradient(130% 70% at 50% 0%,#fcf9f4 0%,rgba(252,249,244,0) 62%),linear-gradient(180deg,#f7f1e9 0%,#f2eadf 100%);background-attachment:fixed;text-rendering:optimizeLegibility;-webkit-font-smoothing:antialiased;overflow-x:hidden;}
img{display:block;max-width:100%;}
p{margin:0;color:var(--muted);}
h1,h2{margin:0;font-weight:400;}
button{font:inherit;color:inherit;cursor:pointer;-webkit-tap-highlight-color:transparent;}
button[hidden],img[hidden]{display:none!important;}
:focus-visible{outline:2px solid var(--accent);outline-offset:3px;}

.btn,.btn-small,.lightbox-bar button{display:inline-flex;align-items:center;justify-content:center;gap:8px;border-radius:999px;border:1.5px solid var(--accent);background:transparent;color:var(--accent);font-family:var(--sans);font-weight:600;text-transform:uppercase;letter-spacing:.14em;white-space:nowrap;transition:background-color .15s ease,color .15s ease,transform .1s ease;}
.btn{min-height:48px;padding:0 24px;font-size:13px;}
.btn.primary{background:var(--accent);color:var(--on-accent);}
.btn.ghost,.btn-small.ghost{border-color:rgba(112,6,11,.35);}
.btn-small{min-height:40px;padding:0 14px;font-size:11px;letter-spacing:.12em;}
.btn:active,.btn-small:active{transform:scale(.97);}
@media (hover:hover){.btn:hover,.btn-small:hover{background:rgba(112,6,11,.07);}.btn.primary:hover{background:var(--accent-hover);}}

.gallery-shell{width:min(100%,1120px);margin:0 auto;padding:calc(28px + env(safe-area-inset-top)) var(--gutter) calc(40px + env(safe-area-inset-bottom));}

.brand-lockup{display:inline-grid;justify-items:center;gap:5px;color:var(--accent);}
.brand-descriptor,.footer-descriptor{font-size:10px;font-weight:600;letter-spacing:.26em;text-transform:uppercase;color:var(--accent);}
.brand-rule{display:block;width:30px;height:1.5px;background:var(--accent);margin:2px 0 3px;}
.brand-wordmark,.footer-wordmark{font-family:var(--serif);font-style:italic;font-weight:400;font-size:clamp(34px,9vw,46px);line-height:.92;letter-spacing:-.035em;color:var(--accent);}
.brand-secondary,.footer-secondary{font-weight:300;font-size:clamp(13px,3.6vw,16px);letter-spacing:.42em;margin-right:-.42em;line-height:1;color:var(--accent);}

.intro{display:grid;gap:28px;justify-items:center;padding:4px 0 36px;}
.gallery-hero{display:grid;justify-items:center;gap:10px;text-align:center;max-width:620px;}
.gallery-hero .brand-lockup{margin-bottom:14px;}
.gallery-hero h1{font-family:var(--serif);font-style:italic;font-size:clamp(32px,8.4vw,54px);line-height:1.02;letter-spacing:-.015em;color:var(--accent);text-wrap:balance;}
.lede{font-size:clamp(16px,4.2vw,18px);color:var(--muted);max-width:30em;}
.session-date{margin-top:4px;font-size:12px;letter-spacing:.16em;text-transform:uppercase;color:var(--taupe);}
.session-date span{color:var(--accent);opacity:.7;margin-right:4px;}

.section-heading{display:flex;align-items:baseline;justify-content:center;gap:12px;margin:0 0 18px;text-align:center;}
.section-heading h2{font-family:var(--serif);font-style:italic;font-size:clamp(26px,6.4vw,34px);line-height:1.1;color:var(--accent);}
.section-heading p{font-size:11px;font-weight:600;letter-spacing:.22em;text-transform:uppercase;color:var(--taupe);}
.section-heading-actions{flex-direction:column;align-items:center;gap:14px;}
.section-heading-actions>div:first-child{display:flex;align-items:baseline;gap:12px;}
.save-all{display:grid;justify-items:center;gap:6px;width:100%;}
.save-all .btn{width:min(100%,340px);}
.section-heading .save-all #allHint{font-size:13px;font-weight:400;letter-spacing:0;text-transform:none;color:var(--muted);text-align:center;max-width:34em;}

.motion-frame,.shot-frame,.receipt-frame{display:block;width:100%;padding:8px;border:1px solid var(--line);border-radius:3px;background:var(--surface);box-shadow:var(--shadow);overflow:hidden;}

.photos{padding-top:6px;}
.photo-grid{display:grid;grid-template-columns:minmax(0,1fr);gap:22px;align-items:start;}
.photo-count-4,.photo-count-6{grid-template-columns:repeat(2,minmax(0,1fr));gap:14px;}
.shot{margin:0;display:grid;gap:10px;}
.shot-frame img,.receipt-frame img{width:100%;height:auto;background:var(--paper-deep);}
.image-placeholder{display:grid;place-items:center;aspect-ratio:3/4;background:linear-gradient(110deg,var(--paper-deep) 30%,#f6efe6 50%,var(--paper-deep) 70%);background-size:220% 100%;animation:shimmer 1.6s ease-in-out infinite;color:var(--taupe);font-family:var(--serif);font-style:italic;font-size:16px;}
.receipt-placeholder{aspect-ratio:1/2.4;}
@keyframes shimmer{from{background-position:120% 0;}to{background-position:-120% 0;}}
.shot-actions{display:flex;align-items:center;justify-content:space-between;gap:8px;flex-wrap:wrap;padding:0 2px;}
.shot-label{font-size:11px;font-weight:600;letter-spacing:.2em;text-transform:uppercase;color:var(--accent);}
.shot-buttons{display:flex;gap:6px;flex-wrap:wrap;justify-content:flex-end;}
.photo-count-4 .shot-label,.photo-count-6 .shot-label{display:none;}
.photo-count-4 .shot-buttons,.photo-count-6 .shot-buttons{width:100%;}
.photo-count-4 .btn-small,.photo-count-6 .btn-small{flex:1 1 0;padding:0 8px;letter-spacing:.08em;}

.receipt-section{margin-top:48px;padding-top:6px;}
.receipt-layout{display:grid;gap:22px;justify-items:center;}
.receipt-item{margin:0;display:grid;gap:10px;width:min(100%,360px);}
.receipt-frame{background:#fff;}
.receipt-frame img{background:#fff;max-height:none;}
.printed-version{width:min(100%,360px);border-top:1px solid var(--line);padding-top:14px;}
.printed-version summary{cursor:pointer;list-style:none;display:flex;flex-direction:column;align-items:center;gap:2px;min-height:44px;justify-content:center;text-align:center;font-size:13px;font-weight:600;letter-spacing:.14em;text-transform:uppercase;color:var(--accent);}
.printed-version summary::-webkit-details-marker{display:none;}
.printed-version summary span{font-size:13px;font-weight:400;letter-spacing:0;text-transform:none;color:var(--muted);}
.printed-version[open] summary{margin-bottom:14px;}

footer{margin-top:56px;padding-top:28px;border-top:1px solid rgba(112,6,11,.18);display:grid;justify-items:center;gap:5px;text-align:center;}
.footer-wordmark{font-size:clamp(28px,7vw,34px);}
.footer-tagline{margin-top:8px;font-family:var(--serif);font-style:italic;font-size:17px;color:var(--accent);}
.privacy-note{margin-top:12px;max-width:34em;font-size:13px;color:var(--muted);}
.reference{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:11px;letter-spacing:.06em;color:var(--taupe);}

.toast{position:fixed;left:50%;bottom:calc(18px + env(safe-area-inset-bottom));z-index:20;width:max-content;max-width:min(92vw,520px);padding:12px 18px;border-radius:14px;background:rgba(43,36,34,.94);color:var(--on-accent);font-size:14px;line-height:1.4;text-align:center;box-shadow:0 10px 30px rgba(0,0,0,.2);opacity:0;transform:translate(-50%,12px);pointer-events:none;transition:opacity .2s ease,transform .2s ease;}
.toast.visible{opacity:1;transform:translate(-50%,0);}

.lightbox{position:fixed;inset:0;z-index:30;display:grid;grid-template-rows:auto minmax(0,1fr) auto;gap:10px;padding:calc(12px + env(safe-area-inset-top)) var(--gutter) calc(14px + env(safe-area-inset-bottom));background:rgba(28,23,21,.96);color:var(--on-accent);}
.lightbox[hidden]{display:none;}
.lightbox-bar{display:flex;align-items:center;justify-content:space-between;gap:10px;min-height:48px;}
.lightbox-bar span{font-size:12px;letter-spacing:.2em;text-transform:uppercase;opacity:.75;}
.lightbox-bar button{min-height:46px;padding:0 20px;font-size:12px;border-color:rgba(251,247,241,.5);color:var(--on-accent);}
.lightbox-actions{justify-content:center;}
.lightbox-actions .lightbox-save{background:var(--on-accent);color:var(--accent);border-color:var(--on-accent);}
.lightbox-stage{position:relative;display:grid;place-items:center;min-height:0;}
.lightbox-stage img{max-width:100%;max-height:100%;width:auto;height:auto;object-fit:contain;}
.lightbox-nav{position:absolute;top:50%;transform:translateY(-50%);width:48px;height:64px;border:0;border-radius:999px;background:rgba(251,247,241,.14);color:var(--on-accent);font-size:34px;line-height:1;}
#lightboxPrev{left:0;}#lightboxNext{right:0;}

.center-page{min-height:100vh;display:grid;place-items:center;padding:calc(28px + env(safe-area-inset-top)) var(--gutter) calc(40px + env(safe-area-inset-bottom));}
.notice{width:min(100%,460px);display:grid;justify-items:center;gap:12px;text-align:center;padding:38px 26px;background:rgba(251,247,241,.86);border:1px solid rgba(112,6,11,.2);border-radius:3px;box-shadow:var(--shadow);}
.notice .brand-lockup{margin-bottom:10px;}
.notice h1{font-family:var(--serif);font-style:italic;font-size:clamp(28px,7.4vw,38px);line-height:1.05;color:var(--accent);text-wrap:balance;}
.notice .btn{margin-top:10px;}
.notice-footnote{font-size:13px;color:var(--taupe);}
.loader{width:30px;height:30px;border-radius:50%;border:1.5px solid var(--line);border-top-color:var(--accent);margin:6px auto;animation:spin 1s linear infinite;}
@keyframes spin{to{transform:rotate(360deg);}}

@media (min-width:600px){
  .photo-count-2,.photo-count-4{grid-template-columns:repeat(2,minmax(0,1fr));gap:22px;}
  .photo-count-3,.photo-count-6{grid-template-columns:repeat(3,minmax(0,1fr));gap:18px;}
  .photo-count-1{max-width:560px;margin:0 auto;}
  .photo-count-4 .shot-label{display:inline;}
  .photo-count-4 .shot-buttons{width:auto;}
  .photo-count-4 .btn-small{flex:0 0 auto;padding:0 14px;letter-spacing:.12em;}
  .section-heading-actions{flex-direction:row;justify-content:space-between;align-items:flex-end;text-align:left;}
  .save-all{width:auto;justify-items:end;}
  .save-all .btn{width:auto;}
  .section-heading .save-all #allHint{text-align:right;}
  .receipt-layout{grid-template-columns:minmax(0,360px) minmax(0,300px);justify-content:center;align-items:start;gap:36px;}
  .printed-version{border-top:0;padding-top:0;}
  .printed-version summary{align-items:flex-start;text-align:left;}
}
@media (min-width:900px){
  .gallery-shell{padding-top:calc(44px + env(safe-area-inset-top));}
  .photo-grid{gap:26px;}
  .lightbox-nav{width:56px;height:72px;}
  #lightboxPrev{left:12px;}#lightboxNext{right:12px;}
}
/* Reference composition: airy centered editorial type and restrained paper strips. */
.gallery-shell{position:relative;max-width:1120px;isolation:isolate;}
.intro{padding:12px 0 42px;}
.gallery-hero{width:100%;max-width:800px;gap:18px;margin:auto;}
.gallery-hero .brand-lockup{margin-bottom:24px;}
.gallery-hero .brand-wordmark{font-size:clamp(44px,8vw,72px);letter-spacing:-.055em;}
.gallery-hero h1{font-size:clamp(42px,8.2vw,94px);font-style:normal;line-height:.98;letter-spacing:-.045em;}
.gallery-hero .lede{font-family:var(--serif);font-size:clamp(19px,2.6vw,26px);color:var(--accent);max-width:30em;}
.gallery-hero .save-all{width:100%;justify-items:center;margin-top:12px;gap:10px;}
.gallery-hero .save-all .btn{width:min(100%,440px);min-height:62px;font-family:var(--serif);font-weight:400;font-size:18px;letter-spacing:.18em;box-shadow:0 8px 18px #70060b20;white-space:normal;}
.gallery-hero .save-all p{font-size:14px;text-transform:none;letter-spacing:0;text-align:center;}
.section-heading-actions{justify-content:center;align-items:center;}
.section-heading-actions>div:first-child{width:100%;justify-content:center;flex-wrap:wrap;}
.photos>.section-heading:before,.photos>.section-heading:after{content:"";height:1px;flex:1;background:var(--accent);opacity:.5;}
.photos>.section-heading>div{width:auto;flex:none;max-width:80%;}
.photos>.section-heading h2{font:600 13px var(--sans);font-style:normal;letter-spacing:.2em;text-transform:uppercase;}
.photos>.section-heading p{font-size:10px;}
.btn-small,.image-button{min-height:44px;}
.paper-strip{display:none;}
@media(max-width:599px){
 .photo-grid{grid-template-columns:minmax(0,1fr);gap:26px;}
 .photo-count-4 .shot-label,.photo-count-6 .shot-label{display:inline;}
 .shot-buttons{width:100%;justify-content:stretch;}
 .shot-buttons .btn-small{flex:1;}
 .gallery-hero .brand-lockup{margin-bottom:14px;}
 .intro{padding-bottom:32px;}
}
@media(min-width:1200px){
 .gallery-shell{padding-left:100px;padding-right:100px;}
 .paper-strip{display:grid;gap:5px;position:absolute;top:65px;width:105px;padding:9px;background:var(--surface);box-shadow:var(--shadow);z-index:-1;pointer-events:none;}
 .paper-strip i{display:block;height:95px;background:linear-gradient(145deg,#a9968a,#eaded1 50%,#ba9c8a);}
 .paper-strip:before{content:"";position:absolute;top:-14px;left:24px;width:60px;height:27px;background:#dfcbb1b3;transform:rotate(3deg);}
 .paper-strip-left{left:-30px;transform:rotate(12deg);}
 .paper-strip-right{right:-30px;transform:rotate(-12deg);}
}
@media (prefers-reduced-motion:reduce){
  *,*:before,*:after{animation:none!important;transition:none!important;}
}
`;
}

function galleryClientScript_() {
  // Everything is embedded in the page: no Drive links (so never a Google sign-in), no per-image
  // script calls and no third-party requests. Files keep their original names and MIME types, so
  // saves retain original image bytes. Unsupported browser features are hidden, never faked.
  return `
const startedAt=performance.now();
const files=[...galleryData.photos,galleryData.receipt,galleryData.thermalReceipt].filter(Boolean);
const assetMap=new Map(files.map(function(item){return [item.filename,item];}));
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
function fileForItem(item){if(realFileCache.has(item.filename)){return realFileCache.get(item.filename);}const binary=atob(item.base64Data);const bytes=new Uint8Array(binary.length);for(let i=0;i<binary.length;i++){bytes[i]=binary.charCodeAt(i);}const file=new File([bytes],item.filename,{type:item.mimeType});realFileCache.set(item.filename,file);return file;}
function objectURLFor(item){return URL.createObjectURL(fileForItem(item));}
function findItem(filename){return assetMap.get(filename);}
function roleText(item){if(item.role==="colorReceipt"){return {name:"color receipt",alt:"Made to Keep Studios color receipt",save:"Save Receipt"};}if(item.role==="thermalReceipt"){return {name:"printed receipt",alt:"Made to Keep Studios thermal receipt",save:"Save Receipt"};}return {name:"photo",alt:"Made to Keep Studios photo",save:"Save Photo"};}
function revealItem(item){const image=document.getElementById("image-"+item.filename);const placeholder=document.getElementById("placeholder-"+item.filename);if(image&&!image.getAttribute("src")){image.src=dataURL(item);image.hidden=false;}if(placeholder){placeholder.remove();}}
function supportsFileShare(item){if(!navigator.share||!navigator.canShare||!item){return false;}try{return navigator.canShare({files:[new File([new Uint8Array([1])],item.filename,{type:item.mimeType})]});}catch(error){return false;}}
function supportsMultipleFileShare(){if(!navigator.share||!navigator.canShare){return false;}try{return navigator.canShare({files:[new File([new Uint8Array([1])],"photo-01.jpg",{type:"image/jpeg"}),new File([new Uint8Array([2])],"photo-02.jpg",{type:"image/jpeg"})]});}catch(error){return false;}}
function downloadItem(item,quiet){try{const url=objectURLFor(item);const a=document.createElement("a");a.href=url;a.download=item.filename;a.rel="noopener";document.body.appendChild(a);a.click();a.remove();setTimeout(function(){URL.revokeObjectURL(url);},30000);if(!quiet){setMessage(isIOS?"Downloading to Files › Downloads. To add it to Photos, use Share and choose Save Image.":"Download started: "+item.filename);}return true;}catch(error){setMessage("We couldn’t start that download. Please try again.");return false;}}
async function shareFiles(items,intentMessage){try{await navigator.share({files:items.map(fileForItem),title:"Made to Keep Studios"});if(intentMessage){setMessage("");}}catch(error){if(error&&error.name==="AbortError"){setMessage("");return;}if(items.length===1){downloadItem(items[0]);}else{setMessage("Sharing didn’t work here. Please save each photo below.");}}}
function shareItem(item){if(!supportsFileShare(item)){downloadItem(item);return;}shareFiles([item]);}
function saveItem(item){if(isIOS&&supportsFileShare(item)){setMessage("Choose Save Image to add it to Photos.");shareFiles([item],true);return;}downloadItem(item);}
function showLightboxItem(){const item=lightboxItems[lightboxIndex];if(!item){return;}const image=document.getElementById("lightboxImage");const save=document.getElementById("lightboxSave");const share=document.getElementById("lightboxShare");const count=document.getElementById("lightboxCount");const text=roleText(item);if(activeLightboxURL){URL.revokeObjectURL(activeLightboxURL);}activeLightboxURL=URL.createObjectURL(fileForItem(item));image.src=activeLightboxURL;image.alt=text.alt+(item.role==="photo"?" "+(lightboxIndex+1):"");save.textContent=text.save;share.hidden=!supportsFileShare(item);count.textContent=lightboxItems.length>1?(lightboxIndex+1)+" / "+lightboxItems.length:text.name;document.getElementById("lightboxPrev").hidden=lightboxItems.length<2;document.getElementById("lightboxNext").hidden=lightboxItems.length<2;}
function openFullSize(item){try{const lightbox=document.getElementById("lightbox");if(!lightbox){const url=objectURLFor(item);window.open(url,"_blank","noopener");setTimeout(function(){URL.revokeObjectURL(url);},30000);return;}lastFocus=document.activeElement;lightboxItems=item.role==="photo"?photoItems:[item];lightboxIndex=Math.max(0,lightboxItems.indexOf(item));showLightboxItem();lightbox.hidden=false;document.body.style.overflow="hidden";document.getElementById("lightboxClose").focus();}catch(error){setMessage("We couldn’t open the full-size image. Please use Save instead.");}}
function stepLightbox(offset){if(lightboxItems.length<2){return;}lightboxIndex=(lightboxIndex+offset+lightboxItems.length)%lightboxItems.length;showLightboxItem();}
function closeLightbox(){const lightbox=document.getElementById("lightbox");const image=document.getElementById("lightboxImage");if(!lightbox||lightbox.hidden){return;}lightbox.hidden=true;if(image){image.removeAttribute("src");}document.body.style.overflow="";if(activeLightboxURL){URL.revokeObjectURL(activeLightboxURL);activeLightboxURL="";}lightboxItems=[];if(lastFocus&&lastFocus.focus){lastFocus.focus();}}
function wireLightbox(){const lightbox=document.getElementById("lightbox");if(!lightbox){return;}document.getElementById("lightboxClose").addEventListener("click",closeLightbox);document.getElementById("lightboxPrev").addEventListener("click",function(){stepLightbox(-1);});document.getElementById("lightboxNext").addEventListener("click",function(){stepLightbox(1);});document.getElementById("lightboxSave").addEventListener("click",function(){const item=lightboxItems[lightboxIndex];if(item){saveItem(item);}});document.getElementById("lightboxShare").addEventListener("click",function(){const item=lightboxItems[lightboxIndex];if(item){shareItem(item);}});lightbox.addEventListener("click",function(event){if(event.target===lightbox||event.target.classList.contains("lightbox-stage")){closeLightbox();}});lightbox.addEventListener("touchstart",function(event){touchStartX=event.touches[0].clientX;},{passive:true});lightbox.addEventListener("touchend",function(event){if(touchStartX===null){return;}const dx=event.changedTouches[0].clientX-touchStartX;touchStartX=null;if(Math.abs(dx)>50){stepLightbox(dx<0?1:-1);}},{passive:true});document.addEventListener("keydown",function(event){if(lightbox.hidden){return;}if(event.key==="Escape"){closeLightbox();}else if(event.key==="ArrowLeft"){stepLightbox(-1);}else if(event.key==="ArrowRight"){stepLightbox(1);}});}
function wireOpenButtons(){document.querySelectorAll("[data-open]").forEach(function(button){button.addEventListener("click",function(){const item=findItem(button.getAttribute("data-open"));if(item){openFullSize(item);}});});}
function wireSaveButtons(){document.querySelectorAll("[data-download]").forEach(function(button){button.addEventListener("click",function(){const item=findItem(button.getAttribute("data-download"));if(item){saveItem(item);}});});}
function wireShareButtons(){document.querySelectorAll("[data-share]").forEach(function(button){const item=findItem(button.getAttribute("data-share"));if(!item||!supportsFileShare(item)){button.hidden=true;return;}button.addEventListener("click",function(){shareItem(item);});});}
function wireShareAll(){const shareAll=document.getElementById("shareAll");const allHint=document.getElementById("allHint");if(!shareAll){return;}const photos=photoItems.map(function(file){return findItem(file.filename);}).filter(Boolean);const count=photos.length;if(count===1){shareAll.addEventListener("click",function(){saveItem(photos[0]);});return;}if(count<1){shareAll.hidden=true;return;}if((isIOS||isAndroid)&&supportsMultipleFileShare()){if(allHint){allHint.textContent=isIOS?"Opens the share sheet. Choose Save "+count+" Images to add them to Photos.":"Opens the share sheet to save or send all "+count+" photos.";}shareAll.addEventListener("click",function(){shareFiles(photos,true);});return;}if(!isIOS){if(allHint){allHint.textContent="Downloads all "+count+" photos to this device.";}shareAll.addEventListener("click",function(){setMessage("Downloading "+count+" photos. Your browser may ask to allow multiple downloads.");photos.forEach(function(item,index){setTimeout(function(){downloadItem(item,true);},index*450);});});return;}shareAll.hidden=true;if(allHint){allHint.textContent="Use Save under each photo to add it to Photos.";}}

function showEmbeddedImages(){try{const ordered=photoItems.concat([galleryData.receipt,galleryData.thermalReceipt].filter(Boolean));if(ordered.length){revealItem(ordered[0]);}const remaining=ordered.slice(1);const reveal=function(){remaining.forEach(revealItem);};if("requestIdleCallback" in window){requestIdleCallback(reveal,{timeout:1200});}else{setTimeout(reveal,40);}wireOpenButtons();wireSaveButtons();wireShareButtons();wireShareAll();wireLightbox();logSafeBrowserTiming();}catch(error){setMessage("Some images didn’t load. Refresh this page to try again.");}}
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
    schemaVersion: 2,
    galleryToken: body.galleryToken,
    sessionID: body.sessionID,
    createdAt: body.createdAt,
    photos: body._expectedPhotoFilenames || expectedPhotoFilenames_(body.photos.length),
    colorReceipt: RECEIPT_FILENAME,
    thermalReceipt: THERMAL_RECEIPT_FILENAME,
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

function expectedFilenames_(photoCount, schemaVersion, hasGIF) {

  return expectedPhotoFilenames_(photoCount).concat(schemaVersion === 2
    ? [RECEIPT_FILENAME, THERMAL_RECEIPT_FILENAME].concat(hasGIF === false ? [] : [GIF_FILENAME])
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

  try {

    const photos = Array.isArray(body.photos) ? body.photos : [];

    const summary = {

      topLevelKeys: Object.keys(body || {}).sort(),

      topLevelTypes: topLevelTypes_(body),

      bodyCharacterCount: bodyCharacterCount,

      schemaVersion: body && body.schemaVersion,

      deviceTokenPresent: !!(body && body.deviceToken),

      galleryTokenLength: body && typeof body.galleryToken === 'string' ? body.galleryToken.length : 0,

      galleryTokenFormatValid: body && typeof body.galleryToken === 'string' && GALLERY_TOKEN_PATTERN.test(body.galleryToken),

      sessionID: body && body.sessionID,

      createdAt: body && body.createdAt,

      photoCount: photos.length,

      photoFilenames: photos.map(function(photo) { return photo && photo.filename; }),

      photoMimeTypes: photos.map(function(photo) { return photo && photo.mimeType; }),

      photoBase64CharacterCounts: photos.map(function(photo) { return photo && typeof photo.base64Data === 'string' ? photo.base64Data.length : 0; }),

      receiptFilename: body && body.receipt && body.receipt.filename,

      receiptMimeType: body && body.receipt && body.receipt.mimeType,

      receiptBase64CharacterCount: body && body.receipt && typeof body.receipt.base64Data === 'string' ? body.receipt.base64Data.length : 0

    };

    console.log('Sanitized upload request: ' + JSON.stringify(summary));

  } catch (error) {

    console.error('Sanitized upload request logging failed: ' + safeErrorMessage_(error));

  }

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

  const details = {

    errorCode: safeError.code,

    stage: stage || 'UNKNOWN',

    publicDetail: safeError.detail || '',

    name: error && error.name,

    message: safeErrorMessage_(error),

    stack: error && error.stack ? safeErrorMessage_({ message: error.stack }) : ''

  };

  console.error('Upload failed: ' + JSON.stringify(details));

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
