# Implementation Plan: 自建 API server 通讯录兼容性修复（api-contact-compat）

**Input**: Feature specification from `spec/api-contact-compat/spec.md`

## Summary

修复 `RustDeskApiService.peers()`（非 legacy 分支）的分页终止逻辑：将"逐页读取 `total` 并在 `total` 与累计行数不符且无新增行时抛错"的守卫，替换为与官方客户端（`upstream/flutter/lib/models/ab_model.dart` `_fetchPeers`）一致的尽力而为语义——`total` 只取首个非零报告值作循环参考，空页/重复页/短页均接受已获数据并终止，不再抛出"服务器未正确分页"。同时交付 `debug-util/ab_debug.py`：单文件、纯标准库、仅 OIDC 网页登录的调试抓取脚本，用于印证根因与验证修复。

## Technical Context

**Language/Version**: ArkTS（HarmonyOS，既有工程）；Python 3.8+（仅调试脚本）
**Primary Dependencies**: @kit.RemoteCommunicationKit（rcp，既有）；Python stdlib（urllib/json/webbrowser/ssl/argparse 等）
**State Management**: 不涉及（无 UI/状态变更；沿用工程既有 V1/V2 混合现状，不迁移）
**Storage**: 无新增持久化；调试产出物落盘于 `debug-util/dump/<时间戳>/`（git 已忽略）
**Testing**: `arkts_check` 静态检查 + `build_project` 构建验证；脚本以 `py_compile` 及用户实测（真实 OIDC 服务器）验证
**Target Platform**: HarmonyOS（客户端修复）；Windows/macOS/Linux 终端（调试脚本）
**Project Type**: 既有 HarmonyOS 应用的缺陷修复 + 开发者调试工具
**Performance Goals**: 地址簿拉取请求数不多于官方客户端同场景（≤100 条时单请求；本缺陷服务器上至多多一次冗余翻页）
**Constraints**: 单响应 2MB 限制、50 页上限、strict 行校验等既有安全设施保持原语义
**Scale/Scope**: 修改 1 个既有 ArkTS 文件中的 1 个方法；新增 1 个 Python 脚本文件

## Project Structure

### Documentation (this feature)

```text
spec/api-contact-compat/
├── spec.md              # 需求（已批准）
├── plan.md              # 本文件
└── tasks.md             # Phase 3 产出
```

### Source Code (repository root)

```text
entry/src/main/ets/service/
└── RustDeskApiService.ets   # 修改：仅 peers() 方法非 legacy 分支的分页循环（约 515-537 行区域）

debug-util/                   # 新增（git 已忽略）
├── ab_debug.py               # 调试抓取脚本（单文件）
└── dump/<时间戳>/            # 运行产出（脚本自建）
    ├── login-options.json
    ├── ab-personal.json
    ├── ab-shared-profiles.json
    ├── ab-peers-p1.json ... pN.json
    ├── ab-tags.json
    ├── ab-legacy.json
    └── summary.json          # 结构分析摘要
```

**Structure Decision**: 遵循既有工程架构。修复点位于既有 service 层文件 `entry/src/main/ets/service/RustDeskApiService.ets`，不新增目录、不引入 MVVM 迁移、不拆分文件；调试脚本独立于应用源码树之外（debug-util，非交付物）。涉及文件总数 2（1 改 1 增），与缺陷的最小修复面一致。

## Complexity Tracking

无宪法检查违规，无需豁免说明。

## Research & Decisions

### R1: 分页语义以官方客户端为基准（而非修补性放行）

- **Decision**: 分页循环完全采用官方客户端语义：`total` 仅取第一个报告非零数值的页面（此后不再逐页更新）；循环终止依据"页码×页大小 ≥ 首页 total"或"本页无新增行"或"短页且 total 未表明还有余量"。
- **Rationale**: 根因实证（`../api/http/controller/api/ab.go:551`）表明目标服务器忽略 `current`/`pageSize`、固定返回整表（≤1000）且 `total` 为真实条数；官方客户端在同服务器上不报错的根本原因是其从不把 `total` 当作完整性校验依据。任何"保留抛错、仅放行特定场景"的修补方案都无法覆盖服务器行为的全部变体（忽略分页、total 口径差异、重复行、>1000 条），且用户已明确选择"完全对齐官方语义"。
- **Alternatives considered**: (a) 仅放行空页场景——仍会在"忽略分页参数 + 坏行"组合下继续误报，已否决；(b) 服务器端修复——超出本项目范围。

### R2: 保留三项保底终止条件，防止无进展循环

- **Decision**: 在官方终止条件之外，保留：(1) 本页无新增行即终止（空页/整页重复——该服务器场景下第二页必为重复）；(2) 短页（行数 < 请求页大小）且 total 未表明还有余量时终止（覆盖无 `total`/`total` 为字符串的服务器，行为与现版本一致）；(3) 50 页上限及既有"设备超过分页限制"报错不变。
- **Rationale**: 官方循环仅按 total 计数翻页，在 `total` 缺失或虚高的病态服务器上会发出大量无效请求；无新增行与短页两个保底可将冗余请求控制在一次以内，且不改变任何场景下的最终数据结果（这些条件只在"继续请求也不可能获得新数据"时生效）。
- **Alternatives considered**: 逐页 `peers.length >= total` 提前终止——结果等价，仅节省一次请求；作为可选优化并入"页码×页大小 ≥ total"条件的等价形式实现，不单列。

### R3: `parsePeers` 行过滤保持不变

- **Decision**: 不放宽 id 校验（`/^[A-Za-z0-9_-]{1,64}$/`、类型与去重过滤）；非常规行仍被丢弃，仅消除"丢弃导致 total 对不上→误报"的连锁反应。
- **Rationale**: 该过滤是既有安全设计（防止无效数据进入本地与同步基线）；官方客户端虽不过滤，但"对齐官方"的范围限定在分页终止语义（用户批准的修复策略）。坏行清单可由调试脚本（FR-009）显式暴露给用户，供其在服务端清理。
- **Alternatives considered**: 放宽 id 正则以容纳如含 `.` 的 id——改变本地数据不变量，影响面不可控，已否决。

### R4: 调试脚本仅 OIDC 登录、纯标准库、原始响应落盘

- **Decision**: 脚本登录仅实现 `/api/oidc/auth` + 浏览器授权 + `/api/oidc/auth-query` 轮询契约（与客户端 `startWebLogin`/`pollWebLogin` 及 lejianwen/rustdesk-api 实现一致）；零第三方依赖；每个接口的原始响应体逐文件落盘，另生成 `summary.json` 分析摘要；token 仅存于内存。
- **Rationale**: 用户明确选择仅 OIDC 登录；零依赖保证任意 Python 环境可直接运行；原始响应落盘确保调试证据未经脚本解释污染，摘要另行生成可交叉核验。
- **Alternatives considered**: (a) 支持账密登录——用户已排除；(b) requests 依赖——破坏"极简、免安装"约定。

### R5: 脚本对 HTTP/自签名证书的处理

- **Decision**: 默认仅允许 HTTPS；HTTP 目标或需跳过证书校验时必须显式传入 `--insecure` 开关，否则拒绝启动。
- **Rationale**: 与客户端 `normalizeServer` 的安全立场一致；调试工具不应弱于客户端的安全默认值。

## Data Model

无新增/变更的持久化数据模型。涉及的两个既有内存结构（仅澄清语义，不改字段）：

- **ApiPeer**: `{ id, name, platform, tags }` —— 由服务器行经 `parsePeers` 过滤解析；本修复不触碰。
- **ApiReply**: 服务器响应的宽松类型视图。本修复中 `total` 字段的使用方式变化：从"逐页完整性校验依据"变为"首页捕获、仅作翻页计数参考"；`total` 非数值（如字符串）或缺失时视为未知，循环依赖保底条件终止。

分页循环新增一个方法级局部状态：首页捕获的 `total`（数值，初始 0，仅在仍为 0 且响应含正数值 total 时更新）。

调试快照（脚本产出，非应用数据）：
- **原始响应文件**: 每接口一份，内容为服务器返回的未经改写响应体文本。
- **summary.json**: 机器可读摘要——各页 `{total 值, total JSON 类型, data 行数, id 类型分布, 页内重复 id 数, 被 OHOS 行校验拒绝的行清单（id、原因分类）}`、跨页重复统计、personal guid、共享地址簿条数、各请求 HTTP 状态。

## Contracts & Interfaces

### C1: `/api/ab/peers` 分页契约（客户端侧解释，修复后）

- 请求：`POST /api/ab/peers?current={页码,1起}&pageSize=100&ab={guid}`，Bearer 认证，无 body（维持现状）。
- 响应解释规则（修复后，对齐官方）：
  1. `data` 缺失/非数组、含 `error`、非 200 —— 维持既有报错不变。
  2. `total`：取第一个响应中报告的正数值作为翻页计数参考；此后不再采信后续页的 `total` 变化；非数值/缺失/0 视为未知。
  3. 终止：`页码*100 ≥ 首页total`（total 已知时）；或本页解析合并后无新增行；或本页行数 <100 且 total 未表明还有余量；或达 50 页上限（报既有错误）。
  4. 合并：跨页按 id 去重合并（现状不变）；strict 模式行校验（现状不变）。
  5. 明确移除："`added==0` 且 `total > peers.length` 时抛'服务器未正确分页'"路径。

### C2: 调试脚本 CLI 契约

- 调用形式：`python ab_debug.py <server_url> [--insecure] [--pages N] [--timeout S]`；`<server_url>` 为必填位置参数；`--pages` 默认 3（地址簿抓取页数上限）；`--timeout` 默认 180（OIDC 授权等待秒数）。
- OIDC 流程：`GET /api/login-options`（免认证）→ 解析 `oidc/<name>` 与 `common-oidc/[...]` 选项（多选项时编号交互选择）→ `POST /api/oidc/auth`（body 含 op、随机 id/uuid、deviceInfo、apiDomain）→ 打开/打印授权 URL → 轮询 `GET /api/oidc/auth-query?code=&id=&uuid=`（3 秒间隔）→ `type == "access_token"` 即成功；服务器返回 `No authed oidc is found` 视为等待中（与客户端一致）；超时非零退出。
- 抓取清单（Bearer）：`POST /api/ab/personal`、`POST /api/ab/shared/profiles?current=1&pageSize=100`、`POST /api/ab/peers?current=P&pageSize=100&ab={personal guid}`（P=1..N）、`POST /api/ab/tags/{guid}`、`GET /api/ab`（legacy，404 容忍）；404/错误响应同样落盘并记录状态码，不中断后续抓取。
- 落盘：`debug-util/dump/<YYYYmmdd-HHMMSS>/`；token 不落盘；摘要打印到终端并写入 `summary.json`。

### C3: 不变的接口

`writePeer` / `deletePeer` / `books()` / legacy 地址簿路径 / 登录与账号会话相关全部接口维持现状。
