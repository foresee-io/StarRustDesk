const fs = require('node:fs');
const path = require('node:path');

// DevEco's icon conversion may introduce alpha=254 into a fully opaque image.
// Keep the validated, full-size source for this app's single-layer icon only.
// Resource IDs/paths, SDK validation, other resources and signing stay unchanged.
function preserveAppIcon(modulePath) {
  const name = 'starrustdesk_app_icon_1024.png';
  const sourcePath = path.join(modulePath, '../AppScope/resources/base/media', name);
  const entryPath = path.join(modulePath, 'src/main/resources/base/media', name);
  const source = fs.readFileSync(sourcePath);
  if (source.subarray(0, 8).toString('hex') !== '89504e470d0a1a0a' ||
      source.readUInt32BE(16) !== 1024 || source.readUInt32BE(20) !== 1024 || source[25] !== 2) {
    throw new Error('App icon must be an opaque 1024x1024 RGB PNG.');
  }
  for (let offset = 8; offset < source.length;) {
    const length = source.readUInt32BE(offset);
    if (source.toString('ascii', offset + 4, offset + 8) === 'tRNS') throw new Error('Transparent app icon is forbidden.');
    offset += length + 12;
  }
  if (!source.equals(fs.readFileSync(entryPath))) throw new Error('AppScope and entry icons do not match.');
  const compiled = path.join(modulePath, 'build/default/intermediates/res/default/resources/base/media', name);
  if (!fs.existsSync(compiled)) throw new Error('Compiled icon missing; resource processing must run first.');
  if (!source.equals(fs.readFileSync(compiled))) fs.copyFileSync(sourcePath, compiled);
}

module.exports = { preserveAppIcon };
