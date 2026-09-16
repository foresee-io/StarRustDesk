import { ApiBook, ApiPeer, ApiFailure, RustDeskApiService, AccountSession } from '../service/RustDeskApiService';
import { ApiAddressBookImport } from '../service/ApiAddressBookImport';
import { RustDeskNapi } from '../service/RustDeskNapi';
import { ButtonShapeModifier } from '../theme/ButtonShapeModifier';

@CustomDialog
export struct ApiAccountDialog {
  controller: CustomDialogController;
  @StorageLink('isDarkMode') isDarkMode: boolean = false;
  @StorageLink('roundedRectButtons') roundedRectButtons: boolean = true;
  @State server: string = '';
  @State provider: string = 'official';
  @State username: string = '';
  @State password: string = '';
  @State code: string = '';
  @State allowHttp: boolean = false;
  @State remember: boolean = false;
  @State authorizeConnections: boolean = false;
  @State busy: boolean = false;
  @State loggedIn: boolean = false;
  @State challenge: string = '';
  @State message: string = '';
  @State books: ApiBook[] = [];
  @State peers: ApiPeer[] = [];
  @State selected: string[] = [];
  @State bookIndex: number = -1;
  private api: RustDeskApiService = AccountSession.getApi();
  private alive: boolean = true;

  aboutToAppear(): void {
    this.alive = true;
    this.server = RustDeskNapi.getOption('api-server');
    this.provider = RustDeskNapi.getOption('api-account-provider') === 'thirdParty' ? 'thirdParty' : 'official';
    this.initialize();
  }
  aboutToDisappear(): void {
    this.alive = false;
    this.password = ''; this.code = '';
    this.api.cancel();
  }
  async initialize(): Promise<void> {
    this.busy = true;
    try {
      this.loggedIn = this.api.isLoggedIn() || await this.api.restore();
      if (!this.alive) return;
      if (this.loggedIn) {
        this.server = this.api.server; this.provider = this.api.provider;
        this.username = this.api.username; this.allowHttp = this.api.allowHttp;
        this.message = this.api.warning;
        this.books = await this.api.books();
      }
    } catch (error) { this.showError(error as Error); }
    finally { if (this.alive) this.busy = false; }
  }
  showError(error: Error): void {
    if (!this.alive) return;
    this.message = error instanceof ApiFailure ? error.message : '操作失败，请稍后重试';
    this.loggedIn = this.api.isLoggedIn();
    if (!this.loggedIn) { this.books = []; this.peers = []; this.selected = []; }
  }
  async login(): Promise<void> {
    this.busy = true; this.message = '';
    try {
      if (!this.challenge) {
        this.api.configure(this.server, this.provider, this.allowHttp);
        this.loggedIn = await this.api.login(this.username, this.password, this.remember, this.authorizeConnections);
      } else { this.loggedIn = await this.api.verify(this.code); }
      if (!this.alive) return;
      this.challenge = this.api.challenge;
      this.message = this.api.warning;
      if (this.loggedIn) { this.username = this.api.username; this.books = await this.api.books(); }
    } catch (error) { this.showError(error as Error); this.challenge = this.api.challenge; }
    finally { this.password = ''; this.code = ''; if (this.alive) this.busy = false; }
  }
  async logout(): Promise<void> {
    this.busy = true;
    await this.api.logout();
    if (!this.alive) return;
    this.loggedIn = false; this.challenge = ''; this.peers = []; this.books = []; this.selected = [];
    this.message = this.api.warning || '已退出账号，本地已保存连接不受影响';
    this.busy = false;
  }
  async refreshBooks(): Promise<void> {
    this.busy = true; this.peers = []; this.selected = []; this.bookIndex = -1;
    try { this.books = await this.api.books(); }
    catch (error) { this.showError(error as Error); }
    finally { if (this.alive) this.busy = false; }
  }
  async loadBook(index: number): Promise<void> {
    this.busy = true; this.message = ''; this.peers = []; this.selected = []; this.bookIndex = index;
    try {
      const peers = await this.api.peers(this.books[index]);
      if (this.alive) { this.peers = peers; this.message = `已获取 ${peers.length} 台设备，请勾选后导入`; }
    } catch (error) { this.showError(error as Error); }
    finally { if (this.alive) this.busy = false; }
  }
  toggle(id: string): void {
    this.selected = this.selected.includes(id) ? this.selected.filter((item: string) => item !== id) : this.selected.concat([id]);
  }
  importPeers(): void {
    try {
      const count = ApiAddressBookImport.importSelected(this.books[this.bookIndex],
        this.peers.filter((peer: ApiPeer) => this.selected.includes(peer.id)));
      this.message = `已新增 ${count} 台设备；已有设备已跳过，未覆盖密码或修改服务器地址`;
      this.selected = [];
    } catch (error) { this.showError(error as Error); }
  }
  textColor(): ResourceColor { return this.isDarkMode ? '#EFF4FB' : '#17253D'; }
  secondaryColor(): ResourceColor { return this.isDarkMode ? '#B6C4D7' : '#60728B'; }
  bookOptions(): SelectOption[] {
    const options: SelectOption[] = [];
    this.books.forEach((book: ApiBook) => { options.push({ value: book.name }); });
    return options;
  }

  @Builder
  action(label: string, selected: boolean, enabled: boolean, handler: () => void) {
    Button(label).height(38).fontSize(13).fontColor(this.isDarkMode ? '#C5DFFF' : '#2763AC')
      .backgroundColor(this.isDarkMode ? (selected ? '#314E71' : '#27384D') : (selected ? '#CFE3FF' : '#EEF4FC'))
      .enabled(enabled).onClick(handler)
      .attributeModifier(new ButtonShapeModifier(this.roundedRectButtons, 12, ButtonType.Capsule));
  }
  build() {
    Column({ space: 12 }) {
      Row() {
        Text('服务器账号与地址簿').fontSize(19).fontWeight(FontWeight.Bold).fontColor(this.textColor()).layoutWeight(1);
        this.action(this.busy ? '取消请求' : '关闭', false, true, () => {
          this.api.cancel();
          if (!this.busy) this.controller.close();
        });
      }.width('100%');
      Scroll() {
        Column({ space: 12 }) {
          Row({ space: 8 }) {
            this.action('官方 Server Pro', this.provider === 'official', !this.busy && !this.loggedIn && !this.challenge,
              () => { this.provider = 'official'; });
            this.action('第三方 rustdesk-api', this.provider === 'thirdParty', !this.busy && !this.loggedIn && !this.challenge,
              () => { this.provider = 'thirdParty'; });
          }.width('100%');
          TextInput({ text: this.server, placeholder: 'API 地址，例如 https://api.example.com' }).fontSize(14)
            .enabled(!this.loggedIn && !this.busy && !this.challenge).onChange((value: string) => { this.server = value; });
          if (!this.loggedIn && !this.challenge) {
            Row() {
              Checkbox({ name: 'allowHttp' }).select(this.allowHttp).enabled(!this.busy)
                .onChange((value: boolean) => { this.allowHttp = value; });
              Text('允许 HTTP（账号密码和令牌可能被窃听）').fontSize(12).fontColor(this.secondaryColor()).layoutWeight(1);
            }.width('100%');
            TextInput({ text: this.username, placeholder: '服务器账号，不是远端设备 ID' }).enabled(!this.busy)
              .onChange((value: string) => { this.username = value; }).maxLength(128);
            TextInput({ text: this.password, placeholder: '账号密码' }).type(InputType.Password).enabled(!this.busy)
              .onChange((value: string) => { this.password = value; }).maxLength(256);
            Row() {
              Checkbox({ name: 'rememberApi' }).select(this.remember).enabled(!this.busy)
                .onChange((value: boolean) => { this.remember = value; });
              Text('记住登录（仅令牌保存在本机安全存储）').fontSize(12).fontColor(this.secondaryColor()).layoutWeight(1);
            }.width('100%');
            Row() {
              Checkbox({ name: 'authorizeConnections' }).select(this.authorizeConnections).enabled(!this.busy)
                .onChange((value: boolean) => { this.authorizeConnections = value; });
              Text('用于当前自建 ID 服务器的连接权限认证（需公钥）')
                .fontSize(12).fontColor(this.secondaryColor()).layoutWeight(1);
            }.width('100%');
            this.action('登录', true, !this.busy, () => { this.login(); });
          } else if (!this.loggedIn) {
            Text(this.challenge === 'email' ? '请输入邮箱验证码' : '请输入身份验证器验证码')
              .fontSize(14).fontColor(this.textColor());
            TextInput({ text: this.code, placeholder: '6 位验证码' }).maxLength(6).type(InputType.Number)
              .enabled(!this.busy).onChange((value: string) => { this.code = value; });
            Row({ space: 8 }) {
              this.action('验证', true, !this.busy, () => { this.login(); });
              this.action('重新登录', false, !this.busy, () => { this.api.cancel(); this.challenge = ''; this.code = ''; });
            }
          } else {
            Row({ space: 8 }) {
              Text(`已登录：${this.username}`).fontSize(14).fontColor(this.textColor()).layoutWeight(1);
              this.action('刷新', false, !this.busy, () => { this.refreshBooks(); });
              this.action('退出', false, !this.busy, () => { this.logout(); });
            }.width('100%');
            Select(this.bookOptions())
              .value(this.bookIndex >= 0 ? this.books[this.bookIndex]?.name : '选择个人或共享地址簿')
              .enabled(!this.busy).width('100%').onSelect((index: number) => { this.loadBook(index); });
            if (this.peers.length > 0) {
              Row({ space: 8 }) {
                this.action(this.selected.length === this.peers.length ? '取消全选' : '全选', false, !this.busy, () => {
                  this.selected = this.selected.length === this.peers.length ? [] : this.peers.map((peer: ApiPeer) => peer.id);
                });
                this.action(`导入已选 (${this.selected.length})`, true, !this.busy && this.selected.length > 0, () => { this.importPeers(); });
              }.width('100%');
              ForEach(this.peers, (peer: ApiPeer) => {
                Row({ space: 8 }) {
                  Checkbox({ name: peer.id }).select(this.selected.includes(peer.id)).onChange(() => { this.toggle(peer.id); });
                  Column({ space: 3 }) {
                    Text(peer.name).fontSize(15).fontColor(this.textColor()).width('100%');
                    Text(`${peer.id} · ${peer.platform || '设备'}${peer.tags.length > 0 ? ' · ' + peer.tags.join(' / ') : ''}`)
                      .fontSize(12).fontColor(this.secondaryColor()).width('100%');
                  }.layoutWeight(1);
                }.width('100%').padding({ top: 8, bottom: 8 });
              }, (peer: ApiPeer) => peer.id);
            }
          }
          if (this.busy) { Text('正在请求服务器…').fontSize(13).fontColor(this.secondaryColor()); }
          if (this.message) { Text(this.message).fontSize(13).fontColor(this.textColor()).width('100%'); }
          Text('API 用于账号和地址簿，不替代 ID/中继服务器。导入后沿用当前中继配置，请确保属于同一网络。不会自动上传本地连接；不导入远端密码或密码哈希。')
            .fontSize(12).fontColor(this.secondaryColor()).width('100%');
        }.width('100%');
      }.width('100%').layoutWeight(1).scrollBar(BarState.Auto);
    }.padding(20).width('94%').constraintSize({ maxWidth: 600 }).height('86%')
      .borderRadius(20).backgroundColor(this.isDarkMode ? '#1E2A3A' : '#FFFFFF');
  }
}
