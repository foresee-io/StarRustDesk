const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const path = require('node:path');
const ts = require('C:/Program Files/Huawei/DevEco Studio/tools/ohpm/node_modules/typescript');
const read = file => fs.readFileSync(path.join(__dirname, '..', file), 'utf8');
const source = read('entry/src/main/ets/service/RemoteDisplayPolicy.ets');
assert.match(read('entry/src/main/module.json5'), /"orientation": "auto_rotation_restricted"/);
const storage = new Map(), hdrMasks = [], logs = [], applied = [];
const O = { AUTO_ROTATION: 5, AUTO_ROTATION_RESTRICTED: 8, LANDSCAPE: 1, PORTRAIT: 2 };
let id = 0, orientation = O.AUTO_ROTATION, listener, failNext = false;
const main = {
  on: (_, fn) => { listener = fn; }, off: () => { listener = undefined; },
  getWindowProperties: () => ({ displayId: id }),
  getPreferredOrientation: () => orientation,
  setPreferredOrientation: async value => {
    if (failNext) { failNext = false; throw Error('window rejected'); }
    orientation = value; applied.push(value);
  }
};
const deviceInfo = { deviceType: 'phone' };
const context = vm.createContext({
  display: { getDefaultDisplaySync: () => ({ id: 0, hdrFormats: [1, 2, 3] }),
    getDisplayByIdSync: id => ({ width: id === 2 ? 1080 : 1920, height: id === 2 ? 1920 : 1080,
      hdrFormats: id === 0 ? [2, 3] : [] }) },
  window: { Orientation: O }, deviceInfo,
  RustDeskNapi: { appendDiagnosticLog: (category, message) => logs.push([category, message]),
    setHdrDisplayFormats: mask => hdrMasks.push(mask) },
  AppStorage: { setOrCreate: (k,v) => storage.set(k,v), get: k => storage.get(k) }
});
vm.runInContext(ts.transpile(source.replace(/^import .*$/gm, '').replace(/^export /gm, '') +
  '\nglobalThis.Policy = RemoteDisplayPolicy; globalThis.Mode = RemoteOrientationMode;'), context);
const p = context.Policy, M = context.Mode;
const select = async mode => { p.setOrientationMode(mode); await p.pending; };
const project = async target => { id = target; listener(target); await p.pending; };
const remote = read('entry/src/main/ets/pages/RemotePage.ets');
const method = name => {
  const start = remote.indexOf(`  ${name}(`);
  assert(start >= 0, `missing RemotePage.${name}`);
  return remote.slice(start, remote.indexOf('\n  }', start) + 4);
};
const menus = [], choices = [];
const ui = vm.createContext({
  RemoteOrientationMode: M,
  RemoteDisplayPolicy: { setOrientationMode: mode => choices.push(mode) },
  RustDeskNapi: { appendDiagnosticLog() {} }, translate: text => text
});
vm.runInContext(ts.transpile('class Page {\n' + method('orientationModeLabel') + '\n' +
  method('showOrientationMenu') + '\n}\nglobalThis.Page = Page;'), ui);
const page = Object.assign(new ui.Page(), {
  remotePageVisible: true, remoteProjectionDisplayId: 0, remoteExternalDisplay: false,
  remoteOrientationMode: M.SYSTEM, isDarkMode: false, uiLanguage: 'zh-Hans',
  primaryTextColor: () => '#182033',
  getUIContext: () => ({ getPromptAction: () => ({ showActionMenu: options => {
    let resolve, reject;
    const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
    menus.push({ options, resolve, reject }); return promise;
  } }) })
});
const settleMenu = async index => { menus.at(-1).resolve({ index }); await Promise.resolve(); await Promise.resolve(); };
(async () => {
  assert.equal(page.orientationModeLabel(), '跟随系统');
  page.showOrientationMenu();
  assert.deepEqual(Array.from(menus.at(-1).options.buttons, button => button.text), ['跟随系统', '固定竖屏', '固定横屏']);
  await settleMenu(1); assert.equal(choices.at(-1), M.PORTRAIT);
  page.remoteOrientationMode = M.LANDSCAPE;
  assert.equal(page.orientationModeLabel(), '固定横屏');
  page.remoteExternalDisplay = true; page.remoteOrientationMode = M.SYSTEM;
  assert.equal(page.orientationModeLabel(), '自动适配');
  page.showOrientationMenu();
  assert.equal(menus.at(-1).options.title, '投屏方向（仅本次）');
  assert.equal(menus.at(-1).options.buttons[0].text, '自动适配');
  const selectedCount = choices.length;
  page.remoteProjectionDisplayId = 1;
  await settleMenu(2);
  assert.equal(choices.length, selectedCount, 'a display switch invalidates the open menu');
  page.showOrientationMenu(); page.remotePageVisible = false;
  await settleMenu(2); assert.equal(choices.length, selectedCount, 'disposed page cannot set orientation');
  page.remotePageVisible = true; page.showOrientationMenu();
  menus.at(-1).reject(Error('cancel')); await Promise.resolve(); await Promise.resolve();
  assert.equal(choices.length, selectedCount, 'cancel leaves policy unchanged');
  page.showOrientationMenu(); await settleMenu(-1);
  assert.equal(choices.length, selectedCount, 'invalid menu result is ignored');
  p.attach(main); p.setActive(true); await p.pending;
  assert.equal(storage.get('remoteExternalDisplay'), false);
  assert.equal(storage.get('remoteProjectionDisplayId'), 0);
  assert.equal(storage.get('remoteOrientationMode'), M.SYSTEM);
  assert.equal(orientation, O.AUTO_ROTATION_RESTRICTED, 'default honors system rotation lock, including old sensor-only policy');
  assert.equal(hdrMasks.at(-1), 6, 'HDR capability comes from the owning display');
  await select(M.PORTRAIT);
  assert.equal(orientation, O.PORTRAIT, 'phone can explicitly lock portrait');
  await select(M.LANDSCAPE);
  assert.equal(orientation, O.LANDSCAPE, 'phone can explicitly lock landscape');
  await select(M.SYSTEM);
  assert.equal(orientation, O.AUTO_ROTATION_RESTRICTED, 'returning to follow-system never enables unrestricted rotation');
  await select(M.PORTRAIT);
  await project(1);
  assert.equal(storage.get('remoteExternalDisplay'), true);
  assert.equal(storage.get('remoteProjectionDisplayId'), 1);
  assert.equal(storage.get('remoteOrientationMode'), M.SYSTEM, 'projection does not inherit phone lock');
  assert.equal(orientation, O.LANDSCAPE, 'wide external display keeps automatic landscape adaptation');
  assert.equal(hdrMasks.at(-1), 0, 'SDR external screen must not inherit phone HDR capability');
  await select(M.PORTRAIT);
  assert.equal(orientation, O.PORTRAIT, 'manual projected portrait overrides automatic wide-screen layout');
  await select(M.LANDSCAPE);
  assert.equal(orientation, O.LANDSCAPE);
  await project(0);
  assert.equal(storage.get('remoteExternalDisplay'), false);
  assert.equal(storage.get('remoteOrientationMode'), M.PORTRAIT);
  assert.equal(orientation, O.PORTRAIT, 'returning to phone restores its separate portrait choice');
  assert.equal(hdrMasks.at(-1), 6);
  await select(M.SYSTEM);
  await project(1);
  assert.equal(storage.get('remoteOrientationMode'), M.LANDSCAPE, 'projection retains its own session choice');
  await select(M.SYSTEM);
  await project(2);
  assert.equal(orientation, O.AUTO_ROTATION_RESTRICTED, 'portrait external screen is not forced wide');
  await select(M.LANDSCAPE);
  assert.equal(orientation, O.LANDSCAPE, 'portrait external screen can be manually overridden');
  await project(0);
  assert.equal(orientation, O.AUTO_ROTATION_RESTRICTED, 'projection override never leaks to phone');
  deviceInfo.deviceType = 'tablet';
  await select(M.PORTRAIT); assert.equal(orientation, O.PORTRAIT);
  await select(M.LANDSCAPE); assert.equal(orientation, O.LANDSCAPE);
  await select(M.SYSTEM); assert.equal(orientation, O.AUTO_ROTATION_RESTRICTED);
  failNext = true;
  await select(M.LANDSCAPE);
  assert.equal(orientation, O.AUTO_ROTATION_RESTRICTED);
  assert(logs.some(([, message]) => message === 'orientation_apply_failed'));
  await select(M.PORTRAIT); assert.equal(orientation, O.PORTRAIT, 'queue recovers after window error');
  await select('invalid'); assert.equal(orientation, O.PORTRAIT, 'invalid values do not change mode');
  p.setActive(false); await p.pending;
  assert.equal(orientation, O.AUTO_ROTATION_RESTRICTED, 'session exit restores rotation-lock-aware default');
  assert.equal(storage.get('remoteOrientationMode'), M.SYSTEM);
  await select(M.LANDSCAPE); assert.equal(orientation, O.AUTO_ROTATION_RESTRICTED, 'inactive session cannot override rotation');
  p.setActive(true); await p.pending;
  await project(1);
  assert.equal(storage.get('remoteOrientationMode'), M.SYSTEM, 'new session clears projection lock');
  await project(0);
  deviceInfo.deviceType = '2in1';
  const count = applied.length;
  await select(M.LANDSCAPE);
  assert.equal(applied.length, count, 'PC window does not receive handheld orientation requests');
  p.detach(); assert.equal(listener, undefined);
  assert.equal(storage.get('remoteExternalDisplay'), false);
  assert.equal(storage.get('remoteProjectionDisplayId'), -1);
  console.log('PASS rotation policy: system lock, phone/tablet portrait/landscape, independent projection, cleanup, failures and PC isolation');
})().catch(e => { console.error(e); process.exitCode = 1; });
