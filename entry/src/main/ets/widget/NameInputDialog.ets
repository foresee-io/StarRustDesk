@CustomDialog
export struct NameInputDialog {
  controller: CustomDialogController;
  title: string = '';
  initial: string = '';
  onSubmit: (name: string) => void = () => {};
  @State name: string = '';
  @StorageLink('isDarkMode') dark: boolean = false;
  aboutToAppear(): void { this.name = this.initial; }
  build() {
    Column({ space: 16 }) {
      Text(this.title).fontSize(18).fontWeight(FontWeight.Bold).fontColor(this.dark ? '#EFF4FB' : '#17253D')
      TextInput({ text: this.name, placeholder: '请输入名称' }).maxLength(255)
        .onChange((text: string) => { this.name = text; })
      Row({ space: 12 }) {
        Button('取消').layoutWeight(1).onClick(() => { this.controller.close(); })
        Button('确定').layoutWeight(1).enabled(this.name.trim().length > 0)
          .onClick(() => { this.onSubmit(this.name.trim()); this.controller.close(); })
      }.width('100%')
    }.padding(24).width('90%').constraintSize({ maxWidth: 480 }).borderRadius(20)
      .backgroundColor(this.dark ? '#1E2A3A' : '#FFFFFF')
  }
}
