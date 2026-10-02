'use strict';
// Read-only inventory by default. --migrate opts into the one-time UI migration.
// Never rewrite services, credentials,
// protocol identifiers, stored names, diagnostics, or connection error comparisons.
const fs = require('node:fs');
const path = require('node:path');
const ts = require('C:/Program Files/Huawei/DevEco Studio/tools/ohpm/node_modules/typescript');
const root = path.join(__dirname, '../entry/src/main/ets');
const chinese = /[\u4e00-\u9fff]/;
const sourceKeys = new Set();
const templates = new Set();
function templateKey(n) {
  let key = n.head.text;
  n.templateSpans.forEach((span, i) => { key += `{${i}}` + span.literal.text; });
  return key;
}
for (const dir of ['pages', 'widget', 'service']) {
  for (const file of fs.readdirSync(path.join(root, dir)).filter(f => f.endsWith('.ets'))) {
    const full = path.join(root, dir, file);
    const source = fs.readFileSync(full, 'utf8');
    const ast = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true);
    function collect(n) {
      if ((ts.isStringLiteral(n) || ts.isNoSubstitutionTemplateLiteral(n)) && chinese.test(n.text)) sourceKeys.add(n.text);
      if (ts.isTemplateExpression(n)) {
        const key = templateKey(n);
        if (chinese.test(key) && !/StarRustDesk.*\.(json|srdbak|zip)|cacheDir|远端文件-/.test(n.getText(ast))) {
          sourceKeys.add(key); templates.add(key);
        }
      }
      ts.forEachChild(n, collect);
    }
    collect(ast);
    if (!process.argv.includes('--migrate') || dir === 'service' ||
        source.includes("@StorageLink('uiLanguage')")) continue;
    const edits = [];
    const add = (a, b, text) => edits.push({ a, b, text });
    function wrap(n) {
      if (!n || ts.isObjectLiteralExpression(n) || ts.isNumericLiteral(n)) return;
      const text = n.getText(ast);
      if (/^translate\(/.test(text) || /^\$r\(/.test(text)) return;
      // User content is never a translation key.
      if (/^(item|peer|entry|record|message)\.(name|id|remoteId|fileName|filePath|localPath|content|text)\b/.test(text) ||
          /^this\.(remoteId|connectionName|password|osPasswordDraft|remotePath|remoteFilePath|remoteDeviceName)\b/.test(text) ||
          /item\.name|peer\.name|entry\.name|record\.fileName/.test(text) ||
          /^groupName$/.test(text)) return;
      add(n.getStart(ast), n.end, `translate(${text}, this.uiLanguage)`);
    }
    function visit(n) {
      if (ts.isCallExpression(n)) {
        const call = n.expression.getText(ast);
        if (call === 'translate' && n.arguments.length === 1) {
          add(n.arguments[0].end, n.arguments[0].end, ', this.uiLanguage');
        } else if (['Text', 'Button'].includes(call) || call.endsWith('.accessibilityText')) {
          wrap(n.arguments[0]);
        }
      }
      if (ts.isPropertyAssignment(n) && ['placeholder', 'title', 'message', 'content', 'value', 'text'].includes(n.name.getText(ast))) {
        const text = n.initializer.getText(ast);
        if (chinese.test(text) && (ts.isStringLiteral(n.initializer) || ts.isTemplateExpression(n.initializer) ||
            ts.isConditionalExpression(n.initializer))) wrap(n.initializer);
      }
      ts.forEachChild(n, visit);
    }
    visit(ast);
    // Nested translate calls are already language-aware; keep only outer wrappers
    // and preserve their inner argument insertions in the replacement text.
    const wrappers = edits.filter(e => e.a !== e.b);
    const inserts = edits.filter(e => e.a === e.b);
    for (const w of wrappers) {
      for (const e of inserts.filter(e => e.a >= w.a && e.a <= w.b).sort((a,b) => b.a-a.a)) {
        const offset = 'translate('.length + e.a - w.a;
        w.text = w.text.slice(0, offset) + e.text + w.text.slice(offset);
      }
    }
    const selected = edits.filter(e => !edits.some(w => w !== e && w.a !== w.b && w.a <= e.a && w.b >= e.b));
    let result = source;
    for (const e of selected.sort((a,b) => b.a-a.a)) result = result.slice(0,e.a) + e.text + result.slice(e.b);
    if (!result.includes("import { translate")) result = "import { translate } from '../utils/I18n'\n" + result;
    result = result.replace(/((?:export )?struct \w+ \{)/g,
      "$1\n  @StorageLink('uiLanguage') uiLanguage: string = 'zh-Hans'");
    fs.writeFileSync(full, result);
  }
}
if (!process.argv.includes('--migrate')) {
  const keys = [...sourceKeys];
  console.log(JSON.stringify({ keys, templates: [...templates] }, null, 2));
}
