import { translate } from '../utils/I18n'
@CustomDialog
export struct NameInputDialog {
  @StorageLink('uiLanguage') uiLanguage: string = 'zh-Hans'
  controller: CustomDialogController;
  title: string = '';
  initial: string = '';
  onSubmit: (name: string) => void = () => {};
  @State name: string = '';
  @StorageLink('isDarkMode') dark: boolean = false;
  aboutToAppear(): void { this.name = this.initial; }
  build() {
    Column({ space: 16 }) {
      Text(translate(this.title, this.uiLanguage)).fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.dark ? '#EFF4FB' : '#17253D')
      TextInput({ text: this.name, placeholder: translate('请输入名称', this.uiLanguage) }).maxLength(255)
        .onChange((text: string) => { this.name = text; })
      Row({ space: 12 }) {
        Button(translate('取消', this.uiLanguage)).layoutWeight(1).onClick(() => { this.controller.close(); })
        Button(translate('确定', this.uiLanguage)).layoutWeight(1).enabled(this.name.trim().length > 0)
          .onClick(() => { this.onSubmit(this.name.trim()); this.controller.close(); })
      }.width('100%')
    }.padding(24).width('90%').constraintSize({ maxWidth: 480 }).borderRadius(20)
      .backgroundColor(this.dark ? '#1E2A3A' : '#FFFFFF')
  }
}
