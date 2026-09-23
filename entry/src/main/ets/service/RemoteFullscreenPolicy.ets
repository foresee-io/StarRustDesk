import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { RemoteDisplayPolicy } from './RemoteDisplayPolicy';
import { RustDeskNapi } from './RustDeskNapi';

// One queue for the main window, including page cleanup. A late enter request
// must complete before cleanup restores the bars or a new session enters.
export class RemoteFullscreenPolicy {
  private static pending: Promise<void> = Promise.resolve();
  private static owner: window.Window | undefined;
  private static enabled: boolean = false;

  static apply(enabled: boolean, rollbackOnFailure: boolean = true): Promise<void> {
    const main = RemoteDisplayPolicy.getMainWindow();
    const operation = RemoteFullscreenPolicy.pending.then(async () => {
      if (!main || main !== RemoteDisplayPolicy.getMainWindow()) {
        RustDeskNapi.appendDiagnosticLog('fullscreen', 'window_unavailable');
        throw new Error('Main window unavailable');
      }
      if (RemoteFullscreenPolicy.owner !== main) {
        RemoteFullscreenPolicy.owner = main;
        RemoteFullscreenPolicy.enabled = false;
      }
      const previous = RemoteFullscreenPolicy.enabled;
      try {
        await RemoteFullscreenPolicy.setWindowState(main, enabled);
        RemoteFullscreenPolicy.enabled = enabled;
        try {
          const properties = main.getWindowProperties();
          RustDeskNapi.appendDiagnosticLog('fullscreen',
            `window_applied requested=${enabled} layout=${properties.isLayoutFullScreen} full=${properties.isFullScreen} width=${properties.windowRect.width} height=${properties.windowRect.height}`);
        } catch (_e) {
          RustDeskNapi.appendDiagnosticLog('fullscreen', `window_applied requested=${enabled} properties=unavailable`);
        }
      } catch (error) {
        if (rollbackOnFailure) {
          try {
            await RemoteFullscreenPolicy.setWindowState(main, previous);
            RustDeskNapi.appendDiagnosticLog('fullscreen', `window_rollback enabled=${previous} result=ok`);
          } catch (_e) {
            RustDeskNapi.appendDiagnosticLog('fullscreen', `window_rollback enabled=${previous} result=failed`);
          }
        }
        throw error as Error;
      }
    });
    // Keep the queue usable after a rejection; callers still receive the error.
    RemoteFullscreenPolicy.pending = operation.catch(() => {});
    return operation;
  }

  private static async setWindowState(main: window.Window, enabled: boolean): Promise<void> {
    let failure: BusinessError | undefined;
    try {
      await main.setWindowLayoutFullScreen(enabled);
      RustDeskNapi.appendDiagnosticLog('fullscreen', `window_layout enabled=${enabled} result=ok`);
    } catch (error) {
      failure = error as BusinessError;
      RustDeskNapi.appendDiagnosticLog('fullscreen',
        `window_layout enabled=${enabled} result=failed code=${failure.code ?? -1}`);
    }
    // Always attempt bar restoration even if the layout API failed.
    try {
      const bars: Array<'status' | 'navigation'> = enabled ? [] : ['status', 'navigation'];
      await main.setWindowSystemBarEnable(bars);
      RustDeskNapi.appendDiagnosticLog('fullscreen', `window_bars hidden=${enabled} result=ok`);
    } catch (error) {
      const barError = error as BusinessError;
      RustDeskNapi.appendDiagnosticLog('fullscreen',
        `window_bars hidden=${enabled} result=failed code=${barError.code ?? -1}`);
      if (!failure) failure = barError;
    }
    if (failure) throw failure as Error;
  }
}
