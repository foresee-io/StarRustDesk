# 服务器账号与 API 地址簿

入口：设置 → 服务器账号 / API 地址簿。

支持两种服务：官方 RustDesk Server Pro、第三方 lejianwen/rustdesk-api。
使用其兼容 RustDesk 客户端的 `/api` 接口，不是管理后台页面，也不是 ID / 中继端口。

## 当前范围

- 账号密码登录、退出、恢复本机记住的登录。
- 官方邮箱验证码和 TOTP 二次验证。
- 新版个人及共享地址簿、旧版 `/api/ab` 地址簿格式。
- 查看设备名称、ID、平台和标签，勾选后导入本地已保存连接。
- 已存在相同 ID 时跳过，不覆盖本地名称、密码、分组和连接参数。
- 新导入设备存入“地址簿 · 名称”分组，不导入服务端密码或密码哈希。
- 兼容分页响应，检测部分第三方版本忽略分页造成的列表不完整。

本次不包含网页 SSO / OIDC、管理后台功能、设备注册管理、服务端地址簿编辑及双向同步。
不会自动把本地连接上传到 API 服务器。
若用户原本开启华为个人云同步，导入后的本地连接会按既有云同步设置处理。

## Pro 连接权限认证

先在服务器配置中填入同一套服务的 ID 服务器、必要的中继地址和正确公钥。
登录时可勾选“用于当前自建 ID 服务器的连接权限认证”。
账号 token 用于 PunchHoleRequest / RequestRelay，不作为远端设备密码。
远控与独立文件传输均使用此绑定。默认不勾选，普通自建服务器可以仅使用地址簿。

令牌只绑定登录时的 ID 服务器及公钥，不跟随网络切换或服务器发现结果扩散。
发送前必须完成 ID 服务器签名验证和加密握手；失败时不把 token 明文发送，也不自动降级。
这比上游部分旧服务器的明文兼容回退更严格；不支持加密账号认证的服务器请仅使用地址簿模式。
修改服务器配置后需要重新登录并绑定，API 地址不自动改写 ID / 中继地址。

## 安全与退出

- 默认 HTTPS；HTTP 必须明确勾选风险确认。
- 不忽略证书错误，不自动跟随 HTTP 重定向，不向诊断日志记录账号密码、token、验证码或响应正文。
- “记住登录”仅保存 token 到 HarmonyOS AssetStore，禁止同步；不保存账号密码。
- 账号安全存储与连接备份、个人云同步隔离；它们最多包含 API 地址，不包含账号令牌。
- native 连接令牌仅保留内存，不写入常规配置文件。
- 退出、HTTP 401、服务器配置变化会清除 native 令牌。安全存储删除失败时，本机退出标记阻止下次恢复旧令牌。
- 网络异常时服务器注销可能未完成，会明确提示；可在服务端撤销会话。

## 验证

`tools/test-api-account.cjs`：模拟两类服务的登录、二次验证、地址簿分页、重定向拦截、令牌生命周期和安全导入。
Rust 单元测试覆盖网络/公钥绑定及账号 token 注入；还需真实 Pro 和第三方服务端联调确认部署差异。
未提供真实 API 地址和测试账号，因此不能把编译及模拟测试成功等同于线上登录、共享权限、认证远控已验证。

## 上游依据

- https://github.com/rustdesk/rustdesk/blob/master/flutter/lib/models/user_model.dart
- https://github.com/rustdesk/rustdesk/blob/master/flutter/lib/common/hbbs/hbbs.dart
- https://github.com/rustdesk/rustdesk/blob/master/flutter/lib/models/ab_model.dart
- https://github.com/rustdesk/rustdesk/blob/master/src/client.rs
- https://github.com/lejianwen/rustdesk-api/blob/master/http/router/api.go
- https://github.com/lejianwen/rustdesk-api/blob/master/http/controller/api/login.go
- https://github.com/lejianwen/rustdesk-api/blob/master/http/controller/api/ab.go
