# 连接认证诊断

当前诊断构建标记：`public-account-auth-20260918-r2`。本次日志增强不改变认证、服务器选择或加密降级策略。

## 用户复现

1. 在设置中开启诊断日志，并清理旧日志。
2. 使用原来的网络、服务器配置和远端设备重试一次。
3. 失败后导出日志。可在相同网络、相同服务器下使用官方客户端对照，但不要提交账号密码或令牌。

## 新字段

- `connection auth config`：默认/自建服务器、配置公钥/内置公钥/空、公钥是否实际存在。不记录公钥内容。
- `account auth selection`：连接认证上下文是否存在、服务器是否匹配、公钥是否匹配、是否选用了令牌。`context=absent` 只表示没有可用连接认证上下文，不能据此认定用户未登录 API。
- `account rendezvous encryption ready`：携带账号令牌前的 ID 服务器加密通道已建立；建立失败仍不发送令牌。
- `punch request sent ... token_attached`：成功发送的请求是否携带令牌，不表示服务器已认可令牌。文件传输、中继请求有对应字段。
- `rendezvous rejected ... detail`：服务器文本的固定原因码，例如 `token_invalid`、`token_expired`、`token_missing_or_required`、`login_required`、`authentication_required`、`authentication_failed`、`permission_denied`。
- `raw_redacted=true`：服务器错误原文不写入日志，避免回显密码、令牌、地址或注入伪造日志。未命中已知文案时显示 `unrecognized_redacted`，不能把它当作已查明原因。

这些字段是客户端观察与已知错误文案归类，并非服务器认证有效性的独立验证。版本号未因此变更；已发布安装包不会自动获得这些新增日志。

## 2026-09-18：账号恢复与网页登录分阶段日志

以下事件受设置中的诊断日志开关控制，默认关闭；开启后仍从原导出日志入口获取，不增加新的日志文件或上传通道。

- `api-account configured`：官方/第三方类型、公共/自建端点、是否 HTTPS，不记录具体地址。
- `restore_start/restore_join/restore_complete/restore_failed/restore_skip`：恢复开始、复用等待、结果、耗时，以及没有本机账号、API 配置改变或取消等原因。
- `binding_selected`、`transport_auth_ready/skipped/failed`：公共/自建认证绑定或仅地址簿模式，配置变化隔离、原生层拒绝等；ready 只表示上下文交接成功，不等于服务器接受登录。
- `prepare_start/complete/bypass/failed`：连接前是否等待恢复、是否存在令牌、绑定是否匹配；无关地址簿账号故障不阻止匿名连接。
- `connection-auth gate_start/ready/failed/cancelled`：连接准备序号 `generation`、耗时、是否直接 IP、取消/网络配置改变；不记录远端 ID、密码或配置快照。
- `request_start/request_end`：进程内请求序号 `id`、请求所属 `request_epoch`、固定操作名 `op`、是否需要账号认证、结果、阶段、HTTP 状态、系统数字错误码 `error_code`、耗时及响应字节数。`http=0` 表示未收到 HTTP 状态，不能单凭此认定是 DNS/TLS/超时；`error_code=0` 表示未提供可记录的数字错误码，非数字内容一律舍弃。`phase` 区分 transport、http_status、decode、response_format、server_result、response_limit、cancelled。
- `login_start/login_challenge/login_complete/login_rejected`：密码/网页方式、是否记住登录、邮箱/TOTP 挑战、成功/无效令牌响应。不记录用户名、密码、验证码、令牌、设备身份。
- `credential_save_complete/failed`、`credential_invalidated`：安全存储结果，以及服务端确认认证失效后的清理结果。普通网络或 5xx 故障不据此删除持久登录数据。
- `web_options_ready`、`web_authorization_ready`、`web_browser_open_start/complete`、`web_launch_failed`：可用方式数量、授权就绪、浏览器打开阶段及失败阶段；不记录方式名称、提供商 URL、网页登录码。
- `web_pending/web_complete/web_timeout`：累计轮询次数。等待及成功请求仅记录第 1 次、每 15 次；失败请求始终记录，避免每秒重复刷屏。HTTP 成功但登录结果无效仍会记录 `login_rejected`。
- `cancel_requested`、`logout_start/complete`：请求取消和退出状态，帮助识别迟到响应；日志中 `epoch` 为当前本机认证操作代次。
- `account rendezvous encryption`、`webrtc offer encryption`：加密开始/结果/耗时；WebRTC 区分 1500ms 预算超时与握手失败，新连接回退成功/失败单独记录。回退关闭的是 WebRTC offer，不代表同意未加密远控。

安全边界：禁止记录请求体、响应体、Authorization、查询参数、网页 URL、SDP/ICE 内容或异常原文。账号日志仅使用白名单操作名、固定原因、布尔值和数字。WebRTC 初始化与本地端点失败也只记录固定分类。

建议复现时在操作前开启日志：先重试账号登录/恢复，再连接原远端；发生失败后立即导出。登录成功、浏览器成功拉起、认证上下文已绑定、服务器接纳、视频首帧是不同阶段，不能相互替代。
