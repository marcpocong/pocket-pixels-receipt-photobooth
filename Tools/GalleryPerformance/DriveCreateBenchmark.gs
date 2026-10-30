/**
 * ISOLATED EXPERIMENT ONLY. Do not add this file to the deployed gallery project.
 * Requires a separate empty Apps Script project with Advanced Drive service v3 enabled.
 * No production properties, deployment IDs, gallery tokens, credentials or folders are used.
 * Keeps synthetic output for inspection; does not delete or alter any existing Drive media.
 * Run one {photoCount: 1|3|6, guests: 1|5|20} cell per invocation to respect runtime limits.
 * Signature-valid buffers exercise storage/transfer, not visual JPEG decoding or image quality.
 */
function benchmarkIsolatedDriveCreate(config) {
  const properties = PropertiesService.getScriptProperties();
  if (!config || config.confirmIsolated !== true ||
      properties.getProperty('POCKET_PIXELS_ROOT_FOLDER_ID') ||
      properties.getProperty('POCKET_PIXELS_DEVICE_TOKEN') ||
      ![1,3,6].includes(config.photoCount) || ![1,5,20].includes(config.guests)) {
    throw new Error('Use an empty isolated project and an explicit synthetic benchmark configuration.');
  }
  const folder = DriveApp.createFolder('MadeToKeep isolated synthetic benchmark ' + Date.now());
  const rows = [];
  const bytes = Array.from({length:300000}, function(_, i) { return i < 3 ? [255,216,255][i] : (i * 31 + 17) % 256; });
  for (let guest = 0; guest < config.guests; guest++) {
    // Alternate ordering to reduce warm-up bias. Both implementations receive identical bytes.
    const order = guest % 2 ? ['advanced', 'driveApp'] : ['driveApp', 'advanced'];
    for (const engine of order) {
      const start = Date.now();
      const operations = [];
      for (let photo = 0; photo < config.photoCount; photo++) {
        const name = engine + '-guest-' + guest + '-photo-' + photo + '.jpg';
        const blob = Utilities.newBlob(bytes, 'image/jpeg', name);
        const began = Date.now();
        const id = engine === 'advanced'
          ? Drive.Files.create({name:name, mimeType:'image/jpeg', parents:[folder.getId()]}, blob, {fields:'id'}).id
          : folder.createFile(blob).getId();
        const createMs = Date.now() - began;
        const verificationStart = Date.now();
        const stored = DriveApp.getFileById(id);
        if (stored.getSize() !== bytes.length || stored.getName() !== name || stored.getMimeType() !== 'image/jpeg') {
          throw new Error('Synthetic file verification failed; no performance conclusion is valid.');
        }
        const parents = stored.getParents();
        if (!parents.hasNext() || parents.next().getId() !== folder.getId() || parents.hasNext()) throw new Error('Wrong synthetic parent.');
        operations.push({createMs:createMs, verificationMs:Date.now()-verificationStart});
      }
      rows.push({engine:engine, photoCount:config.photoCount, guestOrdinal:guest, bytes:bytes.length*config.photoCount, totalMs:Date.now()-start, operations:operations});
    }
  }
  // Numeric observations only. Scratch folder remains private in Drive for manual inspection.
  console.log(JSON.stringify({synthetic:true, rows:rows}));
  return rows;
}
