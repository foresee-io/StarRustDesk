const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/tools/ohpm/node_modules/typescript');
const root = path.resolve(__dirname, '..');
let now = 1000000, watcher, api = 24, failRegister = false, failRead = false, closed = 0;
const disk = new Map(), options = new Map(), logs = [];
const io = {
  OpenMode: { READ_ONLY: 1, CREATE: 2, WRITE_ONLY: 4, TRUNC: 8 },
  open: async (p, mode) => { if (mode === 1 && (!disk.has(p) || failRead)) throw Error('private/path'); if(mode!==1)disk.set(p,'');return { fd: p }; },
  read: async (fd, buffer) => { const bytes = Buffer.from(disk.get(fd)); const n = Math.min(bytes.length, buffer.byteLength); new Uint8Array(buffer).set(bytes.subarray(0,n)); return n; },
  write: async (fd, text) => { const b=Buffer.from(text);disk.set(fd,(disk.get(fd)||'')+b.toString()); return b.length; },
  close: async () => {closed++;},
  rename: async (a,b) => {disk.set(b,disk.get(a));disk.delete(a);},
  unlink: async p => disk.delete(p), lstat: async () => ({isFile:()=>true})
};
const hi = { domain:{OS:'OS'}, event:{APP_CRASH:'APP_CRASH',APP_FREEZE:'APP_FREEZE',APP_KILLED:'APP_KILLED'},
  addWatcher:w=>{if(failRegister)throw Error('private');watcher=w;}, removeWatcher:()=>{watcher=undefined;}
};
const context = {exports:{}, Date:{now:()=>now}, require:p=>({
  '@kit.PerformanceAnalysisKit':{hiAppEvent:hi},
  '@kit.BasicServicesKit':{deviceInfo:{get sdkApiVersion(){return api;}}},
  '@kit.ArkTS':{util:{TextEncoder:class {encodeInto(s){return new Uint8Array(Buffer.from(s));}},TextDecoder:{create:()=>({decodeToString:bytes=>Buffer.from(bytes).toString()})}}},
  '@kit.CoreFileKit':{fileIo:io},
  './RustDeskNapi':{RustDeskNapi:{getOption:k=>options.get(k)||'',setOption:(k,v)=>options.set(k,v),appendDiagnosticLog:(s,t)=>logs.push(t)}}
}[p])};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(path.join(root,'entry/src/main/ets/service/SystemFaultDiagnostic.ets'),'utf8'),
  {compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText,context);
const S = context.exports.SystemFaultDiagnostic;
function emit(name, params) { watcher.onReceive('OS',[{appEventInfos:[{name,params}]}]); }
const external = '/data/storage/el2/log/hiappevent/crash.txt';
const raw = 'Reason: SIGSEGV\npassword=private-password\nuser /private/alice\n#00 pc 00abcdef /data/storage/lib/arm64/libentry.so (secret message) (aabbccddaabbccdd)\n at queryPeer (entry|entry|1.0|src/query.ets:12:3)\nMemory: secret-token\n';
(async()=>{
  S.initialize('/files',false); await S.exportText(); assert(!watcher); assert.equal(disk.size,0);
  S.setEnabled(true); await S.exportText(); assert(watcher); assert(watcher.appEventFilters[0].names.includes('APP_KILLED'));
  disk.set(external,raw); now+=10;
  const params={time:now,pid:3,bundle_version:'1.2.0',crash_type:'NativeCrash',external_log:[external],
    exception:{name:'TypeError',message:'private-password'},hilog:['secret-token']};
  emit('APP_CRASH',params); let out=await S.exportText();
  assert(out.includes('pc 00abcdef libentry.so')); assert(out.includes('query.ets:12:3'));
  for(const s of ['private-password','secret-token','/private','secret message',external]) assert(!out.includes(s));
  const count=(out.match(/event=APP_CRASH/g)||[]).length;
  emit('APP_CRASH',params); assert.equal(( (await S.exportText()).match(/event=APP_CRASH/g)||[]).length,count);
  S.stop(); S.initialize('/files',true); out=await S.exportText(); assert(out.includes('pc 00abcdef'));
  emit('APP_CRASH',{time:now-100000,pid:2,exception:{stack:' at old (old.ets:1:2)'}});
  assert(!(await S.exportText()).includes('old.ets'));
  now++; emit('APP_KILLED',{time:now,reason:'UserRequest'}); assert((await S.exportText()).includes('reason=UserRequest'));
  for(let i=0;i<8;i++) {now++;emit('APP_FREEZE',{time:now,external_log:['/private/secret.txt'],reason:'ThreadBlock6S'});}
  out=await S.exportText(); assert.equal((out.match(/event=/g)||[]).length,6); assert(out.includes('external_read_failures=1'));
  assert(!out.includes('secret.txt')); assert(out.includes('ThreadBlock6S'));
  S.clear(); assert(!(await S.exportText()).includes('event=APP_')); assert(!disk.has('/files/system-faults.json'));
  now++; failRead=true; emit('APP_CRASH',{time:now,external_log:[external]});
  out=await S.exportText(); assert(out.includes('external_read_failures=1')); failRead=false;
  // Already queued callbacks cannot resurrect records after disabling diagnostics.
  now++; emit('APP_CRASH',{time:now,external_log:[external]}); S.setEnabled(false);
  out=await S.exportText(); assert(!watcher); assert(!out.includes('event=APP_')); assert(!disk.has('/files/system-faults.json'));
  api=12; S.setEnabled(true); await S.exportText(); assert(!watcher.appEventFilters[0].names.includes('APP_KILLED'));
  failRegister=true; S.setEnabled(true); await S.exportText(); assert(logs.includes('watcher_unavailable'));
  failRegister=false; S.setEnabled(true); await S.exportText();
  now++;emit('APP_CRASH',{time:now,exception:{stack:' at fresh (fresh.ets:1:2)'}});await S.exportText();
  now+=8*24*60*60*1000; assert(!(await S.exportText()).includes('fresh.ets'));
  assert(!disk.has('/files/system-faults.json'), 'expired records must also be removed from disk'); assert(closed>0);
  const native=fs.readFileSync(path.join(root,'entry/src/main/rust/src/lib.rs'),'utf8');
  for(const phase of ['resolve_connect_start','resolve_connect_complete','send_start','send_complete_wait_response','response_decoded','validate_response','deadline_including_dns','candidate_result']) assert(native.includes(phase));
  console.log('PASS system faults: consent, API gates, restart persistence, duplicate/age/count limits, filtered native/JS frames, killed reason, unsafe paths, read failure, clear/disable races and query phase coverage');
})().catch(e=>{console.error(e);process.exitCode=1;});
