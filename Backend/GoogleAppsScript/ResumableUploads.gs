// Additive transport. Media goes directly to a scoped Drive resumable session;
// broad Google credentials never leave the server. Legacy manifests/URLs remain unchanged.
const RESUMABLE_TRANSPORT = 'drive-resumable-v1';
const RESUMABLE_ENABLED_PROPERTY = 'MTK_RESUMABLE_UPLOADS_ENABLED';
const RESUMABLE_JOURNALS_PROPERTY = 'MTK_UPLOAD_JOURNALS_FOLDER';
const RESUMABLE_ACTIVE_PREFIX = 'MTK_RESUMABLE_ACTIVE_';

function resumableUploadsEnabled_() {
  return PropertiesService.getScriptProperties().getProperty(RESUMABLE_ENABLED_PROPERTY) === 'true';
}

function resumableGalleryPost_(body) {
  const started = Date.now();
  let lock;
  try {
    const auth = validateUploadToken_(body.deviceToken);
    if (auth) throw publicError_(401, 'Gallery upload authorization failed.', 'rejected', auth.code);
    if (!resumableUploadsEnabled_()) throw publicError_(503, 'Resumable delivery is temporarily unavailable.', 'retryable', 'TRANSPORT_UNAVAILABLE');
    const input = validateResumableGallery_(body);
    lock = LockService.getScriptLock();
    if (!lock.tryLock(10000)) throw publicError_(429, 'Upload coordination is busy. Retry later.', 'retryable', 'UPLOAD_SERVICE_BUSY');
    const root = getRootFolder_();
    const journals = resumableJournalFolder_(root);
    const records = collectResumableFiles_(journals, body.galleryToken + '.json');
    if (records.length > 1) throw resumableConflict_();
    let record = records[0];
    let journal = record ? JSON.parse(record.getBlob().getDataAsString()) : null;
    if (journal && journal.fingerprint !== input.fingerprint) throw resumableConflict_();
    if (!journal) {
      const folders = collectFoldersByName_(root, 'gallery-' + body.galleryToken);
      if (folders.length > 1) throw resumableConflict_();
      const folder = folders[0] || createGalleryFolder_(root, 'gallery-' + body.galleryToken);
      const inspection = inspectGalleryFolder_(folder, input.expected);
      if (!inspection.safe || inspection.manifests.length > 1) throw resumableConflict_();
      if (inspection.manifests.length && !resumableManifestMatches_(readManifest_(inspection.manifests[0]), body)) throw resumableConflict_();
      const reserved = resumableDriveJSON_('https://www.googleapis.com/drive/v3/files/generateIds?count=' + input.assets.length + '&space=drive').ids;
      journal = {version:1, fingerprint:input.fingerprint, folderId:folder.getId(), createdAt:Date.now(),
        galleryToken:body.galleryToken, sessionID:body.sessionID,
        assets:input.assets.map(function(asset, index) {
          if ((inspection.fileCounts[asset.filename] || 0) > 1) throw resumableConflict_();
          const file = inspection.filesByName[asset.filename];
          return Object.assign({}, asset, {fileId:file ? file.getId() : reserved[index]});
        })};
      // Commit reserved IDs before any session is created. Even a lost initiation
      // response cannot create a second Drive file for the same asset.
      record = journals.createFile(body.galleryToken + '.json', JSON.stringify(journal), 'application/json');
    }
    const folder = DriveApp.getFolderById(journal.folderId);
    if (!journal.completedAt) PropertiesService.getScriptProperties().setProperty(RESUMABLE_ACTIVE_PREFIX + body.galleryToken, record.getId());
    const folders = collectFoldersByName_(root, 'gallery-' + body.galleryToken);
    if (folders.length !== 1 || folders[0].getId() !== folder.getId()) throw resumableConflict_();
    const inspection = inspectGalleryFolder_(folder, input.expected);
    if (!inspection.safe || inspection.manifests.length > 1) throw resumableConflict_();
    if (input.expected.some(function(name) { return inspection.fileCounts[name] > 1; })) throw resumableConflict_();
    const metadata = resumableAssetMetadata_(journal.assets);
    const missing = [];
    journal.assets.forEach(function(asset, index) {
      const stored = metadata[index];
      if (!stored) { missing.push(asset); return; }
      verifyResumableAsset_(asset, stored, journal.folderId);
      asset.stored = true;
      delete asset.uploadURL;
    });
    if (inspection.manifests.length) {
      if (missing.length || !hasExactlyExpectedImages_(inspection, input.expected) ||
          !resumableManifestMatches_(readManifest_(inspection.manifests[0]), body)) throw resumableConflict_();
      journal.completedAt = journal.completedAt || Date.now();
      record.setContent(JSON.stringify(journal));
      PropertiesService.getScriptProperties().deleteProperty(RESUMABLE_ACTIVE_PREFIX + body.galleryToken);
      return resumableCompleteResponse_(body, input.expected, 'existingComplete');
    }
    if (body.action === 'finalize') {
      if (missing.length) throw publicError_(409, 'Some gallery assets are still transferring.', 'retryable', 'ASSETS_INCOMPLETE');
      if (!hasExactlyExpectedImages_(inspection, input.expected)) throw publicError_(503, 'Drive publication is catching up.', 'retryable', 'DRIVE_UNAVAILABLE');
      const manifestBody = Object.assign({}, body, {_expectedPhotoFilenames:body.photos.map(function(p) { return p.filename; })});
      createManifestFile_(folder, manifestBody, {});
      saveGalleryFolderIndex_(body.galleryToken, journal.folderId);
      journal.completedAt = Date.now();
      record.setContent(JSON.stringify(journal));
      PropertiesService.getScriptProperties().deleteProperty(RESUMABLE_ACTIVE_PREFIX + body.galleryToken);
      return resumableCompleteResponse_(body, input.expected, 'created');
    }
    // A scoped capability expires after a week. Refresh only missing assets;
    // verified files are never retransmitted. A client can invalidate one expired
    // session, while keeping every other asset/session intact.
    const create = missing.filter(function(asset) {
      return !asset.uploadURL || Date.now() - (asset.sessionAt || 0) > 6 * 86400000 || body.expiredAsset === asset.filename;
    });
    if (create.length) {
      const oauth = ScriptApp.getOAuthToken();
      const requests = create.map(function(asset) {
        return {url:'https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id,size,sha256Checksum',
          method:'post', contentType:'application/json', muteHttpExceptions:true,
          headers:{Authorization:'Bearer ' + oauth, 'X-Upload-Content-Type':asset.mimeType, 'X-Upload-Content-Length':String(asset.bytes)},
          payload:JSON.stringify({id:asset.fileId, name:asset.filename, mimeType:asset.mimeType, parents:[journal.folderId]})};
      });
      const responses = resumableFetchAll_(requests);
      responses.forEach(function(response, index) {
        if (response.getResponseCode() !== 200) throw publicError_(503, 'Drive upload initiation is unavailable.', 'retryable', 'DRIVE_UNAVAILABLE');
        const headers = response.getAllHeaders();
        const uri = String(headers.Location || headers.location || '');
        if (!/^https:\/\/www\.googleapis\.com\/upload\/drive\/v3\/files\?/.test(uri) || uri.indexOf('upload_id=') < 0) throw resumableConflict_();
        create[index].uploadURL = uri;
        create[index].sessionAt = Date.now();
      });
    }
    record.setContent(JSON.stringify(journal));
    return jsonResponse(200, {ok:true, transport:RESUMABLE_TRANSPORT, galleryToken:body.galleryToken,
      status:missing.length ? 'transferring' : 'remotelyStored', assets:journal.assets.map(function(asset) {
        return {filename:asset.filename, bytes:asset.bytes, sha256:asset.sha256, stored:asset.stored === true,
          uploadURL:asset.stored ? undefined : asset.uploadURL};
      })});
  } catch (error) {
    // Never serialize/log Google error bodies, session capabilities, IDs or URLs.
    return jsonResponse(error.statusCode || 503, {ok:false, transport:RESUMABLE_TRANSPORT,
      errorCode:error.publicCode || 'DRIVE_UNAVAILABLE', status:error.publicStatus || 'retryable',
      error:error.publicMessage || 'Gallery transfer is temporarily unavailable.'});
  } finally {
    if (lock) { try { lock.releaseLock(); } catch (_) {} }
    console.log('Gallery resumable coordination: ' + JSON.stringify({elapsedMs:Date.now()-started}));
  }
}

function validateResumableGallery_(body) {
  if (!body || ['initialize','finalize'].indexOf(body.action) < 0 || JSON.stringify(body).length > 24576 ||
      !GALLERY_TOKEN_PATTERN.test(String(body.galleryToken || '')) || !SAFE_SESSION_ID_PATTERN.test(String(body.sessionID || '')) ||
      !isValidCreatedAt_(body.createdAt) || [1,2,3,4].indexOf(body.schemaVersion) < 0 ||
      !Array.isArray(body.photos) || body.photos.length < 1 || body.photos.length > 6) throw resumableInvalid_();
  const expected = expectedFilenames_(body.photos.length, body.schemaVersion, !!body.gif, !!body.shareColorReceipt);
  const assets = body.photos.concat(body.schemaVersion === 1 ? [body.receipt] :
    [body.colorReceipt].concat(body.schemaVersion === 4 ? [] : [body.thermalReceipt])).concat(body.gif ? [body.gif] : []).concat(body.shareColorReceipt ? [body.shareColorReceipt] : []);
  if (assets.length !== expected.length || assets.some(function(a) { return !a; })) throw resumableInvalid_();
  let total = 0;
  assets.forEach(function(asset, index) {
    const mime = asset.filename === THERMAL_RECEIPT_FILENAME ? 'image/png' : asset.filename === GIF_FILENAME ? 'image/gif' : 'image/jpeg';
    if (asset.filename !== expected[index] || asset.mimeType !== mime || !Number.isInteger(asset.bytes) || asset.bytes < 3 ||
        asset.bytes > MAX_IMAGE_DECODED_BYTES || !/^[a-f0-9]{64}$/.test(String(asset.sha256 || ''))) throw resumableInvalid_();
    total += asset.bytes;
  });
  if (total > MAX_GALLERY_DECODED_BYTES) throw resumableInvalid_();
  // Reuse the existing receipt-style validation, without creating fake image data.
  if (body.schemaVersion >= 3) {
    if (!validReceiptVariants_(body.receiptVariants) ||
        (body.receiptVariants.originalFooterStyle !== 'decorativeBarcodeOnly') !== !!body.shareColorReceipt) throw resumableInvalid_();
  } else if (body.receiptVariants || body.shareColorReceipt) throw resumableInvalid_();
  if (body.schemaVersion === 4 && body.thermalReceipt) throw resumableInvalid_();
  const canonical = {schemaVersion:body.schemaVersion, galleryToken:body.galleryToken, sessionID:body.sessionID,
    createdAt:body.createdAt, receiptVariants:body.receiptVariants ? {
      originalFooterStyle:body.receiptVariants.originalFooterStyle, defaultStyle:body.receiptVariants.defaultStyle
    } : null,
    assets:assets.map(function(a) { return {filename:a.filename,mimeType:a.mimeType,bytes:a.bytes,sha256:a.sha256}; })};
  return {assets:canonical.assets, expected:expected, fingerprint:resumableSHA256_(JSON.stringify(canonical))};
}

function resumableAssetMetadata_(assets) {
  const oauth = ScriptApp.getOAuthToken();
  return resumableFetchAll_(assets.map(function(asset) {
    return {url:'https://www.googleapis.com/drive/v3/files/' + encodeURIComponent(asset.fileId) + '?fields=id,name,size,mimeType,parents,trashed,sha256Checksum',
      headers:{Authorization:'Bearer ' + oauth}, muteHttpExceptions:true};
  })).map(function(response) {
    if (response.getResponseCode() === 404) return null;
    if (response.getResponseCode() !== 200) throw publicError_(503, 'Drive verification is unavailable.', 'retryable', 'DRIVE_UNAVAILABLE');
    return JSON.parse(response.getContentText());
  });
}

function verifyResumableAsset_(asset, stored, folderId) {
  if (stored.id !== asset.fileId || stored.name !== asset.filename || stored.mimeType !== asset.mimeType ||
      Number(stored.size) !== asset.bytes || stored.trashed || !Array.isArray(stored.parents) ||
      stored.parents.length !== 1 || stored.parents[0] !== folderId) throw resumableConflict_();
  const digest = stored.sha256Checksum || resumableSHA256_(DriveApp.getFileById(asset.fileId).getBlob().getBytes());
  if (digest !== asset.sha256) throw resumableConflict_();
}

function resumableJournalFolder_(root) {
  const properties = PropertiesService.getScriptProperties();
  const known = properties.getProperty(RESUMABLE_JOURNALS_PROPERTY);
  if (known) return DriveApp.getFolderById(known);
  const folders = collectFoldersByName_(root, '.gallery-upload-journals');
  if (folders.length > 1) throw resumableConflict_();
  const folder = folders[0] || root.createFolder('.gallery-upload-journals');
  properties.setProperty(RESUMABLE_JOURNALS_PROPERTY, folder.getId());
  return folder;
}

function collectResumableFiles_(folder, name) {
  const iterator = folder.getFilesByName(name), files = [];
  while (iterator.hasNext()) files.push(iterator.next());
  return files;
}

function resumableDriveJSON_(url) {
  const response = resumableFetchAll_([{url:url, headers:{Authorization:'Bearer ' + ScriptApp.getOAuthToken()}, muteHttpExceptions:true}])[0];
  if (response.getResponseCode() !== 200) throw publicError_(503, 'Drive coordination is unavailable.', 'retryable', 'DRIVE_UNAVAILABLE');
  return JSON.parse(response.getContentText());
}

function resumableFetchAll_(requests) {
  try { return UrlFetchApp.fetchAll(requests); }
  catch (_) { throw publicError_(503, 'Drive coordination is unavailable.', 'retryable', 'DRIVE_UNAVAILABLE'); }
}

function resumableSHA256_(value) {
  return Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, value).map(function(b) { return ('0' + (b & 255).toString(16)).slice(-2); }).join('');
}

function resumableManifestMatches_(manifest, body) {
  return manifest.status === 'complete' && manifest.galleryToken === body.galleryToken && manifest.sessionID === body.sessionID &&
    manifest.schemaVersion === body.schemaVersion && manifest.createdAt === body.createdAt &&
    manifestHasExpectedFiles_(manifest, body.photos.length) && !!manifest.gif === !!body.gif &&
    !!manifest.shareColorReceipt === !!body.shareColorReceipt && (body.schemaVersion < 3 ||
      (manifest.receiptVariants.originalFooterStyle === body.receiptVariants.originalFooterStyle &&
       manifest.receiptVariants.defaultStyle === body.receiptVariants.defaultStyle));
}
function resumableCompleteResponse_(body, expected, status) {
  return jsonResponse(200, {ok:true, transport:RESUMABLE_TRANSPORT, schemaVersion:body.schemaVersion,
    galleryToken:body.galleryToken, galleryURL:makeGalleryURL_(body.galleryToken), fileCount:expected.length + 1, status:status});
}
function resumableInvalid_() { return publicError_(400, 'Invalid gallery transfer description.', 'rejected', 'INVALID_TRANSFER'); }
function resumableConflict_() { return publicError_(409, 'Gallery integrity needs operator inspection.', 'manualInspectionRequired', 'MANUAL_INSPECTION_REQUIRED'); }

function guardLegacyResumableMutation_(token) {
  const id = PropertiesService.getScriptProperties().getProperty(RESUMABLE_ACTIVE_PREFIX + token);
  if (!id) return;
  const journal = JSON.parse(DriveApp.getFileById(id).getBlob().getDataAsString());
  if (journal.galleryToken !== token) throw resumableConflict_();
  if (!journal.completedAt) {
    throw publicError_(429, 'This gallery has an unfinished resumable transfer. Media is retained.', 'retryable', 'UPLOAD_SERVICE_BUSY');
  }
}

// Run once by the existing owner in the editor after source validation. No new
// OAuth credential, public sharing permission, trigger or storage provider is created.
function enableResumableUploadsForOwner() {
  // Exercise Google authorization and API availability before advertising capability.
  resumableDriveJSON_('https://www.googleapis.com/drive/v3/files/generateIds?count=1&space=drive');
  PropertiesService.getScriptProperties().setProperty(RESUMABLE_ENABLED_PROPERTY, 'true');
  console.log('Resumable gallery capability enabled.');
}
