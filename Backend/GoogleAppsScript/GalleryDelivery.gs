// Progressive inline delivery keeps the capability URL and self-contained security model.
// The shell and handlers precede media. Each full-quality asset is included exactly once,
// in photo-first order, so parsing/decoding the first photo need not wait for all receipts.
// All Drive/completeness/budget validation has finished before this function is called.
function progressiveGalleryDelivery_(pageData) {
  const records = [];
  function descriptor(item) {
    if (!item || !item.base64Data) return item;
    const value = Object.assign({}, item);
    delete value.base64Data;
    value.pending = true;
    records.push('<script>acceptGalleryAsset(' + JSON.stringify(item.filename) + ',' + JSON.stringify(item.base64Data) + ');</script>');
    return value;
  }
  const data = Object.assign({}, pageData, {
    photos: pageData.photos.map(descriptor),
    receipt: descriptor(pageData.receipt),
    thermalReceipt: descriptor(pageData.thermalReceipt),
    shareColorReceipt: descriptor(pageData.shareColorReceipt)
  });
  return {data:data, tail:records.join('')};
}
