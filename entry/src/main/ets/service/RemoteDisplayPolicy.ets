import { display, window } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { RustDeskNapi } from './RustDeskNapi';

export enum RemoteOrientationMode {
  SYSTEM = 'system',
  PORTRAIT = 'portrait',
  LANDSCAPE = 'landscape',
}

// Adapts the existing system-projected main window; does not initiate casting
// or create a second remote session/surface.
export class RemoteDisplayPolicy {
  private static main: window.Window | undefined;
  private static localDisplayId: number = -1;
  private static currentDisplayId: number = -1;
  private static original: window.Orientation = window.Orientation.AUTO_ROTATION_RESTRICTED;
  private static localMode: RemoteOrientationMode = RemoteOrientationMode.SYSTEM;
  private static projectionMode: RemoteOrientationMode = RemoteOrientationMode.SYSTEM;
  private static active: boolean = false;
  private static pending: Promise<void> = Promise.resolve();
  private static changed = (id: number): void => {
    RemoteDisplayPolicy.currentDisplayId = id;
    RemoteDisplayPolicy.publishDisplayState();
    RemoteDisplayPolicy.apply();
  };

  static attach(main: window.Window): void {
    RemoteDisplayPolicy.detach();
    RemoteDisplayPolicy.main = main;
    RemoteDisplayPolicy.active = false;
    RemoteDisplayPolicy.localMode = RemoteOrientationMode.SYSTEM;
    RemoteDisplayPolicy.projectionMode = RemoteOrientationMode.SYSTEM;
    RemoteDisplayPolicy.original = window.Orientation.AUTO_ROTATION_RESTRICTED;
    try {
      RemoteDisplayPolicy.localDisplayId = display.getDefaultDisplaySync().id;
      const original = main.getPreferredOrientation();
      // Never restore the old sensor-only default after a session/projection.
      RemoteDisplayPolicy.original = original === window.Orientation.AUTO_ROTATION ?
        window.Orientation.AUTO_ROTATION_RESTRICTED : original;
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
    RemoteDisplayPolicy.publishDisplayState();
  }

  private static publishDisplayState(): void {
    const external: boolean = RemoteDisplayPolicy.localDisplayId >= 0 &&
      RemoteDisplayPolicy.currentDisplayId >= 0 &&
      RemoteDisplayPolicy.localDisplayId !== RemoteDisplayPolicy.currentDisplayId;
    AppStorage.setOrCreate('remoteExternalDisplay', external);
    AppStorage.setOrCreate('remoteProjectionDisplayId', RemoteDisplayPolicy.currentDisplayId);
    AppStorage.setOrCreate('remoteOrientationMode', external ?
      RemoteDisplayPolicy.projectionMode : RemoteDisplayPolicy.localMode);
    RemoteDisplayPolicy.publishHdrCapability();
  }

  private static publishHdrCapability(): void {
    let mask: number = 0;
    try {
      // Query the owning window's display, not the phone screen when projected.
      const target = RemoteDisplayPolicy.currentDisplayId >= 0 ?
        display.getDisplayByIdSync(RemoteDisplayPolicy.currentDisplayId) : display.getDefaultDisplaySync();
      for (const format of target.hdrFormats ?? []) {
        if (format === 1) mask |= 1; // VIDEO_HLG
        if (format === 2) mask |= 2; // VIDEO_HDR10
        if (format === 3) mask |= 4; // VIDEO_HDR_VIVID
      }
    } catch (_error) {
      // Older systems / disconnected external displays: never claim HDR output.
    }
    RustDeskNapi.setHdrDisplayFormats(mask);
  }

  static getMainWindow(): window.Window | undefined {
    return RemoteDisplayPolicy.main;
  }

  static refresh(): void {
    const main = RemoteDisplayPolicy.main;
    if (!main) return;
    try {
      RemoteDisplayPolicy.currentDisplayId = main.getWindowProperties().displayId ?? -1;
    } catch (_e) {}
    RemoteDisplayPolicy.publishDisplayState();
    RemoteDisplayPolicy.apply();
  }

  static setActive(active: boolean): void {
    RemoteDisplayPolicy.active = active;
    if (!active) {
      RemoteDisplayPolicy.localMode = RemoteOrientationMode.SYSTEM;
      RemoteDisplayPolicy.projectionMode = RemoteOrientationMode.SYSTEM;
    }
    RemoteDisplayPolicy.publishDisplayState();
    RemoteDisplayPolicy.apply();
  }

  static setOrientationMode(mode: RemoteOrientationMode): void {
    if (!RemoteDisplayPolicy.active || (mode !== RemoteOrientationMode.SYSTEM &&
      mode !== RemoteOrientationMode.PORTRAIT && mode !== RemoteOrientationMode.LANDSCAPE)) return;
    const external = RemoteDisplayPolicy.localDisplayId >= 0 && RemoteDisplayPolicy.currentDisplayId >= 0 &&
      RemoteDisplayPolicy.localDisplayId !== RemoteDisplayPolicy.currentDisplayId;
    if (external) RemoteDisplayPolicy.projectionMode = mode;
    else RemoteDisplayPolicy.localMode = mode;
    AppStorage.setOrCreate('remoteOrientationMode', mode);
    RustDeskNapi.appendDiagnosticLog('projection', `orientation_selected external=${external} mode=${mode}`);
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
      const mode = external ? RemoteDisplayPolicy.projectionMode : RemoteDisplayPolicy.localMode;
      let orientation = RemoteDisplayPolicy.original;
      if (RemoteDisplayPolicy.active) {
        if (mode === RemoteOrientationMode.PORTRAIT) orientation = window.Orientation.PORTRAIT;
        else if (mode === RemoteOrientationMode.LANDSCAPE || (external && wide)) {
          orientation = window.Orientation.LANDSCAPE;
        } else orientation = window.Orientation.AUTO_ROTATION_RESTRICTED;
      }
      if (main.getPreferredOrientation() !== orientation) await main.setPreferredOrientation(orientation);
      RustDeskNapi.appendDiagnosticLog('projection',
        `window_policy active=${RemoteDisplayPolicy.active} external=${external} wide=${wide} mode=${mode} orientation=${orientation}`);
    }).catch(() => {
      RustDeskNapi.appendDiagnosticLog('projection', 'orientation_apply_failed');
    });
  }
}
