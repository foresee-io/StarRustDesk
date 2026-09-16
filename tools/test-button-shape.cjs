'use strict';
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = path.join(__dirname, '../entry/src/main/ets');
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const source = read('theme/ButtonShapeModifier.ets');
const body = source.match(/applyNormalAttribute\(instance: ButtonAttribute\): void \{([\s\S]*?)\n  \}/)[1];
const ButtonType = { Normal: 'normal', Capsule: 'capsule' };
const apply = new Function('ButtonType', `return function(instance) {${body}}`)(ButtonType);
const values = {};
const instance = { type: v => { values.type = v; }, borderRadius: v => { values.radius = v; } };
apply.call({ rectangular: true, legacyRadius: 21, legacyType: ButtonType.Capsule }, instance);
assert.deepEqual(values, { type: 'normal', radius: 12 });
apply.call({ rectangular: false, legacyRadius: 21, legacyType: ButtonType.Capsule }, instance);
assert.deepEqual(values, { type: 'capsule', radius: 21 });
assert.match(read('entryability/EntryAbility.ets'), /AppStorage\.setOrCreate\('roundedRectButtons', RustDeskNapi\.getOption\('button-shape'\) !== 'classic'\)/);
for (const file of ['pages/ConnectionPage.ets', 'pages/SettingsPage.ets', 'pages/RemotePage.ets',
  'widget/ServerConfigDialog.ets', 'widget/ReleaseNotesDialog.ets', 'widget/FileTransferHistoryDialog.ets']) {
  const page = read(file);
  assert.match(page, /@StorageLink\('roundedRectButtons'\) roundedRectButtons: boolean = true/, file);
  assert.match(page, /\.attributeModifier\(new ButtonShapeModifier\(this.roundedRectButtons,/, file);
}
const settings = read('pages/SettingsPage.ets');
assert.match(settings, /\.onClick\(\(\) => \{ this\.setButtonShape\(true\) \}\)/);
assert.match(settings, /\.onClick\(\(\) => \{ this\.setButtonShape\(false\) \}\)/);
assert.match(settings, /RustDeskNapi\.setOption\('button-shape', rectangular \? 'rectangle' : 'classic'\)/);
const remote = read('pages/RemotePage.ets');
const capture = remote.slice(remote.indexOf("Button('', { stateEffect: false })"), remote.indexOf('buildRemoteViewport()') + 4400);
assert.match(capture, /borderRadius\(0\)/);
assert.doesNotMatch(capture.slice(0, capture.indexOf('\n      XComponent')), /ButtonShapeModifier/);
console.log('PASS button appearance: default, classic restoration, persistence, reactive consumers and input surface exclusion');
