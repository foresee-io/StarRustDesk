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
let failSave = false, waitSave;
const context = vm.createContext({
  CredentialStore: { save: async (id, password) => {
    if (failSave) throw Error('storage failure');
    if (waitSave) await waitSave;
    if (password) credentials.set(id, password); else credentials.delete(id);
  } },
  PerformanceSettings: { normalize: value => value },
});
vm.runInContext(ts.transpileModule(`class Page { ${methods} } globalThis.Page = Page;`,
  { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText, context);
const original = { id: 'a', remoteId: '123456', name: 'Host', password: 'saved-secret', performancePreset: 'smooth', groupId: 'g' };
const other = { ...original, id: 'b', remoteId: '987654', password: 'other-secret' };
function create() {
  const page = new context.Page();
  Object.assign(page, { savedConnections: [{ ...original }, { ...other }], savedConnectionsVersion: 0,
    selectedConnectionId: '', password: '', passwordEditMode: 'keep' });
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
  let finish; waitSave = new Promise(resolve => { finish = resolve; });
  const saving = switched.saveCurrentConnection();
  switched.applySavedConnection(other);
  finish(); await saving; waitSave = undefined;
  assert.equal(switched.selectedConnectionId, 'b');
  assert.equal(switched.password, '');
  assert.equal(switched.connectionPasswordForUse(), 'other-secret');

  const ui = slice('  buildPasswordInput()', '  @Builder\n  buildSavedConnections');
  assert(ui.includes("Text('密码已保存')"));
  assert(ui.includes("Button('更换')") && ui.includes("Button('清除')"));
  assert(ui.includes('保存后生效'));
  assert(ui.includes('.showPasswordIcon(true)'));
  assert(!source.includes('this.password = item.password'));
  assert.match(source, /async onConnect\(fileOnly: boolean = false\): Promise<void>[\s\S]*?let password: string = this.connectionPasswordForUse\(\)/);
  assert.match(source, /password: includesPasswords \? item.password : ''/);
  assert.match(source, /this.password = password\s*this.passwordEditMode = 'replace'/);
  console.log('PASS saved password privacy: no refill, direct connect, metadata save, replace/cancel/clear, peer isolation, save failure, async form switch and backup preservation');
})().catch(error => { console.error(error); process.exitCode = 1; });
