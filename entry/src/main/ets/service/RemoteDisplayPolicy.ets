import { display, window } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { RustDeskNapi } from './RustDeskNapi';

// Adapts the existing system-projected main window; does not initiate casting
// or create a second remote session/surface.
export class RemoteDisplayPolicy {
  private static main: window.Window | undefined;
  private static localDisplayId: number = -1;
  private static currentDisplayId: number = -1;
  private static original: window.Orientation = window.Orientation.AUTO_ROTATION;
  private static active: boolean = false;
  private static pending: Promise<void> = Promise.resolve();
  private static changed = (id: number): void => {
    RemoteDisplayPolicy.currentDisplayId = id;
    RemoteDisplayPolicy.apply();
  };

  static attach(main: window.Window): void {
    RemoteDisplayPolicy.detach();
    RemoteDisplayPolicy.main = main;
    AppStorage.setOrCreate('remoteLandscapeLocked', false);
    try {
      RemoteDisplayPolicy.localDisplayId = display.getDefaultDisplaySync().id;
      RemoteDisplayPolicy.original = main.getPreferredOrientation();
      main.on('displayIdChange', RemoteDisplayPolicy.changed);
    } catch (_e) {
      RustDeskNapi.appendDiagnosticLog('projection', 'display_listener_unavailable');
    }
    RemoteDisplayPolicy.refresh();
  }

  static detach(): void {
    try { RemoteDisplayPolicy.main?.off('displayIdChange', RemoteDisplayPolicy.changed); } catch (_e) {}
    RemoteDisplayPolicy.main = undefined;
    RemoteDisplayPolicy.localDisplayId = -1;
    RemoteDisplayPolicy.currentDisplayId = -1;
  }

  static refresh(): void {
    const main = RemoteDisplayPolicy.main;
    if (!main) return;
    try {
      RemoteDisplayPolicy.currentDisplayId = main.getWindowProperties().displayId ?? -1;
    } catch (_e) {}
    RemoteDisplayPolicy.apply();
  }

  static setActive(active: boolean): void {
    RemoteDisplayPolicy.active = active;
    if (!active) AppStorage.setOrCreate('remoteLandscapeLocked', false);
    RemoteDisplayPolicy.apply();
  }

  static toggleLandscape(): void {
    AppStorage.setOrCreate('remoteLandscapeLocked', !(AppStorage.get<boolean>('remoteLandscapeLocked') ?? false));
    RemoteDisplayPolicy.apply();
  }

  private static apply(): void {
    const main = RemoteDisplayPolicy.main;
    if (!main || (deviceInfo.deviceType !== 'phone' && deviceInfo.deviceType !== 'tablet')) return;
    RemoteDisplayPolicy.pending = RemoteDisplayPolicy.pending.then(async () => {
      if (main !== RemoteDisplayPolicy.main) return;
      const external = RemoteDisplayPolicy.localDisplayId >= 0 && RemoteDisplayPolicy.currentDisplayId >= 0 &&
        RemoteDisplayPolicy.currentDisplayId !== RemoteDisplayPolicy.localDisplayId;
      let wide = false;
      if (external) {
        try {
          const target = display.getDisplayByIdSync(RemoteDisplayPolicy.currentDisplayId);
          wide = target.width > target.height;
        } catch (_e) {}
      }
      const locked = AppStorage.get<boolean>('remoteLandscapeLocked') ?? false;
      const orientation = RemoteDisplayPolicy.active && (locked || wide) ?
        window.Orientation.LANDSCAPE : RemoteDisplayPolicy.original;
      if (main.getPreferredOrientation() !== orientation) await main.setPreferredOrientation(orientation);
      RustDeskNapi.appendDiagnosticLog('projection',
        `window_policy active=${RemoteDisplayPolicy.active} external=${external} wide=${wide} manual=${locked} orientation=${orientation}`);
    }).catch(() => {
      RustDeskNapi.appendDiagnosticLog('projection', 'orientation_apply_failed');
    });
  }
}
