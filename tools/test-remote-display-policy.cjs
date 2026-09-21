const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const ts = require('C:/Program Files/Huawei/DevEco Studio/tools/ohpm/node_modules/typescript');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/service/RemoteDisplayPolicy.ets'), 'utf8');
const storage = new Map();
let id = 0, orientation = 4, listener;
const main = {
  on: (_, fn) => { listener = fn; }, off: () => { listener = undefined; },
  getWindowProperties: () => ({ displayId: id }),
  getPreferredOrientation: () => orientation,
  setPreferredOrientation: async value => { orientation = value; }
};
const deviceInfo = { deviceType: 'phone' };
const context = vm.createContext({
  display: { getDefaultDisplaySync: () => ({ id: 0 }),
    getDisplayByIdSync: id => ({ width: id === 2 ? 1080 : 1920, height: id === 2 ? 1920 : 1080 }) },
  window: { Orientation: { AUTO_ROTATION: 4, LANDSCAPE: 2 } }, deviceInfo,
  RustDeskNapi: { appendDiagnosticLog() {} },
  AppStorage: { setOrCreate: (k,v) => storage.set(k,v), get: k => storage.get(k) }
});
vm.runInContext(ts.transpile(source.replace(/^import .*$/gm, '').replace('export class', 'class') +
  '\nglobalThis.Policy = RemoteDisplayPolicy;'), context);
const p = context.Policy;
(async () => {
  p.attach(main); p.setActive(true); await p.pending;
  assert.equal(orientation, 4, 'phone keeps original local orientation');
  id = 1; listener(1); await p.pending;
  assert.equal(orientation, 2, 'wide external display uses landscape');
  id = 0; listener(0); await p.pending;
  assert.equal(orientation, 4, 'return to local restores original');
  deviceInfo.deviceType = 'tablet';
  p.toggleLandscape(); await p.pending;
  assert.equal(orientation, 2, 'tablet supports same manual override');
  p.toggleLandscape(); await p.pending; assert.equal(orientation, 4);
  id = 2; listener(2); await p.pending;
  assert.equal(orientation, 4, 'portrait external screen is not forced wide');
  p.toggleLandscape(); await p.pending; assert.equal(orientation, 2);
  p.setActive(false); await p.pending; assert.equal(orientation, 4);
  assert.equal(storage.get('remoteLandscapeLocked'), false);
  p.detach(); assert.equal(listener, undefined);
  console.log('PASS display policy: phone/tablet, external wide/portrait, manual override, restore and listener cleanup');
})().catch(e => { console.error(e); process.exitCode = 1; });
