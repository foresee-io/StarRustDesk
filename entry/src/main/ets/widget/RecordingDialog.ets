import { SessionRecording } from '../service/SessionRecording';
import { common } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { OperationDiagnostic } from '../service/OperationDiagnostic';

@CustomDialog
export struct RecordingDialog {
  controller: CustomDialogController;
  @State files: string[] = [];
  @State message: string = '';
  @State busy: boolean = false;
  @StorageLink('isDarkMode') dark: boolean = false;
  aboutToAppear(): void { this.files = SessionRecording.files(getContext(this) as common.UIAbilityContext); }
  async exportFile(name: string): Promise<void> {
    this.busy = true;
    try { this.message = await SessionRecording.exportFile(getContext(this) as common.UIAbilityContext, name) ? '录像已导出' : '已取消，原录像仍保留'; }
    catch (e) { this.message = (e as Error).message || '导出失败，原录像仍保留'; }
    finally { this.busy = false; }
  }
  remove(name: string): void {
    AlertDialog.show({ title: '删除本地录像', message: '确定删除这份录像？', primaryButton: { value: '取消', action: () => {} },
      secondaryButton: { value: '删除', action: () => {
        const trace = new OperationDiagnostic('recording', 'delete');
        try { fileIo.unlinkSync(`${(getContext(this) as common.UIAbilityContext).filesDir}/${name}`); trace.end('completed'); this.aboutToAppear(); }
        catch (_e) { trace.fail(_e as Object); this.message = '删除失败'; }
      } } });
  }
  build() {
    Column({ space: 12 }) {
      Text('远控会话录像').fontSize(20).fontWeight(FontWeight.Bold)
      Text('仅保存远端画面，不含声音；停止、断开或离开后可导出。取消导出不会删除原录像。').fontSize(12)
      Scroll() {
        Column({ space: 10 }) {
          ForEach(this.files, (name: string) => {
            Row({ space: 8 }) {
              Text(name).fontSize(12).layoutWeight(1).maxLines(2)
              Button('导出').height(34).fontSize(12).enabled(!this.busy).onClick(() => { this.exportFile(name); })
              Button('删除').height(34).fontSize(12).enabled(!this.busy).onClick(() => { this.remove(name); })
            }.width('100%')
          }, (name: string) => name)
          if (!this.files.length) { Text('暂无已结束的录像').fontSize(14) }
        }.width('100%')
      }.layoutWeight(1).width('100%')
      Text(this.message).fontSize(13)
      Button('关闭').enabled(!this.busy).onClick(() => { this.controller.close(); })
    }.padding(20).width('94%').constraintSize({ maxWidth: 650 }).height('70%').borderRadius(20)
      .backgroundColor(this.dark ? '#1E2A3A' : '#FFFFFF').foregroundColor(this.dark ? '#EFF4FB' : '#17253D')
  }
}
