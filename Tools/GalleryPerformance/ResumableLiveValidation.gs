// Owner-only editor diagnostic. Load temporarily into HEAD, never the production
// deployment. The wrapper supplies a private synthetic JPEG/file and evidence
// folder plus an isolated versioned Web App URL. Credentials stay server-side.
function validateLiveResumableGallery_(config) {
  let stage = 'fixture';
  const started = Date.now(), report = {synthetic:true};
  let token;
  try {
    const bytes = DriveApp.getFileById(config.fixtureId).getBlob().getBytes();
    if (bytes.length <= 262144 || bytes.length > 2 * 1024 * 1024) throw new Error('fixture');
    token = resumableSHA256_(Utilities.getUuid() + Utilities.getUuid());
    const asset = function(name) { return {filename:name, mimeType:'image/jpeg', bytes:bytes.length, sha256:resumableSHA256_(bytes)}; };
    const body = {transport:'drive-resumable-v1',action:'initialize',
      deviceToken:PropertiesService.getScriptProperties().getProperty(DEVICE_TOKEN_PROPERTY),
      galleryToken:token,sessionID:'PP-20261111-120000-' + Utilities.getUuid(),createdAt:new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'),
      schemaVersion:4,photos:[asset('photo-01.jpg')],colorReceipt:asset('receipt-color.jpg'),
      receiptVariants:{originalFooterStyle:'decorativeBarcodeOnly',defaultStyle:'shareFriendly'}};
    function require_(condition) { if (!condition) throw new Error('validation'); }
    function coordinate_(action) {
      body.action = action;
      const response = UrlFetchApp.fetch(config.endpoint, {method:'post',contentType:'application/json',
        payload:JSON.stringify(body),muteHttpExceptions:true});
      require_(response.getResponseCode() === 200);
      const result = JSON.parse(response.getContentText());
      require_(result.ok && result.galleryToken === token && result.transport === 'drive-resumable-v1');
      return result;
    }
    function put_(url, range, payload) {
      const options = {method:'put',headers:{'Content-Range':range},muteHttpExceptions:true};
      if (payload) { options.contentType = 'image/jpeg'; options.payload = payload; }
      return UrlFetchApp.fetch(url, options); // Scoped capability; no OAuth header.
    }
    stage = 'initialize';
    const initAt = Date.now(), initial = coordinate_('initialize'), repeated = coordinate_('initialize');
    require_(initial.assets.length === 2 && repeated.assets.length === 2);
    initial.assets.forEach(function(asset, index) {
      require_(asset.uploadURL === repeated.assets[index].uploadURL && !asset.stored);
    });
    report.initializationMs = Date.now() - initAt;
    report.initializationIdempotent = true;
    report.decodedMediaBytes = bytes.length * 2;
    report.actualMediaBytesSent = 0;
    stage = 'binary';
    const transferAt = Date.now();
    initial.assets.forEach(function(asset, index) {
      let offset = 0;
      if (index === 0) {
        // Deliberately discard the first chunk's acknowledgment, then recover
        // from Google's persisted offset instead of the local sent-byte count.
        put_(asset.uploadURL, 'bytes 0-262143/' + bytes.length, bytes.slice(0,262144));
        report.actualMediaBytesSent += 262144;
        const probe = put_(asset.uploadURL, 'bytes */' + bytes.length);
        const headers = probe.getAllHeaders();
        require_(probe.getResponseCode() === 308);
        offset = Number(String(headers.Range || headers.range || '').replace('bytes=0-','')) + 1;
        require_(offset === 262144);
        report.confirmedResumeOffset = offset;
      }
      while (offset < bytes.length) {
        const end = Math.min(bytes.length,offset + 262144);
        const response = put_(asset.uploadURL, 'bytes ' + offset + '-' + (end-1) + '/' + bytes.length, bytes.slice(offset,end));
        const code = response.getResponseCode();
        require_(end === bytes.length ? code === 200 || code === 201 : code === 308);
        report.actualMediaBytesSent += end-offset;
        offset = end;
      }
    });
    report.binaryMs = Date.now()-transferAt;
    report.unnecessaryRetransmittedBytes = report.actualMediaBytesSent-report.decodedMediaBytes;
    stage = 'remote-storage';
    const stored = coordinate_('initialize');
    require_(stored.status === 'remotelyStored' && stored.assets.every(function(a) { return a.stored && !a.uploadURL; }));
    report.remotelyStored = true;
    stage = 'publication';
    const publishAt = Date.now(), published = coordinate_('finalize');
    require_(published.status === 'created' && published.fileCount === 3);
    require_(coordinate_('finalize').status === 'existingComplete');
    report.publicationMs = Date.now()-publishAt;
    report.finalizationIdempotent = true;
    stage = 'public-verification';
    const url = 'https://gallery.madetokeepstudios.workers.dev/?g=' + token;
    const ready = JSON.parse(UrlFetchApp.fetch(url + '&galleryStatus=1').getContentText());
    require_(ready.ok && ready.status === 'complete' && ready.galleryToken === token && ready.sessionID === body.sessionID && ready.fileCount === 3);
    const html = UrlFetchApp.fetch(url).getContentText();
    require_(html.indexOf('data-pocket-pixels-gallery-status="complete"') >= 0);
    const root = getRootFolder_(), folders = collectFoldersByName_(root,'gallery-' + token);
    require_(folders.length === 1);
    const files = inspectGalleryFolder_(folders[0],['photo-01.jpg','receipt-color.jpg']);
    require_(files.safe && files.manifests.length === 1 && files.fileCounts['photo-01.jpg'] === 1 && files.fileCounts['receipt-color.jpg'] === 1);
    report.publicReady = true; report.publicPageComplete = true; report.duplicateAssetFiles = 0;
    report.elapsedMs = Date.now()-started; report.ok = true;
    DriveApp.getFolderById(config.evidenceFolderId).createFile('resumable-live-validation-result.json',
      JSON.stringify({report:report,galleryToken:token,galleryURL:url}), 'application/json');
    console.log('Live resumable validation: ' + JSON.stringify(report));
    return report;
  } catch (_) {
    report.ok = false; report.failedStage = stage; report.elapsedMs = Date.now()-started;
    DriveApp.getFolderById(config.evidenceFolderId).createFile('resumable-live-validation-failure.json',
      JSON.stringify({report:report,galleryToken:token}), 'application/json');
    console.log('Live resumable validation: ' + JSON.stringify(report));
    throw new Error('Synthetic live gallery validation failed at ' + stage + '. Private evidence retained.');
  }
}
