const SCHEMA_VERSION = 1;

const ROOT_FOLDER_ID_PROPERTY = 'POCKET_PIXELS_ROOT_FOLDER_ID';

const DEVICE_TOKEN_PROPERTY = 'POCKET_PIXELS_DEVICE_TOKEN';

const CUSTOMER_GALLERY_BASE_URL_PROPERTY = 'POCKET_PIXELS_CUSTOMER_GALLERY_BASE_URL';

const REQUIRED_PHOTO_COUNT = 3;

const MAX_IMAGE_DECODED_BYTES = 6 * 1024 * 1024;

const GALLERY_TOKEN_PATTERN = /^[a-f0-9]{64}$/;

const SAFE_SESSION_ID_PATTERN = /^PP-[0-9]{8}-[0-9]{6}$/;

const RFC3339_UTC_SECONDS_PATTERN = /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$/;

const PHOTO_FILENAMES = ['photo-01.jpg', 'photo-02.jpg', 'photo-03.jpg'];

const RECEIPT_FILENAME = 'receipt-color.jpg';

const MANIFEST_FILENAME = 'manifest.json';

const MAX_REQUEST_BYTES = 28 * 1024 * 1024;

const MAX_GALLERY_DECODED_BYTES = 6 * 1024 * 1024;

const MAX_GALLERY_BASE64_CHARS = 9 * 1024 * 1024;

const BACKEND_VERSION = 'phase6c-worker-raw-html-proxy-20260831';

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

  assert_(!validateUploadToken_(''), 'Missing token should fail.');

  assert_(!validateUploadToken_('wrong'), 'Incorrect token should fail when script property is configured.');

  assert_(!GALLERY_TOKEN_PATTERN.test('../bad'), 'Invalid token format should fail.');

  assert_(!GALLERY_TOKEN_PATTERN.test('A'.repeat(64)), 'Uppercase token should fail.');

  assert_(GALLERY_TOKEN_PATTERN.test('a'.repeat(64)), 'Lowercase 64-character hex token should pass.');

  const validPayload = makeSelfTestPayload_();

  const missingToken = JSON.parse(JSON.stringify(validPayload));

  delete missingToken.galleryToken;

  assert_(!validateUploadPayload_(missingToken).ok, 'Older non-idempotent requests should fail.');

  const wrongCount = JSON.parse(JSON.stringify(validPayload));

  wrongCount.photos = wrongCount.photos.slice(0, 2);

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

  badCount.photos = badCount.photos.slice(0, 2);

  assertValidationCode_(badCount, 'INVALID_PHOTO_COUNT');

  const badFilename = JSON.parse(JSON.stringify(validPayload));

  badFilename.photos[0].filename = 'photo-99.jpg';

  assertValidationCode_(badFilename, 'INVALID_PHOTO_FILENAME');

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

  if (expectedFilenames_().indexOf(String(filename || '')) === -1) {

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

    return { code: 'INVALID_FIELD_TYPE', message: 'Upload is not authorized.' };

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

  if (!Array.isArray(body.photos) || body.photos.length !== REQUIRED_PHOTO_COUNT) {

    return validationError_('INVALID_PHOTO_COUNT', 'Exactly three photos are required.', 'photos');

  }

  const validatedImages = [];

  for (let i = 0; i < REQUIRED_PHOTO_COUNT; i++) {

    const error = validateImage_(body.photos[i], PHOTO_FILENAMES[i], 'photos[' + i + ']');

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

  const folders = collectFoldersByName_(root, folderName);

  if (folders.length > 1) {

    console.error('Multiple gallery folders found for token ' + redactToken_(body.galleryToken) + '. Manual inspection required.');

    throw publicError_(409, 'Multiple matching galleries require manual inspection.', 'manualInspectionRequired', 'MANUAL_INSPECTION_REQUIRED');

  }

  if (folders.length === 0) {

    const folder = createGalleryFolder_(root, folderName);

    saveExpectedImages_(folder, body, {});

    const inspection = inspectGalleryFolder_(folder);

    if (!inspection.safe || !hasExactlyExpectedImages_(inspection)) {

      throw publicError_(500, 'Gallery could not be completed. Manual inspection required.', 'manualInspectionRequired', 'MANUAL_INSPECTION_REQUIRED');

    }

    createManifestFile_(folder, body);

    console.log('Created Pocket Pixels gallery for session ' + body.sessionID + ' with token ' + redactToken_(body.galleryToken));

    return { status: 'created', fileCount: 5 };

  }

  const folder = folders[0];

  const inspection = inspectGalleryFolder_(folder);

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

      if (manifest.galleryToken === body.galleryToken && manifest.sessionID === body.sessionID && manifestHasExpectedFiles_(manifest) && hasExactlyExpectedImages_(inspection)) {

        console.log('Returned existing Pocket Pixels gallery for session ' + body.sessionID + ' with token ' + redactToken_(body.galleryToken));

        return { status: 'existingComplete', fileCount: 5 };

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

  const repairedInspection = inspectGalleryFolder_(folder);

  if (!repairedInspection.safe || !hasExactlyExpectedImages_(repairedInspection) || repairedInspection.manifests.length > 1) {

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

  return { status: 'completedIncomplete', fileCount: 5 };

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

function inspectGalleryFolder_(folder) {

  const expected = expectedFilenames_();

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

function hasExactlyExpectedImages_(inspection) {

  const expected = expectedFilenames_();

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

function manifestHasExpectedFiles_(manifest) {

  return manifest.schemaVersion === SCHEMA_VERSION &&

    GALLERY_TOKEN_PATTERN.test(String(manifest.galleryToken || '')) &&

    SAFE_SESSION_ID_PATTERN.test(String(manifest.sessionID || '')) &&

    isValidCreatedAt_(manifest.createdAt) &&

    Array.isArray(manifest.photos) &&

    manifest.photos.join('|') === PHOTO_FILENAMES.join('|') &&

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

  const folders = collectFoldersByName_(root, 'gallery-' + token);

  if (timings) {

    timings.galleryFolderLookupMs = Date.now() - folderStartedAt;

  }

  if (folders.length !== 1) {

    return null;

  }

  const folder = folders[0];

  const inspectionStartedAt = Date.now();

  const inspection = inspectGalleryFolder_(folder);

  if (timings) {

    timings.folderInspectionMs = Date.now() - inspectionStartedAt;

  }

  if (!inspection.safe || !hasExactlyExpectedImages_(inspection) || inspection.manifests.length !== 1) {

    return null;

  }

  const manifestStartedAt = Date.now();

  const manifest = readManifest_(inspection.manifests[0]);

  if (timings) {

    timings.manifestReadValidationMs = Date.now() - manifestStartedAt;

  }

  if (manifest.galleryToken !== token || manifest.status !== 'complete' || !manifestHasExpectedFiles_(manifest)) {

    return null;

  }

  return { folder: folder, manifest: manifest, filesByName: inspection.filesByName };

}

function renderInvalidGalleryPage_() {

  return makeHTML_(pageShell_(

    '<main class="center-page"><section class="notice"><p class="brand">Pocket Pixels</p><h1>Gallery unavailable.</h1><p>This gallery link cannot be opened.</p></section></main>',

    ''

  ));

}

function renderPendingGalleryPage_() {

  const script = 'var started=Date.now();var timer=setInterval(function(){if(Date.now()-started>120000){clearInterval(timer);return;}window.location.reload();},8000);';

  return makeHTML_(pageShell_(

    '<main class="center-page"><section class="notice"><p class="brand">Pocket Pixels</p><h1>Your photos are still being prepared</h1><div class="loader" aria-hidden="true"></div><p>Your gallery will appear here as soon as the upload finishes.</p><button type="button" onclick="window.location.reload()">Check again</button></section></main>',

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

  body += '<main class="gallery">';

  body += '<header><p class="brand">Pocket Pixels</p><h1>Your photos are ready</h1><p class="meta">' + escapeHTML(createdAt) + ' · Ref ' + escapeHTML(reference) + '</p></header>';

  body += '<section class="actions"><button type="button" id="shareAll">Save All Photos</button><p id="allHint">Save your favorites before closing this page.</p><p id="message" role="status" aria-live="polite"></p></section>';

  body += '<section class="photo-grid" aria-label="Photos">';

  for (let i = 0; i < assets.photos.length; i++) {

    const filename = assets.photos[i].filename;

    body += '<article class="card"><div class="image-placeholder" id="placeholder-' + filename + '">Loading photo</div><img hidden decoding="async" id="image-' + filename + '" alt="Pocket Pixels photo ' + (i + 1) + '"><div class="card-body"><h2>Photo ' + (i + 1) + '</h2><div class="button-row"><button type="button" data-download="' + filename + '">Download Photo</button><button type="button" data-share="' + filename + '">Share Photo</button><button type="button" class="secondary" data-open="' + filename + '">Open Full Size</button></div></div></article>';

  }

  body += '</section>';

  body += '<section class="receipt-section"><h2>Receipt</h2><article class="card receipt-card"><div class="image-placeholder" id="placeholder-' + assets.receipt.filename + '">Loading receipt</div><img hidden decoding="async" loading="lazy" id="image-' + assets.receipt.filename + '" alt="Pocket Pixels receipt preview"><div class="card-body"><div class="button-row"><button type="button" data-download="' + assets.receipt.filename + '">Download Receipt</button><button type="button" data-share="' + assets.receipt.filename + '">Share Receipt</button><button type="button" class="secondary" data-open="' + assets.receipt.filename + '">Open Full Size</button></div></div></article></section>';

  body += '<footer><strong>@pocketpixels.ceb</strong><span>Cebu</span><p>Thank you for collecting moments with us.</p></footer>';

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

    '<main class="center-page"><section class="notice"><p class="brand">Pocket Pixels</p><h1>Gallery temporarily unavailable.</h1><p>Please ask the booth operator to refresh this gallery.</p></section></main>',

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

    ':root{color-scheme:light;--ink:#27191b;--muted:#6d5b5e;--paper:#fffdf9;--soft:#f6f0ed;--line:#eadcda;--accent:#8b1e2d;--accent-dark:#641521;--focus:#0f62fe;}',

    '*{box-sizing:border-box;}html{background:var(--paper);}body{margin:0;font-family:-apple-system,BlinkMacSystemFont,\"Segoe UI\",Roboto,Arial,sans-serif;background:var(--paper);color:var(--ink);line-height:1.45;}',

    'button,a{font:inherit;}button,.button-row a{min-height:44px;border-radius:8px;border:1px solid var(--accent);padding:11px 14px;background:var(--accent);color:white;text-decoration:none;font-weight:700;display:inline-flex;align-items:center;justify-content:center;gap:8px;cursor:pointer;}',

    '.button-row a{background:white;color:var(--accent);}button.secondary{background:white;color:var(--accent);}button[hidden]{display:none;}button:focus-visible,a:focus-visible{outline:3px solid var(--focus);outline-offset:3px;}',

    '.gallery{width:min(100%,920px);margin:0 auto;padding:calc(24px + env(safe-area-inset-top)) max(18px,env(safe-area-inset-left)) calc(36px + env(safe-area-inset-bottom));}',

    'header{padding:10px 0 18px;border-bottom:1px solid var(--line);}h1{font-size:clamp(32px,7vw,52px);line-height:1.03;margin:4px 0 8px;letter-spacing:0;}h2{font-size:20px;margin:0 0 10px;letter-spacing:0;}.brand{text-transform:uppercase;letter-spacing:.08em;color:var(--accent);font-weight:900;margin:0 0 4px;}.meta,p{color:var(--muted);margin:0;}',

    '.actions{display:grid;gap:8px;padding:18px 0 20px;}#shareAll{width:100%;font-size:17px;}#message{min-height:22px;color:var(--accent-dark);font-weight:600;}',

    '.photo-grid{display:grid;grid-template-columns:1fr;gap:18px;}.card{background:white;border:1px solid var(--line);border-radius:8px;overflow:hidden;box-shadow:0 1px 10px rgba(39,25,27,.06);}img{display:block;width:100%;height:auto;background:var(--soft);}.image-placeholder{min-height:240px;display:grid;place-items:center;background:var(--soft);color:var(--muted);font-weight:700;}.card-body{padding:14px;}.button-row{display:grid;grid-template-columns:1fr;gap:10px;}',

    '.receipt-section{margin-top:28px;padding-top:22px;border-top:1px solid var(--line);}.receipt-card{max-width:440px;margin:0 auto;}.receipt-card img{max-height:520px;object-fit:contain;}',

    'footer{margin-top:30px;padding-top:20px;border-top:1px solid var(--line);display:grid;gap:4px;color:var(--muted);}footer strong{color:var(--accent);}footer span{font-weight:700;}',

    '.center-page{min-height:100vh;display:grid;place-items:center;padding:calc(28px + env(safe-area-inset-top)) 20px calc(36px + env(safe-area-inset-bottom));}.notice{width:min(100%,460px);text-align:center;background:white;border:1px solid var(--line);border-radius:8px;padding:28px 20px;box-shadow:0 1px 12px rgba(39,25,27,.06);}.notice h1{font-size:32px;}.notice button{margin-top:18px;}.loader{width:34px;height:34px;border-radius:50%;border:4px solid var(--line);border-top-color:var(--accent);margin:18px auto;animation:spin 1s linear infinite;}@keyframes spin{to{transform:rotate(360deg);}}',

    '@media(min-width:700px){.actions{grid-template-columns:max-content 1fr;align-items:center;}#shareAll{width:auto;}.photo-grid{grid-template-columns:repeat(3,1fr);}.button-row{grid-template-columns:1fr;}.card-body{padding:16px;}}'

  ].join('');

}

function galleryClientScript_() {

  return [

    'const startedAt=performance.now();const files=[...galleryData.photos,galleryData.receipt];const assetMap=new Map(files.map(function(item){return [item.filename,item];}));const realFileCache=new Map();',

    'const message=document.getElementById(\"message\");',

    'function setMessage(text){if(message){message.textContent=text||\"\";}}',

    'function dataURL(item){return \"data:\"+item.mimeType+\";base64,\"+item.base64Data;}',

    'function fileForItem(item){if(realFileCache.has(item.filename)){return realFileCache.get(item.filename);}const binary=atob(item.base64Data);const bytes=new Uint8Array(binary.length);for(let i=0;i<binary.length;i++){bytes[i]=binary.charCodeAt(i);}const file=new File([bytes],item.filename,{type:item.mimeType});realFileCache.set(item.filename,file);return file;}',

    'function objectURLFor(item){return URL.createObjectURL(fileForItem(item));}',

    'function findItem(filename){return assetMap.get(filename);}',

    'function showEmbeddedImages(){try{files.forEach(function(item){const image=document.getElementById(\"image-\"+item.filename);const placeholder=document.getElementById(\"placeholder-\"+item.filename);if(image){image.src=dataURL(item);image.hidden=false;}if(placeholder){placeholder.remove();}});wireOpenButtons();wireShareButtons();wireShareAll();logSafeBrowserTiming();setMessage(\"\");}catch(error){setMessage(\"Some images did not load. Refresh this page and try again.\");}}',

    'function downloadItem(item){try{const url=objectURLFor(item);const a=document.createElement(\"a\");a.href=url;a.download=item.filename;document.body.appendChild(a);a.click();a.remove();setTimeout(function(){URL.revokeObjectURL(url);},1500);setMessage(\"Download started.\");}catch(error){setMessage(\"Could not start the download. Please try again.\");}}',

    'function openFullSize(item){try{const url=objectURLFor(item);const opened=window.open(url,\"_blank\",\"noopener\");setTimeout(function(){URL.revokeObjectURL(url);},30000);if(!opened){setMessage(\"Pop-up blocked. Use Download Photo instead.\");}else{setMessage(\"Full-size image opened.\");}}catch(error){setMessage(\"Could not open the full-size image. Please try Download instead.\");}}',

    'async function shareItem(item){try{const file=fileForItem(item);if(!supportsSingleFileShare()){downloadItem(item);return;}await navigator.share({files:[file],title:\"Pocket Pixels\",text:\"Pocket Pixels photo\"});setMessage(\"Share sheet opened.\");}catch(error){if(error&&error.name===\"AbortError\"){return;}setMessage(\"Sharing did not work here. Please use Download instead.\");}}',

    'function supportsSingleFileShare(){if(!navigator.share||!navigator.canShare){return false;}try{return navigator.canShare({files:[new File([new Uint8Array([1])],\"photo-01.jpg\",{type:\"image/jpeg\"})]});}catch(error){return false;}}',

    'function supportsMultipleFileShare(){if(!navigator.share||!navigator.canShare){return false;}try{return navigator.canShare({files:[new File([new Uint8Array([1])],\"photo-01.jpg\",{type:\"image/jpeg\"}),new File([new Uint8Array([2])],\"photo-02.jpg\",{type:\"image/jpeg\"})]});}catch(error){return false;}}',

    'document.querySelectorAll(\"[data-download]\").forEach(function(button){button.addEventListener(\"click\",function(){const item=findItem(button.getAttribute(\"data-download\"));if(item){downloadItem(item);}});});',

    'function wireOpenButtons(){document.querySelectorAll(\"[data-open]\").forEach(function(button){button.addEventListener(\"click\",function(){const item=findItem(button.getAttribute(\"data-open\"));if(item){openFullSize(item);}});});}',

    'function wireShareButtons(){const supported=supportsSingleFileShare();document.querySelectorAll(\"[data-share]\").forEach(function(button){const item=findItem(button.getAttribute(\"data-share\"));if(!item||!supported){button.hidden=true;return;}button.addEventListener(\"click\",function(){shareItem(item);});});}',

    'function wireShareAll(){const shareAll=document.getElementById(\"shareAll\");const allHint=document.getElementById(\"allHint\");if(!shareAll){return;}const photos=galleryData.photos.map(function(file){return findItem(file.filename);}).filter(Boolean);if(supportsMultipleFileShare()){shareAll.addEventListener(\"click\",async function(){try{await navigator.share({files:photos.map(fileForItem),title:\"Pocket Pixels\",text:\"Pocket Pixels photos\"});setMessage(\"Share sheet opened.\");}catch(error){if(error&&error.name!==\"AbortError\"){setMessage(\"Sharing all photos did not work here. Please download each photo below.\");}}});}else{shareAll.className=\"secondary\";shareAll.textContent=\"Download Photos Individually\";shareAll.addEventListener(\"click\",function(){setMessage(\"Use each Download Photo button below for the most reliable save.\");});if(allHint){allHint.textContent=\"This browser does not support sharing multiple image files from the page.\";}}}',

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

    photos: PHOTO_FILENAMES,

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

function expectedFilenames_() {

  return PHOTO_FILENAMES.concat([RECEIPT_FILENAME]);

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

function makeSelfTestPayload_() {

  return {

    schemaVersion: SCHEMA_VERSION,

    deviceToken: 'self-test-token',

    galleryToken: 'a'.repeat(64),

    sessionID: 'PP-20260830-120000',

    createdAt: '2026-08-30T12:00:00Z',

    photos: [

      { filename: 'photo-01.jpg', mimeType: 'image/jpeg', base64Data: '/9j/4AAQSkZJRg==' },

      { filename: 'photo-02.jpg', mimeType: 'image/jpeg', base64Data: '/9j/4AAQSkZJRg==' },

      { filename: 'photo-03.jpg', mimeType: 'image/jpeg', base64Data: '/9j/4AAQSkZJRg==' }

    ],

    receipt: { filename: 'receipt-color.jpg', mimeType: 'image/jpeg', base64Data: '/9j/4AAQSkZJRg==' }

  };

}

function assert_(condition, message) {

  if (!condition) {

    throw new Error(message);

  }

}