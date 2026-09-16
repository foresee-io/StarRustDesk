import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import native from 'libentry.so';
import { RustDeskNapi } from './RustDeskNapi';
import { RemoteSessionBackgroundTask } from './RemoteSessionBackgroundTask';

export class SessionChatMessage {
  id: number = 0;
  text: string = '';
  outgoing: boolean = false;
  time: string = '';
}

// This service is scoped to RemotePage, not a persistent conversation store.
export class CommunicationService {
  static messages: SessionChatMessage[] = [];
  static unread: number = 0;
  static callState: number = 0;
  static muted: boolean = false;
  static notice: string = '';
  static revision: number = 0;
  private static timer: number = -1;
  private static generation: number = 0;
  private static nextId: number = 0;
  private static captureStarted: boolean = false;
  private static audioOverride: boolean = false;
  private static panelOpen: boolean = false;
  private static requesting: boolean = false;
  private static connectedOnce: boolean = false;
  private static hasCallAttempt: boolean = false;
  private static onChange: () => void = () => {};

  static start(onChange: () => void): void {
    CommunicationService.dispose();
    CommunicationService.messages = [];
    CommunicationService.unread = 0;
    CommunicationService.callState = 0;
    CommunicationService.notice = '';
    CommunicationService.connectedOnce = false;
    CommunicationService.hasCallAttempt = false;
    CommunicationService.onChange = onChange;
    CommunicationService.timer = setInterval(() => { CommunicationService.poll(); }, 200);
  }

  static dispose(): void {
    CommunicationService.generation++;
    CommunicationService.requesting = false;
    if (CommunicationService.timer !== -1) { clearInterval(CommunicationService.timer); CommunicationService.timer = -1; }
    CommunicationService.hangup();
    CommunicationService.messages = [];
    CommunicationService.unread = 0;
    CommunicationService.panelOpen = false;
    CommunicationService.onChange = () => {};
  }

  private static changed(): void {
    CommunicationService.revision++;
    CommunicationService.onChange();
  }

  static setPanelOpen(open: boolean): void {
    CommunicationService.panelOpen = open;
    if (open) CommunicationService.unread = 0;
    CommunicationService.changed();
  }

  private static append(text: string, outgoing: boolean): void {
    let message = new SessionChatMessage();
    message.id = ++CommunicationService.nextId;
    message.text = text;
    message.outgoing = outgoing;
    const now = new Date();
    message.time = `${now.getHours().toString().padStart(2, '0')}:${now.getMinutes().toString().padStart(2, '0')}`;
    CommunicationService.messages = CommunicationService.messages.concat([message]).slice(-100);
    if (!outgoing && !CommunicationService.panelOpen) CommunicationService.unread = Math.min(CommunicationService.unread + 1, 99);
    CommunicationService.changed();
  }

  static send(text: string): boolean {
    if (text.trim().length === 0 || text.length > 1000) return false;
    if (native.sendChatMessage(text) !== 0) {
      CommunicationService.notice = '发送失败，请检查远控连接后重试';
      CommunicationService.changed();
      return false;
    }
    CommunicationService.notice = '';
    CommunicationService.append(text, true);
    return true;
  }

  static async call(context: common.UIAbilityContext): Promise<void> {
    if (CommunicationService.requesting || CommunicationService.callState === 1 || CommunicationService.callState === 2) return;
    CommunicationService.requesting = true;
    const generation = CommunicationService.generation;
    try {
      const result = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context,
        ['ohos.permission.MICROPHONE']);
      if (generation !== CommunicationService.generation) return;
      if (result.authResults.length !== 1 || result.authResults[0] !== 0) {
        CommunicationService.notice = '需要麦克风权限才能发起语音通话';
        return;
      }
      if (RustDeskNapi.getConnectionStatus() !== 2 || RemoteSessionBackgroundTask.isAppBackground()) {
        CommunicationService.notice = '请在远控连接正常且应用在前台时呼叫';
        return;
      }
      // Enable the existing receive audio route, but never persist this override.
      RustDeskNapi.setRemoteAudioEnabled(true);
      CommunicationService.audioOverride = true;
      CommunicationService.muted = false;
      if (native.requestVoiceCall() !== 0) {
        CommunicationService.notice = '呼叫发送失败';
        CommunicationService.releaseCapture();
        return;
      }
      CommunicationService.notice = '';
      CommunicationService.hasCallAttempt = true;
      CommunicationService.callState = 1;
    } catch (_error) {
      CommunicationService.notice = '无法申请麦克风权限，请到系统设置检查';
    } finally {
      if (generation === CommunicationService.generation) { CommunicationService.requesting = false; CommunicationService.changed(); }
    }
  }

  static hangup(): void {
    CommunicationService.generation++;
    CommunicationService.requesting = false;
    native.endVoiceCall();
    CommunicationService.releaseCapture();
    CommunicationService.callState = CommunicationService.hasCallAttempt ? 4 : 0;
    CommunicationService.changed();
  }

  static onBackground(): void {
    if (CommunicationService.callState === 1 || CommunicationService.callState === 2 || CommunicationService.requesting) {
      CommunicationService.hangup();
      CommunicationService.notice = '应用已进入后台，语音通话已结束；远控连接按原设置保留';
      CommunicationService.changed();
    }
  }

  static toggleMute(): void {
    if (CommunicationService.callState !== 2) return;
    if (!CommunicationService.muted) {
      native.stopVoiceCapture();
      CommunicationService.captureStarted = false;
      CommunicationService.muted = true;
    } else {
      if (native.startVoiceCapture() !== 0) {
        CommunicationService.hangup();
        CommunicationService.notice = '麦克风恢复失败，通话已结束';
      } else {
        CommunicationService.captureStarted = true;
        CommunicationService.muted = false;
      }
    }
    CommunicationService.changed();
  }

  private static releaseCapture(): void {
    native.stopVoiceCapture();
    CommunicationService.captureStarted = false;
    CommunicationService.muted = false;
    if (CommunicationService.audioOverride) {
      CommunicationService.audioOverride = false;
      RustDeskNapi.setRemoteAudioEnabled(RustDeskNapi.getOption('remote-audio-enabled') !== '0');
    }
  }

  private static poll(): void {
    const connected = RustDeskNapi.getConnectionStatus() === 2;
    if (!connected) {
      if (CommunicationService.connectedOnce) {
        CommunicationService.connectedOnce = false;
        CommunicationService.hangup();
        CommunicationService.messages = [];
        CommunicationService.unread = 0;
        CommunicationService.notice = '远控连接已断开，本次聊天记录已清空';
        CommunicationService.changed();
      }
      return;
    }
    CommunicationService.connectedOnce = true;
    try {
      const received: string[] = JSON.parse(native.takeChatMessages()) as string[];
      received.forEach((text: string) => { CommunicationService.append(text, false); });
      const nativeState = native.getVoiceCallState();
      const state = nativeState === 4 && !CommunicationService.hasCallAttempt ? 0 : nativeState;
      if (state !== CommunicationService.callState) {
        CommunicationService.callState = state;
        if (state === 2 && !CommunicationService.captureStarted && !CommunicationService.muted) {
          if (RemoteSessionBackgroundTask.isAppBackground() || native.startVoiceCapture() !== 0) {
            CommunicationService.hangup();
            CommunicationService.notice = '麦克风启动失败，通话已结束';
          } else { CommunicationService.captureStarted = true; }
        } else if (state !== 1 && state !== 2) {
          CommunicationService.releaseCapture();
        }
        CommunicationService.changed();
      }
    } catch (_error) {
      CommunicationService.hangup();
      CommunicationService.notice = '会话通信异常，请重新连接';
      CommunicationService.changed();
    }
  }
}
