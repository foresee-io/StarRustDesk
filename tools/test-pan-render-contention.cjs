const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
const page = read('entry/src/main/ets/pages/RemotePage.ets');
function method(name) {
  const start = page.indexOf('\n  ' + name + '(');
  assert(start >= 0, name);
  return page.slice(start, page.indexOf('\n  }', start) + 4);
}
const callbacks = [];
const context = vm.createContext({
  ViewportFrameCallback: class { constructor(apply) { this.apply = apply; } }
});
vm.runInContext(ts.transpile('class Pan {' +
  ['discardViewportPanFrame', 'flushViewportPanFrame', 'queueViewportPanFrame', 'finishViewportPan'].map(method).join('\n') +
  '} globalThis.Pan = Pan;'), context);
const p = new context.Pan();
Object.assign(p, {
  offsetX: 0, offsetY: 0, zoomScale: 2, viewportPanFramePending: false,
  viewportPanFrameGeneration: 0, viewportPanActive: true,
  clampHorizontalOffset: x => Math.max(-100, Math.min(100, x)),
  clampVerticalOffset: y => Math.max(-100, Math.min(100, y)),
  getUIContext: () => ({ postFrameCallback: c => callbacks.push(c.apply) }),
  syncVirtualMouseToCurrentPointer() { this.syncs = (this.syncs || 0) + 1; },
  clampViewportOffset() {}
});
for (let i = 0; i < 20; i++) p.queueViewportPanFrame(1, 2);
assert.equal(callbacks.length, 1);
assert.equal(p.offsetX, 0);
callbacks.shift()();
assert.equal(p.offsetX, 20);
assert.equal(p.offsetY, 40);
assert.equal(p.syncs, 1);
p.queueViewportPanFrame(5, 6);
p.finishViewportPan();
assert.equal(p.offsetX, 25);
callbacks.shift()();
assert.equal(p.syncs, 2, 'stale callback must not reapply after release');
p.queueViewportPanFrame(9, 9);
p.discardViewportPanFrame();
p.queueViewportPanFrame(1, 1);
callbacks.shift()();
assert.equal(p.offsetX, 25, 'old callback must not flush new gesture');
callbacks.shift()();
assert.equal(p.offsetX, 26);
p.queueViewportPanFrame(200, 0);
p.queueViewportPanFrame(-10, 0);
callbacks.shift()();
assert.equal(p.offsetX, 90, 'clamp each event before reversal');
assert(method('resetViewportTransform').includes('discardViewportPanFrame'));
assert(method('cancelActiveTouchGesture').includes('discardViewportPanFrame'));
assert(!method('handleViewportPan').includes('refreshVideo'));
console.log('PASS pan: frame coalescing, accumulated movement, final flush, cancellation, edge reversal');
const napi = read('entry/src/main/cpp/napi_init.cpp');
const cursor = napi.slice(napi.indexOf('static napi_value GetRemoteCursorData'), napi.indexOf('static napi_value GetRemoteCursorData') + 3800);
assert(cursor.indexOf('if (!changed)') < cursor.indexOf('std::vector<unsigned char> colors'));
assert(method('pollRemoteCursorImage').includes('getRemoteCursorData(this.lastRemoteCursorImageSequence)'));
console.log('PASS cursor: unchanged sequence exits before pixel allocation/copy');
const soft = read('entry/src/main/cpp/core/software_vp9_decoder.cpp');
assert(soft.includes('outputLock(presentationMutex_)'));
assert(soft.includes('presentationLock(presentationMutex_)'));
assert(soft.includes('queueLock(mutex_)'));
assert(!soft.includes('outputLock(mutex_)'));
const video = read('entry/src/main/cpp/core/video_render.cpp');
const render = video.slice(video.indexOf('void VideoRender::renderFrameNow'));
assert(render.indexOf('SoftwareVP9Decoder::instance().decodeFrame') < render.indexOf('OHNativeWindow* window'));
console.log('PASS source guards: VP9 queue/presentation locks separated, reset barrier retained, no window lock before software enqueue');
