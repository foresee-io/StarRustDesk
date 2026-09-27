const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');
const source = fs.readFileSync('entry/src/main/ets/pages/RemotePage.ets', 'utf8');
const model = fs.readFileSync('entry/src/main/ets/model/PhysicalMousePolicy.ets', 'utf8');
const method = name => {
  const start = source.indexOf('\n  ' + name + '(');
  assert(start >= 0, name);
  return source.slice(start, source.indexOf('\n  }', start) + 4);
};
let now = 1000, enabled = false;
const sent = [], logs = [];
const MouseAction = { Move: 1, Hover: 2, Press: 3, Release: 4 };
const MouseButton = { Left: 1, Right: 2 };
const SourceType = { TouchScreen: 1, Mouse: 2 };
const SourceTool = { Finger: 1, Pen: 2, MOUSE: 3, TOUCHPAD: 4 };
const context = vm.createContext({
  Date: { now: () => now }, Math, Number, MouseAction, MouseButton, SourceType, SourceTool,
  TouchType: { Down: 0, Move: 1, Up: 2, Cancel: 3 },
  INPUT_MODE_MOUSE: 'mouse', ConnectionStatus: { CONNECTED: 2 },
  NATIVE_MOUSE_ACTION_MOVE: 3, NATIVE_MOUSE_ACTION_PRESS: 1,
  NATIVE_MOUSE_ACTION_RELEASE: 2, NATIVE_MOUSE_ACTION_CANCEL: 13,
  NATIVE_MOUSE_BUTTON_LEFT: 1, NATIVE_MOUSE_BUTTON_RIGHT: 2,
  RustDeskNapi: { getOption: () => enabled ? '1' : '0', appendDiagnosticLog: (...v) => logs.push(v) },
  ConnectionService: { sendMouseEvent: (...v) => sent.push(v), syncNativeModifierState() {} }
});
vm.runInContext(ts.transpile(model.replace(/export /g, '') + `
globalThis.Dedup = PhysicalMouseDeduplicator;
globalThis.isTouchOnly = isTouchOnlyMouseEvent;
class Page {${[
  'handleNativeMouseInput', 'handleRemoteMouse', 'mapMouseAction',
  'updatePointerFromLocal', 'updateCursorOverlayFromPosition', 'markLocalPointerInput',
  'noteProjectedPhysicalPointer', 'shouldShowCursorOverlay',
  'resetPointerDiagnostics', 'flushPointerDiagnostics', 'onProjectionDisplayChanged',
  'handleRemoteClickFallback'
].map(method).join('\n')}}
globalThis.Page = Page;`), context);
let checks = 0;
function test(name, run) { run(); checks++; console.log('PASS ' + name); }
const d = new context.Dedup();
test('native click cannot swallow following unpressed movement', () => {
  d.rememberNative(1, 50, 60, 1000);
  assert.equal(d.consumeDuplicate(0, 51, 60, 1010), false);
});
test('only matching action and position are deduplicated, once', () => {
  d.rememberNative(0, 50, 60, 1000);
  assert.equal(d.consumeDuplicate(0, 50, 60, 1010), true);
  assert.equal(d.consumeDuplicate(0, 50, 60, 1011), false);
  d.rememberNative(0, 50, 60, 1000);
  assert.equal(d.consumeDuplicate(0, 51, 60, 1010), false);
  d.rememberNative(1, 50, 60, 1000);
  assert.equal(d.consumeDuplicate(2, 50, 60, 1010), false);
});
test('expired, invalid and reset samples never suppress new input', () => {
  d.rememberNative(0, 50, 60, 1000);
  assert.equal(d.consumeDuplicate(0, 50, 60, 1080), false);
  d.rememberNative(0, NaN, 60, 1000);
  assert.equal(d.consumeDuplicate(0, 50, 60, 1010), false);
  d.rememberNative(0, 50, 60, 1000); d.clear();
  assert.equal(d.consumeDuplicate(0, 50, 60, 1010), false);
});
test('explicit mouse/touchpad survives touch wrapper; real finger/pen stays filtered', () => {
  assert.equal(context.isTouchOnly(true, false, true, false), false);
  assert.equal(context.isTouchOnly(false, true, false, true), false);
  assert.equal(context.isTouchOnly(true, false, false, true), true);
  assert.equal(context.isTouchOnly(false, false, false, true), true);
});
function page(overrides = {}) {
  const p = Object.assign(new context.Page(), {
    connectionStatus: 2, remoteWidth: 1000, remoteHeight: 500,
    componentWidth: 600, componentHeight: 400, inputMode: 'mouse',
    remoteExternalDisplay: true, remoteProjectionDisplayId: 8, projectedPhysicalPointer: false,
    showCursor: false, relativeMouseEnabled: false, hasAuthoritativeRemoteCursor: false,
    remoteCursorEmbedded: false, embeddedCursorOverlayFallback: false,
    remoteCursorImageWidth: 0, remoteCursorImageHeight: 0,
    cursorCompatibilityMode: 'auto', lastMoveSentAt: 0, lastNativeMouseEventAt: 0,
    lastTouchEventAt: 0, lastMappedPhysicalLeftUpAt: 0,
    physicalMouseDeduplicator: new context.Dedup(),
    getDisplayWidth: () => 500, getDisplayHeight: () => 250,
    getDisplayLeft: () => 50, getDisplayTop: () => 75,
    suppressCompatibilityCursor() { return this.cursorCompatibilityMode === 'embedded'; },
    handleRemoteHover() {}, syncModifiersFromPointerEvent() {}, updateSystemPointerVisibility() {},
    clearLongPressTimer() {}, clearTapTimer() {}, requestRemoteInputFocus() {},
    reconcilePhysicalMouseButtons() {}, updateEdgeAutoPan() {}, stopEdgeAutoPan() {},
    sendLeftDown(x,y) { sent.push([x,y,1]); }, sendLeftUp(x,y) { sent.push([x,y,2]); },
    sendRightDown(x,y) { sent.push([x,y,3]); }, sendRightUp(x,y) { sent.push([x,y,4]); },
    sendLeftClick(x,y) { sent.push([x,y,'click']); },
    releaseHeldMouseButtons(reason) { this.releaseReason = reason; },
    ...overrides
  });
  p.resetPointerDiagnostics(); sent.length = 0;
  return p;
}
function ark(p, x, y, extra = {}) {
  p.handleRemoteMouse({ action: MouseAction.Move, button: 0, x, y,
    source: SourceType.Mouse, sourceTool: SourceTool.MOUSE,
    stopPropagation() {}, ...extra });
}
function native(p, x, y, action = 3, button = 0) {
  p.handleNativeMouseInput({ x,y,action,button,hover:-1,modifierValid:false });
}
test('native button followed by ArkUI movement forwards and positions overlay', () => {
  const p = page(); now = 1000; native(p, 100, 100, 1, 1);
  now += 16; ark(p, 160, 175);
  assert.deepEqual(sent.at(-1), [220, 200, 0]);
  assert.equal(p.cursorX, 160); assert.equal(p.cursorY, 175);
  assert.equal(p.shouldShowCursorOverlay(), true);
});
test('same native/ArkUI move forwards once; different next move still works', () => {
  const p = page(); now = 1000; native(p, 100, 100);
  now += 16; ark(p, 150, 175);
  assert.equal(sent.length, 1); assert.equal(p.pointerDuplicateEvents, 1);
  now += 16; ark(p, 160, 175);
  assert.equal(sent.length, 2); assert.deepEqual(sent.at(-1), [220,200,0]);
});
test('matching native buttons do not double-click or drop the next release', () => {
  const p = page(); now = 1000; native(p, 100,100,1,1);
  now += 10; ark(p,150,175,{action:MouseAction.Press,button:MouseButton.Left});
  now += 10; ark(p,150,175,{action:MouseAction.Release,button:MouseButton.Left});
  assert.deepEqual(sent.map(v => v[2]), [1,2]);
});
test('projected physical cursor displays in direct-touch mode without changing preference', () => {
  const p = page({inputMode:'touch'}); now = 1000;
  ark(p,100,100,{source:SourceType.TouchScreen});
  assert.equal(p.projectedPhysicalPointer,true);
  assert.equal(p.shouldShowCursorOverlay(),true);
  assert.equal(p.inputMode,'touch');
  assert.deepEqual(sent.at(-1),[200,200,0]);
  p.remoteExternalDisplay=false;
  assert.equal(p.shouldShowCursorOverlay(),false,'local/mirror touch-mode behavior stays unchanged');
});
test('finger compatibility cannot take over physical cursor or send another move', () => {
  const p = page(); now=1000;
  ark(p,100,100,{source:SourceType.TouchScreen,sourceTool:SourceTool.Finger});
  assert.equal(sent.length,0); assert.equal(p.pointerFilteredEvents,1);
  assert.equal(p.projectedPhysicalPointer,false);
});
test('relative mode and explicit embedded preference keep their cursor constraints', () => {
  const p=page({showCursor:true,projectedPhysicalPointer:true,relativeMouseEnabled:true});
  assert.equal(p.shouldShowCursorOverlay(),false);
  p.hasAuthoritativeRemoteCursor=true; assert.equal(p.shouldShowCursorOverlay(),true);
  p.cursorCompatibilityMode='embedded'; assert.equal(p.shouldShowCursorOverlay(),false);
});
test('display transition clears stale pairing and relative baseline', () => {
  const p=page({remotePageVisible:true,projectedPhysicalPointer:true,relativePointerSampleValid:true});
  p.physicalMouseDeduplicator.rememberNative(0,10,10,1000);
  p.onProjectionDisplayChanged();
  assert.equal(p.relativePointerSampleValid,false); assert.equal(p.projectedPhysicalPointer,false);
  assert.equal(p.physicalMouseDeduplicator.consumeDuplicate(0,10,10,1010),false);
  assert.equal(p.releaseReason,'projection_display_changed');
});
test('diagnostics disabled by default; rate-limited movement and display reasons when enabled', () => {
  const p=page(); logs.length=0; now=5000; enabled=false;
  ark(p,100,100); p.flushPointerDiagnostics(); assert.equal(logs.length,0);
  now+=2000; enabled=true; ark(p,110,110); p.flushPointerDiagnostics();
  assert.equal(logs.length,1); assert.match(logs[0][1],/ark_move=1/);
  assert.match(logs[0][1],/physical_move_dispatch=1/); assert.match(logs[0][1],/overlay=true/);
  p.flushPointerDiagnostics(); assert.equal(logs.length,1);
  now+=2000; p.flushPointerDiagnostics();
  assert.match(logs.at(-1)[1],/native_move=0 ark_move=0 touch_move=0/);
  assert.doesNotMatch(logs.map(v=>v[1]).join('\n'), /password|token|clipboard/);
});
test('cursor overlay does not intercept input and is explicitly above the surface', () => {
  const start=source.indexOf('\n  buildCursorOverlay()');
  const overlay=source.slice(start,source.indexOf('\n  }',start)+4);
  assert.match(overlay,/\.zIndex\(11\)/);
  assert.match(overlay,/\.hitTestBehavior\(HitTestMode.None\)/);
});
console.log(`${checks} projection pointer regression checks passed`);
