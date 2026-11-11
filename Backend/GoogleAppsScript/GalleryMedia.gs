// Server-only read acceleration. Every ID comes from the already validated folder inspection.
// DriveApp remains the fallback; neither cached metadata nor REST success proves completion.
function preloadGalleryMedia_(filesByName, names, timings) {
  const bytesByName = {};
  const started = Date.now();
  try {
    const sizes = names.map(function(name) { return filesByName[name].getSize(); });
    // Keep oversized/historical edge cases on the existing render-budget path.
    if (sizes.some(function(size) { return size <= 0 || size > MAX_IMAGE_DECODED_BYTES; }) ||
        sizes.reduce(function(sum, size) { return sum + size; }, 0) > MAX_GALLERY_DECODED_BYTES) return bytesByName;
    const credential = ScriptApp.getOAuthToken();
    const requests = names.map(function(name) {
      return {
        url:'https://www.googleapis.com/drive/v3/files/' + encodeURIComponent(filesByName[name].getId()) + '?alt=media',
        method:'get', headers:{Authorization:'Bearer ' + credential},
        followRedirects:false, muteHttpExceptions:true
      };
    });
    const responses = UrlFetchApp.fetchAll(requests);
    responses.forEach(function(response, index) {
      if (index >= names.length || response.getResponseCode() !== 200) return;
      const bytes = response.getContent();
      // Never use a truncated response or an unexpected replacement file.
      if (bytes.length === sizes[index]) bytesByName[names[index]] = bytes;
    });
  } catch (_) {
    // No exception text: it can contain an authenticated request or private file ID.
    console.log('Gallery parallel reads deferred to DriveApp.');
  } finally {
    if (timings) {
      timings.parallelMediaMs = Date.now() - started;
      timings.parallelMediaFiles = Object.keys(bytesByName).length;
    }
  }
  return bytesByName;
}

// Avoid another service-boundary conversion for each image. Drive returns signed bytes;
// bounded chunks keep string construction linear and preserve standard Base64 padding.
function encodeGalleryBytes_(bytes) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  const chunks = [];
  for (let offset = 0; offset < bytes.length; offset += 12288) {
    let chunk = '';
    const end = Math.min(bytes.length, offset + 12288);
    for (let index = offset; index < end; index += 3) {
      const bits = ((bytes[index] & 255) << 16) | ((bytes[index + 1] & 255) << 8) | (bytes[index + 2] & 255);
      chunk += alphabet[(bits >>> 18) & 63] + alphabet[(bits >>> 12) & 63] +
        (index + 1 < bytes.length ? alphabet[(bits >>> 6) & 63] : '=') +
        (index + 2 < bytes.length ? alphabet[bits & 63] : '=');
    }
    chunks.push(chunk);
  }
  return chunks.join('');
}
