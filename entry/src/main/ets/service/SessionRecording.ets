import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { RustDeskNapi } from './RustDeskNapi';
import { OperationDiagnostic } from './OperationDiagnostic';

export class SessionRecording {
  private static path: string = '';
  private static started: number = 0;
  private static trace?: OperationDiagnostic;
  static begin(context: common.UIAbilityContext): boolean {
    if (SessionRecording.path) return false;
    const trace = new OperationDiagnostic('recording', 'record');
    const path = `${context.filesDir}/remote-session-${Date.now()}.webm`;
    const result = RustDeskNapi.startRecording(path);
    if (result !== 0) { trace.end('failed', { result: result }); try { fileIo.unlinkSync(path); } catch (_e) {} return false; }
    SessionRecording.trace = trace;
    SessionRecording.path = path; SessionRecording.started = Date.now();
    trace.event('started');
    return true;
  }
  static active(): boolean { return SessionRecording.path.length > 0 && RustDeskNapi.getRecordingStatus() > 0; }
  static status(): number { return RustDeskNapi.getRecordingStatus(); }
  static stop(reason: number = 0): void {
    if (!SessionRecording.path) return;
    const result = RustDeskNapi.stopRecording();
    let bytes = 0;
    try { bytes = fileIo.statSync(SessionRecording.path).size; } catch (_e) {}
    SessionRecording.trace?.end(result < 0 || bytes === 0 ? 'failed' : 'stop', { native_status: result, bytes: bytes, kind: reason });
    SessionRecording.trace = undefined;
    SessionRecording.path = '';
  }
  static files(context: common.UIAbilityContext): string[] {
    return fileIo.listFileSync(context.filesDir).filter((name: string) => /^remote-session-\d+\.webm$/.test(name))
      .filter((name: string) => `${context.filesDir}/${name}` !== SessionRecording.path)
      .sort().reverse();
  }
  static async exportFile(context: common.UIAbilityContext, name: string): Promise<boolean> {
    const trace = new OperationDiagnostic('recording', 'export');
    let total = 0;
    try {
    trace.event('open_source');
    if (!/^remote-session-\d+\.webm$/.test(name)) throw new Error('invalid recording');
    const path = `${context.filesDir}/${name}`;
    if (path === SessionRecording.path) throw new Error('recording is active');
    const sourceSize = fileIo.statSync(path).size;
    if (sourceSize <= 0) throw new Error('录像尚未收到关键帧，没有可导出画面');
    trace.event('select', { source_bytes: sourceSize });
    const destinations = await new picker.DocumentViewPicker(context).save({ newFileNames: [name] });
    if (!destinations.length) { trace.end('cancelled'); return false; }
    trace.event('open_source');
    const source = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
    let target: fileIo.File | undefined = undefined;
    try {
      trace.event('open_target');
      target = await fileIo.open(destinations[0], fileIo.OpenMode.READ_WRITE | fileIo.OpenMode.TRUNC);
      const buffer = new ArrayBuffer(1024 * 1024);
      trace.event('copy');
      while (total < sourceSize) {
        const n = await fileIo.read(source.fd, buffer);
        if (n <= 0) throw new Error('录像读取失败');
        let written = 0;
        while (written < n) {
          const count = await fileIo.write(target.fd, buffer.slice(written, n));
          if (count <= 0) throw new Error('录像保存失败');
          written += count;
        }
        total += n;
      }
      trace.event('verify', { written_bytes: total });
      if (fileIo.statSync(target.fd).size !== sourceSize) throw new Error('录像大小校验失败');
    } catch (error) {
      // Capture the failing phase before cleanup changes the current step.
      trace.fail(error as Object, { written_bytes: total });
      throw error as Error;
    } finally { trace.event('close'); try { await fileIo.close(source); } finally { if (target) await fileIo.close(target); } }
    trace.end('completed', { written_bytes: total });
    return true;
    } catch (error) { trace.fail(error as Object, { written_bytes: total }); throw error as Error; }
  }
}
