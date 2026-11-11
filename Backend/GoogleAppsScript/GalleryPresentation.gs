// Apps Script globals: presentation only; no imports or initialization side effects.
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

function renderGalleryPage_(gallery, timings, startedAt, progressive) {

  const assetStartedAt = Date.now();

  const assets = loadGalleryAssets_(gallery.filesByName, gallery.manifest, false, timings, progressive);
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

  const pageData = {

    createdAt: createdAt,

    reference: reference,

    photos: assets.photos,

    receipt: assets.receipt,
    thermalReceipt: assets.thermalReceipt,
    shareColorReceipt: assets.shareColorReceipt,
    receiptVariants: gallery.manifest.schemaVersion >= 3 ? gallery.manifest.receiptVariants : null

  };
  const delivery = progressive ? progressiveGalleryDelivery_(pageData) : {data:pageData, tail:''};
  const dataJSON = JSON.stringify(delivery.data).replace(/</g, '\\u003c');

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

  let html = pageShell_(body, script, delivery.tail);

  if (timings) {

    timings.generatedHTMLCharacters = html.length;

    timings.totalDoGetRenderMs = Date.now() - startedAt;

    const numericTimings = {};
    Object.keys(timings).forEach(function(key) { if (typeof timings[key] === 'number' && isFinite(timings[key])) numericTimings[key] = timings[key]; });
    html = html.replace('</body>', '<meta name="gallery-origin-timing" content="' + escapeHTML(JSON.stringify(numericTimings)) + '"></body>');
    console.log('Gallery render timings: ' + JSON.stringify(timings) + ' decodedBytes=' + sizeCheck.decodedBytes + ' base64Chars=' + sizeCheck.base64Chars);

  }

  return makeHTML_(html);

}

function makeHTML_(html) {

  return HtmlService.createHtmlOutput(html)

    .setTitle(MADE_TO_KEEP_BRAND.galleryTitle)

    .setXFrameOptionsMode(HtmlService.XFrameOptionsMode.ALLOWALL);

}

function pageShell_(body, script, tail) {

  return '<!doctype html><html lang="en"><head><meta charset="utf-8">' +

    '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">' +

    '<meta name="robots" content="noindex,nofollow"><meta name="referrer" content="no-referrer"><meta name="format-detection" content="telephone=no"><meta name="theme-color" content="#F7F1E9"><base target="_top">' +

    '<title>' + MADE_TO_KEEP_BRAND.galleryTitle + '</title><style>' + galleryCSS_() + '</style></head><body>' +

    body + '<script>' + script + '</script>' + (tail || '') + '</body></html>';

}
