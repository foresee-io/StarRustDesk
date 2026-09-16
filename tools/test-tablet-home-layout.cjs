'use strict';
const fs = require('node:fs');
const assert = require('node:assert/strict');
const source = fs.readFileSync(require('node:path').join(__dirname,
  '../entry/src/main/ets/pages/ConnectionPage.ets'), 'utf8');
const deviceInfo = { deviceType: 'tablet' };
const body = source.match(/isTabletWideLayout\(\): boolean \{([\s\S]*?)\n  \}/)[1];
const isWide = new Function('deviceInfo', `return function() {${body}}`)(deviceInfo);
assert.equal(isWide.call({ pageWidth: 1200, pageFullHeight: 760 }), true);
assert.equal(isWide.call({ pageWidth: 900, pageFullHeight: 1200 }), false);
assert.equal(isWide.call({ pageWidth: 700, pageFullHeight: 500 }), false);
deviceInfo.deviceType = 'phone';
assert.equal(isWide.call({ pageWidth: 1200, pageFullHeight: 760 }), false);
deviceInfo.deviceType = '2in1';
assert.equal(isWide.call({ pageWidth: 1200, pageFullHeight: 760 }), false);
assert.match(source, /Math\.max\(this\.pageFullHeight, nextHeight\)/,
  'keyboard resize must retain the full window height');
assert.match(source, /if \(this\.isTabletWideLayout\(\)\) \{\s*Column[\s\S]*?buildTabletQuickConnect\(\)[\s\S]*?Scroll\(\)[\s\S]*?buildSavedConnections\(\)/);
assert.match(source, /FlexWrap\.Wrap, justifyContent: FlexAlign\.SpaceBetween/);
assert.match(source, /\.width\(this\.isTabletWideLayout\(\) \? '49%' : '100%'\)/);
assert.match(source, /editSavedConnection\(item:[\s\S]*?if \(this\.isTabletWideLayout\(\)\) this\.setTabletEditorVisible\(true\)/);
assert.match(source, /await this\.saveCurrentConnection\(\)[\s\S]*?if \(this\.tabletEditorVisible\) this\.setTabletEditorVisible\(false\)/);
assert.match(source, /\.zIndex\(8\)[\s\S]*?duration: 240/);
console.log('PASS tablet layout: device/size scope, IME stability, quick connect, grid and editor');
