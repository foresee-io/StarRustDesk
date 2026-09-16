const fs = require('node:fs');
const vm = require('node:vm');
const path = require('node:path');
const assert = require('node:assert/strict');
const ts = require('C:/Program Files/Huawei/DevEco Studio/tools/ohpm/node_modules/typescript');
const root = path.resolve(__dirname, '..');
const read = p => fs.readFileSync(path.join(root, p), 'utf8');
const options = new Map();
let stored, sequence = 0, pending = [], calls = [], clearWait;
const vault = {
  load: async () => stored,
  save: async value => { stored = value; },
  clear: async () => { if (clearWait) await clearWait; stored = undefined; }
};
let transportContext = '';
const native = { getOption: key => options.get(key) || '', setOption: (key, value) => options.set(key, value), getDeviceName: () => 'test device',
  setApiAccountContext: json => { transportContext = json; return 0; } };
class Request {
  constructor(url, method, headers, content, _cookies, _range, configuration) {
    Object.assign(this, { url, method, headers, content, configuration });
  }
}
const rcp = {
  Request,
  createSession: () => ({
    cancel() {}, close() {},
    async fetch(request) {
      calls.push(request);
      assert.equal(request.configuration.transfer.autoRedirect, false);
      assert.equal(request.configuration.tracing.verbose, false);
      const next = pending.shift();
      assert(next, `unexpected ${request.url}`);
      if (next.path) assert(request.url.endsWith(next.path), request.url);
      if (next.check) next.check(request);
      const raw = next.raw !== undefined ? next.raw : JSON.stringify(next.body);
      const bytes = new TextEncoder().encode(raw);
      request.configuration.tracing.httpEventsHandler.onDataReceive(bytes.buffer);
      return { statusCode: next.status || 200 };
    }
  })
};
function load(file, extra = {}) {
  const js = ts.transpileModule(read(file), { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText;
  const context = {
    exports: {}, Uint8Array, ArrayBuffer, AppStorage: { get: () => 0, setOrCreate: () => {} },
    require: name => {
      if (name === '@kit.ArkTS') return { url: { URL }, util: { generateRandomUUID: () => `uuid-${++sequence}`, TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text); } }, TextDecoder: { create: () => ({ decodeToString: bytes => new TextDecoder().decode(bytes) }) } } };
      if (name === '@kit.RemoteCommunicationKit') return { rcp };
      if (name === './RustDeskNapi') return { RustDeskNapi: native };
      if (name === './ApiAccountStore') return { ApiAccountStore: vault };
      if (name === './CloudSyncService') return { CloudSyncService: { markLocalChanged: () => {} } };
      if (extra[name]) return extra[name];
      throw Error(name);
    }
  };
  vm.runInNewContext(js, context);
  return context.exports;
}
const exported = load('entry/src/main/ets/service/RustDeskApiService.ets');
const Api = exported.RustDeskApiService;
function respond(body, path, status) { pending.push({ body, path, status }); }
async function login(api, provider = 'official') {
  api.configure('https://example.test/api/', provider, false);
  respond({ type: 'access_token', access_token: 'private-token', user: { name: 'alice' } }, '/api/login');
  assert.equal(await api.login('alice', 'private-password', true), true);
}
(async () => {
  assert.equal(Api.normalizeServer('https://example.test/api/', false), 'https://example.test');
  for (const bad of ['http://example.test', 'https://user:pass@example.test', 'https://example.test?q=1', 'file:///tmp/x']) {
    assert.throws(() => Api.normalizeServer(bad, false));
  }
  assert.equal(Api.normalizeServer('http://192.168.1.2:21114/', true), 'http://192.168.1.2:21114');
  const api = new Api(); await login(api);
  assert.equal(stored.token, 'private-token');
  assert(!JSON.stringify([...options]).includes('private-token'));
  assert(!JSON.stringify(stored).includes('private-password'));
  respond({ guid: 'personal' }, '/api/ab/personal');
  respond({ total: 0, data: [{ guid: 'team', name: 'Team', rule: 1 }] }, '/api/ab/shared/profiles?current=1&pageSize=100');
  const books = await api.books(); assert.equal(books.length, 2);
  const rows = Array.from({ length: 100 }, (_, i) => ({ id: String(100000000 + i), alias: `PC ${i}` }));
  respond({ total: 101, data: rows }); respond({ total: 101, data: [{ id: '200000000', alias: '中文电脑', password: 'secret', hash: 'secret-hash' }] });
  const peers = await api.peers(books[1]); assert.equal(peers.length, 101);
  assert.equal(peers[100].name, '中文电脑'); assert(!JSON.stringify(peers).includes('secret'));
  assert(calls.at(-1).url.includes('current=2'));
  assert.equal(calls.at(-1).headers.Authorization, 'Bearer private-token');
  const third = new Api(); await login(third, 'thirdParty');
  respond({}, '/api/ab/personal', 404); respond({}, undefined, 404);
  const legacy = await third.books(); assert.equal(legacy[0].legacy, true);
  respond({ data: JSON.stringify({ peers: [{ id: '123456789', alias: '第三方', tags: ['home'] }] }) });
  assert.equal((await third.peers(legacy[0]))[0].name, '第三方');
  const auth = new Api(); auth.configure('https://two.test', 'official', false);
  respond({ type: 'tfa_check', secret: 'challenge-secret', user: { name: 'alice' } });
  assert.equal(await auth.login('alice', 'password', false), false);
  pending.push({ body: { type: 'access_token', access_token: 'otp-token' }, check: request => {
    const body = JSON.parse(request.content); assert.equal(body.tfaCode, '123456');
    assert.equal(body.type, 'email_code'); assert.equal(body.secret, 'challenge-secret'); assert.equal(body.password, undefined);
  } });
  assert.equal(await auth.verify('123456'), true);
  assert.equal(stored, undefined);
  respond({}, undefined, 302); await assert.rejects(auth.books(), /跳转/);
  respond({}, undefined, 401); await assert.rejects(api.books(), /过期/); assert.equal(api.isLoggedIn(), false);
  await login(api);
  pending.push({ raw: 'x'.repeat(2 * 1024 * 1024 + 1) }); await assert.rejects(api.books(), /安全/);
  respond({ total: 2, data: [{ id: '123' }] }); respond({ total: 2, data: [{ id: '123' }] });
  await assert.rejects(api.peers({ guid: 'broken', legacy: false }), /分页/);
  let release; clearWait = new Promise(resolve => { release = resolve; });
  const before = calls.length; const canceled = api.login('alice', 'password', false); api.cancel(); release();
  await assert.rejects(canceled, /取消/); clearWait = undefined; assert.equal(calls.length, before);
  const Import = load('entry/src/main/ets/service/ApiAddressBookImport.ets', { './RustDeskApiService': exported }).ApiAddressBookImport;
  options.set('saved-connections', JSON.stringify([{ id: 'old', remoteId: '123', name: 'keep', credentialAlias: 'old' }]));
  assert.equal(Import.importSelected({ name: 'Team' }, [{ id: '123', name: 'overwrite' }, { id: '456', name: 'new' }]), 1);
  const savedRows = JSON.parse(options.get('saved-connections')); assert.equal(savedRows[0].name, 'keep'); assert.equal(savedRows[0].credentialAlias, 'old');
  options.set('saved-connections', 'invalid');
  assert.throws(() => Import.importSelected({ name: 'Team' }, [{ id: '999' }]));
  assert.equal(options.get('saved-connections'), 'invalid');
  // Account transport is opt-in and only restored for the same API/network.
  const pro = new Api(); pro.configure('https://pro.test', 'official', false);
  await assert.rejects(pro.login('alice', 'password', false, true), /公钥/);
  options.set('custom-rendezvous-server', 'id.pro.test'); options.set('key', 'public-key');
  respond({ type: 'access_token', access_token: 'pro-token' });
  await pro.login('alice', 'password', true, true);
  assert.equal(JSON.parse(transportContext).token, 'pro-token');
  assert.equal(JSON.parse(transportContext).rendezvous, 'id.pro.test');
  assert.equal(stored.boundRendezvous, 'id.pro.test');
  const restored = new Api(); respond({ name: 'alice' });
  assert.equal(await restored.restore(), true);
  options.set('api-server', 'https://another.test');
  assert.equal(await new Api().restore(), false);
  options.set('api-server', 'https://pro.test');
  options.set('custom-rendezvous-server', 'other-id.test');
  const changedNetwork = new Api(); respond({ name: 'alice' });
  assert.equal(await changedNetwork.restore(), true);
  assert.equal(transportContext, ''); assert.match(changedNetwork.warning, /配置已改变/);
  respond({}); await pro.logout();
  assert.equal(transportContext, ''); assert.equal(stored, undefined);
  const storage = read('entry/src/main/ets/service/ApiAccountStore.ets');
  assert(storage.includes('asset.SyncType.NEVER'));
  assert(storage.includes("getOption('api-session-disabled') === '1'"));
  const assets = new Map(); let removalFails = false;
  const asset = {
    Tag: { ALIAS: 1, SECRET: 2, RETURN_TYPE: 3, ACCESSIBILITY: 4, SYNC_TYPE: 5 },
    ReturnType: { ALL: 1 }, Accessibility: { DEVICE_FIRST_UNLOCKED: 1 }, SyncType: { NEVER: 0 },
    add: async attrs => { assert(attrs.get(2).length <= 1024); assets.set(new TextDecoder().decode(attrs.get(1)), attrs); },
    query: async query => { const found = assets.get(new TextDecoder().decode(query.get(1))); return found ? [found] : []; },
    remove: async query => { if (removalFails) throw Error('storage locked'); assets.delete(new TextDecoder().decode(query.get(1))); }
  };
  const Store = load('entry/src/main/ets/service/ApiAccountStore.ets', { '@kit.AssetStoreKit': { asset } }).ApiAccountStore;
  const longSession = { server: 'https://pro.test', username: '中文账号', provider: 'official', token: 'long-token'.repeat(800), allowHttp: false };
  await Store.save(longSession); assert.equal((await Store.load()).token, longSession.token);
  assert(assets.size > 2);
  removalFails = true; await Store.clear(); assert.equal(await Store.load(), undefined);
  removalFails = false;
  const saving = Store.save(longSession); const clearing = Store.clear();
  await Promise.all([saving, clearing]); assert.equal(await Store.load(), undefined);
  assert.equal(pending.length, 0);
  console.log('PASS official/third-party API login, 2FA, legacy/shared/pagination, HTTPS, redirects, tokens, cancellation and safe import');
})().catch(error => { console.error(error); process.exitCode = 1; });
