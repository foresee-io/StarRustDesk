# 连接认证诊断

诊断构建标记：`auth-diagnostics-20260917-r1`。此改动只增强诊断，不改变认证、服务器选择或加密降级策略。

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
