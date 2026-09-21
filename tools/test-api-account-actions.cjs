const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const read = name => fs.readFileSync(path.join(__dirname, '../entry/src/main/ets/widget', name), 'utf8');
const dialog = read('ApiAccountDialog.ets');
const action = read('ApiAccountAction.ets');
// Builder value parameters captured the initial busy=true state on-device.
// Every stateful button must instead receive reactive component props.
assert(!dialog.includes('this.action('));
for (const prop of ['label: string', 'selected: boolean', 'isEnabled: boolean']) {
  assert(action.includes('@Prop ' + prop), prop);
}
assert(action.includes('.enabled(this.isEnabled)'));
assert(action.includes('Button(this.label)'));
assert(action.includes('if (this.isEnabled) this.onAction()'));
assert.equal((dialog.match(/ApiAccountAction\(\{/g) || []).length, 17);
assert(dialog.includes("label: this.busy ? '取消请求' : '关闭'"));
assert(dialog.includes("label: '登录', selected: true, isEnabled: !this.busy"));
assert(dialog.includes('isEnabled: !this.busy && this.selected.length > 0'));
console.log('PASS account buttons: reactive labels, selected state, enablement and click guard on all 17 actions');
