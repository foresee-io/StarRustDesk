import { common } from '@kit.AbilityKit'
import { util } from '@kit.ArkTS'
import { fileIo } from '@kit.CoreFileKit'
import { CloudSyncFailure, CloudSyncTask, CloudSyncTrace } from './CloudSyncTask'
import { CloudSyncSnapshotStore } from './CloudSyncSnapshotStore'
import { CredentialStore } from './CredentialStore'
import {
  ConnectionBackupGroup,
  ConnectionBackupItem,
  ConnectionBackupPayload,
  ConnectionBackupServerConfig,
  ConnectionBackupService
} from './ConnectionBackupService'
import { RustDeskNapi } from './RustDeskNapi'

const CLOUD_SYNC_ENABLED_OPTION: string = 'cloud-sync-enabled'
const CLOUD_SYNC_SECRETS_OPTION: string = 'cloud-sync-include-secrets'
const CLOUD_SYNC_LOCAL_CHANGED_OPTION: string = 'cloud-sync-local-changed-at'
const CLOUD_SYNC_LAST_APPLIED_OPTION: string = 'cloud-sync-last-applied-at'
const CLOUD_SYNC_LAST_SUCCESS_OPTION: string = 'cloud-sync-last-success-at'
const CLOUD_SYNC_PASSWORD_ID: string = '__cloud_sync_master_password__'
const CLOUD_FOLDER_NAME: string = 'StarRustDesk'
const CLOUD_FILE_NAME: string = 'cloud-sync-v1.srdsync'
const BACKUP_MIRROR_FOLDER: string = 'cloud_backup'

interface SavedConnectionRow {
  id: string
  name: string
  remoteId: string
  credentialAlias: string
  performancePreset: string
  groupId: string
}

interface SavedConnectionGroupRow {
  id: string
  name: string
  expanded: boolean
}

export interface CloudSyncResult {
  success: boolean
  restored: boolean
  uploaded: boolean
  needsPassword: boolean
  message: string
  syncTime: number
  pending?: boolean
  code?: number
  stage?: string
  passwordAction?: 'sync' | 'restore'
}

export class CloudSyncService {
  private static inFlight: Promise<CloudSyncResult> | undefined = undefined
  private static inFlightAction: string = ''
  private static epoch: number = 0
  private static localRevision: number = 0
  private static lastResult: CloudSyncResult | undefined = undefined

  static isEnabled(): boolean {
    try {
      return RustDeskNapi.getOption(CLOUD_SYNC_ENABLED_OPTION) === '1'
    } catch (_error) {
      return false
    }
  }

  static setEnabled(enabled: boolean): void {
    CloudSyncService.epoch++
    CloudSyncService.lastResult = undefined
    try {
      RustDeskNapi.setOption(CLOUD_SYNC_ENABLED_OPTION, enabled ? '1' : '0')
    } catch (_error) {
    }
  }

  static includesSecrets(): boolean {
    try {
      return RustDeskNapi.getOption(CLOUD_SYNC_SECRETS_OPTION) === '1'
    } catch (_error) {
      return false
    }
  }

  static setIncludesSecrets(enabled: boolean): void {
    try {
      RustDeskNapi.setOption(CLOUD_SYNC_SECRETS_OPTION, enabled ? '1' : '0')
      CloudSyncService.markLocalChanged()
    } catch (_error) {
    }
  }

  static markLocalChanged(): void {
    CloudSyncService.localRevision++
    try {
      RustDeskNapi.setOption(CLOUD_SYNC_LOCAL_CHANGED_OPTION, Date.now().toString())
    } catch (_error) {
    }
  }

  static getLastSuccessTime(): number {
    return CloudSyncService.readTimestamp(CLOUD_SYNC_LAST_SUCCESS_OPTION)
  }

  static getLastResult(): CloudSyncResult | undefined { return CloudSyncService.lastResult }

  static async hasCloudPassword(): Promise<boolean> {
    return (await CredentialStore.load(CLOUD_SYNC_PASSWORD_ID)).length >= 8
  }

  static async saveCloudPassword(password: string): Promise<void> {
    if (password.length < 8) {
      throw new Error('备份密码至少需要 8 位')
    }
    await CredentialStore.save(CLOUD_SYNC_PASSWORD_ID, password)
    CloudSyncService.markLocalChanged()
  }

  static async clearCloudPassword(): Promise<void> {
    await CredentialStore.remove(CLOUD_SYNC_PASSWORD_ID)
  }

  static syncNow(context: common.UIAbilityContext): Promise<CloudSyncResult> {
    return CloudSyncService.run(context, 'sync')
  }

  static upload(context: common.UIAbilityContext): Promise<CloudSyncResult> {
    // Background uploads reconcile first too, so a stale local snapshot cannot
    // overwrite a newer backup from another device.
    return CloudSyncService.run(context, 'upload')
  }

  static restore(context: common.UIAbilityContext): Promise<CloudSyncResult> {
    return CloudSyncService.run(context, 'restore')
  }

  private static run(context: common.UIAbilityContext, action: 'sync' | 'upload' | 'restore'): Promise<CloudSyncResult> {
    const trace = new CloudSyncTrace(action)
    if (!CloudSyncService.isEnabled()) {
      return Promise.resolve(CloudSyncService.result(false, false, false, false, '云同步未开启', 0))
    }
    if (CloudSyncService.inFlight !== undefined) {
      if ((action === 'restore') !== (CloudSyncService.inFlightAction === 'restore')) {
        trace.event('busy')
        const busy = CloudSyncService.result(false, false, false, false, '其他云同步任务正在进行，请完成后再试', 0)
        busy.pending = true
        return Promise.resolve(busy)
      }
      trace.event('coalesced')
      return CloudSyncService.inFlight
    }
    const epoch = CloudSyncService.epoch
    const revision = CloudSyncService.localRevision
    CloudSyncService.inFlightAction = action
    const operation = CloudSyncService.perform(context, action, trace, epoch, revision)
      .then((result: CloudSyncResult): CloudSyncResult => {
        trace.event(result.success ? 'success' : (result.pending ? 'pending' : 'failed'), result.code ?? 0)
        if (epoch === CloudSyncService.epoch) CloudSyncService.lastResult = result
        return result
      }).finally(() => {
        CloudSyncService.inFlight = undefined
        CloudSyncService.inFlightAction = ''
      })
    CloudSyncService.inFlight = operation
    return operation
  }

  private static assertCurrent(epoch: number, revision?: number): void {
    if (!CloudSyncService.isEnabled() || epoch !== CloudSyncService.epoch) {
      throw new CloudSyncFailure(-1002, 'cancelled', '云同步设置已改变，本次结果不再应用')
    }
    if (revision !== undefined && revision !== CloudSyncService.localRevision) {
      throw new CloudSyncFailure(-1004, 'local_changed', '本机配置在同步期间已修改，已保留修改，请再次同步')
    }
  }

  private static async waitForSystem(trace: CloudSyncTrace, epoch: number): Promise<void> {
    CloudSyncService.assertCurrent(epoch)
    await CloudSyncTask.wait(trace, () => !CloudSyncService.isEnabled() || epoch !== CloudSyncService.epoch)
    CloudSyncService.assertCurrent(epoch)
  }

  private static async perform(context: common.UIAbilityContext, action: string, trace: CloudSyncTrace,
    epoch: number, revision: number): Promise<CloudSyncResult> {
    try {
      CloudSyncService.ensureFolders(context, trace)
      trace.event('preflight')
      await CloudSyncService.waitForSystem(trace, epoch)
      CloudSyncService.assertCurrent(epoch, revision)
      trace.event('cloud_probe')
      const raw = await CloudSyncSnapshotStore.readLatest(`${context.cloudFileDir}/${CLOUD_FOLDER_NAME}`,
        CloudSyncService.cloudPath(context), trace, (content: string) => CloudSyncService.readContentTime(content))
      CloudSyncService.assertCurrent(epoch, revision)
      if (raw === undefined) {
        if (action === 'restore') return CloudSyncService.result(false, false, false, false, '云端暂无 StarRustDesk 备份，本机数据未改动', 0)
        return await CloudSyncService.uploadSnapshot(context, trace, epoch, revision)
      }
      trace.event('cloud_parse')
      let cloudTime: number = CloudSyncService.readContentTime(raw)
      if (cloudTime <= 0) {
        throw new CloudSyncFailure(-1005, 'invalid_backup', '云端备份格式异常，已保留原文件，未进行覆盖')
      }
      let localChanged: number = CloudSyncService.readTimestamp(CLOUD_SYNC_LOCAL_CHANGED_OPTION)
      if (action === 'restore' || cloudTime > localChanged) {
        return await CloudSyncService.applyCloudContent(context, raw, trace, epoch, revision)
      }
      if (localChanged > cloudTime) {
        return await CloudSyncService.uploadSnapshot(context, trace, epoch, revision)
      }
      let syncTime: number = Date.now()
      RustDeskNapi.setOption(CLOUD_SYNC_LAST_SUCCESS_OPTION, syncTime.toString())
      return CloudSyncService.result(true, false, false, false, '云端与本机已是最新', syncTime)
    } catch (error) {
      const failure = CloudSyncFailure.from(error as Object)
      const result = CloudSyncService.result(false, false, false, false,
        `${failure.message}（错误码 ${failure.code}）`, 0)
      result.pending = [-1001, -1002, -1003, -1004].includes(failure.code)
      result.code = failure.code
      result.stage = trace.stage
      return result
    }
  }

  private static async uploadSnapshot(context: common.UIAbilityContext, trace: CloudSyncTrace,
    epoch: number, revision: number): Promise<CloudSyncResult> {
    let includesSecrets: boolean = CloudSyncService.includesSecrets()
    let password: string = ''
    if (includesSecrets) {
      trace.event('credential')
      password = await CredentialStore.load(CLOUD_SYNC_PASSWORD_ID)
      if (password.length < 8) {
        return CloudSyncService.passwordRequired('请先设置至少 8 位的云备份密码', 'sync')
      }
    }
    trace.event('snapshot')
    let payload: ConnectionBackupPayload = await CloudSyncService.buildPayload(includesSecrets)
    trace.event('encrypt')
    let content: string = includesSecrets ? await ConnectionBackupService.encrypt(payload, password) :
      ConnectionBackupService.createPlainText(payload)
    CloudSyncService.assertCurrent(epoch, revision)
    trace.event('mirror_write')
    CloudSyncService.writeText(CloudSyncService.mirrorPath(context), content)
    trace.event('cloud_write')
    await CloudSyncSnapshotStore.publish(`${context.cloudFileDir}/${CLOUD_FOLDER_NAME}`, content,
      CloudSyncService.payloadTime(payload), trace, () => CloudSyncService.assertCurrent(epoch, revision))
    trace.event('upload_wait')
    await CloudSyncService.waitForSystem(trace, epoch)
    let contentTime: number = CloudSyncService.payloadTime(payload)
    let syncTime: number = Date.now()
    RustDeskNapi.setOption(CLOUD_SYNC_LAST_APPLIED_OPTION, contentTime.toString())
    if (revision === CloudSyncService.localRevision) {
      RustDeskNapi.setOption(CLOUD_SYNC_LOCAL_CHANGED_OPTION, contentTime.toString())
    }
    RustDeskNapi.setOption(CLOUD_SYNC_LAST_SUCCESS_OPTION, syncTime.toString())
    if (revision !== CloudSyncService.localRevision) {
      const pending = CloudSyncService.result(false, false, true, false, '本次快照已同步，但本机又有新修改待同步，请再次同步', syncTime)
      pending.pending = true
      return pending
    }
    return CloudSyncService.result(true, false, true, false, '已同步到华为云空间', syncTime)
  }

  private static async buildPayload(includesSecrets: boolean): Promise<ConnectionBackupPayload> {
    let groups: ConnectionBackupGroup[] = []
    let groupRows: SavedConnectionGroupRow[] = CloudSyncService.readGroups()
    groupRows.forEach((row: SavedConnectionGroupRow) => {
      groups.push({ id: row.id, name: row.name })
    })

    let connections: ConnectionBackupItem[] = []
    let rows: SavedConnectionRow[] = CloudSyncService.readConnections()
    for (let row of rows) {
      let password: string = includesSecrets ? await CredentialStore.load(row.id) : ''
      connections.push({
        id: row.id,
        name: row.name,
        remoteId: row.remoteId,
        password: password,
        performancePreset: row.performancePreset,
        groupId: row.groupId
      })
    }
    let serverConfig: ConnectionBackupServerConfig = {
      idServer: RustDeskNapi.getOption('custom-rendezvous-server'),
      relayServer: RustDeskNapi.getOption('relay-server'),
      apiServer: RustDeskNapi.getOption('api-server'),
      serverKey: includesSecrets ? RustDeskNapi.getOption('key') : ''
    }
    return ConnectionBackupService.createPayload(groups, connections, includesSecrets, serverConfig)
  }

  private static async applyCloudContent(context: common.UIAbilityContext, raw: string, trace: CloudSyncTrace,
    epoch: number, revision: number): Promise<CloudSyncResult> {
    let payload: ConnectionBackupPayload
    if (ConnectionBackupService.isEncrypted(raw)) {
      trace.event('credential')
      let password: string = await CredentialStore.load(CLOUD_SYNC_PASSWORD_ID)
      if (password.length < 8) {
        return CloudSyncService.passwordRequired('该云备份已加密，请输入备份密码', 'restore')
      }
      try {
        trace.event('encrypt')
        payload = await ConnectionBackupService.decrypt(raw, password)
      } catch (_error) {
        return CloudSyncService.passwordRequired('备份密码错误或云备份已损坏', 'restore')
      }
    } else {
      payload = ConnectionBackupService.parsePlainText(raw)
    }

    CloudSyncService.assertCurrent(epoch, revision)
    trace.event('mirror_restore_write')
    CloudSyncService.writeText(CloudSyncService.mirrorPath(context), raw)
    trace.event('credential')
    let oldRows: SavedConnectionRow[] = CloudSyncService.readConnections()
    let newRows: SavedConnectionRow[] = []
    for (let item of payload.connections) {
      CloudSyncService.assertCurrent(epoch, revision)
      let row: SavedConnectionRow = {
        id: item.id,
        name: item.name,
        remoteId: item.remoteId,
        credentialAlias: item.id,
        performancePreset: item.performancePreset,
        groupId: item.groupId
      }
      newRows.push(row)
      if (payload.includesPasswords) {
        await CredentialStore.save(item.id, item.password)
      } else {
        let old: SavedConnectionRow | undefined = oldRows.find((value: SavedConnectionRow) =>
          value.remoteId === item.remoteId)
        if (old !== undefined && old.id !== item.id) {
          let oldPassword: string = await CredentialStore.load(old.id)
          CloudSyncService.assertCurrent(epoch, revision)
          if (oldPassword.length > 0) {
            await CredentialStore.save(item.id, oldPassword)
          }
        }
      }
    }
    CloudSyncService.assertCurrent(epoch, revision)
    trace.event('apply')
    let groupRows: SavedConnectionGroupRow[] = []
    payload.groups.forEach((group: ConnectionBackupGroup) => {
      groupRows.push({ id: group.id, name: group.name, expanded: true })
    })
    RustDeskNapi.setOption('saved-connection-groups', JSON.stringify(groupRows))
    RustDeskNapi.setOption('saved-connections', JSON.stringify(newRows))
    RustDeskNapi.setOption(CLOUD_SYNC_SECRETS_OPTION, payload.includesPasswords ? '1' : '0')
    if (payload.serverConfig !== undefined) {
      RustDeskNapi.setOption('custom-rendezvous-server', payload.serverConfig.idServer)
      RustDeskNapi.setOption('relay-server', payload.serverConfig.relayServer)
      RustDeskNapi.setOption('api-server', payload.serverConfig.apiServer)
      if (payload.includesPasswords) {
        RustDeskNapi.setOption('key', payload.serverConfig.serverKey)
      }
      let serverVersion: number = AppStorage.get<number>('serverConfigVersion') ?? 0
      AppStorage.set<number>('serverConfigVersion', serverVersion + 1)
    }
    let syncTime: number = CloudSyncService.payloadTime(payload)
    if (syncTime <= 0) {
      syncTime = Date.now()
    }
    RustDeskNapi.setOption(CLOUD_SYNC_LAST_APPLIED_OPTION, syncTime.toString())
    RustDeskNapi.setOption(CLOUD_SYNC_LOCAL_CHANGED_OPTION, syncTime.toString())
    RustDeskNapi.setOption(CLOUD_SYNC_LAST_SUCCESS_OPTION, Date.now().toString())
    let cloudRevision: number = AppStorage.get<number>('savedConnectionsCloudRevision') ?? 0
    AppStorage.set<number>('savedConnectionsCloudRevision', cloudRevision + 1)
    return CloudSyncService.result(true, true, false, false, '已从华为云空间恢复', Date.now())
  }

  private static readConnections(): SavedConnectionRow[] {
    try {
      let raw: string = RustDeskNapi.getOption('saved-connections')
      return raw.length > 0 ? JSON.parse(raw) as SavedConnectionRow[] : []
    } catch (_error) {
      return []
    }
  }

  private static readGroups(): SavedConnectionGroupRow[] {
    try {
      let raw: string = RustDeskNapi.getOption('saved-connection-groups')
      return raw.length > 0 ? JSON.parse(raw) as SavedConnectionGroupRow[] : []
    } catch (_error) {
      return []
    }
  }

  private static readContentTime(raw: string): number {
    try {
      if (ConnectionBackupService.isEncrypted(raw)) {
        interface EnvelopeTime { exportedAt: string }
        let envelope: EnvelopeTime = JSON.parse(raw) as EnvelopeTime
        const time = Date.parse(envelope.exportedAt)
        return Number.isFinite(time) ? time : 0
      }
      return CloudSyncService.payloadTime(ConnectionBackupService.parsePlainText(raw))
    } catch (_error) {
      return 0
    }
  }

  private static payloadTime(payload: ConnectionBackupPayload): number {
    let value: number = Date.parse(payload.exportedAt)
    return Number.isNaN(value) ? 0 : value
  }

  private static readTimestamp(option: string): number {
    try {
      let value: number = parseInt(RustDeskNapi.getOption(option))
      return Number.isNaN(value) ? 0 : value
    } catch (_error) {
      return 0
    }
  }

  private static ensureFolders(context: common.UIAbilityContext, trace: CloudSyncTrace): void {
    trace.event('cloud_directory')
    if (!context.cloudFileDir || !context.cloudFileDir.startsWith('/')) {
      throw new CloudSyncFailure(22400001, 'cloud_not_ready', '系统尚未提供云同步目录；若 StarRustDesk 专用开关已开启，请稍后重试')
    }
    let cloudFolder: string = `${context.cloudFileDir}/${CLOUD_FOLDER_NAME}`
    let mirrorFolder: string = `${context.filesDir}/${BACKUP_MIRROR_FOLDER}`
    if (!fileIo.accessSync(cloudFolder)) {
      fileIo.mkdirSync(cloudFolder, true)
    }
    trace.event('mirror_directory')
    if (!fileIo.accessSync(mirrorFolder)) {
      fileIo.mkdirSync(mirrorFolder, true)
    }
  }

  private static cloudPath(context: common.UIAbilityContext): string {
    return `${context.cloudFileDir}/${CLOUD_FOLDER_NAME}/${CLOUD_FILE_NAME}`
  }

  private static mirrorPath(context: common.UIAbilityContext): string {
    return `${context.filesDir}/${BACKUP_MIRROR_FOLDER}/${CLOUD_FILE_NAME}`
  }

  // Local backup mirror only. Cloud snapshots use CloudSyncSnapshotStore.
  private static writeText(path: string, content: string): void {
    let file: fileIo.File | undefined = undefined
    const temporary = `${path}.pending`
    try {
      file = fileIo.openSync(temporary,
        fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC)
      const data = new util.TextEncoder().encodeInto(content)
      const written = fileIo.writeSync(file.fd, data.buffer)
      if (written !== data.byteLength) throw new CloudSyncFailure(13900005, 'file_io', '云备份未完整写入，原备份已保留')
      fileIo.fsyncSync(file.fd)
      fileIo.closeSync(file)
      file = undefined
      fileIo.renameSync(temporary, path)
    } finally {
      try {
        if (file !== undefined) fileIo.closeSync(file)
      } finally {
        try { if (fileIo.accessSync(temporary)) fileIo.unlinkSync(temporary) } catch (_e) {}
      }
    }
  }

  private static passwordRequired(message: string, action: 'sync' | 'restore'): CloudSyncResult {
    const result = CloudSyncService.result(false, false, false, true, message, 0)
    result.passwordAction = action
    return result
  }

  private static result(success: boolean, restored: boolean, uploaded: boolean,
    needsPassword: boolean, message: string, syncTime: number): CloudSyncResult {
    return {
      success: success,
      restored: restored,
      uploaded: uploaded,
      needsPassword: needsPassword,
      message: message,
      syncTime: syncTime
    }
  }
}
