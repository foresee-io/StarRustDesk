const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/tools/ohpm/node_modules/typescript');
const source = fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/pages/ConnectionPage.ets'), 'utf8');
const slice = (start, end) => source.slice(source.indexOf(start), source.indexOf(end, source.indexOf(start)));
const methods = slice('  applySavedConnection(', '  clearSaveTip(') +
  slice('  async saveCurrentConnection(', '  async deleteSavedConnection(') +
  source.slice(source.indexOf('  clearConnectionForm('), source.lastIndexOf('\n}'));
const credentials = new Map();
const osCredentials = new Map();
const securityOptions = new Map();
let failSave = false, waitSave;
const context = vm.createContext({
  CredentialStore: { save: async (id, password) => {
    if (failSave) throw Error('storage failure');
    if (waitSave) await waitSave;
    if (password) credentials.set(id, password); else credentials.delete(id);
  } },
  RemoteSecurityStore: {
    options: id => securityOptions.get(id) || { lockAfterDisconnect: false, privacyMode: false, autoUnlock: false },
    saveOptions: (id, options) => securityOptions.set(id, options),
    loadOsPassword: async id => osCredentials.get(id) || '',
    saveOsPassword: async (id, password) => osCredentials.set(id, password),
    removeOsPassword: async id => osCredentials.delete(id),
    remove: async id => { osCredentials.delete(id); securityOptions.delete(id); },
  },
  RustDeskNapi: { appendDiagnosticLog: () => {} },
  PerformanceSettings: { normalize: value => value },
});
vm.runInContext(ts.transpileModule(`class Page { ${methods} } globalThis.Page = Page;`,
  { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, context);
const original = { id: 'a', remoteId: '123456', name: 'Host', password: 'saved-secret', performancePreset: 'smooth', groupId: 'g' };
const other = { ...original, id: 'b', remoteId: '987654', password: 'other-secret' };
function create() {
  const page = new context.Page();
  Object.assign(page, { savedConnections: [{ ...original }, { ...other }], savedConnectionsVersion: 0,
    selectedConnectionId: '', password: '', passwordEditMode: 'keep', osPasswordDraft: '',
    hasStoredOsPassword: false, clearOsPassword: false, lockAfterDisconnect: false,
    privacyMode: false, autoUnlock: false });
  page.validGroupId = value => value;
  page.persistSavedConnections = list => { page.persisted = list; };
  page.refreshSavedConnectionOnlineStates = () => {};
  page.onConnect = () => { page.sentPassword = page.connectionPasswordForUse(); };
  return page;
}
(async () => {
  const page = create();
  page.applySavedConnection(original);
  assert.equal(page.password, '', 'saved secret must never populate input');
  assert.equal(page.hasSavedConnectionPassword(), true);
  page.connectSavedConnection(original);
  assert.equal(page.sentPassword, 'saved-secret');
  assert.equal(page.password, '');
  page.connectionName = 'Renamed';
  await page.saveCurrentConnection();
  assert.equal(credentials.get('a'), 'saved-secret', 'metadata edits retain secret');
  assert.equal(page.password, '');
  page.startPasswordReplacement();
  assert.equal(page.password, '');
  assert.equal(page.connectionPasswordForUse(), '', 'empty replacement cannot fall back to old password');
  await assert.rejects(page.saveCurrentConnection(), /Empty replacement/);
  assert.equal(credentials.get('a'), 'saved-secret');
  page.password = 'new-secret';
  assert.equal(page.connectionPasswordForUse(), 'new-secret');
  await page.saveCurrentConnection();
  assert.equal(credentials.get('a'), 'new-secret');
  assert.equal(page.password, '', 'saved new password must disappear from input');
  assert.equal(page.passwordEditMode, 'keep');
  page.clearSavedPassword();
  assert.equal(credentials.get('a'), 'new-secret', 'clear remains staged until save');
  assert.equal(page.connectionPasswordForUse(), '');
  page.cancelPasswordChange();
  assert.equal(page.connectionPasswordForUse(), 'new-secret');
  page.clearSavedPassword();
  await page.saveCurrentConnection();
  assert.equal(credentials.has('a'), false);
  assert.equal(page.hasSavedConnectionPassword(), false);
  page.applySavedConnection(original);
  page.autoUnlock = true;
  page.lockAfterDisconnect = true;
  page.osPasswordDraft = 'private-os-secret';
  await page.saveCurrentConnection();
  assert.equal(osCredentials.get('a'), 'private-os-secret');
  assert.equal(page.osPasswordDraft, '', 'OS password draft must be cleared after save');
  assert.equal(securityOptions.get('a').autoUnlock, true);
  page.remoteId = 'different-device';
  await page.saveCurrentConnection();
  assert.equal(osCredentials.has('a'), false, 'changing peer identity must clear its saved OS password');
  assert.equal(securityOptions.get('a').autoUnlock, false);
  page.applySavedConnection(other);
  page.remoteId = 'another-peer';
  assert.equal(page.hasSavedConnectionPassword(), false);
  assert.equal(page.connectionPasswordForUse(), '', 'changed peer cannot inherit saved credentials');
  page.clearConnectionForm();
  assert.equal(page.password, '');
  assert.equal(page.passwordEditMode, 'keep');

  const failed = create(); failed.applySavedConnection(original); failed.startPasswordReplacement(); failed.password = 'replacement';
  failSave = true;
  await assert.rejects(failed.saveCurrentConnection());
  failSave = false;
  assert.equal(failed.savedConnections[0].password, 'saved-secret');
  assert.equal(failed.password, 'replacement', 'failure retains only user-entered draft');

  const switched = create(); switched.applySavedConnection(original);
  switched.osPasswordDraft = 'first-device-os-secret';
  switched.autoUnlock = true;
  let finish; waitSave = new Promise(resolve => { finish = resolve; });
  const saving = switched.saveCurrentConnection();
  switched.applySavedConnection(other);
  finish(); await saving; waitSave = undefined;
  assert.equal(switched.selectedConnectionId, 'b');
  assert.equal(switched.password, '');
  assert.equal(switched.connectionPasswordForUse(), 'other-secret');
  assert.equal(osCredentials.get('a'), 'first-device-os-secret', 'async save must retain its original OS password draft');
  assert.equal(osCredentials.has('b'), false, 'async save must not copy OS password to another device');

  const ui = slice('  buildPasswordInput()', '  @Builder\n  buildSavedConnections');
  assert(ui.includes("Text('密码已保存')"));
  assert(ui.includes("Button('更换')") && ui.includes("Button('清除')"));
  assert(ui.includes('保存后生效'));
  assert(ui.includes('.showPasswordIcon(true)'));
  assert(!source.includes('this.password = item.password'));
  assert.match(source, /async onConnect\(fileOnly: boolean = false\): Promise<void>[\s\S]*?let password: string = this.connectionPasswordForUse\(\)/);
  assert.match(source, /password: includesPasswords \? item.password : ''/);
  assert.doesNotMatch(slice('  buildBackupPayload(', '  async saveBackupFile('), /osPassword|RemoteSecurityStore/,
    'connection backups must never include the OS password');
  assert.match(source, /this.password = password\s*this.passwordEditMode = 'replace'/);
  console.log('PASS saved password privacy: no refill, direct connect, metadata save, replace/cancel/clear, peer isolation, save failure, async form switch and backup preservation');
})().catch(error => { console.error(error); process.exitCode = 1; });
