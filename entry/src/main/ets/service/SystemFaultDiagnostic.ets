import { hiAppEvent } from '@kit.PerformanceAnalysisKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { RustDeskNapi } from './RustDeskNapi';

interface FaultException { name?: string; message?: string; stack?: string; }
interface FaultParams {
  time?: number; pid?: number; foreground?: boolean; crash_type?: string;
  bundle_version?: string; exception?: FaultException; external_log?: string[];
  reason?: string; log_over_limit?: boolean;
}
interface FaultRecord { key: string; time: number; text: string; }

// No raw exception messages, hilog, register/memory dumps or user paths are stored.
// Keep this independent of native logging: a native crash must not erase its evidence.
export class SystemFaultDiagnostic {
  private static readonly LIMIT: number = 6;
  private static readonly MAX_READ: number = 512 * 1024;
  private static readonly MAX_STACK: number = 64 * 1024;
  private static readonly AGE: number = 7 * 24 * 60 * 60 * 1000;
  private static root: string = '';
  private static enabled: boolean = false;
  private static epoch: number = 0;
  private static since: number = 0;
  private static records: FaultRecord[] = [];
  private static watcher: hiAppEvent.Watcher | undefined = undefined;
  private static pending: number = 0;
  private static queue: Promise<void> = Promise.resolve();

  static initialize(filesDir: string, enabled: boolean): void {
    SystemFaultDiagnostic.root = filesDir;
    SystemFaultDiagnostic.setEnabled(enabled);
  }

  static setEnabled(enabled: boolean): void {
    SystemFaultDiagnostic.stop();
    SystemFaultDiagnostic.enabled = enabled;
    const epoch = SystemFaultDiagnostic.epoch;
    try {
      const previous = RustDeskNapi.getOption('system-fault-consent-since');
      const saved = Number(previous);
      SystemFaultDiagnostic.since = enabled && saved > 0 ? saved : Date.now();
      const next = enabled ? `${SystemFaultDiagnostic.since}` : '';
      if (previous !== next) RustDeskNapi.setOption('system-fault-consent-since', next);
    } catch (_e) { SystemFaultDiagnostic.since = Date.now(); }
    SystemFaultDiagnostic.queue = SystemFaultDiagnostic.queue.then(async () => {
      if (!SystemFaultDiagnostic.root || epoch !== SystemFaultDiagnostic.epoch) return;
      SystemFaultDiagnostic.records = [];
      if (!enabled) { await SystemFaultDiagnostic.removeArchive(); return; }
      try {
        const raw = await SystemFaultDiagnostic.readLimited(`${SystemFaultDiagnostic.root}/system-faults.json`);
        const stored = JSON.parse(raw) as FaultRecord[];
        if (Array.isArray(stored)) {
          SystemFaultDiagnostic.records = stored.filter((r: FaultRecord) => r && typeof r.time === 'number' &&
            r.time >= SystemFaultDiagnostic.since && r.time >= Date.now() - SystemFaultDiagnostic.AGE && typeof r.text === 'string' &&
            r.text.length <= SystemFaultDiagnostic.MAX_STACK + 1024 && typeof r.key === 'string').slice(-SystemFaultDiagnostic.LIMIT);
          if (SystemFaultDiagnostic.active(epoch) && SystemFaultDiagnostic.records.length !== stored.length) {
            if (SystemFaultDiagnostic.records.length) await SystemFaultDiagnostic.persist();
            else await SystemFaultDiagnostic.removeArchive();
          }
        }
      } catch (_e) { /* First run or damaged local archive: never block startup. */ }
      if (!SystemFaultDiagnostic.active(epoch)) return;
      SystemFaultDiagnostic.subscribe(epoch);
    }).catch(() => { SystemFaultDiagnostic.note('initialization_failed'); });
  }

  static stop(): void {
    SystemFaultDiagnostic.epoch++;
    SystemFaultDiagnostic.enabled = false;
    if (SystemFaultDiagnostic.watcher) {
      try { hiAppEvent.removeWatcher(SystemFaultDiagnostic.watcher); } catch (_e) {}
      SystemFaultDiagnostic.watcher = undefined;
    }
  }

  private static active(epoch: number): boolean { return SystemFaultDiagnostic.enabled && SystemFaultDiagnostic.epoch === epoch; }

  private static subscribe(epoch: number): void {
    try {
      if (deviceInfo.sdkApiVersion < 12) { SystemFaultDiagnostic.note('unsupported_api'); return; }
      const names: string[] = [hiAppEvent.event.APP_CRASH, hiAppEvent.event.APP_FREEZE];
      if (deviceInfo.sdkApiVersion >= 20) names.push(hiAppEvent.event.APP_KILLED);
      const watcher: hiAppEvent.Watcher = {
        name: 'starrustdesk_system_faults',
        appEventFilters: [{ domain: hiAppEvent.domain.OS, names: names }],
        onReceive: (domain: string, groups: hiAppEvent.AppEventGroup[]): void => {
          try {
            if (!SystemFaultDiagnostic.active(epoch) || domain !== hiAppEvent.domain.OS) return;
            for (const group of groups) {
              for (const event of group.appEventInfos) {
                if (!names.includes(event.name) || SystemFaultDiagnostic.pending >= 12) continue;
                SystemFaultDiagnostic.pending++;
                SystemFaultDiagnostic.queue = SystemFaultDiagnostic.queue.then(async () => {
                  try { if (SystemFaultDiagnostic.active(epoch)) await SystemFaultDiagnostic.collect(event, epoch); }
                  catch (_e) { SystemFaultDiagnostic.note('collection_failed'); }
                  finally { SystemFaultDiagnostic.pending--; }
                }).catch(() => { SystemFaultDiagnostic.note('queue_failed'); });
              }
            }
          } catch (_e) { SystemFaultDiagnostic.note('callback_failed'); }
        }
      };
      hiAppEvent.addWatcher(watcher);
      SystemFaultDiagnostic.watcher = watcher;
      SystemFaultDiagnostic.note('watcher_started');
    } catch (_e) { SystemFaultDiagnostic.note('watcher_unavailable'); }
  }

  // Extract code locations only, instead of attempting to redact an arbitrary dump.
  static stackOnly(raw: string): string {
    const result: string[] = [];
    let length = 0;
    for (const line of raw.slice(0, SystemFaultDiagnostic.MAX_READ).split('\n')) {
      const native = line.match(/^\s*(#\d+)\s+pc\s+([0-9a-fA-F]+)\s+(\S+)(.*)$/);
      let frame = '';
      const thread = line.match(/^\s*Tid:\s*(\d+)/);
      if (thread) frame = `Tid: ${thread[1]}`;
      if (line.trim() === 'Fault thread info:') frame = 'Fault thread info:';
      if (native) {
        const module = native[3].split('/').pop() ?? '';
        if (!/^[A-Za-z0-9_.+-]+$/.test(module)) continue;
        const build = native[4].match(/\b([0-9a-fA-F]{16,64})\b/);
        frame = `${native[1]} pc ${native[2]} ${module}${build ? ' build_id=' + build[1] : ''}`;
      } else {
        const js = line.match(/^\s*at\s+([A-Za-z0-9_.$<> ]+)\s*\(([^\r\n]+):(\d+):(\d+)\)\s*$/);
        if (js) {
          const file = js[2].split('/').pop() ?? '';
          if (/^[A-Za-z0-9_.-]+$/.test(file)) frame = `at ${js[1].trim()} (${file}:${js[3]}:${js[4]})`;
        }
      }
      if (frame && length + frame.length + 1 <= SystemFaultDiagnostic.MAX_STACK) {
        result.push(frame); length += frame.length + 1;
      }
    }
    return result.join('\n');
  }

  private static reason(raw: string): string {
    const known: string[] = ['LowMemoryKill', 'SwapFull', 'OomKiller', 'RssThresholdKiller',
      'KillApplication', 'OnRemoteDied', 'Restart', 'UserRequest', 'Upgrade', 'PermissionUpdate',
      'aaForceStop', 'ThreadBlock6S', 'AppInputBlock', 'LifecycleTimeout', 'JsError', 'CppCrash',
      'AppFreeze', 'PowerSaveClean', 'HighTemperature', 'CPUHighload', 'IOHighload',
      'TransientTaskTimeout', 'HardwareDecodingResourcesLimit', 'TooManyReadyThreads'];
    if (known.includes(raw.trim())) return raw.trim();
    if (/^ResourceLeak\((IonLeak|GpuRsLeak|GpuLeak|AshmemLeak|CES|PSSSoftLeak|PSSLeak|VMALeak|FDLeak|ThreadLeak|KernelZoneLeak)\)$/.test(raw.trim())) return raw.trim();
    const signal = raw.match(/\b(SIGSEGV|SIGABRT|SIGBUS|SIGILL|SIGFPE|SIGTRAP|SIGKILL)\b/);
    if (signal) return signal[1];
    if (/out.of.memory|low.memory|oom/i.test(raw)) return 'memory';
    if (/THREAD_BLOCK|APP_INPUT_BLOCK|freeze|watchdog/i.test(raw)) return 'freeze';
    if (/TypeError|ReferenceError|RangeError|SyntaxError/.test(raw)) return 'js_exception';
    return 'unclassified';
  }

  private static async collect(event: hiAppEvent.AppEventInfo, epoch: number): Promise<void> {
    const p = event.params as FaultParams;
    const time = p.time;
    if (typeof time !== 'number' || !Number.isFinite(time) || time < SystemFaultDiagnostic.since || time > Date.now() + 60000) return;
    const key = `${event.name}-${time}-${typeof p.pid === 'number' ? p.pid : 0}`;
    if (SystemFaultDiagnostic.records.some((r: FaultRecord) => r.key === key)) return;
    let stack = SystemFaultDiagnostic.stackOnly(typeof p.exception?.stack === 'string' ? p.exception.stack : '');
    let reason = SystemFaultDiagnostic.reason(typeof p.reason === 'string' ? p.reason : '');
    if (reason === 'unclassified') reason = SystemFaultDiagnostic.reason(`${p.exception?.name ?? ''} ${p.exception?.message ?? ''}`);
    let attachments = 0;
    let readFailures = 0;
    if (Array.isArray(p.external_log)) {
      for (const path of p.external_log.slice(0, 3)) {
        if (!SystemFaultDiagnostic.active(epoch)) return;
        try {
          if (typeof path !== 'string' || path.includes('..')) { readFailures++; continue; }
          const real = path;
          if (!real.startsWith('/data/storage/el2/log/') && !real.startsWith('/data/storage/el1/log/')) {
            readFailures++; continue;
          }
          if (!(await fileIo.lstat(real)).isFile()) { readFailures++; continue; }
          const raw = await SystemFaultDiagnostic.readLimited(real);
          if (reason === 'unclassified') reason = SystemFaultDiagnostic.reason(raw);
          const frames = SystemFaultDiagnostic.stackOnly(raw);
          if (frames) stack += `\n--- system stack ${++attachments} ---\n${frames}`;
        } catch (_e) { readFailures++; }
      }
    }
    if (!SystemFaultDiagnostic.active(epoch)) return;
    const version = typeof p.bundle_version === 'string' && /^[\d.]{1,32}$/.test(p.bundle_version) ? p.bundle_version : 'unknown';
    const kind = p.crash_type === 'NativeCrash' || p.crash_type === 'JsError' ? p.crash_type : 'system';
    const text = `event=${event.name} time=${time} version=${version} kind=${kind} reason=${reason} ` +
      `foreground=${p.foreground === true} external_read_failures=${readFailures} log_over_limit=${p.log_over_limit === true}\n` +
      `Filtered code frames (no raw messages, hilog, paths or memory); read_limit=${SystemFaultDiagnostic.MAX_READ}\n` +
      (stack ? stack.slice(0, SystemFaultDiagnostic.MAX_STACK) : '[System event received; no usable stack supplied]');
    SystemFaultDiagnostic.records = SystemFaultDiagnostic.records.filter((r: FaultRecord) => r.time >= Date.now() - SystemFaultDiagnostic.AGE);
    SystemFaultDiagnostic.records.push({ key: key, time: time, text: text });
    SystemFaultDiagnostic.records = SystemFaultDiagnostic.records.sort((a: FaultRecord, b: FaultRecord) => a.time - b.time).slice(-SystemFaultDiagnostic.LIMIT);
    await SystemFaultDiagnostic.persist();
    SystemFaultDiagnostic.note('event_archived');
  }

  private static async readLimited(path: string): Promise<string> {
    const file = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
    try {
      const buffer = new ArrayBuffer(SystemFaultDiagnostic.MAX_READ);
      const length = await fileIo.read(file.fd, buffer);
      return util.TextDecoder.create('utf-8').decodeToString(new Uint8Array(buffer, 0, length));
    } finally { await fileIo.close(file); }
  }

  private static async persist(): Promise<void> {
    const target = `${SystemFaultDiagnostic.root}/system-faults.json`;
    const file = await fileIo.open(target + '.tmp', fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    try {
      const bytes = new util.TextEncoder().encodeInto(JSON.stringify(SystemFaultDiagnostic.records));
      let offset = 0;
      while (offset < bytes.length) {
        const written = await fileIo.write(file.fd, bytes.slice(offset).buffer);
        if (written <= 0) throw new Error('fault_archive_short_write');
        offset += written;
      }
    }
    finally { await fileIo.close(file); }
    await fileIo.rename(target + '.tmp', target);
  }

  private static async removeArchive(): Promise<void> {
    for (const suffix of ['system-faults.json', 'system-faults.json.tmp']) {
      try { await fileIo.unlink(`${SystemFaultDiagnostic.root}/${suffix}`); } catch (_e) {}
    }
  }

  static clear(): void {
    SystemFaultDiagnostic.since = Date.now();
    try { RustDeskNapi.setOption('system-fault-consent-since', SystemFaultDiagnostic.enabled ? `${SystemFaultDiagnostic.since}` : ''); } catch (_e) {}
    SystemFaultDiagnostic.queue = SystemFaultDiagnostic.queue.then(async () => {
      SystemFaultDiagnostic.records = [];
      if (SystemFaultDiagnostic.root) await SystemFaultDiagnostic.removeArchive();
    }).catch(() => { SystemFaultDiagnostic.note('clear_failed'); });
  }

  static async exportText(): Promise<string> {
    let output = '\n\n===== SYSTEM FAULTS (LOCAL, FILTERED) =====\n';
    SystemFaultDiagnostic.queue = SystemFaultDiagnostic.queue.then(async () => {
      const records = SystemFaultDiagnostic.records.filter((r: FaultRecord) => r.time >= SystemFaultDiagnostic.since && r.time >= Date.now() - SystemFaultDiagnostic.AGE);
      if (records.length !== SystemFaultDiagnostic.records.length) {
        SystemFaultDiagnostic.records = records;
        try {
          if (records.length) await SystemFaultDiagnostic.persist();
          else if (SystemFaultDiagnostic.root) await SystemFaultDiagnostic.removeArchive();
        } catch (_e) { SystemFaultDiagnostic.note('archive_prune_failed'); }
      }
      output += records.length ? records.map((r: FaultRecord) => r.text).join('\n\n') :
        'No collected system fault. Enable diagnostics, reproduce, reopen the app and wait for system delivery before exporting.\n';
    }).catch(() => { output += 'System fault archive unavailable.\n'; });
    await SystemFaultDiagnostic.queue;
    return output;
  }

  private static note(message: string): void {
    try { RustDeskNapi.appendDiagnosticLog('system-fault', message); } catch (_e) {}
  }
}
