import { rcp } from '@kit.RemoteCommunicationKit';
import { url, util } from '@kit.ArkTS';
import { RustDeskNapi } from './RustDeskNapi';
import { ApiAccountStore, ApiSession } from './ApiAccountStore';

export interface ApiPeer {
  id: string;
  name: string;
  platform: string;
  tags: string[];
}
export interface ApiBook {
  guid: string;
  name: string;
  legacy: boolean;
}
interface ApiUser { name?: string; display_name?: string; }
interface ApiRow {
  id?: string; alias?: string; hostname?: string; platform?: string; tags?: string[];
  guid?: string; name?: string; owner?: string;
}
interface ApiReply {
  error?: string; access_token?: string; type?: string; tfa_type?: string; secret?: string;
  user?: ApiUser; name?: string; guid?: string; total?: number;
  data?: string | ApiRow[]; peers?: ApiRow[];
}
interface LoginDevice { name: string; os: string; type: string; }
interface LoginBody {
  username?: string; password?: string; id: string; uuid: string; autoLogin: boolean;
  type: string; deviceInfo: LoginDevice; secret?: string; verificationCode?: string; tfaCode?: string;
}
interface ClientIdentity { id: string; uuid: string; }
interface AccountTransport { token: string; rendezvous: string; key: string; }

export class ApiFailure extends Error {
  status: number;
  constructor(message: string, status: number = 0) { super(message); this.status = status; }
}

export class AccountSession {
  private static instance: RustDeskApiService | undefined = undefined;
  static getApi(): RustDeskApiService {
    if (!AccountSession.instance) AccountSession.instance = new RustDeskApiService();
    return AccountSession.instance;
  }
}

export class RustDeskApiService {
  server: string = '';
  provider: string = 'official';
  username: string = '';
  allowHttp: boolean = false;
  challenge: string = '';
  warning: string = '';
  private token: string = '';
  private secret: string = '';
  private remember: boolean = false;
  private epoch: number = 0;
  private requests: rcp.Session[] = [];
  private boundRendezvous: string = '';
  private boundKey: string = '';
  private restorePromise: Promise<boolean> | undefined = undefined;
  private restoring: boolean = false;

  static normalizeServer(value: string, allowHttp: boolean): string {
    if (value.length > 2048) throw new ApiFailure('API 地址过长');
    let parsed: url.URL;
    try { parsed = new url.URL(value.trim()); } catch (_e) { throw new ApiFailure('请输入完整 API 地址，例如 https://api.example.com'); }
    if (parsed.protocol !== 'https:' && !(allowHttp && parsed.protocol === 'http:')) {
      throw new ApiFailure('默认只允许 HTTPS；确需 HTTP 时请明确勾选风险确认');
    }
    if (!parsed.hostname || parsed.username || parsed.password || parsed.search || parsed.hash) {
      throw new ApiFailure('API 地址不能包含账号、密码、查询参数或片段');
    }
    return parsed.toString().replace(/\/+$/, '').replace(/\/api$/, '');
  }

  isLoggedIn(): boolean { return this.token.length > 0 && !this.restoring; }

  configure(server: string, provider: string, allowHttp: boolean): void {
    const normalized = RustDeskApiService.normalizeServer(server, allowHttp);
    if (provider !== 'official' && provider !== 'thirdParty') throw new ApiFailure('不支持的 API 类型');
    this.cancel();
    RustDeskNapi.setApiAccountContext('');
    this.boundRendezvous = ''; this.boundKey = '';
    this.server = normalized;
    this.provider = provider;
    this.allowHttp = allowHttp;
    this.token = ''; this.username = ''; this.challenge = ''; this.secret = ''; this.warning = '';
  }

  cancel(): void {
    this.epoch++;
    this.requests.forEach((session: rcp.Session) => { session.cancel(); });
    this.secret = ''; this.challenge = '';
  }

  async restore(): Promise<boolean> {
    if (this.isLoggedIn()) return true;
    if (this.restorePromise) return this.restorePromise;
    this.restoring = true;
    this.restorePromise = this.restoreStored();
    try { return await this.restorePromise; }
    finally { this.restorePromise = undefined; this.restoring = false; }
  }

  private async restoreStored(): Promise<boolean> {
    const epoch = this.epoch;
    const saved = await ApiAccountStore.load();
    if (epoch !== this.epoch) throw new ApiFailure('请求已取消');
    if (!saved) return false;
    // A backup or manual server change must not silently restore the old account.
    const configuredServer = RustDeskNapi.getOption('api-server');
    if (!configuredServer || RustDeskApiService.normalizeServer(configuredServer, saved.allowHttp === true) !== saved.server) return false;
    this.configure(saved.server, saved.provider, saved.allowHttp === true);
    const restoreEpoch = this.epoch;
    this.token = saved.token; this.username = saved.username; this.remember = true;
    this.boundRendezvous = saved.boundRendezvous || ''; this.boundKey = saved.boundKey || '';
    try {
      const user = await this.request('/api/currentUser', 'POST', JSON.stringify(this.identity()));
      if (typeof user.name !== 'string' || user.name.length === 0) throw new ApiFailure('服务器返回的账号信息无效');
      this.username = user.name;
      this.publishTransport();
      return true;
    } catch (error) {
      if (this.epoch === restoreEpoch) {
        this.token = '';
        RustDeskNapi.setApiAccountContext('');
      }
      throw error as Error;
    }
  }

  private publishTransport(): void {
    RustDeskNapi.setApiAccountContext('');
    if (!this.boundRendezvous) return;
    if (RustDeskNapi.getOption('custom-rendezvous-server').trim() !== this.boundRendezvous ||
      RustDeskNapi.getOption('key').trim() !== this.boundKey || RustDeskNapi.getOption('api-server') !== this.server) {
      this.warning = '服务器配置已改变，账号连接认证未启用；请在新网络下重新登录绑定';
      return;
    }
    const context: AccountTransport = { token: this.token, rendezvous: this.boundRendezvous, key: this.boundKey };
    if (RustDeskNapi.setApiAccountContext(JSON.stringify(context)) !== 0) {
      this.warning = '已登录地址簿，但 ID 服务器公钥无效，账号连接认证未启用';
    }
  }

  private identity(): ClientIdentity {
    let uuid = RustDeskNapi.getOption('api-client-uuid');
    if (!uuid) { uuid = util.generateRandomUUID(true); RustDeskNapi.setOption('api-client-uuid', uuid); }
    let id = RustDeskNapi.getOption('client-id');
    if (!id) {
      id = `harmony-${uuid.replace(/-/g, '').slice(0, 16)}`;
      RustDeskNapi.setOption('client-id', id);
    }
    return { id: id, uuid: uuid };
  }

  async login(username: string, password: string, remember: boolean, authorizeConnections: boolean = false): Promise<boolean> {
    if (!username.trim() || !password) throw new ApiFailure('请输入账号和密码');
    this.token = ''; this.secret = ''; this.challenge = '';
    RustDeskNapi.setApiAccountContext('');
    this.boundRendezvous = authorizeConnections ? RustDeskNapi.getOption('custom-rendezvous-server').trim() : '';
    this.boundKey = authorizeConnections ? RustDeskNapi.getOption('key').trim() : '';
    if (authorizeConnections && (!this.boundRendezvous || !this.boundKey)) {
      throw new ApiFailure('请先在服务器配置中填写自建 ID 服务器及公钥，再启用账号连接认证');
    }
    const epoch = this.epoch;
    await ApiAccountStore.clear();
    if (epoch !== this.epoch) throw new ApiFailure('请求已取消');
    this.remember = remember;
    this.username = username.trim();
    const identity = this.identity();
    const body: LoginBody = {
      username: this.username, password: password, id: identity.id, uuid: identity.uuid,
      autoLogin: remember, type: 'account', deviceInfo: { name: RustDeskNapi.getDeviceName(), os: 'HarmonyOS', type: 'client' }
    };
    return this.acceptLogin(await this.request('/api/login', 'POST', JSON.stringify(body), false));
  }

  async verify(code: string): Promise<boolean> {
    if (!this.secret || !/^\d{6}$/.test(code)) throw new ApiFailure('请输入 6 位验证码');
    const identity = this.identity();
    // Upstream sends email_code for both email and TOTP, with tfaCode for TOTP.
    const body: LoginBody = {
      username: this.username, id: identity.id, uuid: identity.uuid, autoLogin: this.remember,
      type: 'email_code', secret: this.secret, verificationCode: code,
      deviceInfo: { name: RustDeskNapi.getDeviceName(), os: 'HarmonyOS', type: 'client' }
    };
    if (this.challenge !== 'email') body.tfaCode = code;
    return this.acceptLogin(await this.request('/api/login', 'POST', JSON.stringify(body), false));
  }

  private async acceptLogin(reply: ApiReply): Promise<boolean> {
    if (reply.type === 'email_check' || reply.type === 'tfa_check') {
      if (typeof reply.secret !== 'string' || !reply.secret || reply.secret.length > 16384) throw new ApiFailure('二次验证响应无效');
      this.secret = reply.secret;
      this.challenge = reply.type === 'email_check' || reply.tfa_type === 'email' ? 'email' : 'totp';
      if (reply.user && typeof reply.user.name === 'string') this.username = reply.user.name;
      return false;
    }
    if (reply.type !== 'access_token' || typeof reply.access_token !== 'string' ||
      !reply.access_token || reply.access_token.length > 16384 || /[\r\n]/.test(reply.access_token)) {
      throw new ApiFailure('服务器未返回兼容的登录令牌；网页 SSO 登录暂未接入');
    }
    this.token = reply.access_token; this.secret = ''; this.challenge = '';
    if (reply.user && typeof reply.user.name === 'string') this.username = reply.user.name;
    RustDeskNapi.setOption('api-server', this.server);
    RustDeskNapi.setOption('api-account-provider', this.provider);
    this.publishTransport();
    if (this.remember) {
      const saved: ApiSession = { server: this.server, provider: this.provider, token: this.token,
        username: this.username, allowHttp: this.allowHttp, boundRendezvous: this.boundRendezvous, boundKey: this.boundKey };
      try { await ApiAccountStore.save(saved); }
      catch (_e) { this.warning = '已登录，但安全存储失败；退出应用后需要重新登录'; }
    }
    return true;
  }

  async logout(): Promise<void> {
    try { if (this.token) await this.request('/api/logout', 'POST', JSON.stringify(this.identity())); }
    catch (_e) { this.warning = '本机已退出；服务器注销未确认，可在服务端撤销会话'; }
    finally {
      this.cancel(); this.token = ''; this.username = ''; this.remember = false;
      RustDeskNapi.setApiAccountContext('');
      await ApiAccountStore.clear();
    }
  }

  async books(): Promise<ApiBook[]> {
    const books: ApiBook[] = [];
    let personal: ApiReply = {};
    try { personal = await this.request('/api/ab/personal', 'POST'); }
    catch (error) { if (!(error instanceof ApiFailure) || error.status !== 404) throw error as Error; }
    if (typeof personal.guid === 'string' && personal.guid.length > 0) {
      books.push({ guid: personal.guid, name: '个人地址簿', legacy: false });
    } else { books.push({ guid: '', name: '个人地址簿（旧版）', legacy: true }); }
    const seen: string[] = books.map((book: ApiBook) => book.guid);
    for (let page = 1; page <= 20; page++) {
      let result: ApiReply;
      try { result = await this.request(`/api/ab/shared/profiles?current=${page}&pageSize=100`, 'POST'); }
      catch (error) { if (error instanceof ApiFailure && error.status === 404) break; throw error as Error; }
      if (result.data === undefined || result.data === null) break;
      if (!Array.isArray(result.data)) throw new ApiFailure('共享地址簿格式不兼容');
      let added = 0;
      for (const row of result.data) {
        if (row && typeof row.guid === 'string' && row.guid && !seen.includes(row.guid)) {
          seen.push(row.guid); added++;
          books.push({ guid: row.guid, name: (typeof row.name === 'string' ? row.name : '共享地址簿').slice(0, 100), legacy: false });
        }
      }
      if (!added || result.data.length < 100 || (typeof result.total === 'number' && (result.total === 0 || page * 100 >= result.total))) break;
      if (page === 20) throw new ApiFailure('地址簿数量过多，请在服务端缩小范围');
    }
    return books;
  }

  static parsePeers(rows: ApiRow[]): ApiPeer[] {
    const peers: ApiPeer[] = [];
    for (const row of rows) {
      if (!row || typeof row.id !== 'string' || !/^[A-Za-z0-9_-]{1,64}$/.test(row.id)) continue;
      if (peers.some((peer: ApiPeer) => peer.id === row.id)) continue;
      const name = typeof row.alias === 'string' && row.alias ? row.alias :
        (typeof row.hostname === 'string' ? row.hostname : row.id);
      peers.push({ id: row.id, name: name.slice(0, 100), platform: typeof row.platform === 'string' ? row.platform.slice(0, 32) : '',
        tags: Array.isArray(row.tags) ? row.tags.filter((tag: string) => typeof tag === 'string').slice(0, 20) : [] });
    }
    return peers;
  }

  async peers(book: ApiBook): Promise<ApiPeer[]> {
    if (book.legacy) {
      const result = await this.request('/api/ab', 'GET');
      if (result.data === undefined || result.data === null || result.data === '') return [];
      if (typeof result.data !== 'string') throw new ApiFailure('旧版地址簿格式不兼容');
      let data: ApiReply;
      try { data = JSON.parse(result.data) as ApiReply; } catch (_e) { throw new ApiFailure('旧版地址簿内容无效'); }
      if (!data || data.peers === undefined || data.peers === null) return [];
      if (!Array.isArray(data.peers)) throw new ApiFailure('地址簿设备列表无效');
      return RustDeskApiService.parsePeers(data.peers);
    }
    const peers: ApiPeer[] = [];
    for (let page = 1; page <= 50; page++) {
      const result = await this.request(`/api/ab/peers?current=${page}&pageSize=100&ab=${encodeURIComponent(book.guid)}`, 'POST');
      if (result.data === undefined || result.data === null) break;
      if (!Array.isArray(result.data)) throw new ApiFailure('地址簿设备列表无效');
      const rows = RustDeskApiService.parsePeers(result.data);
      let added = 0;
      for (const row of rows) {
        if (!peers.some((peer: ApiPeer) => peer.id === row.id)) { peers.push(row); added++; }
      }
      // Some third-party releases ignore pagination and return 1000 entries.
      // Never spin forever or silently claim a partial list is complete.
      if (typeof result.total === 'number' && result.total > 0 && peers.length >= result.total) break;
      if (!added) {
        if (typeof result.total === 'number' && result.total > peers.length) throw new ApiFailure('服务器未正确分页，设备列表不完整，请升级 API 服务');
        break;
      }
      if (result.data.length < 100 && !(typeof result.total === 'number' && result.total > peers.length)) break;
      if (page === 50) throw new ApiFailure('设备超过分页限制，请在服务端分组后重试');
    }
    return peers;
  }

  private async request(path: string, method: rcp.HttpMethod, content?: string, authenticated: boolean = true): Promise<ApiReply> {
    if (authenticated && !this.token) throw new ApiFailure('请先登录');
    const epoch = this.epoch;
    const session = rcp.createSession();
    this.requests.push(session);
    const chunks: Uint8Array[] = [];
    let size = 0;
    let tooLarge = false;
    const headers: Record<string, string> = { 'Content-Type': 'application/json', 'Accept': 'application/json' };
    if (authenticated) headers['Authorization'] = `Bearer ${this.token}`;
    try {
      const response = await session.fetch(new rcp.Request(this.server + path, method, headers, content,
        undefined, undefined, {
          transfer: { autoRedirect: false, timeout: { connectMs: 10000, transferMs: 15000 } },
          tracing: { verbose: false, httpEventsHandler: { onDataReceive: (buffer: ArrayBuffer): number => {
            size += buffer.byteLength;
            if (size > 2 * 1024 * 1024) { tooLarge = true; session.cancel(); return 0; }
            chunks.push(new Uint8Array(buffer)); return buffer.byteLength;
          } } }
        }));
      if (epoch !== this.epoch) throw new ApiFailure('请求已取消');
      if (tooLarge) throw new ApiFailure('服务器响应超过安全大小限制');
      if (response.statusCode >= 300 && response.statusCode < 400) throw new ApiFailure('API 地址发生跳转，请填写最终地址；为保护凭据已阻止跳转');
      if (response.statusCode === 401) {
        RustDeskNapi.setApiAccountContext('');
        this.token = ''; this.secret = ''; this.challenge = '';
        await ApiAccountStore.clear();
        throw new ApiFailure('账号或密码不正确，或登录已过期，请重新登录', 401);
      }
      if (response.statusCode !== 200) throw new ApiFailure(`API 请求被拒绝（HTTP ${response.statusCode}），请检查地址和账号权限`, response.statusCode);
      const bytes = new Uint8Array(size);
      let offset = 0;
      for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.length; }
      const raw = util.TextDecoder.create('utf-8').decodeToString(bytes);
      if (!raw.trim() || raw.trim() === 'null') return {};
      let reply: ApiReply;
      try { reply = JSON.parse(raw) as ApiReply; } catch (_e) { throw new ApiFailure('服务器没有返回 JSON，请检查 API 地址是否指向网页'); }
      if (!reply || typeof reply !== 'object' || Array.isArray(reply)) throw new ApiFailure('API 响应格式不兼容');
      if (reply.error !== undefined) throw new ApiFailure('服务器拒绝操作，请检查账号密码、验证码、权限及服务端登录策略');
      return reply;
    } catch (error) {
      if (tooLarge) throw new ApiFailure('服务器响应超过安全大小限制');
      if (error instanceof ApiFailure) throw error;
      throw new ApiFailure('API 网络请求失败，请检查网络、端口和 HTTPS 证书');
    } finally {
      this.requests = this.requests.filter((item: rcp.Session) => item !== session);
      session.close();
    }
  }
}
