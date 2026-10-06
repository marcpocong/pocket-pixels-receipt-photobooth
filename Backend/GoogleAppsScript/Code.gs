const SCHEMA_VERSION = 1;

const ROOT_FOLDER_ID_PROPERTY = 'POCKET_PIXELS_ROOT_FOLDER_ID';

const DEVICE_TOKEN_PROPERTY = 'POCKET_PIXELS_DEVICE_TOKEN';

const CUSTOMER_GALLERY_BASE_URL_PROPERTY = 'POCKET_PIXELS_CUSTOMER_GALLERY_BASE_URL';

const GALLERY_FOLDER_INDEX_PREFIX = 'POCKET_PIXELS_GALLERY_FOLDER_';

const MIN_PHOTO_COUNT = 1;

const MAX_PHOTO_COUNT = 6;

const MAX_IMAGE_DECODED_BYTES = 6 * 1024 * 1024;

const GALLERY_TOKEN_PATTERN = /^[a-f0-9]{64}$/;

const SAFE_SESSION_ID_PATTERN = /^PP-[0-9]{8}-[0-9]{6}$/;

const RFC3339_UTC_SECONDS_PATTERN = /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/;

const RECEIPT_FILENAME = 'receipt-color.jpg';

const MANIFEST_FILENAME = 'manifest.json';

const MAX_REQUEST_BYTES = 28 * 1024 * 1024;

const MAX_GALLERY_DECODED_BYTES = 6 * 1024 * 1024;

const MAX_GALLERY_BASE64_CHARS = 9 * 1024 * 1024;

const BACKEND_VERSION = 'phase6c-worker-raw-html-proxy-20260831';

const POCKET_PIXELS_MONOGRAM_WEB_BASE64 = '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';

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
      schemaVersion: SCHEMA_VERSION,
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

  assert_(Object.keys(manifest).join(',') === 'schemaVersion,galleryToken,sessionID,createdAt,photos,receipt,status', 'Manifest keys changed.');

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

  wrongSchema.schemaVersion = 2;

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

  if (expectedFilenames_(MAX_PHOTO_COUNT).indexOf(String(filename || '')) === -1) {

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

  const requiredFields = ['schemaVersion', 'deviceToken', 'galleryToken', 'sessionID', 'createdAt', 'photos', 'receipt'];

  for (let i = 0; i < requiredFields.length; i++) {

    if (!body || !Object.prototype.hasOwnProperty.call(body, requiredFields[i])) {

      return validationError_('MISSING_FIELD', 'Missing required field.', requiredFields[i]);

    }

  }

  if (typeof body.schemaVersion !== 'number') {

    return validationError_('INVALID_FIELD_TYPE', 'schemaVersion must be a number.', 'schemaVersion');

  }

  if (body.schemaVersion !== SCHEMA_VERSION) {

    return validationError_('INVALID_SCHEMA_VERSION', 'Unsupported schema version.', 'schemaVersion');

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

  const receiptError = validateImage_(body.receipt, RECEIPT_FILENAME, 'receipt');

  if (!receiptError.ok) {

    return receiptError;

  }

  validatedImages.push(receiptError.image);

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

function validateImage_(image, expectedFilename, field) {

  if (!image || typeof image !== 'object') {

    return validationError_(field === 'receipt' ? 'INVALID_RECEIPT' : 'INVALID_FIELD_TYPE', 'Image must be an object.', field);

  }

  if (typeof image.filename !== 'string' || typeof image.mimeType !== 'string' || typeof image.base64Data !== 'string') {

    return validationError_(field === 'receipt' ? 'INVALID_RECEIPT' : 'INVALID_FIELD_TYPE', 'Image fields must be strings.', field);

  }

  if (!image || image.filename !== expectedFilename) {

    return validationError_(field === 'receipt' ? 'INVALID_RECEIPT' : 'INVALID_PHOTO_FILENAME', 'Unexpected image filename.', field + '.filename');

  }

  if (image.mimeType !== 'image/jpeg') {

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

  if (!hasJpegSignature_(bytes)) {

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
  const expected = expectedFilenames_(body.photos.length);
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

  const images = body.photos.concat([body.receipt]);

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

  return manifest.schemaVersion === SCHEMA_VERSION &&

    GALLERY_TOKEN_PATTERN.test(String(manifest.galleryToken || '')) &&

    SAFE_SESSION_ID_PATTERN.test(String(manifest.sessionID || '')) &&

    isValidCreatedAt_(manifest.createdAt) &&

    Array.isArray(manifest.photos) &&

    count >= MIN_PHOTO_COUNT &&

    count <= MAX_PHOTO_COUNT &&

    photoFilenames.length === count &&

    manifest.photos.join('|') === photoFilenames.join('|') &&

    manifest.receipt === RECEIPT_FILENAME &&

    Object.keys(manifest).join(',') === 'schemaVersion,galleryToken,sessionID,createdAt,photos,receipt,status';

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

  const inspection = inspectGalleryFolder_(folder, expectedFilenames_(MAX_PHOTO_COUNT));

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

  const expected = expectedFilenames_(manifest.photos.length);
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
  const inspection = inspectGalleryFolder_(folder, expectedFilenames_(MAX_PHOTO_COUNT));
  if (!inspection.safe || inspection.manifests.length !== 1) {
    return null;
  }

  const manifest = readManifest_(inspection.manifests[0]);
  if (manifest.galleryToken !== token || manifest.status !== 'complete' || !manifestHasExpectedFiles_(manifest)) {
    return null;
  }

  const expected = expectedFilenames_(manifest.photos.length);
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

function pocketPixelsMonogramDataURI_() {

  return 'data:image/png;base64,' + POCKET_PIXELS_MONOGRAM_WEB_BASE64;

}

function pocketPixelsBrandLockupHTML_() {

  return '<div class="brand-lockup"><img src="' + pocketPixelsMonogramDataURI_() + '" alt="" aria-hidden="true" width="135" height="128"><div><p>Pocket Pixels</p><span>Receipt Photobooth</span></div></div>';

}

function renderInvalidGalleryPage_() {

  return makeHTML_(pageShell_(

    '<main class="center-page"><section class="notice">' + pocketPixelsBrandLockupHTML_() + '<h1>we could not load your photos just yet.</h1><p>This gallery link cannot be opened. Please try scanning the QR again.</p><button type="button" onclick="window.location.reload()">Try Again</button></section></main>',

    ''

  ));

}

function renderPendingGalleryPage_() {

  const script = 'var started=Date.now();var timer=setInterval(function(){if(Date.now()-started>120000){clearInterval(timer);return;}window.location.reload();},8000);';

  return makeHTML_(pageShell_(

    '<main class="center-page"><section class="notice">' + pocketPixelsBrandLockupHTML_() + '<h1>your photos are still being prepared.</h1><div class="loader" aria-hidden="true"></div><p>Please check again in a moment.</p><button type="button" onclick="window.location.reload()">Check Again</button></section></main>',

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

    receipt: assets.receipt

  }).replace(/</g, '\\u003c');

  let body = '';

  body += '<main class="gallery-shell" data-pocket-pixels-gallery-status="complete">';

  body += '<header class="gallery-hero">' + pocketPixelsBrandLockupHTML_() + '<h1>your photos are ready.</h1><p class="lede">save the moments you made at the receipt photobooth.</p></header>';

  body += '<section class="primary-actions" aria-label="Save photos"><button type="button" id="shareAll">Save All Photos</button><p id="allHint">Save your photos before closing this page.</p><p id="message" role="status" aria-live="polite"></p></section>';

  body += '<section class="section-heading"><p>Photo Gallery</p></section>';

  body += '<section class="photo-grid photo-count-' + assets.photos.length + '" aria-label="Pocket Pixels photo gallery">';

  for (let i = 0; i < assets.photos.length; i++) {

    const filename = assets.photos[i].filename;
    const loading = i === 0 ? 'eager' : 'lazy';

    body += '<article class="photo-item"><button type="button" class="image-button" data-open="' + filename + '" aria-label="View photo ' + (i + 1) + ' larger"><div class="image-placeholder" id="placeholder-' + filename + '">getting photo ready...</div><img hidden decoding="async" loading="' + loading + '" id="image-' + filename + '" alt="Pocket Pixels photo ' + (i + 1) + '"></button><div class="photo-actions"><span>Photo ' + (i + 1) + '</span><div><button type="button" data-download="' + filename + '">Save Photo</button><button type="button" class="secondary" data-share="' + filename + '">Share</button></div></div></article>';

  }

  body += '</section>';

  body += '<section class="receipt-section"><div class="section-heading"><p>Receipt Copy</p></div><article class="receipt-item"><button type="button" class="image-button" data-open="' + assets.receipt.filename + '" aria-label="View receipt larger"><div class="image-placeholder receipt-placeholder" id="placeholder-' + assets.receipt.filename + '">getting receipt ready...</div><img hidden decoding="async" loading="lazy" id="image-' + assets.receipt.filename + '" alt="Pocket Pixels receipt preview"></button><div class="photo-actions"><span>Receipt</span><div><button type="button" data-download="' + assets.receipt.filename + '">Save Receipt</button><button type="button" class="secondary" data-share="' + assets.receipt.filename + '">Share</button></div></div></article></section>';

  body += '<section class="session-note"><p>' + escapeHTML(createdAt) + '</p><p>' + escapeHTML(reference) + '</p></section>';

  body += '<footer><img class="footer-mark" src="' + pocketPixelsMonogramDataURI_() + '" alt="" aria-hidden="true" width="135" height="128"><strong>Pocket Pixels</strong><a href="https://www.instagram.com/pocketpixels.ceb" rel="noreferrer noopener">@pocketpixels.ceb</a><span>receipt photobooth</span></footer>';

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

    '<main class="center-page"><section class="notice">' + pocketPixelsBrandLockupHTML_() + '<h1>Gallery temporarily unavailable.</h1><p>Please ask the booth operator to refresh this gallery.</p></section></main>',

    ''

  ));

}

function makeHTML_(html) {

  return HtmlService.createHtmlOutput(html)

    .setTitle('Pocket Pixels Gallery')

    .setXFrameOptionsMode(HtmlService.XFrameOptionsMode.ALLOWALL);

}

function pageShell_(body, script) {

  return '<!doctype html><html lang="en"><head><meta charset="utf-8">' +

    '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">' +

    '<meta name="robots" content="noindex,nofollow"><base target="_top">' +

    '<title>Pocket Pixels Gallery</title><style>' + galleryCSS_() + '</style></head><body>' +

    body + '<script>' + script + '</script></body></html>';

}

function loadGalleryAssets_(filesByName, manifest) {

  const photos = [];

  for (let i = 0; i < manifest.photos.length; i++) {

    photos.push(loadGalleryAsset_(filesByName, manifest.photos[i]));

  }

  return {

    photos: photos,

    receipt: loadGalleryAsset_(filesByName, manifest.receipt)

  };

}

function loadGalleryAsset_(filesByName, filename) {

  const file = filesByName && filesByName[filename];

  if (!file) {

    throw publicError_(404, 'Gallery unavailable.', 'rejected', 'GALLERY_NOT_FOUND');

  }

  const blob = file.getBlob();

  return {

    filename: filename,

    mimeType: 'image/jpeg',

    base64Data: Utilities.base64Encode(blob.getBytes())

  };

}

function validateGalleryRenderSize_(assets) {

  const items = assets.photos.concat([assets.receipt]);

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

  return [

    ':root{color-scheme:light;--ink:#2a2020;--muted:#77605b;--paper:#fff8f2;--paper-warm:#f7ebe3;--surface:#fffdf9;--line:#ead7ce;--accent:#781f2c;--accent-soft:#f3d8cd;--accent-dark:#4f111c;--focus:#7a4cff;}',

    '*{box-sizing:border-box;}html{background:var(--paper);}body{margin:0;font-family:-apple-system,BlinkMacSystemFont,\"Segoe UI\",Roboto,Arial,sans-serif;background:linear-gradient(180deg,var(--paper) 0%,var(--surface) 46%,var(--paper-warm) 100%);color:var(--ink);line-height:1.45;text-rendering:optimizeLegibility;}',

    'button,a{font:inherit;}button{min-height:44px;border-radius:8px;border:1px solid var(--accent);padding:11px 15px;background:var(--accent);color:white;text-decoration:none;font-weight:800;display:inline-flex;align-items:center;justify-content:center;gap:8px;cursor:pointer;-webkit-tap-highlight-color:transparent;}',

    'button.secondary{background:transparent;color:var(--accent);border-color:rgba(120,31,44,.24);}button[hidden]{display:none;}button:focus-visible,a:focus-visible{outline:3px solid var(--focus);outline-offset:3px;}',

    '.gallery-shell{width:min(100%,880px);margin:0 auto;padding:calc(26px + env(safe-area-inset-top)) max(18px,env(safe-area-inset-left)) calc(40px + env(safe-area-inset-bottom));}',

    '.gallery-hero{padding:8px 0 22px;text-align:left;}.brand-lockup{display:inline-flex;align-items:center;gap:10px;margin:0 0 16px;vertical-align:top;}.brand-lockup img{width:34px;height:34px;object-fit:contain;background:transparent;border-radius:0;box-shadow:none;flex:0 0 auto;}.brand-lockup div{display:grid;gap:1px;min-width:0;}.brand-lockup p{text-transform:uppercase;letter-spacing:.16em;color:var(--accent);font-size:12px;font-weight:900;margin:0;line-height:1.05;}.brand-lockup span{text-transform:uppercase;letter-spacing:.13em;color:#8f635c;font-size:10px;font-weight:900;line-height:1.1;}h1{font-family:Georgia,\"Times New Roman\",serif;font-size:clamp(38px,11vw,74px);font-weight:400;line-height:.98;margin:8px 0 12px;letter-spacing:0;color:var(--accent-dark);}h2{font-size:20px;margin:0 0 10px;letter-spacing:0;}.brand{text-transform:uppercase;letter-spacing:.16em;color:var(--accent);font-size:12px;font-weight:900;margin:0 0 8px;}.lede{max-width:620px;font-size:clamp(18px,4.8vw,24px);color:var(--muted);margin:0;}p{color:var(--muted);margin:0;}',

    '.primary-actions{display:grid;gap:9px;padding:2px 0 30px;}#shareAll{width:100%;min-height:54px;font-size:17px;box-shadow:0 10px 22px rgba(120,31,44,.16);}#message{min-height:22px;color:var(--accent-dark);font-weight:700;}#allHint{font-size:14px;}',

    '.section-heading{display:flex;align-items:center;gap:12px;margin:0 0 14px;}.section-heading:after{content:\"\";height:1px;background:var(--line);flex:1;}.section-heading p{text-transform:uppercase;letter-spacing:.14em;font-size:12px;font-weight:900;color:var(--accent);}',

    '.photo-grid{display:grid;grid-template-columns:1fr;gap:22px;}.photo-item,.receipt-item{display:grid;gap:10px;}.image-button{display:block;width:100%;min-height:0;padding:0;border:0;border-radius:10px;background:transparent;color:inherit;box-shadow:0 16px 32px rgba(42,32,32,.08);overflow:hidden;text-align:inherit;}img{display:block;width:100%;height:auto;background:var(--paper-warm);border-radius:10px;}.image-placeholder{min-height:245px;display:grid;place-items:center;background:var(--paper-warm);color:var(--muted);font-weight:800;border:1px solid var(--line);border-radius:10px;}.photo-actions{display:flex;align-items:center;justify-content:space-between;gap:12px;padding:0 2px;}.photo-actions span{font-size:14px;font-weight:800;color:var(--muted);}.photo-actions div{display:flex;gap:8px;flex-wrap:wrap;justify-content:flex-end;}.photo-actions button{min-height:40px;padding:9px 12px;font-size:14px;}',

    '.receipt-section{margin-top:34px;padding-top:6px;}.receipt-item{max-width:430px;margin:0 auto;}.receipt-placeholder{min-height:360px;}.receipt-item img{max-height:560px;object-fit:contain;}',

    '.session-note{margin:34px auto 0;display:grid;gap:3px;text-align:center;font-size:13px;color:var(--muted);}.session-note p:last-child{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;color:#8f7771;}footer{margin-top:30px;padding-top:22px;border-top:1px solid var(--line);display:grid;justify-items:center;gap:5px;text-align:center;color:var(--muted);}.footer-mark{width:30px;height:30px;object-fit:contain;background:transparent;border-radius:0;margin-bottom:2px;}footer strong{font-family:Georgia,\"Times New Roman\",serif;font-size:24px;font-weight:400;color:var(--accent-dark);}footer a{color:var(--accent);font-weight:800;text-decoration:none;}footer span{font-size:13px;text-transform:uppercase;letter-spacing:.12em;font-weight:900;}',

    '.center-page{min-height:100vh;display:grid;place-items:center;padding:calc(28px + env(safe-area-inset-top)) 20px calc(42px + env(safe-area-inset-bottom));}.notice{width:min(100%,480px);text-align:center;background:var(--surface);border:1px solid var(--line);border-radius:10px;padding:34px 22px;box-shadow:0 14px 32px rgba(42,32,32,.08);}.notice .brand-lockup{justify-content:center;margin-bottom:16px;}.notice .brand-lockup img{width:32px;height:32px;}.notice h1{font-family:Georgia,\"Times New Roman\",serif;font-size:clamp(34px,9vw,48px);font-weight:400;line-height:1.02;margin:8px 0 12px;color:var(--accent-dark);}.notice button{margin-top:22px;}.loader{width:34px;height:34px;border-radius:50%;border:4px solid var(--line);border-top-color:var(--accent);margin:20px auto;animation:spin 1s linear infinite;}@keyframes spin{to{transform:rotate(360deg);}}',

    '.lightbox{position:fixed;inset:0;z-index:10;display:grid;grid-template-rows:auto 1fr auto;gap:14px;padding:calc(16px + env(safe-area-inset-top)) 16px calc(18px + env(safe-area-inset-bottom));background:rgba(42,32,32,.92);}.lightbox[hidden]{display:none;}.lightbox img{width:100%;height:100%;max-height:calc(100vh - 150px);object-fit:contain;background:transparent;border-radius:0;}.lightbox-close,.lightbox-save{justify-self:center;min-width:150px;}.lightbox-close{background:var(--surface);color:var(--accent);border-color:var(--surface);}',

    '@media(prefers-reduced-motion:reduce){.loader{animation:none;}}',

    '@media(min-width:560px){.photo-grid{grid-template-columns:repeat(2,minmax(0,1fr));}.photo-count-1{grid-template-columns:1fr;}.photo-count-1 .photo-item{max-width:680px;margin:0 auto;}.primary-actions{grid-template-columns:minmax(220px,320px) 1fr;align-items:center;}#shareAll{width:auto;}}',

    '@media(min-width:900px){.gallery-shell{padding-left:24px;padding-right:24px;}.gallery-hero{padding-top:18px;}.photo-grid{gap:26px;}.photo-count-3,.photo-count-4{grid-template-columns:repeat(2,minmax(0,1fr));}}'

  ].join('');

}

function galleryClientScript_() {

  return [

    'const startedAt=performance.now();const files=[...galleryData.photos,galleryData.receipt];const assetMap=new Map(files.map(function(item){return [item.filename,item];}));const realFileCache=new Map();let activeLightboxURL=\"\";let activeLightboxItem=null;',

    'const message=document.getElementById(\"message\");',

    'function setMessage(text){if(message){message.textContent=text||\"\";}}',

    'function dataURL(item){return \"data:\"+item.mimeType+\";base64,\"+item.base64Data;}',

    'function fileForItem(item){if(realFileCache.has(item.filename)){return realFileCache.get(item.filename);}const binary=atob(item.base64Data);const bytes=new Uint8Array(binary.length);for(let i=0;i<binary.length;i++){bytes[i]=binary.charCodeAt(i);}const file=new File([bytes],item.filename,{type:item.mimeType});realFileCache.set(item.filename,file);return file;}',

    'function objectURLFor(item){return URL.createObjectURL(fileForItem(item));}',

    'function findItem(filename){return assetMap.get(filename);}',

    'function showEmbeddedImages(){try{files.forEach(function(item){const image=document.getElementById(\"image-\"+item.filename);const placeholder=document.getElementById(\"placeholder-\"+item.filename);if(image){image.src=dataURL(item);image.hidden=false;}if(placeholder){placeholder.remove();}});wireOpenButtons();wireShareButtons();wireShareAll();wireLightbox();logSafeBrowserTiming();setMessage(\"\");}catch(error){setMessage(\"Some images did not load. Refresh this page and try again.\");}}',

    'function downloadItem(item){try{const url=objectURLFor(item);const a=document.createElement(\"a\");a.href=url;a.download=item.filename;document.body.appendChild(a);a.click();a.remove();setTimeout(function(){URL.revokeObjectURL(url);},1500);setMessage(\"Download started.\");}catch(error){setMessage(\"Could not start the download. Please try again.\");}}',

    'function openFullSize(item){try{const lightbox=document.getElementById(\"lightbox\");const image=document.getElementById(\"lightboxImage\");const save=document.getElementById(\"lightboxSave\");if(!lightbox||!image||!save){const url=objectURLFor(item);window.open(url,\"_blank\",\"noopener\");setTimeout(function(){URL.revokeObjectURL(url);},30000);return;}if(activeLightboxURL){URL.revokeObjectURL(activeLightboxURL);}activeLightboxItem=item;activeLightboxURL=URL.createObjectURL(fileForItem(item));image.src=activeLightboxURL;image.alt=item.filename.indexOf(\"receipt\")===0?\"Pocket Pixels receipt preview\":\"Pocket Pixels photo\";save.textContent=item.filename.indexOf(\"receipt\")===0?\"Save Receipt\":\"Save Photo\";lightbox.hidden=false;document.body.style.overflow=\"hidden\";document.getElementById(\"lightboxClose\").focus();setMessage(\"Photo opened.\");}catch(error){setMessage(\"Could not open the full-size image. Please try Save instead.\");}}',

    'function closeLightbox(){const lightbox=document.getElementById(\"lightbox\");const image=document.getElementById(\"lightboxImage\");if(lightbox){lightbox.hidden=true;}if(image){image.removeAttribute(\"src\");}document.body.style.overflow=\"\";if(activeLightboxURL){URL.revokeObjectURL(activeLightboxURL);activeLightboxURL=\"\";}activeLightboxItem=null;}',

    'async function shareItem(item){try{const file=fileForItem(item);if(!supportsSingleFileShare()){downloadItem(item);return;}await navigator.share({files:[file],title:\"Pocket Pixels\",text:\"Pocket Pixels photo\"});setMessage(\"Share sheet opened.\");}catch(error){if(error&&error.name===\"AbortError\"){return;}setMessage(\"Sharing did not work here. Please use Download instead.\");}}',

    'function supportsSingleFileShare(){if(!navigator.share||!navigator.canShare){return false;}try{return navigator.canShare({files:[new File([new Uint8Array([1])],\"photo-01.jpg\",{type:\"image/jpeg\"})]});}catch(error){return false;}}',

    'function supportsMultipleFileShare(){if(!navigator.share||!navigator.canShare){return false;}try{return navigator.canShare({files:[new File([new Uint8Array([1])],\"photo-01.jpg\",{type:\"image/jpeg\"}),new File([new Uint8Array([2])],\"photo-02.jpg\",{type:\"image/jpeg\"})]});}catch(error){return false;}}',

    'document.querySelectorAll(\"[data-download]\").forEach(function(button){button.addEventListener(\"click\",function(){const item=findItem(button.getAttribute(\"data-download\"));if(item){downloadItem(item);}});});',

    'function wireOpenButtons(){document.querySelectorAll(\"[data-open]\").forEach(function(button){button.addEventListener(\"click\",function(){const item=findItem(button.getAttribute(\"data-open\"));if(item){openFullSize(item);}});});}',

    'function wireLightbox(){const close=document.getElementById(\"lightboxClose\");const lightbox=document.getElementById(\"lightbox\");const save=document.getElementById(\"lightboxSave\");if(close){close.addEventListener(\"click\",closeLightbox);}if(lightbox){lightbox.addEventListener(\"click\",function(event){if(event.target===lightbox){closeLightbox();}});}if(save){save.addEventListener(\"click\",function(){if(activeLightboxItem){downloadItem(activeLightboxItem);}});}document.addEventListener(\"keydown\",function(event){if(event.key===\"Escape\"){closeLightbox();}});}',

    'function wireShareButtons(){const supported=supportsSingleFileShare();document.querySelectorAll(\"[data-share]\").forEach(function(button){const item=findItem(button.getAttribute(\"data-share\"));if(!item||!supported){button.hidden=true;return;}button.addEventListener(\"click\",function(){shareItem(item);});});}',

    'function wireShareAll(){const shareAll=document.getElementById(\"shareAll\");const allHint=document.getElementById(\"allHint\");if(!shareAll){return;}const photos=galleryData.photos.map(function(file){return findItem(file.filename);}).filter(Boolean);if(supportsMultipleFileShare()){shareAll.addEventListener(\"click\",async function(){try{await navigator.share({files:photos.map(fileForItem),title:\"Pocket Pixels\",text:\"Pocket Pixels photos\"});setMessage(\"Share sheet opened.\");}catch(error){if(error&&error.name!==\"AbortError\"){setMessage(\"Sharing all photos did not work here. Please save each photo below.\");}}});}else{shareAll.className=\"secondary\";shareAll.textContent=\"Save Photos Individually\";shareAll.addEventListener(\"click\",function(){setMessage(\"Use each Save Photo button below for the most reliable save.\");});if(allHint){allHint.textContent=\"This browser does not support sharing multiple image files from the page.\";}}}',

    'function logSafeBrowserTiming(){setTimeout(function(){const supportsShare=!!navigator.share;const supportsSingle=supportsSingleFileShare();const supportsMultiple=supportsMultipleFileShare();console.log(\"Pocket Pixels gallery timing: imageInitializationMs=\"+Math.round(performance.now()-startedAt)+\" webShare=\"+supportsShare+\" singleFileShare=\"+supportsSingle+\" multiFileShare=\"+supportsMultiple+\" realFileConversionsAtInit=0\");},0);}',

    'showEmbeddedImages();'

  ].join('');

}

function makeCompleteManifest_(body) {

  return {

    schemaVersion: SCHEMA_VERSION,

    galleryToken: body.galleryToken,

    sessionID: body.sessionID,

    createdAt: body.createdAt,

    photos: body._expectedPhotoFilenames || expectedPhotoFilenames_(body.photos.length),

    receipt: RECEIPT_FILENAME,

    status: 'complete'

  };

}

function makeGalleryURL_(galleryToken) {

  if (!GALLERY_TOKEN_PATTERN.test(String(galleryToken || ''))) {

    throw publicError_(400, 'Invalid gallery token.', 'rejected', 'INVALID_GALLERY_TOKEN');

  }

  const customerGalleryBaseURL = PropertiesService.getScriptProperties().getProperty(CUSTOMER_GALLERY_BASE_URL_PROPERTY);

  return makeGalleryURLFromCustomerBaseURL_(customerGalleryBaseURL, galleryToken);

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
  const raw = PropertiesService.getScriptProperties().getProperty(CUSTOMER_GALLERY_BASE_URL_PROPERTY);
  const result = {
    propertyName: CUSTOMER_GALLERY_BASE_URL_PROPERTY,
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

function expectedFilenames_(photoCount) {

  return expectedPhotoFilenames_(photoCount).concat([RECEIPT_FILENAME]);

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

    receipt: { filename: 'receipt-color.jpg', mimeType: 'image/jpeg', base64Data: '/9j/4AAQSkZJRg==' }

  };

}

function assert_(condition, message) {

  if (!condition) {

    throw new Error(message);

  }

}
