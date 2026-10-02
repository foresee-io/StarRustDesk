'use strict';
const fs = require('node:fs');
const path = require('node:path');
const cp = require('node:child_process');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/tools/ohpm/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = name => fs.readFileSync(path.join(root, name), 'utf8');
const cpp = 'entry/src/main/cpp/';
const page = read('entry/src/main/ets/pages/RemotePage.ets');
const start = page.indexOf('\n  videoDynamicRangeStatus(');
const method = page.slice(start, page.indexOf('\n  }', start) + 4);
const context = { exports: {}, translate: s => s };
vm.runInNewContext(ts.transpileModule('export class Page {' + method + '}', {
  compilerOptions: { target: ts.ScriptTarget.ES2021, module: ts.ModuleKind.CommonJS }
}).outputText, context);
const p = new context.exports.Page();
assert.equal(p.videoDynamicRangeStatus({ hasFrame: false, dynamicRange: 2 }), '-');
assert.equal(p.videoDynamicRangeStatus({ hasFrame: true, dynamicRange: 0, bitDepth: 10 }), '未标记 · 10 bit');
assert.equal(p.videoDynamicRangeStatus({ hasFrame: true, dynamicRange: 1, bitDepth: 10 }), 'SDR · 10 bit');
assert.equal(p.videoDynamicRangeStatus({ hasFrame: true, dynamicRange: 2, colorOutput: 3 }), 'HDR10/PQ → SDR');
assert.equal(p.videoDynamicRangeStatus({ hasFrame: true, dynamicRange: 3, colorOutput: 2 }), 'HLG · Surface');
assert.equal(p.videoDynamicRangeStatus({ hasFrame: true, dynamicRange: 4, colorOutput: 4 }), 'HDR Vivid · 系统适配');
assert.equal(p.videoDynamicRangeStatus({ hasFrame: true, dynamicRange: 2, colorOutput: 5 }), 'HDR10/PQ · 输出不支持');
for (const decoder of ['h264_decoder', 'vp9_decoder', 'system_video_decoder']) {
  const source = read(cpp + 'core/' + decoder + '.cpp');
  assert.match(source, /color_ = readVideoColorFormat\(format\)/);
  assert.match(source, /decoder->codec_ != codec/);
  assert.match(source, /applyVideoColor\(decoder->window_, color\)/);
  assert.match(source, /updateColorInfo\(color\)/);
  assert.match(source, /enrichVideoColorFromBuffer\(buffer, color\)/);
  assert.match(source, /std::try_to_lock/);
  assert.match(source, /OH_VideoDecoder_GetOutputDescription\(codec\)/);
}
const window = read(cpp + 'core/xcomponent_render.cpp');
const create = window.slice(window.indexOf('bool XComponentRender::createWindowLocked()'), window.indexOf('void XComponentRender::configureWindowLocked'));
assert.doesNotMatch(create, /configureWindowLocked\(|SET_FORMAT/);
assert.match(window, /OH_NativeWindow_SetColorSpace/);
assert.match(window, /!cpuConfigured_ \|\| bufferWidth_/);
assert.match(window, /expectedWindow != nativeWindow_/);
assert.match(window, /appliedHdrFormats_ == hdrDisplayFormats_\.load\(\)/);
assert.match(window, /color.bitDepth >= 10/);
assert.match(window, /if \(cpuConfigured_\) \{ destroyWindowLocked\(\); createWindowLocked\(\); \}/);
const bufferMetadata = read(cpp + 'core/video_color_format.h');
assert.match(bufferMetadata, /OH_AVBuffer_GetNativeBuffer/);
assert.match(bufferMetadata, /OH_NativeBuffer_Unreference\(native\)/);
assert.match(bufferMetadata, /NATIVEBUFFER_PIXEL_FMT_YCBCR_P010/);
assert.match(read(cpp + 'core/video_render.cpp'), /SoftwareAV1Decoder::instance\(\)\.release\(\);\s+VideoRender::instance\(\)\.resetColorInfo\(\)/);
assert.match(read(cpp + 'core/software_av1_decoder.cpp'), /color\.isHdr\(\) \|\| highBitDepth/);
assert.match(read(cpp + 'napi_init.cpp'), /"dynamicRange"/);
const display = read('entry/src/main/ets/service/RemoteDisplayPolicy.ets');
assert.match(display, /getDisplayByIdSync\(RemoteDisplayPolicy.currentDisplayId\)/);
assert.match(display, /target.hdrFormats/);
assert.match(display, /RustDeskNapi.setHdrDisplayFormats\(mask\)/);

// Run the real C++ conversion code on the host; never substitute a JS reimplementation.
const vswhere = 'C:/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe';
const vs = cp.execFileSync(vswhere, ['-latest', '-products', '*', '-requires',
  'Microsoft.VisualStudio.Component.VC.Tools.x86.x64', '-property', 'installationPath'], { encoding: 'utf8' }).trim();
assert(vs, 'MSVC is required for native color tests');
const out = path.join(root, 'build-artifacts/hdr-tests');
fs.mkdirSync(out, { recursive: true });
const vcvars = path.join(vs, 'VC/Auxiliary/Build/vcvars64.bat');
const exe = path.join(out, 'test-video-color.exe');
const command = `call "${vcvars}" >nul && cl /nologo /std:c++17 /EHsc /O2 /I"${path.join(root, cpp, 'core')}" ` +
  `"${path.join(root, 'tools/native/test-video-color.cpp')}" "${path.join(root, cpp, 'core/video_color.cpp')}" ` +
  `/Fe:"${exe}" /Fo:"${out}/"`;
cp.execFileSync('cmd.exe', ['/d', '/s', '/c', command], { cwd: root, stdio: 'pipe', windowsVerbatimArguments: true });
process.stdout.write(cp.execFileSync(exe, [], { encoding: 'utf8' }));
console.log('HDR UI, metadata, lifecycle and display selection checks passed');
