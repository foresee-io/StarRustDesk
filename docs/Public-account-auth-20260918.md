# 官方账号认证流程补齐（2026-09-18）

## 范围

- 不改版本号；当前版本仍为 1.2.0（1002005）。
- 不改远端密码、二次验证、安全降级授权、地址簿数据及自建服务器隔离策略。
- 未登录且无已保存账号时，继续允许服务器支持的匿名连接；不能把单个 `login_required` 误认为所有公共连接都要求登录。

## 改动

1. API 地址优先使用配置，自建网络按 ID 端口减二推导；公共网络默认 `https://admin.rustdesk.com`。HTTP 仍需要用户明确同意。
2. 官方 API + 默认公共网络自动绑定连接认证。Rust 层使用内置公钥，并限制为公共网络候选服务器；向 ID 服务器发送令牌前必须完成签名校验和加密握手。自建账号仍需显式启用认证及服务器/公钥匹配。
3. 首连等待账号恢复；配置变更、页面离开、取消等使等待中的连接失效。直接 IP 连接不依赖 API 登录。
4. 临时 API 故障不删除安全存储中的令牌，但本次连接明确失败并可重试；401 或 currentUser 的 400 清除失效令牌。启动恢复失败记录固定脱敏事件。
5. 接入官方 `/api/login-options`、`/api/oidc/auth`、`/api/oidc/auth-query` 网页登录契约。仅打开 HTTPS 登录页，每次请求串行轮询，三分钟有效期；取消、超时和迟到响应不可恢复登录。浏览器中完成后返回 App 等待确认。邮箱/TOTP 沿用已有二次验证。
6. “需要账号登录”“令牌无效/过期”“无权限”独立提示，不混同远端设备密码，也不触发未加密降级。
7. 匿名 WebRTC 连接也必须加密协商信息；协商加密设置 1.5 秒预算。不支持握手的服务器使用新连接继续无 WebRTC 的连接尝试，绝不在旧连接明文发送 ICE 信息。
8. 读取超时和连接 EOF/读取失败分开；已断开的套接字不继续发送重试。诊断只记录固定类型/错误枚举，不记录原始服务端文本、令牌、网页登录码或 URL。
9. 补充账号恢复、认证绑定、HTTP 请求编号/状态/耗时、网页登录浏览器跳转/限频轮询、连接等待取消和加密回退诊断。字段与排查方法见 `Connection-auth-diagnostics.md`；诊断默认关闭，不记录凭据或响应原文。

## 官方参考

- https://github.com/rustdesk/rustdesk/blob/master/src/common.rs
- https://github.com/rustdesk/rustdesk/blob/master/src/client.rs
- https://github.com/rustdesk/rustdesk/blob/master/src/ui_session_interface.rs
- https://github.com/rustdesk/rustdesk/blob/master/src/hbbs_http/account.rs
- https://github.com/rustdesk/rustdesk/blob/master/flutter/lib/common/widgets/login.dart
- https://github.com/rustdesk/rustdesk/blob/master/flutter/lib/models/user_model.dart

## 验证与边界

- 本轮验证：49 项 Rust 测试、26 组脚本回归通过；ARM64、x86_64 Release 原生库编译及 Release assembleApp 通过。HAP 内两种架构均核验包含 `public-account-auth-20260918-r2` 标记及 WebRTC 回退日志，ArkTS 产物核验包含账号恢复、请求结果、连接等待和浏览器跳转日志。
- 日志增强回归覆盖默认关闭/立即关闭、固定事件与失败阶段、仅记录数字错误码、每 15 次轮询采样、HTTP/网络/格式/取消/超大响应错误，以及密码、令牌、验证码、用户名、网页登录码、URL 和原始错误不进入日志。
- 回归覆盖公共/自建账号隔离、登录恢复等待/取消/配置变更、过期令牌清理、临时故障重试、网页登录取消/超时/不安全 URL、连接 EOF 及握手失败不泄露凭据。
- 构建通过不等于真实官方服务器账号登录成功；需用户在真机通过自己的账号完成登录，并对原失败远端复测。浏览器跳转、系统后台调度、真实 OIDC 提供商均需真机验证。
- 本轮不提交仓库、不发布 Release、不改变已有正式签名上架包。
