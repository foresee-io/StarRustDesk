const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const zlib = require('node:zlib');
const root = path.resolve(__dirname, '..');
const files = ['AppScope/resources/base/media', 'entry/src/main/resources/base/media']
  .flatMap(dir => ['starrustdesk_app_icon_1024.png', 'starrustdesk_app_icon.png'].map(name => `${dir}/${name}`));
let reference;
for (const file of files) {
  const png = fs.readFileSync(path.join(root, file));
  assert.equal(png.subarray(0, 8).toString('hex'), '89504e470d0a1a0a');
  const width = png.readUInt32BE(16), height = png.readUInt32BE(20);
  assert.equal(width, 1024, file); assert.equal(height, 1024, file);
  assert.equal(png[24], 8, '8-bit PNG');
  assert([2, 6].includes(png[25]), 'RGB or RGBA PNG');
  const channels = png[25] === 6 ? 4 : 3;
  assert.equal(png[28], 0, 'non-interlaced');
  const parts = [];
  for (let offset = 8; offset < png.length;) {
    const len = png.readUInt32BE(offset), type = png.toString('ascii', offset + 4, offset + 8);
    assert.notEqual(type, 'tRNS', 'no transparent color key');
    if (type === 'IDAT') parts.push(png.subarray(offset + 8, offset + 8 + len));
    offset += len + 12;
  }
  const raw = zlib.inflateSync(Buffer.concat(parts)), stride = width * channels;
  assert.equal(raw.length, height * (stride + 1));
  const pixels = Buffer.alloc(height * stride);
  function paeth(a, b, c) {
    const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
    return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
  }
  for (let y = 0; y < height; y++) {
    const filter = raw[y * (stride + 1)]; assert(filter <= 4);
    for (let x = 0; x < stride; x++) {
      const pos = y * stride + x;
      const a = x >= channels ? pixels[pos - channels] : 0;
      const b = y ? pixels[pos - stride] : 0;
      const c = y && x >= channels ? pixels[pos - stride - channels] : 0;
      const predictor = [0, a, b, Math.floor((a + b) / 2), paeth(a, b, c)][filter];
      pixels[pos] = (raw[y * (stride + 1) + 1 + x] + predictor) & 255;
    }
  }
  if (channels === 4) for (let i = 3; i < pixels.length; i += 4) assert.equal(pixels[i], 255, 'no transparent pixel');
  // Full-bleed blue must reach the perimeter: no black/white rounded-corner fill.
  for (let i = 0; i < width; i++) {
    for (const [x, y] of [[i, 0], [i, height - 1], [0, i], [width - 1, i]]) {
      const p = (y * width + x) * channels;
      assert(pixels[p + 2] > 120 && pixels[p + 2] > pixels[p] + 30, `blue edge missing at ${x},${y}: ${file}`);
    }
  }
  if (reference) assert.deepEqual(png, reference, 'AppScope/entry/legacy resources must match');
  reference = png;
  console.log(`PASS ${file}: 1024x1024, opaque, square blue perimeter`);
}
for (const file of ['AppScope/app.json5', 'entry/src/main/module.json5']) {
  assert.match(fs.readFileSync(path.join(root, file), 'utf8'), /"icon"\s*:\s*"\$media:starrustdesk_app_icon_1024"/);
}
// The build hook must preserve exact source bytes, be idempotent and fail closed
// when the two source copies differ. Test only in an isolated temporary tree.
const os = require('node:os');
const { preserveAppIcon } = require('./preserve-app-icon.cjs');
const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'starrustdesk-icon-test-'));
try {
  const modulePath = path.join(fixture, 'entry');
  const sourcePath = path.join(fixture, files[0]);
  const entryPath = path.join(fixture, files[2]);
  const targetPath = path.join(modulePath, 'build/default/intermediates/res/default/resources/base/media/starrustdesk_app_icon_1024.png');
  for (const file of [sourcePath, entryPath, targetPath]) fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(sourcePath, reference); fs.writeFileSync(entryPath, reference);
  fs.writeFileSync(targetPath, 'simulated SDK-transcoded image');
  preserveAppIcon(modulePath); assert.deepEqual(fs.readFileSync(targetPath), reference);
  preserveAppIcon(modulePath); assert.deepEqual(fs.readFileSync(targetPath), reference);
  fs.writeFileSync(entryPath, 'different source'); assert.throws(() => preserveAppIcon(modulePath), /do not match/);
  console.log('PASS packaging hook: exact opaque source, incremental-safe, mismatched sources rejected');
} finally {
  assert.equal(path.dirname(path.resolve(fixture)), path.resolve(os.tmpdir()));
  assert(path.basename(fixture).startsWith('starrustdesk-icon-test-'));
  fs.rmSync(fixture, { recursive: true, force: true });
}
