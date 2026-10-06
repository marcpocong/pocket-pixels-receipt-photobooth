// Run with: node Backend/GoogleAppsScript/GridSixValidation.test.cjs
// Only pure validation runs locally; no Drive writes or network requests.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const scriptProperties = new Map();
const context = vm.createContext({
  Utilities: { base64Decode: value => Array.from(Buffer.from(value, 'base64')) },
  PropertiesService: {
    getScriptProperties: () => ({
      getProperty: key => scriptProperties.get(key) ?? null,
      setProperty: (key, value) => scriptProperties.set(key, value),
      deleteProperty: key => scriptProperties.delete(key),
    }),
  },
});
vm.runInContext(fs.readFileSync(path.join(__dirname, 'Code.gs'), 'utf8'), context);
assert.equal(context.validateUploadToken_('').code, 'SERVER_NOT_CONFIGURED');
scriptProperties.set('POCKET_PIXELS_DEVICE_TOKEN', 'correct-device-token-value');
assert.equal(context.validateUploadToken_('').code, 'MISSING_DEVICE_TOKEN');
assert.equal(context.validateUploadToken_('wrong-device-token-value').code, 'INVALID_DEVICE_TOKEN');
assert.equal(context.validateUploadToken_('correct-device-token-value'), null);
for (const count of [1, 2, 3, 4, 6]) {
  const payload = context.makeSelfTestPayload_(count);
  assert.equal(context.validateUploadPayload_(payload).ok, true);
  assert.equal(payload._validatedImages.length, count + 1);
  assert.deepEqual(Array.from(payload._expectedPhotoFilenames), Array.from({ length: count }, (_, i) => `photo-${String(i + 1).padStart(2, '0')}.jpg`));
  assert.equal(context.expectedFilenames_(count).length, count + 1);
}
for (const count of [0, 7, 36]) {
  const payload = context.makeSelfTestPayload_(count);
  if (count === 0) payload.photos = [];
  assert.equal(context.validateUploadPayload_(payload).code, 'INVALID_PHOTO_COUNT');
}
const missingSixth = context.makeSelfTestPayload_(6);
missingSixth.photos[5].filename = 'photo-04.jpg';
assert.equal(context.validateUploadPayload_(missingSixth).code, 'INVALID_PHOTO_FILENAME');
console.log('Grid 6 backend validation passed: existing counts, six filenames, upper bound, sixth image validation.');
