import { cloudSync } from '@kit.CoreFileKit'
import { OperationDiagnostic } from './OperationDiagnostic'
import { RustDeskNapi } from './RustDeskNapi'

export class CloudSyncFailure extends Error {
  code: number
  reason: string
  constructor(code: number, reason: string, message: string) {
    super(message)
    this.code = code
    this.reason = reason
  }

  static from(error: Object): CloudSyncFailure {
    if (error instanceof CloudSyncFailure) return error
    const code = OperationDiagnostic.errorCode(error)
    switch (code) {
      case 22400001: return new CloudSyncFailure(code, 'cloud_not_ready', '系统云同步服务尚未就绪；若 StarRustDesk 专用开关已开启，请稍后重试')
      case 22400002: return new CloudSyncFailure(code, 'network', '云同步网络不可用，请检查网络或云空间的移动数据限制')
      case 22400003: return new CloudSyncFailure(code, 'battery', '电量过低，系统暂停云同步，请充电后重试')
      case 13600001: return new CloudSyncFailure(code, 'ipc', '暂时无法连接系统云同步服务，请稍后重试')
      case 13900002: return new CloudSyncFailure(code, 'missing_file', '同步文件或目录暂不可用，请稍后重试')
      case 13900005: return new CloudSyncFailure(code, 'file_io', '同步文件读写失败，请检查本机存储后重试')
      case 13900020: return new CloudSyncFailure(code, 'cloud_file_operation', '系统云目录拒绝此次文件操作，原备份已保留；请导出诊断日志排查兼容性')
      case 201:
      case 13900012: return new CloudSyncFailure(code, 'permission', '应用无法访问云同步目录，请检查本应用的云空间授权')
      case 801:
      case 13900031: return new CloudSyncFailure(code, 'unsupported', '当前系统暂不支持所需的云文件同步能力')
      default: return new CloudSyncFailure(code, 'unknown', '云同步未完成，请开启诊断日志后重试并导出日志')
    }
  }

  static progress(error: number): CloudSyncFailure {
    const messages: string[] = ['云同步任务失败，请稍后重试', '所有网络均不可用，请连接网络后重试',
      '云同步需要可用的 Wi-Fi，请检查云空间的移动数据限制', '电量过低，请充电后再同步',
      '系统因电量不足暂停云同步，请充电后重试', '华为云空间容量不足，请释放云端空间',
      '本机存储空间不足，请释放空间后重试', '设备温度过高，系统暂停云同步', '华为云端服务暂不可用，请稍后重试']
    const index = Number.isInteger(error) && error >= 0 && error < messages.length ? error : 0
    return new CloudSyncFailure(22410000 + index, `progress_${index}`, messages[index])
  }
}

// Closed stages plus numeric fields only; never include error.message, paths,
// account information, connection data, passwords or server addresses in logs.
const STAGES: string[] = ['begin', 'coalesced', 'busy', 'cloud_directory', 'mirror_directory', 'preflight',
  'cloud_probe', 'cloud_read', 'cloud_parse', 'credential', 'snapshot', 'encrypt', 'mirror_write', 'cloud_write',
  'upload_wait', 'apply', 'mirror_restore_write', 'success', 'pending', 'failed', 'cancelled',
  'system_baseline', 'system_listen', 'system_snapshot', 'system_start', 'system_started',
  'system_progress', 'system_completed', 'system_unlisten', 'system_time_unavailable']
STAGES.push('cloud_list', 'cloud_validate', 'cloud_digest', 'cloud_allocate', 'cloud_open', 'cloud_write_bytes',
  'cloud_close', 'cloud_verify_content', 'cloud_publish', 'cleanup_close', 'cleanup_pending',
  'cloud_read_open', 'cloud_read_stat', 'cloud_read_bytes', 'cloud_read_close',
  'cloud_verify_open', 'cloud_verify_stat', 'cloud_verify_bytes', 'cloud_verify_close')

export class CloudSyncTrace {
  private static sequence: number = 0
  readonly id: number = ++CloudSyncTrace.sequence
  private started: number = Date.now()
  stage: string = 'begin'
  private action: 'sync' | 'upload' | 'restore'
  constructor(action: 'sync' | 'upload' | 'restore') {
    this.action = action
    this.event('begin')
  }
  event(stage: string, code: number = 0, state: number = -1): void {
    if (!STAGES.includes(stage)) return
    if (!stage.startsWith('system_') && !stage.startsWith('cleanup_') &&
      !['success', 'pending', 'failed', 'cancelled', 'coalesced', 'busy'].includes(stage)) this.stage = stage
    try {
      if (RustDeskNapi.getOption('diagnostic-log-enabled') !== '1') return
      RustDeskNapi.appendDiagnosticLog('cloud-sync',
        `op_id=${this.id} action=${this.action} stage=${stage} operation_stage=${this.stage} code=${Number.isFinite(code) ? code : 0} state=${Number.isFinite(state) ? state : -1} elapsed_ms=${Math.max(0, Date.now() - this.started)}`)
    } catch (_e) {}
  }
}

export class CloudSyncTask {
  static wait(trace: CloudSyncTrace, cancelled: () => boolean): Promise<void> {
    const sync = new cloudSync.FileSync()
    return new Promise<void>((resolve, reject) => {
      let finished = false
      let registered = false
      let baseline: number = -1
      let sentAt = 0
      let accepted = false
      let snapshotSeen = false
      let activeSeen = false
      let state: number = -1
      let progressError = 0
      let checkingTime = false
      let timeWarningLogged = false
      let timeout = -1
      let poll = -1

      const finish = (failure?: CloudSyncFailure): void => {
        if (finished) return
        finished = true
        if (timeout !== -1) clearTimeout(timeout)
        if (poll !== -1) clearInterval(poll)
        if (registered) {
          try { sync.off('progress', progress); trace.event('system_unlisten') }
          catch (error) { trace.event('system_unlisten', OperationDiagnostic.errorCode(error as Object)) }
        }
        if (failure) reject(failure)
        else { trace.event('system_completed'); resolve() }
      }
      const check = async (): Promise<void> => {
        if (finished) return
        if (cancelled()) { finish(new CloudSyncFailure(-1002, 'cancelled', '云同步已关闭，本次结果不再应用')); return }
        if (!accepted) return
        if (state === cloudSync.SyncState.UPLOAD_FAILED || state === cloudSync.SyncState.DOWNLOAD_FAILED || progressError !== 0) {
          finish(CloudSyncFailure.progress(progressError)); return
        }
        if (state === cloudSync.SyncState.STOPPED) {
          finish(new CloudSyncFailure(-1003, 'stopped', '系统已暂停云同步，请稍后重试')); return
        }
        if (activeSeen && state === cloudSync.SyncState.COMPLETED) { finish(); return }
        // Registration can deliver COMPLETED from a previous task, even after
        // start() resolves. Require fresh activity or a newly advanced timestamp.
        if (checkingTime || state === cloudSync.SyncState.UPLOADING || state === cloudSync.SyncState.DOWNLOADING) return
        checkingTime = true
        try {
          const time = await sync.getLastSyncTime()
          if (!finished && !cancelled() && baseline >= 0 && time > baseline && time >= sentAt &&
            (state === -1 || state === cloudSync.SyncState.COMPLETED)) finish()
        } catch (error) {
          if (!finished && !timeWarningLogged) {
            timeWarningLogged = true
            trace.event('system_time_unavailable', OperationDiagnostic.errorCode(error as Object))
          }
        } finally { checkingTime = false }
      }
      const progress = (value: cloudSync.SyncProgress): void => {
        if (finished) return
        if (!snapshotSeen) {
          snapshotSeen = true
          trace.event('system_snapshot', value.error, value.state)
          return
        }
        if (sentAt <= 0) return
        if (state === value.state && progressError === value.error) return
        state = value.state
        progressError = value.error
        trace.event('system_progress', progressError, state)
        if (state === cloudSync.SyncState.UPLOADING || state === cloudSync.SyncState.DOWNLOADING) activeSeen = true
        check().catch((error: Object) => finish(CloudSyncFailure.from(error)))
      }
      timeout = setTimeout(() => finish(new CloudSyncFailure(-1001, 'timeout',
        '等待云同步结果超时，尚未确认完成；系统可能仍在同步，请稍后重试')), 35000)
      poll = setInterval(() => { check().catch((error: Object) => finish(CloudSyncFailure.from(error))) }, 1000)
      const start = async (): Promise<void> => {
        try {
          trace.event('system_baseline')
          baseline = await sync.getLastSyncTime()
        } catch (error) {
          trace.event('system_time_unavailable', OperationDiagnostic.errorCode(error as Object))
        }
        if (finished || cancelled()) { if (!finished) finish(new CloudSyncFailure(-1002, 'cancelled', '云同步已关闭')); return }
        trace.event('system_listen')
        registered = true
        sync.on('progress', progress)
        sentAt = Date.now()
        trace.event('system_start')
        await sync.start()
        if (finished) return
        accepted = true
        trace.event('system_started')
        await check()
      }
      start().catch((error: Object) => finish(CloudSyncFailure.from(error)))
    })
  }
}
