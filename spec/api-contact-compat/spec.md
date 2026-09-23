# Feature Specification: 自建 API server 通讯录兼容性修复（api-contact-compat）

**Created**: 2026-09-23  
**Status**: Approved  
**Input**: 用户报告：`entry/src/main/ets/service/RustDeskApiService.ets:530` 抛出"服务器未正确分页，设备列表不完整，请升级 API 服务"；同一自建 API server（lejianwen/rustdesk-api，Go 实现）下官方客户端可正常读取通讯录的地址、tag 与备注。要求定位并修复，并按约定提供极简 Python 调试脚本（OIDC 网页登录）引导用户抓取真实数据。

## Overview

修复 OHOS 客户端地址簿拉取的分页兼容性缺陷。根因已通过双方源码比对实证：目标服务器（lejianwen/rustdesk-api）的 `/api/ab/peers` 接口忽略 `current`/`pageSize` 分页参数，每次请求固定返回整表（上限 1000 条）且 `total` 为真实条数；当地址簿中存在被客户端行校验拒绝的条目（空 id、非常规字符 id、超长 id、页内重复行——服务端允许重复行）或条目超过 1000 时，客户端第一页后 `peers.length < total`，继续翻页得到相同数据，`added=0` 且 `total > peers.length`，触发误报。官方客户端（`upstream/flutter/lib/models/ab_model.dart`）因 `total` 只取第一页且从不因计数与行数不符而报错，故表现正常。修复策略（用户已确认）：分页语义完全对齐官方客户端。同时交付调试脚本用于真实数据印证与修复验证。

## User Scenarios & Testing *(mandatory)*

### User Story 1 - 正常读取自建 server 通讯录 (Priority: P1)

用户在 OHOS 客户端登录 lejianwen/rustdesk-api 自建 server，打开地址簿同步/账号对话框，客户端应成功读取并展示完整通讯录（地址、tag、备注/别名），不再抛出"服务器未正确分页，设备列表不完整，请升级 API 服务"。

**Why this priority**: 这是用户报告的核心缺陷，直接阻断地址簿功能；官方客户端在同一服务器上完全正常，用户预期我方行为一致。

**Independent Test**: 对存在非常规条目（重复行/特殊 id）的地址簿执行拉取，能获得与官方客户端一致可见的设备列表，全程无分页报错。

**Acceptance Scenarios**:

1. **Given** 地址簿含 ≤1000 条且其中存在重复行或 id 含 `.` 等非常规字符的条目，**When** 客户端拉取该地址簿，**Then** 成功返回可解析的设备列表，不抛分页错误。
2. **Given** 服务器忽略分页参数（每次返回同一份 ≤1000 条数据、total 为真实条数），**When** 客户端分页拉取，**Then** 第一页取到全部数据后正常终止循环，不发起无意义的第二页请求后报错。
3. **Given** 服务器行为与官方 Pro server 一致（正确分页），**When** 客户端跨多页拉取 >100 条的地址簿，**Then** 仍能取全所有页数据（不回归）。
4. **Given** 服务器未返回 `total` 字段或 `total` 为字符串，**When** 客户端拉取，**Then** 仍能依据"短页/无新增行"保底条件正确终止并返回已获数据。
5. **Given** strict 模式（同步预览/应用）下拉取，**When** 返回行含无效或重复记录，**Then** 仍按既有 strict 校验报"设备列表含无效或重复记录"（该安全行为保持不变）。

---

### User Story 2 - 调试脚本抓取真实服务器数据 (Priority: P2)

用户运行 `./debug-util` 下的极简 Python 脚本，指定 API server 地址后，脚本经 RustDesk OIDC 网页授权流程登录（打开浏览器授权、轮询换取 token），随后拉取调试所需接口的原始响应（登录选项、个人地址簿 guid、共享地址簿、地址簿 peers 多页、tags、旧版 /api/ab），连同结构分析摘要落盘到 debug-util 目录，然后退出。token 不落盘。

**Why this priority**: 用于印证根因（确认用户地址簿中具体哪些行被客户端行校验拒绝、服务器 total 与实际返回的差异）并验证修复效果；非阻塞性交付，故为 P2。

**Independent Test**: 在配置了 OIDC 登录的 lejianwen/rustdesk-api 上运行脚本，浏览器完成授权后，脚本自动完成数据拉取并在 debug-util 下生成原始响应文件与分析摘要。

**Acceptance Scenarios**:

1. **Given** 服务器启用了 OIDC 网页登录，**When** 用户运行脚本并提供 server 地址，**Then** 脚本列出可用登录方式、发起授权并在浏览器打开授权页，轮询直至取得 access_token。
2. **Given** 已取得 token，**When** 脚本拉取调试数据，**Then** 原始 JSON 响应（含 HTTP 状态码）逐接口保存为文件，并生成摘要：每页 total 的值与类型、data 行数、id 字段类型样本、跨页重复行数量。
3. **Given** 授权超时（用户未在时限内完成浏览器授权），**When** 轮询到达上限，**Then** 脚本明确提示超时并退出，不残留挂起状态。

---

### Edge Cases

- 地址簿条目超过 1000 条（服务器单页上限）：客户端应在其分页保护上限（50 页/5000 条）内尽力获取，并在达到上限时报既有"设备超过分页限制"错误，而非"未正确分页"。
- 服务器返回 `total=0` 但 data 非空：按官方语义接受 data。
- 服务器返回空 data 且 `total>0`（计数虚高）：接受已获数据并终止，不报错。
- 用户在脚本浏览器授权未完成时 Ctrl+C：脚本应干净退出。
- 脚本面对自签名证书/HTTP 部署：提供明确的风险确认开关，默认拒绝。

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: 客户端地址簿分页拉取 MUST 对齐官方客户端语义：`total` 只取第一个非零页的报告值，作为循环终止参考，而非逐页校验数据完整性的依据。
- **FR-002**: 分页循环 MUST 在满足以下任一条件时终止并接受已获取数据：按第一页 total 推断已取完（页码×页大小 ≥ total）；本页未新增任何行（空页或整页重复）；本页为短页（行数小于请求页大小且 total 未表明还有更多）；达到 50 页上限。
- **FR-003**: 分页循环 MUST NOT 因 `total` 与实际累计行数不符而抛出"服务器未正确分页"类错误（移除该误报路径）。
- **FR-004**: 既有安全设施 MUST 保持不变：strict 模式行校验（无效/重复记录报错）、50 页上限报错、单响应 2MB 限制、行级 id 格式过滤（parsePeers 行为不变）。
- **FR-005**: 修复 MUST NOT 改变跨页去重合并、legacy 地址簿路径、写入路径（writePeer/deletePeer）的行为。
- **FR-006**: 调试脚本 MUST 为单文件、仅依赖 Python 标准库，放置于已被 git 忽略的 `./debug-util`。
- **FR-007**: 调试脚本 MUST 仅支持 OIDC 网页登录（用户已确认）：通过 login-options 发现登录方式、发起授权、打开浏览器、轮询换取 token；不实现账密登录。
- **FR-008**: 调试脚本 MUST 拉取并原样落盘以下调试数据：login-options、/api/ab/personal、/api/ab/shared/profiles、/api/ab/peers（连续多页，页大小 100，含响应原始 JSON 与 HTTP 状态）、/api/ab/tags/{guid}、旧版 GET /api/ab（容忍 404）。
- **FR-009**: 调试脚本 MUST 生成结构分析摘要：各页 total 值与 JSON 类型、data 行数、id 字段类型分布、跨页重复 id 数量、被 OHOS 客户端行校验拒绝的行清单（含原因分类）。
- **FR-010**: 调试脚本 MUST NOT 将 access_token 写入任何落盘文件。
- **FR-011**: 调试脚本 MUST 支持 HTTP/自签名证书场景的显式风险确认开关（非 HTTPS 时要求命令行显式确认）。

### Key Entities

- **ApiPeer（客户端既有）**: id、name、platform、tags；由服务器返回行经行校验解析而来。
- **分页响应（服务器契约）**: `total`（条目总数，可能缺失/类型不稳）、`data`（行数组，可能为空、含重复、含非常规 id 行）、`licensed_devices` 等额外字段须容忍。
- **调试快照（脚本产出）**: 按接口逐文件的原始响应 + 一份机器可读摘要（summary），存放于 debug-util 下的时间戳子目录。

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: 对用户报告的同一自建 server 与同一账号，修复后客户端拉取地址簿 0 次出现"服务器未正确分页"错误，成功进入设备列表展示。
- **SC-002**: 与官方客户端同账号同地址簿对比，客户端可读到的设备条目数不少于官方客户端（在官方语义允许的范围内）。
- **SC-003**: 修复涉及的行为变更 100% 局限于分页循环终止与误报路径；strict 行校验、页上限、响应大小限制相关代码路径保持原语义（以代码审查与构建验证为准）。
- **SC-004**: 调试脚本在启用 OIDC 的服务器上一次性完成"授权→拉取→落盘→退出"全流程，落盘文件包含全部目标接口原始响应与摘要。

## Assumptions

- 用户服务器为 lejianwen/rustdesk-api 且已启用 OIDC 网页登录（用户已确认）；脚本 OIDC 流程遵循该服务器与官方客户端共同的 `/api/oidc/auth` + `/api/oidc/auth-query` 轮询契约。
- 地址簿规模在 50 页×100 条保护上限内（超过则保留既有上限报错，视为服务器端需分组）。
- `parsePeers` 丢弃非常规行是既有设计（防止无效数据进入本地），本修复不改变该过滤，仅消除"因过滤导致 total 对不上而误报"的连锁反应。
- debug-util 已被 git 忽略（用户已声明），脚本与其产出物不会进入版本库。
- 修复后与官方客户端的兼容基线为"读取"行为；写入路径行为不在本次对比范围。

## Open Questions

- （已由用户提供服务器源码 ../api 与真实数据抓取约定解决，无遗留阻塞项。）
