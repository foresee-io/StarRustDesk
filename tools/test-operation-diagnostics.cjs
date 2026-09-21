const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/tools/ohpm/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const logs = []; let enabled = false, failLog = false, now = 1000;
const native = { getOption: () => enabled ? '1' : '0', appendDiagnosticLog: (scope, text) => {
  if (failLog) throw Error('logger unavailable'); logs.push({scope,text});
} };
function load(name, deps) {
  const context = { exports: {}, Date: { now: () => now }, require: p => {
    if (p === './RustDeskNapi') return { RustDeskNapi: native };
    if (deps[p]) return deps[p]; throw Error(p);
  } };
  const src = fs.readFileSync(path.join(root, `entry/src/main/ets/service/${name}.ets`), 'utf8');
  vm.runInNewContext(ts.transpileModule(src, {compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText, context);
  return context.exports;
}
const { OperationDiagnostic: Trace } = load('OperationDiagnostic', {});
let trace = new Trace('file-transfer','transfer'); trace.event('copy'); trace.end('completed');
assert.equal(logs.length, 0, 'default-disabled logs must write nothing');
enabled = true; trace = new Trace('file-transfer','transfer'); now += 125;
trace.event('copy', { bytes: 10, token: 'private-token', items: 'private-password', code: Infinity });
trace.fail({ code: '13900012', message: '保存到 /private/folder/private-name.bin 失败 private-token' }, { written_bytes: 7 });
const ended = logs.length; trace.end('completed'); trace.event('progress'); assert.equal(logs.length, ended);
const lines = logs.map(v=>v.text).join('\n');
assert.match(lines, /op_id=1000-2/); assert.match(lines,/elapsed_ms=125/); assert.match(lines,/written_bytes=7/);
assert.match(lines,/code=13900012/); assert.match(lines,/step=failed after=copy/);
for (const secret of ['private-token','private-password','private-name','/private/','Infinity']) assert(!lines.includes(secret));
trace = new Trace('api-book-sync', 'apply'); trace.fail({message:'服务器数据已变化，请重新预览',status:409});
assert.match(logs.at(-1).text,/reason=state_changed/); assert.match(logs.at(-1).text,/code=409/);
for (const [message, reason] of [['ENOSPC /private/folder','storage_full'], ['permission denied /private/folder','permission'],
  ['request timed out private-token','timeout'], ['saved file size mismatch','verification'], ['downloaded source file is missing','missing_file']]) {
  trace = new Trace('file-transfer', 'transfer'); trace.fail({message});
  assert(logs.at(-1).text.includes(`reason=${reason}`));
  assert(!logs.at(-1).text.includes('/private/') && !logs.at(-1).text.includes('private-token'));
}
const before = logs.length; trace = new Trace('recording','export'); trace.event('private-token');
enabled = false; trace.end('completed'); assert.equal(logs.length,before+1,'disabling takes effect mid-operation');
enabled = true; failLog = true; assert.doesNotThrow(()=>new Trace('recording','export').fail({code:1})); failLog = false;
assert.equal(Trace.errorCode({code:'secret'}), 0); assert.equal(Trace.errorCode(null),0);

let cancel = false, ioError = false, mismatch = false, closes = 0, recording = 0;
native.startRecording = () => { recording=1; return 0; }; native.stopRecording = () => { recording=0; return -2; };
native.getRecordingStatus = () => recording;
const fileIo = { OpenMode:{READ_ONLY:1, READ_WRITE:2, TRUNC:4}, statSync: p => ({size: typeof p === 'number' && mismatch ? 0 : 4}),
  open: async p => { if(ioError) throw {code:13900012,message:'private-path'}; return {fd:p==='target'?2:1}; },
  close: async () => {closes++;}, read: async () => 4, write: async (_,buf) => buf.byteLength,
  listFileSync: () => [], unlinkSync() {} };
const {SessionRecording: Recording} = load('SessionRecording', {
  './OperationDiagnostic': {OperationDiagnostic:Trace}, '@kit.AbilityKit': {},
  '@kit.CoreFileKit': {fileIo, picker:{DocumentViewPicker:class {async save(){return cancel?[]:['target'];}}}}
});
(async()=>{
  const context = {filesDir:'/private/folder'};
  assert.equal(Recording.begin(context),true); Recording.stop(2); assert.match(logs.at(-1).text,/native_status=-2/);
  cancel=true; assert.equal(await Recording.exportFile(context,'remote-session-123.webm'),false); assert.match(logs.at(-1).text,/step=cancelled/);
  cancel=false; assert.equal(await Recording.exportFile(context,'remote-session-123.webm'),true); assert.equal(closes,2); assert.match(logs.at(-1).text,/step=completed/);
  ioError=true; await assert.rejects(Recording.exportFile(context,'remote-session-123.webm')); assert.match(logs.at(-1).text,/code=13900012/);
  ioError=false; mismatch=true; await assert.rejects(Recording.exportFile(context,'remote-session-123.webm')); assert.match(logs.at(-1).text,/reason=verification/); assert.equal(closes,4);
  assert.match(logs.at(-1).text,/step=failed after=verify/,'cleanup must not hide the original failing phase');
  assert(!JSON.stringify(logs).includes('/private/')); assert(!JSON.stringify(logs).includes('private-path'));
  console.log('PASS operation diagnostics: disabled gate, correlation, elapsed time, redaction, terminal deduplication, logger isolation and recording success/cancel/I-O/verification failures');
})().catch(e=>{console.error(e);process.exitCode=1;});
