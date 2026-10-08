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

const SAFE_SESSION_ID_PATTERN = /^PP-[0-9]{8}-[0-9]{6}$/;

const RFC3339_UTC_SECONDS_PATTERN = /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/;

const RECEIPT_FILENAME = 'receipt-color.jpg';
const THERMAL_RECEIPT_FILENAME = 'receipt-bw.png';
const GIF_FILENAME = 'session.gif';

const MANIFEST_FILENAME = 'manifest.json';

const MAX_REQUEST_BYTES = 9 * 1024 * 1024;

const MAX_GALLERY_DECODED_BYTES = 6 * 1024 * 1024;

const MAX_GALLERY_BASE64_CHARS = 9 * 1024 * 1024;

const BACKEND_VERSION = 'gallery-v2-gif-dual-receipts-20261007';

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

  const tooMany = makeSelfTestPayload_(5);

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

  badReceipt.receipt.filename = 'receipt.png';

  assertValidationCode_(badReceipt, 'INVALID_RECEIPT');

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

  const versionFields = body.schemaVersion === 1 ? ['receipt'] : ['colorReceipt', 'thermalReceipt', 'gif'];
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
    const gifError = validateImage_(body.gif, GIF_FILENAME, 'gif', 'image/gif');
    if (!gifError.ok) return gifError;
    validatedImages.push(colorError.image, thermalError.image, gifError.image);
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
    ? [body.colorReceipt, body.thermalReceipt, body.gif]
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
  const expected = expectedFilenames_(body.photos.length, body.schemaVersion);
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
    ? body.photos.concat([body.colorReceipt, body.thermalReceipt, body.gif])
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
      manifest.thermalReceipt === THERMAL_RECEIPT_FILENAME && manifest.gif === GIF_FILENAME;

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

  const expected = expectedFilenames_(manifest.photos.length, manifest.schemaVersion);
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

  const expected = expectedFilenames_(manifest.photos.length, manifest.schemaVersion);
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

function madeToKeepBrandLockupHTML_() {

  // Pure HTML/CSS typographic lockup; no bitmap logo is embedded in the gallery.
  return '<div class="brand-lockup" role="img" aria-label="' + MADE_TO_KEEP_BRAND.fullName + '"><span class="brand-descriptor">' + MADE_TO_KEEP_BRAND.descriptor + '</span><span class="brand-rule" aria-hidden="true"></span><span class="brand-wordmark">' + MADE_TO_KEEP_BRAND.wordmark + '</span><span class="brand-secondary">' + MADE_TO_KEEP_BRAND.secondary + '</span></div>';

}

function renderInvalidGalleryPage_() {

  return makeHTML_(pageShell_(

    '<main class="center-page"><section class="notice">' + madeToKeepBrandLockupHTML_() + '<h1>we could not load your photos just yet.</h1><p>This gallery link cannot be opened. Please try scanning the QR again.</p><button type="button" onclick="window.location.reload()">Try Again</button></section></main>',

    ''

  ));

}

function renderPendingGalleryPage_() {

  const script = 'var started=Date.now();var timer=setInterval(function(){if(Date.now()-started>120000){clearInterval(timer);return;}window.location.reload();},8000);';

  return makeHTML_(pageShell_(

    '<main class="center-page"><section class="notice">' + madeToKeepBrandLockupHTML_() + '<h1>your photos are still being prepared.</h1><div class="loader" aria-hidden="true"></div><p>Please check again in a moment.</p><button type="button" onclick="window.location.reload()">Check Again</button></section></main>',

    script

  ));

}

function renderGalleryPage_(gallery, timings, startedAt) {

  const assetStartedAt = Date.now();

  const assets = loadGalleryAssets_(gallery.filesByName, gallery.manifest);

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
    thermalReceipt: assets.thermalReceipt,
    gif: assets.gif

  }).replace(/</g, '\\u003c');

  let body = '';

  body += '<main class="gallery-shell" data-pocket-pixels-gallery-status="complete">';

  body += '<header class="gallery-hero">' + madeToKeepBrandLockupHTML_() + '<h1>your photos are ready.</h1><p class="lede">' + MADE_TO_KEEP_BRAND.tagline + '</p></header>';

  body += '<section class="primary-actions" aria-label="Save photos"><button type="button" id="shareAll">Save All Photos</button><p id="allHint">Save your photos before closing this page.</p><p id="message" role="status" aria-live="polite"></p></section>';

  body += '<section class="section-heading"><p>Photo Gallery</p></section>';

  body += '<section class="photo-grid photo-count-' + assets.photos.length + '" aria-label="Made to Keep Studios photo gallery">';

  for (let i = 0; i < assets.photos.length; i++) {

    const filename = assets.photos[i].filename;
    const loading = i === 0 ? 'eager' : 'lazy';

    body += '<article class="photo-item"><button type="button" class="image-button" data-open="' + filename + '" aria-label="View photo ' + (i + 1) + ' larger"><div class="image-placeholder" id="placeholder-' + filename + '">getting photo ready...</div><img hidden decoding="async" loading="' + loading + '" id="image-' + filename + '" alt="Made to Keep Studios photo ' + (i + 1) + '"></button><div class="photo-actions"><span>Photo ' + (i + 1) + '</span><div><button type="button" data-download="' + filename + '">Save Photo</button><button type="button" class="secondary" data-share="' + filename + '">Share</button></div></div></article>';

  }

  body += '</section>';

  if (assets.gif) body += '<section class="gif-section"><div class="section-heading"><p>Your GIF</p></div><article class="gif-item"><button type="button" class="image-button" data-open="' + assets.gif.filename + '" aria-label="Open animated GIF larger"><img decoding="async" loading="eager" id="image-' + assets.gif.filename + '" alt="Animated Made to Keep Studios session GIF"></button><div class="photo-actions"><span>Your GIF</span><div><button type="button" data-download="' + assets.gif.filename + '">Save GIF</button><button type="button" class="secondary" data-share="' + assets.gif.filename + '">Share GIF</button></div></div></article></section>';

  body += '<section class="receipt-section"><div class="section-heading"><p>Receipt Copy</p></div><div class="receipt-grid"><article class="receipt-item"><button type="button" class="image-button" data-open="' + assets.receipt.filename + '" aria-label="View color receipt larger"><div class="image-placeholder receipt-placeholder" id="placeholder-' + assets.receipt.filename + '">getting receipt ready...</div><img hidden decoding="async" loading="lazy" id="image-' + assets.receipt.filename + '" alt="Made to Keep Studios color receipt"></button><div class="photo-actions"><span>Color Receipt</span><div><button type="button" data-download="' + assets.receipt.filename + '">Save Receipt</button><button type="button" class="secondary" data-share="' + assets.receipt.filename + '">Share</button></div></div></article>' + (assets.thermalReceipt ? '<article class="receipt-item"><button type="button" class="image-button" data-open="' + assets.thermalReceipt.filename + '" aria-label="View thermal receipt larger"><div class="image-placeholder receipt-placeholder" id="placeholder-' + assets.thermalReceipt.filename + '">getting receipt ready...</div><img hidden decoding="async" loading="lazy" id="image-' + assets.thermalReceipt.filename + '" alt="Made to Keep Studios thermal receipt"></button><div class="photo-actions"><span>Thermal Receipt</span><div><button type="button" data-download="' + assets.thermalReceipt.filename + '">Save Receipt</button><button type="button" class="secondary" data-share="' + assets.thermalReceipt.filename + '">Share</button></div></div></article>' : '') + '</div></section>';

  body += '<section class="session-note"><p>' + escapeHTML(createdAt) + '</p><p>' + escapeHTML(reference) + '</p></section>';

  body += '<footer><span class="footer-descriptor">' + MADE_TO_KEEP_BRAND.descriptor + '</span><span class="brand-rule" aria-hidden="true"></span><strong class="footer-wordmark">' + MADE_TO_KEEP_BRAND.wordmark + '</strong><span class="footer-secondary">' + MADE_TO_KEEP_BRAND.secondary + '</span><em class="footer-tagline">' + MADE_TO_KEEP_BRAND.tagline + '</em></footer>';

  body += '<div class="lightbox" id="lightbox" hidden><button type="button" class="lightbox-close" id="lightboxClose">Close</button><img id="lightboxImage" alt=""><button type="button" class="lightbox-save" id="lightboxSave">Save Photo</button></div>';

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

function renderGalleryTooLargePage_() {

  return makeHTML_(pageShell_(

    '<main class="center-page"><section class="notice">' + madeToKeepBrandLockupHTML_() + '<h1>Gallery temporarily unavailable.</h1><p>Please ask the booth operator to refresh this gallery.</p></section></main>',

    ''

  ));

}

function makeHTML_(html) {

  return HtmlService.createHtmlOutput(html)

    .setTitle(MADE_TO_KEEP_BRAND.galleryTitle)

    .setXFrameOptionsMode(HtmlService.XFrameOptionsMode.ALLOWALL);

}

function pageShell_(body, script) {

  return '<!doctype html><html lang="en"><head><meta charset="utf-8">' +

    '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">' +

    '<meta name="robots" content="noindex,nofollow"><base target="_top">' +

    '<title>' + MADE_TO_KEEP_BRAND.galleryTitle + '</title><style>' + galleryCSS_() + '</style></head><body>' +

    body + '<script>' + script + '</script></body></html>';

}

function loadGalleryAssets_(filesByName, manifest) {

  const photos = [];

  for (let i = 0; i < manifest.photos.length; i++) {

    photos.push(loadGalleryAsset_(filesByName, manifest.photos[i], 'photo'));

  }

  return {

    photos: photos,

    receipt: loadGalleryAsset_(filesByName, manifest.schemaVersion === 2 ? manifest.colorReceipt : manifest.receipt, 'colorReceipt'),
    thermalReceipt: manifest.schemaVersion === 2 ? loadGalleryAsset_(filesByName, manifest.thermalReceipt, 'thermalReceipt') : null,
    gif: manifest.schemaVersion === 2 ? loadGalleryAsset_(filesByName, manifest.gif, 'gif') : null

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

  return Utilities.formatDate(date, 'Asia/Manila', 'MMM d, yyyy h:mm a');

}

function galleryCSS_() {
  // Made to Keep Studios: warm ivory printed paper, deep oxblood typography, thin outlined capsules.
  // The paper grain is a tiny inline SVG noise layer, so no texture image is downloaded.
  return [
    ':root{color-scheme:light;--ink:#2b2422;--muted:#6b5f57;--taupe:#a39990;--paper:#f7f1e9;--paper-warm:#eee6dc;--surface:#fbf7f1;--line:#d9ccbf;--accent:#70060b;--accent-soft:#efe3da;--accent-dark:#5a0409;--focus:#70060b;--serif-italic:\"Bodoni 72\",\"Bodoni Moda\",Didot,\"Playfair Display\",Georgia,\"Times New Roman\",serif;--serif:\"Bodoni 72\",\"Bodoni Moda\",Didot,Georgia,\"Times New Roman\",serif;--sans:-apple-system,BlinkMacSystemFont,\"Segoe UI\",Roboto,Arial,sans-serif;}',
    '*{box-sizing:border-box;}html{background:var(--paper);}body{margin:0;font-family:var(--sans);background-color:var(--paper);background-image:url(\"data:image/svg+xml,%3Csvg xmlns=%22http://www.w3.org/2000/svg%22 width=%22220%22 height=%22220%22%3E%3Cfilter id=%22n%22%3E%3CfeTurbulence type=%22fractalNoise%22 baseFrequency=%22.85%22 numOctaves=%222%22 stitchTiles=%22stitch%22/%3E%3CfeColorMatrix values=%220 0 0 0 .43 0 0 0 0 .35 0 0 0 0 .28 0 0 0 .07 0%22/%3E%3C/filter%3E%3Crect width=%22100%25%22 height=%22100%25%22 filter=%22url(%23n)%22/%3E%3C/svg%3E\"),radial-gradient(120% 80% at 50% 0%,#fbf7f1 0%,rgba(251,247,241,0) 60%),linear-gradient(180deg,#f7f1e9 0%,#f3ece2 100%);background-attachment:fixed;color:var(--ink);line-height:1.45;text-rendering:optimizeLegibility;}',
    'button,a{font:inherit;}button{min-height:46px;border-radius:999px;border:1.5px solid var(--accent);padding:11px 22px;background:rgba(251,247,241,.7);color:var(--accent);text-decoration:none;font-family:var(--serif);font-weight:400;font-size:15px;letter-spacing:.2em;text-transform:uppercase;display:inline-flex;align-items:center;justify-content:center;gap:8px;cursor:pointer;-webkit-tap-highlight-color:transparent;transition:opacity .12s ease;}button:active{opacity:.72;}',
    'button.secondary{background:transparent;color:var(--accent);border-color:rgba(112,6,11,.35);}button[hidden]{display:none;}button:focus-visible,a:focus-visible{outline:2px solid var(--focus);outline-offset:3px;}',
    '.gallery-shell{width:min(100%,880px);margin:0 auto;padding:calc(30px + env(safe-area-inset-top)) max(18px,env(safe-area-inset-left)) calc(40px + env(safe-area-inset-bottom));}',
    '.gallery-hero{padding:8px 0 26px;text-align:center;}.brand-lockup{display:inline-grid;justify-items:center;gap:6px;margin:0 0 22px;color:var(--accent);}.brand-descriptor,.footer-descriptor{font-family:var(--sans);text-transform:uppercase;letter-spacing:.24em;font-size:11px;font-weight:500;color:var(--accent);}.brand-rule{display:block;width:34px;height:1.5px;background:var(--accent);margin:2px 0 4px;}.brand-wordmark,.footer-wordmark{font-family:var(--serif-italic);font-style:italic;font-weight:400;font-size:clamp(44px,13vw,66px);line-height:.92;letter-spacing:-.04em;color:var(--accent);}.brand-secondary,.footer-secondary{font-family:var(--sans);font-weight:300;font-size:clamp(16px,4.6vw,21px);letter-spacing:.42em;margin-right:-.42em;color:var(--accent);line-height:1;}',
    'h1{font-family:var(--serif-italic);font-style:italic;font-size:clamp(34px,9.5vw,58px);font-weight:400;line-height:1.02;margin:6px 0 12px;letter-spacing:-.01em;color:var(--accent);}h2{font-size:20px;margin:0 0 10px;letter-spacing:0;}.brand{text-transform:uppercase;letter-spacing:.22em;color:var(--accent);font-size:12px;font-weight:500;margin:0 0 8px;}.lede{max-width:620px;margin:0 auto;font-family:var(--serif-italic);font-style:italic;font-size:clamp(18px,4.8vw,23px);color:var(--accent);}p{color:var(--muted);margin:0;}',
    '.primary-actions{display:grid;justify-items:center;gap:9px;padding:2px 0 34px;text-align:center;}#shareAll{width:min(100%,360px);min-height:58px;font-size:16px;}#message{min-height:22px;color:var(--accent);font-weight:500;}#allHint{font-size:14px;letter-spacing:.04em;}',
    '.section-heading{display:flex;align-items:center;gap:14px;margin:0 0 16px;}.section-heading:before,.section-heading:after{content:\"\";height:1px;background:rgba(112,6,11,.25);flex:1;}.section-heading p{text-transform:uppercase;letter-spacing:.24em;font-size:12px;font-weight:500;color:var(--accent);}',
    '.photo-grid{display:grid;grid-template-columns:1fr;gap:24px;}.photo-item,.receipt-item{display:grid;gap:10px;}.image-button{display:block;width:100%;min-height:0;padding:7px;border:1px solid var(--line);border-radius:2px;background:var(--surface);color:inherit;letter-spacing:0;text-transform:none;box-shadow:0 10px 24px rgba(110,90,72,.12);overflow:hidden;text-align:inherit;}img{display:block;width:100%;height:auto;background:var(--paper-warm);border-radius:0;}.image-placeholder{min-height:245px;display:grid;place-items:center;background:var(--paper-warm);color:var(--muted);font-family:var(--serif-italic);font-style:italic;font-size:17px;border:0;border-radius:0;}.photo-actions{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:0 2px;}.photo-actions span{font-size:12px;font-weight:500;letter-spacing:.2em;text-transform:uppercase;color:var(--accent);}.photo-actions div{display:flex;gap:8px;flex-wrap:wrap;justify-content:flex-end;}.photo-actions button{min-height:40px;padding:8px 14px;font-size:12px;}',
    '.gif-section,.receipt-section{margin-top:38px;padding-top:6px;}.gif-item{max-width:680px;margin:0 auto;width:100%;display:grid;gap:10px}.gif-item img{width:100%;max-height:680px;object-fit:contain;}.receipt-grid{display:grid;grid-template-columns:1fr;gap:24px}.receipt-item{max-width:430px;margin:0 auto;width:100%}.receipt-placeholder{min-height:360px;}.receipt-item img{max-height:560px;object-fit:contain;background:#fff;}',
    '.session-note{margin:36px auto 0;display:grid;gap:3px;text-align:center;font-size:12px;letter-spacing:.12em;text-transform:uppercase;color:var(--taupe);}.session-note p{color:var(--taupe);}.session-note p:last-child{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;letter-spacing:.04em;text-transform:none;}footer{margin-top:34px;padding-top:28px;border-top:1px solid rgba(112,6,11,.2);display:grid;justify-items:center;gap:6px;text-align:center;color:var(--accent);}.footer-wordmark{font-size:clamp(36px,10vw,48px);}.footer-tagline{margin-top:8px;font-family:var(--serif-italic);font-style:italic;font-size:17px;color:var(--accent);}',
    '.center-page{min-height:100vh;display:grid;place-items:center;padding:calc(28px + env(safe-area-inset-top)) 20px calc(42px + env(safe-area-inset-bottom));}.notice{width:min(100%,480px);text-align:center;background:rgba(251,247,241,.82);border:1px solid rgba(112,6,11,.22);border-radius:2px;padding:36px 24px;box-shadow:0 14px 32px rgba(110,90,72,.1);}.notice .brand-lockup{margin-bottom:18px;}.notice h1{font-size:clamp(30px,8vw,42px);margin:8px 0 12px;}.notice button{margin-top:22px;}.loader{width:32px;height:32px;border-radius:50%;border:1.5px solid var(--line);border-top-color:var(--accent);margin:20px auto;animation:spin 1s linear infinite;}@keyframes spin{to{transform:rotate(360deg);}}',
    '.lightbox{position:fixed;inset:0;z-index:10;display:grid;grid-template-rows:auto 1fr auto;gap:14px;padding:calc(16px + env(safe-area-inset-top)) 16px calc(18px + env(safe-area-inset-bottom));background:rgba(43,36,34,.94);}.lightbox[hidden]{display:none;}.lightbox img{width:100%;height:100%;max-height:calc(100vh - 150px);object-fit:contain;background:transparent;border-radius:0;}.lightbox-close,.lightbox-save{justify-self:center;min-width:160px;}.lightbox-close,.lightbox-save{background:var(--surface);color:var(--accent);border-color:var(--surface);}',
    '@media(prefers-reduced-motion:reduce){.loader{animation:none;}button{transition:none;}}',
    '@media(min-width:560px){.photo-grid{grid-template-columns:repeat(2,minmax(0,1fr));}.photo-count-1{grid-template-columns:1fr;}.photo-count-1 .photo-item{max-width:680px;margin:0 auto;}}',
    '@media(min-width:900px){.gallery-shell{padding-left:24px;padding-right:24px;}.gallery-hero{padding-top:18px;}.photo-grid{gap:28px;}.photo-count-3,.photo-count-4{grid-template-columns:repeat(2,minmax(0,1fr));}}'
  ].join('');
}
function galleryClientScript_() {

  return [

    'const startedAt=performance.now();const files=[...galleryData.photos,galleryData.gif,galleryData.receipt,galleryData.thermalReceipt].filter(Boolean);const assetMap=new Map(files.map(function(item){return [item.filename,item];}));const realFileCache=new Map();let activeLightboxURL=\"\";let activeLightboxItem=null;',

    'const message=document.getElementById(\"message\");',

    'function setMessage(text){if(message){message.textContent=text||\"\";}}',

    'function dataURL(item){return \"data:\"+item.mimeType+\";base64,\"+item.base64Data;}',

    'function fileForItem(item){if(realFileCache.has(item.filename)){return realFileCache.get(item.filename);}const binary=atob(item.base64Data);const bytes=new Uint8Array(binary.length);for(let i=0;i<binary.length;i++){bytes[i]=binary.charCodeAt(i);}const file=new File([bytes],item.filename,{type:item.mimeType});realFileCache.set(item.filename,file);return file;}',

    'function objectURLFor(item){return URL.createObjectURL(fileForItem(item));}',

    'function findItem(filename){return assetMap.get(filename);}',

    'function showEmbeddedImages(){try{files.forEach(function(item){const image=document.getElementById(\"image-\"+item.filename);const placeholder=document.getElementById(\"placeholder-\"+item.filename);if(image){image.src=dataURL(item);image.hidden=false;}if(placeholder){placeholder.remove();}});wireOpenButtons();wireShareButtons();wireShareAll();wireLightbox();logSafeBrowserTiming();setMessage(\"\");}catch(error){setMessage(\"Some images did not load. Refresh this page and try again.\");}}',

    'function downloadItem(item){try{const url=objectURLFor(item);const a=document.createElement(\"a\");a.href=url;a.download=item.filename;document.body.appendChild(a);a.click();a.remove();setTimeout(function(){URL.revokeObjectURL(url);},1500);setMessage(\"Download started.\");}catch(error){setMessage(\"Could not start the download. Please try again.\");}}',

    'function roleText(item){if(item.role===\"gif\"){return {name:\"GIF\",alt:\"Animated Made to Keep Studios session GIF\",save:\"Save GIF\"};}if(item.role===\"colorReceipt\"){return {name:\"color receipt\",alt:\"Made to Keep Studios color receipt preview\",save:\"Save Receipt\"};}if(item.role===\"thermalReceipt\"){return {name:\"thermal receipt\",alt:\"Made to Keep Studios thermal receipt preview\",save:\"Save Receipt\"};}return {name:\"photo\",alt:\"Made to Keep Studios photo\",save:\"Save Photo\"};}',

    'function openFullSize(item){try{const lightbox=document.getElementById(\"lightbox\");const image=document.getElementById(\"lightboxImage\");const save=document.getElementById(\"lightboxSave\");const text=roleText(item);if(!lightbox||!image||!save){const url=objectURLFor(item);window.open(url,\"_blank\",\"noopener\");setTimeout(function(){URL.revokeObjectURL(url);},30000);return;}if(activeLightboxURL){URL.revokeObjectURL(activeLightboxURL);}activeLightboxItem=item;activeLightboxURL=URL.createObjectURL(fileForItem(item));image.src=activeLightboxURL;image.alt=text.alt;save.textContent=text.save;lightbox.hidden=false;document.body.style.overflow=\"hidden\";document.getElementById(\"lightboxClose\").focus();setMessage(text.name+\" opened.\");}catch(error){setMessage(\"Could not open the full-size image. Please try Save instead.\");}}',

    'function closeLightbox(){const lightbox=document.getElementById(\"lightbox\");const image=document.getElementById(\"lightboxImage\");if(lightbox){lightbox.hidden=true;}if(image){image.removeAttribute(\"src\");}document.body.style.overflow=\"\";if(activeLightboxURL){URL.revokeObjectURL(activeLightboxURL);activeLightboxURL=\"\";}activeLightboxItem=null;}',

    'async function shareItem(item){try{const file=fileForItem(item);if(!supportsFileShare(item)){downloadItem(item);return;}await navigator.share({files:[file],title:\"Made to Keep Studios\",text:\"Made to Keep Studios \"+roleText(item).name});setMessage(\"Share sheet opened.\");}catch(error){if(error&&error.name===\"AbortError\"){return;}downloadItem(item);setMessage(\"Sharing is unavailable here. Download started instead.\");}}',

    'function supportsFileShare(item){if(!navigator.share||!navigator.canShare||!item){return false;}try{return navigator.canShare({files:[new File([new Uint8Array([1])],item.filename,{type:item.mimeType})]});}catch(error){return false;}}',

    'function supportsSingleFileShare(){return supportsFileShare({filename:\"photo-01.jpg\",mimeType:\"image/jpeg\"});}',

    'function supportsMultipleFileShare(){if(!navigator.share||!navigator.canShare){return false;}try{return navigator.canShare({files:[new File([new Uint8Array([1])],\"photo-01.jpg\",{type:\"image/jpeg\"}),new File([new Uint8Array([2])],\"photo-02.jpg\",{type:\"image/jpeg\"})]});}catch(error){return false;}}',

    'document.querySelectorAll(\"[data-download]\").forEach(function(button){button.addEventListener(\"click\",function(){const item=findItem(button.getAttribute(\"data-download\"));if(item){downloadItem(item);}});});',

    'function wireOpenButtons(){document.querySelectorAll(\"[data-open]\").forEach(function(button){button.addEventListener(\"click\",function(){const item=findItem(button.getAttribute(\"data-open\"));if(item){openFullSize(item);}});});}',

    'function wireLightbox(){const close=document.getElementById(\"lightboxClose\");const lightbox=document.getElementById(\"lightbox\");const save=document.getElementById(\"lightboxSave\");if(close){close.addEventListener(\"click\",closeLightbox);}if(lightbox){lightbox.addEventListener(\"click\",function(event){if(event.target===lightbox){closeLightbox();}});}if(save){save.addEventListener(\"click\",function(){if(activeLightboxItem){downloadItem(activeLightboxItem);}});}document.addEventListener(\"keydown\",function(event){if(event.key===\"Escape\"){closeLightbox();}});}',

    'function wireShareButtons(){document.querySelectorAll(\"[data-share]\").forEach(function(button){const item=findItem(button.getAttribute(\"data-share\"));if(!item){button.hidden=true;return;}if(!supportsFileShare(item)){button.textContent=item.role===\"gif\"?\"Download GIF\":\"Download\";}button.addEventListener(\"click\",function(){shareItem(item);});});}',

    'function wireShareAll(){const shareAll=document.getElementById(\"shareAll\");const allHint=document.getElementById(\"allHint\");if(!shareAll){return;}const photos=galleryData.photos.map(function(file){return findItem(file.filename);}).filter(Boolean);if(supportsMultipleFileShare()){shareAll.addEventListener(\"click\",async function(){try{await navigator.share({files:photos.map(fileForItem),title:\"Made to Keep Studios\",text:\"Made to Keep Studios photos\"});setMessage(\"Share sheet opened.\");}catch(error){if(error&&error.name!==\"AbortError\"){setMessage(\"Sharing all photos did not work here. Please save each photo below.\");}}});}else{shareAll.className=\"secondary\";shareAll.textContent=\"Save Photos Individually\";shareAll.addEventListener(\"click\",function(){setMessage(\"Use each Save Photo button below for the most reliable save.\");});if(allHint){allHint.textContent=\"This browser does not support sharing multiple image files from the page.\";}}}',

    'function logSafeBrowserTiming(){setTimeout(function(){const supportsShare=!!navigator.share;const supportsSingle=supportsSingleFileShare();const supportsMultiple=supportsMultipleFileShare();console.log(\"Made to Keep gallery timing: imageInitializationMs=\"+Math.round(performance.now()-startedAt)+\" webShare=\"+supportsShare+\" singleFileShare=\"+supportsSingle+\" multiFileShare=\"+supportsMultiple+\" realFileConversionsAtInit=0\");},0);}',

    'showEmbeddedImages();'

  ].join('');

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
    gif: GIF_FILENAME,
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

function expectedFilenames_(photoCount, schemaVersion) {

  return expectedPhotoFilenames_(photoCount).concat(schemaVersion === 2
    ? [RECEIPT_FILENAME, THERMAL_RECEIPT_FILENAME, GIF_FILENAME]
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
