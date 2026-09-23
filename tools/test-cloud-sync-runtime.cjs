// Execute the production cloud state machine with simulated SDK/files/timers.
// No cloud account, network request, user data or real filesystem writes.
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const vm = require('node:vm')
const crypto = require('node:crypto')
const ts = require('C:/Program Files/Huawei/DevEco Studio/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript')
const root = path.resolve(__dirname, '..')
const source = name => fs.readFileSync(path.join(root, 'entry/src/main/ets', name), 'utf8')
const flush = async () => { for (let i = 0; i < 40; i++) await Promise.resolve() }
function environment(config = {}) {
  const clock = { now: 2000000000000, next: 0, tasks: new Map() }
  const schedule = (fn, delay, interval = 0) => {
    const id = ++clock.next
    clock.tasks.set(id, { fn, at: clock.now + delay, interval })
    return id
  }
  const logs = [], drivers = [], files = new Map(), directories = new Set(['/cloud', '/local']), handles = new Map()
  const options = new Map(Object.entries({ 'cloud-sync-enabled': '1', 'diagnostic-log-enabled': '1', ...config.options }))
  let fd = 0, uuid = 0, lastSync = clock.now - 10000, cloudWrites = 0, starts = 0
  const operations = []
  const states = { UPLOADING: 0, UPLOAD_FAILED: 1, DOWNLOADING: 2, DOWNLOAD_FAILED: 3, COMPLETED: 4, STOPPED: 5 }
  class FileSync {
    constructor() { this.offCount = 0; drivers.push(this) }
    async getLastSyncTime() {
      if (config.timeError) throw { code: 13600001 }
      if (config.timeHang) return new Promise(() => {})
      return lastSync
    }
    on(_, callback) {
      this.callback = callback
      if (config.listenError) throw { code: 201 }
      if (config.asyncSnapshot) schedule(() => this.emit(config.snapshot ?? 4), 1)
      else this.emit(config.snapshot ?? 4)
    }
    off(_, callback) { assert.equal(callback, this.callback); this.offCount++; this.callback = undefined }
    emit(state, error = 0) { this.callback?.({ state, error }) }
    async start() {
      starts++
      if (config.startError) throw { code: config.startError, message: 'SECRET_RAW_MESSAGE' }
      if (config.startHang) return new Promise(() => {})
      if (!config.manual) {
        schedule(() => this.emit(0), 10)
        schedule(() => { lastSync = clock.now; this.emit(4) }, 20)
      }
    }
  }
  const fail = (operation, p = '') => {
    operations.push({ operation, path: p })
    if (config.cloudError === operation && p.startsWith('/cloud/')) {
      if (config.failOnce) config.cloudError = undefined
      throw { code: config.cloudErrorCode ?? 13900020, message: 'SECRET_PATH' }
    }
    if (config.fileError === operation) throw { code: 13900012, message: 'SECRET_PATH' }
  }
  const fileIo = {
    OpenMode: { READ_ONLY: 0, CREATE: 1, WRITE_ONLY: 2, TRUNC: 4 },
    accessSync(p) { return files.has(p) || directories.has(p) },
    listFileSync(p) { fail('list', p); return [...files.keys()].filter(k => k.startsWith(p + '/')).map(k => k.slice(p.length + 1)) },
    mkdirSync(p) { fail('mkdir'); directories.add(p) },
    openSync(p, mode) {
      fail('open', p)
      if (mode && (!files.has(p) || (mode & 4))) files.set(p, Buffer.alloc(0))
      if (!files.has(p)) throw { code: 13900002 }
      const f = { fd: ++fd }; handles.set(fd, p); return f
    },
    statSync(fd) { fail('stat', handles.get(fd)); return { size: files.get(handles.get(fd)).length } },
    readSync(fd, buffer) {
      fail('read', handles.get(fd))
      const bytes = files.get(handles.get(fd)); new Uint8Array(buffer).set(bytes)
      if (config.corruptRead && handles.get(fd).endsWith('.pending')) new Uint8Array(buffer)[5] ^= 1
      return config.shortRead ? bytes.length - 1 : bytes.length
    },
    writeSync(fd, data) { fail('write', handles.get(fd)); const bytes = Buffer.from(data); files.set(handles.get(fd), bytes); return config.shortWrite ? bytes.length - 1 : bytes.length },
    fsyncSync(fd) { fail('fsync', handles.get(fd)) },
    closeSync(file) { const id = typeof file === 'number' ? file : file.fd; fail('close', handles.get(id)); handles.delete(id) },
    renameSync(from, to) {
      fail('rename', to)
      // CloudDisk differs from local files: rename over an existing name is EINVAL.
      if (to.startsWith('/cloud/') && files.has(to)) throw { code: 13900020 }
      files.set(to, files.get(from)); files.delete(from); if (to.startsWith('/cloud/')) cloudWrites++
    },
    unlinkSync(p) { fail('unlink', p); files.delete(p) }
  }
  const sandbox = vm.createContext({ exports: {}, console, Promise, Error, Number, String, JSON, ArrayBuffer, Uint8Array,
    Date: class extends Date { constructor(v) { super(v === undefined ? clock.now : v) } static now() { return clock.now } },
    setTimeout: (fn, delay) => schedule(fn, delay), clearTimeout: id => clock.tasks.delete(id),
    setInterval: (fn, delay) => schedule(fn, delay, delay), clearInterval: id => clock.tasks.delete(id),
    cloudSync: { FileSync, SyncState: states }, fileIo,
    cryptoFramework: { createMd: () => {
      const hash = crypto.createHash('sha256')
      return { update: async ({ data }) => { hash.update(data) }, digest: async () => ({ data: new Uint8Array(hash.digest()) }) }
    } },
    util: { generateRandomUUID: () => config.uuids?.length ? config.uuids.shift() : `00000000-0000-4000-8000-${String(++uuid).padStart(12, '0')}`,
      TextEncoder: class { encodeInto(text) { return new TextEncoder().encode(text) } },
      TextDecoder: { create: () => ({ decodeToString: data => new TextDecoder().decode(data) }) } },
    OperationDiagnostic: { errorCode: e => Number.isFinite(Number(e?.code)) ? Number(e.code) : 0 },
    RustDeskNapi: { getOption: key => options.get(key) ?? '', setOption: (key, value) => options.set(key, value),
      appendDiagnosticLog: (_, value) => { if (config.logError) throw new Error('logger'); logs.push(value) } },
    CredentialStore: { load: async () => { if (config.credentialError) throw { code: 201 }; return config.password ?? 'TEST_PASSWORD' }, save: async () => {}, remove: async () => {} },
    ConnectionBackupService: {
      createPayload: (groups, connections, includesPasswords, serverConfig) => ({ groups, connections, includesPasswords, serverConfig, exportedAt: new Date(clock.now).toISOString() }),
      createPlainText: JSON.stringify, parsePlainText: JSON.parse, isEncrypted: () => config.encrypted === true,
      encrypt: async payload => JSON.stringify(payload), decrypt: async raw => JSON.parse(raw)
    },
    AppStorage: { get: () => 0, set: () => {} }
  })
  function load(code, label) {
    code = code.replace(/^import[\s\S]*?from\s+['"][^'"]+['"]\s*;?\r?\n/gm, '')
    sandbox.exports = {}
    vm.runInContext(ts.transpileModule(code, { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2021 } }).outputText, sandbox, { filename: label })
    Object.assign(sandbox, sandbox.exports)
    return sandbox.exports
  }
  load(source('service/CloudSyncTask.ets'), 'CloudSyncTask.ets')
  load(source('service/CloudSyncSnapshotStore.ets'), 'CloudSyncSnapshotStore.ets')
  load(source('service/CloudSyncService.ets'), 'CloudSyncService.ets')
  const context = { cloudFileDir: config.noCloudDir ? '' : '/cloud', filesDir: '/local' }
  const cloudPath = '/cloud/StarRustDesk/cloud-sync-v1.srdsync'
  async function tick(ms) {
    await flush()
    const end = clock.now + ms
    while (true) {
      const next = [...clock.tasks].filter(([, t]) => t.at <= end).sort((a, b) => a[1].at - b[1].at)[0]
      if (!next) break
      const [id, t] = next
      clock.now = t.at
      if (t.interval) t.at += t.interval
      else clock.tasks.delete(id)
      t.fn(); await flush()
    }
    clock.now = end; await flush()
  }
  function wait() { return sandbox.CloudSyncTask.wait(new sandbox.CloudSyncTrace('sync'), () => config.cancelled === true) }
  const cloudSnapshots = () => [...files.keys()].filter(p => /\/cloud-sync-v2-.*\.srdsync$/.test(p)).sort()
  const latestContent = () => JSON.parse(JSON.parse(files.get(cloudSnapshots().at(-1))).content)
  return { config, clock, logs, drivers, files, options, context, cloudPath, tick, wait, load, sandbox, handles, operations, cloudSnapshots, latestContent,
    service: sandbox.CloudSyncService, setLastSync: v => { lastSync = v }, stats: () => ({ cloudWrites, starts }) }
}

let passed = 0
async function test(name, fn) { await fn(); console.log(`PASS ${name}`); passed++ }
;(async () => {
  await test('start acknowledgement and registration snapshot never report success', async () => {
    for (const asyncSnapshot of [false, true]) {
      const e = environment({ manual: true, asyncSnapshot })
      let settled = false
      const p = e.wait().then(() => { settled = true })
      await e.tick(100)
      e.drivers[0].emit(4)
      await e.tick(1000)
      assert.equal(settled, false)
      e.drivers[0].emit(0); e.drivers[0].emit(4)
      await p
      assert.equal(e.drivers[0].offCount, 1)
      assert.equal(e.clock.tasks.size, 0)
    }
  })
  await test('initial previous-task failure is ignored; fresh failure is actionable', async () => {
    const e = environment({ manual: true, snapshot: 1 })
    const p = e.wait().catch(x => x)
    await e.tick(100)
    e.drivers[0].emit(1, 5)
    assert.equal((await p).code, 22410005)
  })
  await test('fresh last-sync timestamp confirms no-op sync, old timestamp does not', async () => {
    const e = environment({ manual: true })
    let done = false
    const p = e.wait().then(() => { done = true })
    await e.tick(1000); assert.equal(done, false)
    e.setLastSync(e.clock.now)
    await e.tick(1000); await p
  })
  await test('all SDK start errors remain distinct and never expose raw message', async () => {
    const messages = new Set()
    for (const code of [22400001, 22400002, 22400003, 13600001, 13900012, 801, 999999]) {
      const e = environment({ startError: code })
      const result = await e.service.syncNow(e.context)
      assert.equal(result.success, false); assert.equal(result.code, code)
      assert.equal(result.stage, 'preflight')
      assert.ok(!result.message.includes('SECRET'))
      assert.ok(e.logs.some(l => l.includes(`code=${code}`) && l.includes('operation_stage=preflight')))
      assert.ok(e.logs.every(l => !l.includes('SECRET')))
      messages.add(result.message)
    }
    assert.equal(messages.size, 7)
  })
  await test('progress failures distinguish network/Wi-Fi/battery/cloud/local/heat/service', async () => {
    for (let code = 0; code <= 8; code++) {
      const e = environment({ manual: true })
      const p = e.wait().catch(x => x)
      await flush(); e.drivers[0].emit(1, code)
      assert.equal((await p).code, 22410000 + code)
    }
  })
  await test('timeout is pending, preserves success timestamp, removes listeners, ignores late events', async () => {
    const e = environment({ manual: true, options: { 'cloud-sync-last-success-at': '1234' } })
    const p = e.service.syncNow(e.context)
    await e.tick(35000)
    const result = await p
    assert.equal(result.pending, true); assert.equal(result.code, -1001)
    assert.equal(e.options.get('cloud-sync-last-success-at'), '1234')
    assert.equal(e.clock.tasks.size, 0)
    assert.equal(e.drivers[0].offCount, 1)
    e.drivers[0].emit(4); await flush()
    assert.equal(e.service.getLastResult(), result)
  })
  await test('hung baseline/start are bounded; listener registration and logger errors are safe', async () => {
    for (const config of [{ timeHang: true }, { startHang: true }]) {
      const e = environment(config), p = e.wait().catch(x => x)
      await e.tick(35000)
      assert.equal((await p).code, -1001)
      assert.equal(e.clock.tasks.size, 0)
    }
    const e = environment({ listenError: true, logError: true })
    const p = e.wait().catch(x => x)
    assert.equal((await p).code, 201)
    assert.equal(e.drivers[0].offCount, 1)
  })
  await test('sync/background upload coalesce; explicit restore reports busy, not false success', async () => {
    const e = environment(), a = e.service.syncNow(e.context), b = e.service.upload(e.context)
    assert.equal(a, b)
    const busy = await e.service.restore(e.context)
    assert.equal(busy.success, false); assert.equal(busy.pending, true)
    await e.tick(100)
    assert.equal((await a).uploaded, true)
    assert.equal(e.stats().cloudWrites, 1)
    assert.equal(e.stats().starts, 2)
  })
  await test('upload only succeeds after second system completion, not after writing mirror', async () => {
    const e = environment({ manual: true })
    let result
    const p = e.service.upload(e.context).then(r => { result = r })
    await flush(); e.drivers[0].emit(0); e.drivers[0].emit(4); await flush()
    assert.equal(e.stats().cloudWrites, 1)
    assert.equal(e.options.has('cloud-sync-last-success-at'), false)
    assert.equal(result, undefined)
    e.drivers[1].emit(0); e.drivers[1].emit(4)
    await p; assert.equal(result.success, true)
  })
  await test('disable invalidates old completion and never stamps success or restores data', async () => {
    const e = environment({ manual: true }), p = e.service.syncNow(e.context)
    await flush(); e.service.setEnabled(false)
    e.drivers[0].emit(0); e.drivers[0].emit(4)
    const result = await p
    assert.equal(result.code, -1002)
    assert.equal(e.stats().cloudWrites, 0)
    assert.equal(e.options.has('cloud-sync-last-success-at'), false)
    assert.equal(e.service.getLastResult(), undefined)
  })
  await test('failed upload acknowledgement after successful preflight keeps prior success time', async () => {
    const e = environment({ manual: true, options: { 'cloud-sync-last-success-at': '1234' } })
    const p = e.service.upload(e.context)
    await flush()
    e.drivers[0].emit(0); e.drivers[0].emit(4)
    e.config.startError = 22400002
    const result = await p
    assert.equal(result.success, false); assert.equal(result.stage, 'upload_wait')
    assert.equal(result.code, 22400002)
    assert.equal(e.options.get('cloud-sync-last-success-at'), '1234')
    assert.equal(e.options.has('cloud-sync-last-applied-at'), false)
  })
  await test('password prompt resumes the right operation instead of restoring an absent backup', async () => {
    const e = environment({ password: '', options: { 'cloud-sync-include-secrets': '1' } })
    const upload = e.service.upload(e.context)
    await e.tick(100)
    const a = await upload
    assert.equal(a.needsPassword, true); assert.equal(a.passwordAction, 'sync')
    const f = environment({ password: '', encrypted: true })
    f.files.set(f.cloudPath, Buffer.from(JSON.stringify({ exportedAt: new Date(f.clock.now).toISOString() })))
    const restore = f.service.restore(f.context)
    await f.tick(100)
    const b = await restore
    assert.equal(b.needsPassword, true); assert.equal(b.passwordAction, 'restore')
  })
  await test('edits during preflight prevent stale writes; edits during upload remain dirty', async () => {
    const e = environment({ manual: true }), p = e.service.syncNow(e.context)
    await flush(); e.service.markLocalChanged(); e.drivers[0].emit(0); e.drivers[0].emit(4)
    assert.equal((await p).code, -1004); assert.equal(e.stats().cloudWrites, 0)
    const f = environment({ manual: true }), q = f.service.upload(f.context)
    await flush(); f.drivers[0].emit(0); f.drivers[0].emit(4); await flush()
    await f.tick(100); f.service.markLocalChanged()
    const dirty = f.options.get('cloud-sync-local-changed-at')
    f.drivers[1].emit(0); f.drivers[1].emit(4)
    assert.equal((await q).pending, true)
    assert.equal(f.options.get('cloud-sync-local-changed-at'), dirty)
  })
  await test('specific directory/credential/file errors identify exact operation stage', async () => {
    const cases = [ [{ noCloudDir: true }, 'cloud_directory', 22400001], [{ fileError: 'mkdir' }, 'cloud_directory', 13900012],
      [{ credentialError: true, options: { 'cloud-sync-include-secrets': '1' } }, 'credential', 201],
      [{ fileError: 'write' }, 'mirror_write', 13900012] ]
    for (const [config, stage, code] of cases) {
      const e = environment(config), p = e.service.syncNow(e.context)
      await e.tick(100)
      const result = await p
      assert.equal(result.stage, stage); assert.equal(result.code, code)
      assert.ok(!result.message.includes('SECRET'))
      assert.equal(e.stats().cloudWrites, 0)
    }
  })
  await test('cloud restore never misrepresents a local mirror as a cloud backup', async () => {
    const e = environment()
    e.files.set('/local/cloud_backup/cloud-sync-v1.srdsync', Buffer.from('{}'))
    const p = e.service.restore(e.context); await e.tick(100)
    const r = await p
    assert.equal(r.restored, false); assert.equal(r.success, false)
    assert.equal(e.options.has('saved-connections'), false)
  })
  await test('failed atomic write preserves previous data and cleans temporary file', async () => {
    for (const config of [{ shortWrite: true }, { fileError: 'rename' }]) {
      const e = environment(config)
      const original = Buffer.from('ORIGINAL_BACKUP')
      e.files.set(e.cloudPath, original)
      assert.throws(() => e.service.writeText(e.cloudPath, 'NEW_BACKUP'))
      assert.deepEqual(e.files.get(e.cloudPath), original)
      assert.equal(e.files.has(e.cloudPath + '.pending'), false)
    }
  })
  await test('enabling sync does not dirty the backup; removing all connections does not resurrect old cloud rows', async () => {
    const e = environment({ options: { 'cloud-sync-local-changed-at': '2000000000000' } })
    e.service.setEnabled(true)
    assert.equal(e.options.get('cloud-sync-local-changed-at'), '2000000000000')
    e.files.set(e.cloudPath, Buffer.from(JSON.stringify({ exportedAt: new Date(1999999999000).toISOString(), groups: [], connections: [{ id: 'old' }] })))
    const p = e.service.syncNow(e.context); await e.tick(100)
    assert.equal((await p).uploaded, true)
    assert.equal(e.latestContent().connections.length, 0)
  })
  await test('diagnostics default-off and logger failure never changes successful sync', async () => {
    for (const config of [{ options: { 'diagnostic-log-enabled': '0' } }, { logError: true }]) {
      const e = environment(config), p = e.service.syncNow(e.context)
      await e.tick(100)
      assert.equal((await p).success, true); assert.equal(e.logs.length, 0)
    }
  })
  await test('CloudDisk overwrite incompatibility reproduced; repeated new snapshots succeed and retain v1', async () => {
    const e = environment({ options: { 'cloud-sync-local-changed-at': '2000000000000' } })
    const original = Buffer.from(JSON.stringify({ exportedAt: new Date(e.clock.now - 1000).toISOString(), groups: [], connections: [] }))
    e.files.set(e.cloudPath, original)
    assert.throws(() => e.service.writeText(e.cloudPath, 'NEW_BACKUP'), error => error.code === 13900020)
    assert.deepEqual(e.files.get(e.cloudPath), original)
    for (let i = 0; i < 2; i++) {
      e.service.markLocalChanged()
      const p = e.service.syncNow(e.context); await e.tick(100)
      assert.equal((await p).success, true)
    }
    assert.equal(e.cloudSnapshots().length, 2)
    assert.deepEqual(e.files.get(e.cloudPath), original)
    assert.equal([...e.files.keys()].some(p => p.endsWith('.pending')), false)
    assert.equal(e.handles.size, 0)
  })
  await test('cloud writer avoids fsync while local mirror still requires it', async () => {
    const e = environment({ cloudError: 'fsync' })
    const p = e.service.syncNow(e.context); await e.tick(100)
    assert.equal((await p).success, true)
    assert.ok(e.operations.some(o => o.operation === 'fsync' && o.path.startsWith('/local/')))
    assert.ok(!e.operations.some(o => o.operation === 'fsync' && o.path.startsWith('/cloud/')))
    const f = environment({ fileError: 'fsync' }), q = f.service.syncNow(f.context)
    await f.tick(100)
    assert.equal((await q).stage, 'mirror_write')
    assert.equal(f.cloudSnapshots().length, 0)
  })
  await test('restores newest complete snapshot on another simulated device, retains legacy support', async () => {
    const writer = environment()
    for (let i = 0; i < 2; i++) {
      writer.options.set('saved-connections', JSON.stringify([{ id: `device${i}`, remoteId: `12345678${i}`, name: '测试', performancePreset: 'balanced', groupId: '' }]))
      writer.service.markLocalChanged()
      const p = writer.service.syncNow(writer.context); await writer.tick(100)
      assert.equal((await p).uploaded, true)
    }
    const reader = environment()
    for (const name of writer.cloudSnapshots()) reader.files.set(name, writer.files.get(name))
    reader.files.set(reader.cloudPath, Buffer.from(JSON.stringify({ exportedAt: new Date(writer.clock.now - 1000).toISOString(), groups: [], connections: [] })))
    reader.files.set('/cloud/StarRustDesk/cloud-sync-v2-9999999999999-00000000-0000-4000-8000-000000000000.srdsync.pending', Buffer.from('PARTIAL'))
    const p = reader.service.restore(reader.context); await reader.tick(100)
    assert.equal((await p).restored, true)
    assert.equal(JSON.parse(reader.options.get('saved-connections'))[0].id, 'device1')
    // A newer valid legacy snapshot is still read, never overwritten in place.
    reader.files.set(reader.cloudPath, Buffer.from(JSON.stringify({ exportedAt: new Date(writer.clock.now + 1000).toISOString(), groups: [], connections: [] })))
    const q = reader.service.restore(reader.context); await reader.tick(100)
    assert.equal((await q).restored, true)
    assert.equal(JSON.parse(reader.options.get('saved-connections')).length, 0)
  })
  await test('damaged newest snapshot blocks restoration instead of resurrecting older data', async () => {
    for (const damage of ['partial', 'checksum', 'time', 'null']) {
      const e = environment(), p = e.service.syncNow(e.context); await e.tick(100); await p
      const name = e.cloudSnapshots()[0], good = e.files.get(name)
      const envelope = JSON.parse(good)
      if (damage === 'checksum') envelope.sha256 = '0'.repeat(64)
      if (damage === 'time') envelope.contentTime++
      e.files.set(name, Buffer.from(damage === 'partial' ? '{' : damage === 'null' ? 'null' : JSON.stringify(envelope)))
      e.files.set(e.cloudPath, Buffer.from(JSON.stringify({ exportedAt: new Date(e.clock.now - 1000).toISOString(), groups: [], connections: [{ id: 'old' }] })))
      e.options.set('saved-connections', 'LOCAL_UNCHANGED')
      const q = e.service.restore(e.context); await e.tick(100)
      const result = await q
      assert.equal(result.success, false); assert.equal(result.code, -1005)
      assert.equal(result.stage, 'cloud_validate')
      assert.equal(e.options.get('saved-connections'), 'LOCAL_UNCHANGED')
      assert.equal(e.cloudSnapshots().length, 1)
    }
  })
  await test('file operation failures retain exact stage/code and do not delete previous snapshots', async () => {
    for (const [operation, stage] of [['open', 'cloud_open'], ['write', 'cloud_write_bytes'], ['close', 'cloud_close'],
      ['stat', 'cloud_verify_stat'], ['read', 'cloud_verify_bytes'], ['rename', 'cloud_publish']]) {
      const e = environment({ cloudError: operation, failOnce: true })
      const trace = new e.sandbox.CloudSyncTrace('upload')
      const original = Buffer.from('OLD_BACKUP')
      e.files.set(e.cloudPath, original)
      const failure = await e.sandbox.CloudSyncSnapshotStore.publish('/cloud/StarRustDesk', 'SEALED_CONTENT', e.clock.now, trace, () => {}).catch(x => x)
      assert.equal(failure.code, 13900020, operation)
      assert.equal(trace.stage, stage, operation)
      assert.deepEqual(e.files.get(e.cloudPath), original)
      assert.equal(e.cloudSnapshots().length, 0)
      assert.equal([...e.files.keys()].some(p => p.endsWith('.pending')), false)
      assert.equal(e.handles.size, 0)
      assert.ok(e.logs.every(l => !l.includes('SEALED_CONTENT') && !l.includes('/cloud/') && !l.includes('SECRET')))
    }
  })
  await test('short write, short read and mismatched readback never publish', async () => {
    for (const config of [{ shortWrite: true }, { shortRead: true }, { corruptRead: true }]) {
      const e = environment(config), trace = new e.sandbox.CloudSyncTrace('upload')
      const failure = await e.sandbox.CloudSyncSnapshotStore.publish('/cloud/StarRustDesk', 'DATA', e.clock.now, trace, () => {}).catch(x => x)
      assert.equal(failure.code, 13900005)
      assert.equal(e.cloudSnapshots().length, 0)
      assert.equal([...e.files.keys()].some(p => p.endsWith('.pending')), false)
    }
  })
  await test('unique naming handles retries, simultaneous writers and publish-time collision without overwrite', async () => {
    const e = environment(), store = e.sandbox.CloudSyncSnapshotStore
    const trace = () => new e.sandbox.CloudSyncTrace('upload')
    await Promise.all([store.publish('/cloud/StarRustDesk', 'A', e.clock.now, trace(), () => {}),
      store.publish('/cloud/StarRustDesk', 'B', e.clock.now, trace(), () => {})])
    assert.equal(e.cloudSnapshots().length, 2)
    const original = e.files.get(e.cloudSnapshots()[0])
    e.config.uuids = ['00000000-0000-4000-8000-000000000001']
    await store.publish('/cloud/StarRustDesk', 'C', e.clock.now, trace(), () => {})
    assert.equal(e.cloudSnapshots().length, 3)
    assert.deepEqual(e.files.get(e.cloudSnapshots()[0]), original)
    const collision = `/cloud/StarRustDesk/cloud-sync-v2-${e.clock.now}-00000000-0000-4000-8000-000000000009.srdsync`
    e.config.uuids = ['00000000-0000-4000-8000-000000000009']
    let checks = 0
    const error = await store.publish('/cloud/StarRustDesk', 'D', e.clock.now, trace(), () => {
      if (++checks === 2) e.files.set(collision, Buffer.from('OTHER_WRITER'))
    }).catch(x => x)
    assert.equal(error.code, 13900015)
    assert.equal(e.files.get(collision).toString(), 'OTHER_WRITER')
    assert.equal([...e.files.keys()].some(p => p.endsWith('.pending')), false)
  })
  await test('cleanup errors cannot replace the primary error or failure stage', async () => {
    const e = environment({ cloudError: 'rename', fileError: 'unlink' }), trace = new e.sandbox.CloudSyncTrace('upload')
    const failure = await e.sandbox.CloudSyncSnapshotStore.publish('/cloud/StarRustDesk', 'DATA', e.clock.now, trace, () => {}).catch(x => x)
    assert.equal(failure.code, 13900020)
    assert.equal(trace.stage, 'cloud_publish')
    assert.ok(e.logs.some(l => l.includes('stage=cleanup_pending') && l.includes('code=13900012')))
    assert.equal(e.cloudSnapshots().length, 0)
    const raw = await e.sandbox.CloudSyncSnapshotStore.readLatest('/cloud/StarRustDesk', e.cloudPath, trace, () => 0)
    assert.equal(raw, undefined)
  })
  await test('settings preserve failed status, reset busy in finally, and ignore disabled completion', async () => {
    const e = environment()
    const settings = source('pages/SettingsPage.ets')
    const method = settings.slice(settings.indexOf('  async syncCloudNow('), settings.indexOf('  confirmCloudRestore('))
    const update = settings.slice(settings.indexOf('  updateCloudSyncStatus():'), settings.indexOf('  @Builder\n  buildDiagnosticsCard()') > 0 ? settings.indexOf('  @Builder\n  buildDiagnosticsCard()') : settings.indexOf('  @Builder\r\n  buildDiagnosticsCard()'))
    const { UI } = e.load(`export class UI { ${method}\n${update}\n}`, 'CloudSettingsMethods')
    e.sandbox.getContext = () => e.context
    e.sandbox.promptAction = { showToast() {} }
    const ui = new UI()
    ui.cloudSyncEnabled = true; ui.cloudSyncBusy = false
    let result = { success: false, message: 'network failure', code: 22400002 }
    e.service.syncNow = async () => result
    await ui.syncCloudNow(false, false)
    assert.equal(ui.cloudSyncStatus, 'network failure'); assert.equal(ui.cloudSyncBusy, false)
    e.service.syncNow = async () => { throw new Error('SECRET') }
    await ui.syncCloudNow(false, false)
    assert.equal(ui.cloudSyncBusy, false); assert.ok(!ui.cloudSyncStatus.includes('SECRET'))
    e.service.syncNow = async () => { ui.cloudSyncEnabled = false; return { success: true } }
    await ui.syncCloudNow(false, false)
    assert.equal(ui.cloudSyncStatus, '未开启'); assert.equal(ui.cloudSyncBusy, false)
  })
  console.log(`cloud-sync runtime: ${passed} scenario groups passed`)
})().catch(error => { console.error(error); process.exitCode = 1 })
