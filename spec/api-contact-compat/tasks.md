# Tasks: 自建 API server 通讯录兼容性修复（api-contact-compat）

**Input**: Design documents from `spec/api-contact-compat/`
**Prerequisites**: plan.md (required), spec.md (required for user stories)

**Tests**: 未要求测试任务；以静态检查、构建验证与用户真实服务器实测代替。

**Organization**: 按用户故事分组，US1（分页修复，P1）为 MVP，US2（调试脚本，P2）独立交付。

## Format: `[ID] [P?] [Story] Description`

- **[P]**: 可并行（不同文件、无未完成依赖）
- **[Story]**: 所属用户故事（US1/US2）

## Path Conventions

- HarmonyOS 应用源码：`entry/src/main/ets/`
- 调试脚本与产出：`debug-util/`（须确保 git 忽略）
- 规格工件：`spec/api-contact-compat/`

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: 变更前置条件核验

- [X] T001 核验 `debug-util` 的 git 忽略状态：运行 `git check-ignore -v debug-util`，若无匹配则在项目根 `.gitignore` 追加 `debug-util/` 条目并确认生效

---

## Phase 2: Foundational (Blocking Prerequisites)

无阻塞前置项（既有工程、无新基础设施）。

---

## Phase 3: User Story 1 - 正常读取自建 server 通讯录 (Priority: P1) 🎯 MVP

**Goal**: 客户端在 lejianwen/rustdesk-api（忽略分页参数、允许重复行）及各类分页行为变体的服务器上，拉取地址簿不再抛"服务器未正确分页"，最终数据与官方客户端一致。

**Independent Test**: 对 spec.md US1 的 5 个验收场景逐一推演分页循环行为；`arkts_check` 通过；不触碰 `parsePeers`/`writePeer`/`deletePeer`/`books()`/legacy 路径。

### Implementation for User Story 1

- [X] T002 [US1] 重写 `entry/src/main/ets/service/RustDeskApiService.ets` 中 `peers()` 方法非 legacy 分支的分页循环（现约 515-537 行）：(a) 新增方法级局部变量捕获首个非零数值 `total`（仅在其仍为 0 时更新，对齐官方 `ab_model.dart` 语义）；(b) 终止条件按序判定——`total>0 且 peers.length>=total`、`total>0 且 page*100>=total`、本页无新增行（added==0，接受数据）、短页（data.length<100 且 total 未表明还有余量）、page==50 抛既有"设备超过分页限制"；(c) 移除 530 行"服务器未正确分页，设备列表不完整，请升级 API 服务"抛错路径；(d) 保持既有不变：data 缺失/非数组报错、strict 行校验报错、跨页按 id 去重合并、请求构造（POST、current/pageSize=100/ab 参数）不变
- [X] T003 [US1] 对 `entry/src/main/ets/service/RustDeskApiService.ets` 运行 `arkts_check` 静态检查并修复全部诊断（须为 0 错误），同时目视复查：`ApiReply.total` 使用方式、`ApiFailure` 抛错集合、方法签名与调用方（`ApiBookSync.ets` strict 调用、`ApiAccountDialog.ets` 非 strict 调用）兼容性无变化

**Checkpoint**: US1 完成——分页语义与官方对齐，其余接口行为不变。

---

## Phase 4: User Story 2 - 调试脚本抓取真实服务器数据 (Priority: P2)

**Goal**: 用户运行单文件脚本，经 OIDC 网页登录自建 server，自动拉取调试数据落盘并生成分析摘要后退出。

**Independent Test**: `py_compile` 通过；对照 plan.md C2 契约核验 CLI 参数、OIDC 流程步骤、抓取清单、落盘布局、token 不落盘、`--insecure` 安全默认。

### Implementation for User Story 2

- [X] T004 [P] [US2] 创建 `debug-util/ab_debug.py`：CLI 骨架（必填 `server_url` 位置参数；`--insecure`/`--pages`(默认3)/`--timeout`(默认180) 选项；HTTP 目标或跳过证书校验须 `--insecure` 否则拒绝启动）与 OIDC 登录流程（`GET /api/login-options` 解析 `oidc/` 与 `common-oidc/` 选项、多选项编号交互选择、`POST /api/oidc/auth` 携带随机 id/uuid 与 apiDomain、`webbrowser` 打开并打印授权 URL、3 秒间隔轮询 `GET /api/oidc/auth-query` 至 `type=="access_token"`，`No authed oidc is found` 视为等待中，超时非零退出）
- [X] T005 [US2] 在 `debug-util/ab_debug.py` 中实现数据抓取与落盘（Bearer 认证；按序抓取 `POST /api/ab/personal`、`POST /api/ab/shared/profiles?current=1&pageSize=100`、`POST /api/ab/peers?current=P&pageSize=100&ab={guid}` P=1..pages、`POST /api/ab/tags/{guid}`、`GET /api/ab`；404/错误响应同样落盘记录状态码且不中断后续抓取；原始响应体逐文件写入 `debug-util/dump/<YYYYmmdd-HHMMSS>/`；token 仅存内存）与 `summary.json` 分析摘要（各页 total 值与 JSON 类型、data 行数、id 字段类型分布、页内重复 id 数、被 OHOS 行校验拒绝的行清单及原因分类——空 id/超64位/含非法字符/重复、跨页重复统计、personal guid、各请求 HTTP 状态；摘要同时打印终端）
- [X] T006 [P] [US2] 对 `debug-util/ab_debug.py` 运行 `python -m py_compile` 语法校验，并以 `--help` 与无参数调用验证 CLI 契约（无参数须非零退出并提示用法；默认拒绝 HTTP 而无 `--insecure`）

**Checkpoint**: US2 完成——脚本可独立交付使用。

---

## Phase 5: Polish & Cross-Cutting Concerns

**Purpose**: 变更管理（用户要求用 git 管理变更）

- [ ] T007 审查全部变更 diff（`git diff` + `git status`），确认仅涉及 `entry/src/main/ets/service/RustDeskApiService.ets`、`debug-util/ab_debug.py`、`.gitignore`（如 T001 有追加）与 `spec/` 工件；按仓库既有提交风格创建 git 提交（含 spec 工件），提交信息概述根因与修复（服务器忽略分页参数 + 行过滤导致 total 失配 → 分页语义对齐官方）

---

## Phase 6: Verification

<!-- verification_scope: build-only -->

**Purpose**: 构建与部署验证（真实服务器功能验证由用户以 debug-util 脚本与实机登录完成，不在本阶段范围）

- [ ] T008 运行 `build_project` 构建 entry 模块并修复全部编译错误（迭代修复→重建直至成功，构建调用上限 10 次）
- [ ] T009 经 `start_app` 部署到已连接设备或模拟器验证可安装启动（无可用设备时如实报告跳过原因）

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: 无依赖，立即开始
- **Foundational (Phase 2)**: 无内容；不阻塞任何故事
- **User Stories (Phase 3-4)**: 依赖 T001（忽略规则核验）；US1 与 US2 相互独立、可并行
- **Polish (Phase 5)**: 依赖 US1（T003）与 US2（T006）全部完成
- **Verification (Phase 6)**: 依赖 T007 提交完成

### User Story Dependencies

- **User Story 1 (P1)**: T001 后即可开始；不依赖 US2
- **User Story 2 (P2)**: T001 后即可开始；不依赖 US1

### Within Each User Story

- US1: 先改代码（T002）后静态检查与复查（T003）
- US2: 先 CLI/OIDC 骨架（T004），后抓取与摘要（T005），最后校验（T006）；同文件必须串行
- 核心实现先于集成校验；故事完成后才进入 Polish

### Parallel Opportunities

- T002 与 T004 可同时启动（不同文件）
- T003 与 T005 可同时进行（不同文件）
- 不同故事可由不同执行者并行推进

---

## Parallel Example: User Story 1 与 User Story 2 并行

```text
# T001 完成后，同时启动：
Task T002: "重写 peers() 分页循环" (entry/src/main/ets/service/RustDeskApiService.ets)
Task T004: "创建 ab_debug.py CLI+OIDC 骨架" (debug-util/ab_debug.py)

# 随后并行：
Task T003: "arkts_check + 调用方复查" (entry/src/main/ets/service/RustDeskApiService.ets)
Task T005: "抓取+落盘+summary" (debug-util/ab_debug.py)
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. 完成 Phase 1: T001 核验忽略规则
2. 完成 US1: T002 → T003（MVP——用户报告的缺陷即被修复）
3. 停止即可独立验证：arkts_check + 构建 + 用户实机登录自建 server 拉取通讯录

### Incremental Delivery

1. T001 → 基础就绪
2. US1 (T002-T003) → 修复缺陷（MVP）
3. US2 (T004-T006) → 调试脚本交付
4. T007 → git 提交全部变更
5. T008-T009 → 构建/部署验证收尾

### 任务统计

- **总任务数**: 9（T001-T009）
- **按故事**: US1 = 2（T002-T003）；US2 = 3（T004-T006）；Setup = 1（T001）；Polish = 1（T007）；Verification = 2（T008-T009）
- **并行机会**: T002∥T004、T003∥T005（不同文件）
- **独立测试标准**: US1 以 5 个分页场景推演 + arkts_check；US2 以 py_compile + CLI 契约核验
- **建议 MVP 范围**: T001-T003

---

## Notes

- [P] 标记基于"不同文件且无未完成依赖"；US2 内部同文件任务不并行
- 验证阶段为 build-only（用户已授权默认选择；真实服务器实测由用户执行）
- 提交在 T007 一次性完成，避免中间破碎提交
