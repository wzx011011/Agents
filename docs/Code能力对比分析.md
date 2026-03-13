# Code（Opus AI 编码 CLI）官方能力 vs 当前架构 — 全面对比分析

## 一、Code 官方能力全景

基于对 Code 运行时环境、Agent SDK 文档和 CLI 工具的调研，以下是当前官方支持的所有能力：

> 数据来源：运行时系统提示、环境变量、工具定义、本地文件系统 + 官方文档

### 1. Agent 定义系统

| 特性 | 说明 | 你们是否使用 |
|------|------|:----------:|
| `.github/agents/*.agent.md` | Markdown + YAML frontmatter 定义角色 | ✅ 已使用 |
| `handoffs` 交接定义 | label + agent + prompt + send 字段 | ✅ 已使用 |
| `subagent_type` | 启动时指定专业化子 Agent 类型 | ⚠️ 仅运行时使用 |
| `isolation: "worktree"` | 在独立 git worktree 中运行 Agent | ❌ 未使用 |
| `run_in_background` | 后台异步运行 Agent | ⚠️ 仅运行时使用 |
| `model` 参数 | 为不同 Agent 指定不同模型（opus/sonnet/haiku） | ❌ 未使用 |

### 2. 子 Agent 系统（Agent Tool）

| 特性 | 说明 | 你们是否使用 |
|------|------|:----------:|
| `Agent` 工具 | 主 Agent 可启动专业子 Agent | ⚠️ 探索阶段用过 |
| 并行子 Agent | 一条消息启动多个 Agent 并行执行 | ⚠️ 有限的并行 |
| 子 Agent 类型 | `general-purpose`, `Explore`, `Plan`, `code-reviewer` 等 | ⚠️ 部分使用 |
| 子 Agent 上下文隔离 | 子 Agent 有独立上下文窗口 | ✅ 自动使用 |
| 子 Agent 结果汇总 | 子 Agent 完成后返回摘要给主 Agent | ✅ 自动使用 |
| 子 Agent 恢复 | 通过 `resume` 参数恢复之前的子 Agent | ❌ 未使用 |
| Fan-out/Fan-in | 一主多从并行分发收集 | ⚠️ 有限的扇出 |

### 3. 记忆系统（Memory）

| 特性 | 说明 | 你们是否使用 |
|------|------|:----------:|
| 项目级记忆 `MEMORY.md` | 自动加载到上下文，持久化跨会话 | ✅ 有等效机制 |
| 用户级记忆目录 | `~/.code/memory/` 跨项目持久 | ✅ 有等效机制 |
| 工作区指令 | `.github/copilot-instructions.md` 工作区级指令自动加载 | ✅ 已使用 |
| 上下文自动压缩 | `/compact` 命令，自动截断长对话 | ✅ 自动使用 |

### 4. Instructions 规则系统

| 特性 | 说明 | 你们是否使用 |
|------|------|:----------:|
| `.github/instructions/*.md` | 按 topic 组织的规则文件 | ✅ 已使用 |
| YAML frontmatter `applyTo` | glob 模式匹配路径自动生效 | ✅ 已使用 |
| 子目录组织 `global/` `testing/` | 按范围分类规则 | ✅ 已使用 |
| 个人级指令 | 用户级持久偏好 | ❌ 未使用 |

### 5. Hooks（生命周期钩子）

| 特性 | 说明 | 你们是否使用 |
|------|------|:----------:|
| Pre-tool-use 钩子 | 工具执行前拦截/修改/阻止 | ❌ 未使用 |
| Post-tool-use 钩子 | 工具执行后检查/记录 | ❌ 未使用 |
| On-error 钩子 | 错误处理回调 | ❌ 未使用 |
| 配置位置 | settings.json 或项目级配置 | ❌ 未使用 |

### 6. Worktree（工作树隔离）

| 特性 | 说明 | 你们是否使用 |
|------|------|:----------:|
| `EnterWorktree` 工具 | 创建独立 git worktree | ❌ 未使用 |
| `ExitWorktree` 工具 | 退出 worktree（keep/remove） | ❌ 未使用 |
| 子 Agent worktree 隔离 | `isolation: "worktree"` 参数 | ❌ 未使用 |
| 自动清理 | 会话结束自动清理 worktree | ❌ 未使用 |

### 7. MCP（Model Context Protocol）

| 特性 | 说明 | 你们是否使用 |
|------|------|:----------:|
| MCP 配置 | 配置 MCP 服务器连接 | ❌ 未使用 |
| MCP 工具服务器 | 外部工具和数据源连接 | ❌ 未使用 |
| MCP 资源读取 | ListMcpResourceTool / ReadMcpResourceTool | ❌ 未使用 |

### 8. Skills / 斜杠命令

| 特性 | 说明 | 你们是否使用 |
|------|------|:----------:|
| 内置命令 | `/help`, `/clear`, `/compact`, `/cost`, `/init` 等 | ✅ 自动可用 |
| 自定义 Skill | 通过 Skill 工具调用 | ⚠️ 部分定义 |
| Skill 参数 | 可选 args 传递参数 | ❌ 未自定义 |

### 9. Headless / 自治模式

| 特性 | 说明 | 你们是否使用 |
|------|------|:----------:|
| `--print` 标志 | 非交互模式输出到 stdout | ❌ 未使用 |
| `--output-format` | JSON / text / stream-json 格式 | ❌ 未使用 |
| 管道组合 | CLI 输出可管道传递给其他脚本 | ❌ 未使用 |

### 10. 计划模式

| 特性 | 说明 | 你们是否使用 |
|------|------|:----------:|
| `EnterPlanMode` | 进入只读规划模式 | ✅ 已使用 |
| 计划文件 | 写入指定 `.md` 文件 | ✅ 已使用 |
| `ExitPlanMode` | 请求用户审批计划 | ✅ 已使用 |
| 5 阶段流程 | 理解→设计→审查→最终→退出 | ✅ 已使用 |

### 11. 定时任务（Cron）

| 特性 | 说明 | 你们是否使用 |
|------|------|:----------:|
| `CronCreate` | 创建定时提示任务 | ⚠️ 运行时可使用 |
| `CronDelete` | 删除定时任务 | ⚠️ 运行时可使用 |
| `CronList` | 列出当前定时任务 | ⚠️ 运行时可使用 |
| 循环任务 | recurring 默认 true | ⚠️ 运行时可使用 |
| 3 天自动过期 | 防止无限循环 | ⚠️ 运行时可使用 |

### 12. 任务追踪（TodoWrite）

| 特性 | 说明 | 你们是否使用 |
|------|------|:----------:|
| `TodoWrite` | 结构化任务列表 | ✅ 已使用 |
| 状态管理 | pending/in_progress/completed | ✅ 已使用 |
| 强制单任务进行 | 同时只能有一个 in_progress | ✅ 已使用 |

### 13. Git / PR 集成

| 特性 | 说明 | 你们是否使用 |
|------|------|:----------:|
| `gh` CLI | 完整的 PR 创建工作流 | ✅ 已使用 |
| 分支管理 | 创建分支、推送、创建 PR | ✅ 已使用 |
| Issue 管理 | gh issue 创建/评论 | ❌ 未使用 |

---

## 二、当前架构的独特优势

你们的工作区在以下方面**超越了官方开箱能力**：

### 1. 结构化多角色交付流水线

官方：单 Agent 通用模式，无角色分离，无工具边界
你们：4 个命名角色 + 明确的文件权限边界 + 阶段化的交付流程

### 2. 显式交接协议

官方：Agent Tool 的子 Agent 通过 `prompt` 参数一次性传递上下文，无持久化
你们：结构化的交接文件 `交接.md`，Git 可追踪、持久化可审计、3 分钟恢复

### 3. 项目状态机

官方：无内置项目状态管理，无枚举校验
你们：`项目状态.yaml` 包含 10+ 个枚举字段 + 完整性检查规则

### 4. 组合级项目管理

官方：单项目单会话模式
你们：5 个项目槽位 + 组合索引 + 依赖关系管理 + 周报

### 5. 模板驱动的初始化

官方：无标准化项目初始化流程
你们：7 套模板 + 6 步初始化指南 + 验证清单

### 6. 升级路径规则

官方：无内置异常处理协议
你们：4 种异常场景的升级规则（阻塞、驳回、失败、过载）

---

## 三、可优化的关键方向

### 优先级 P0：立即可用，收益最大

#### 1. 利用 Headless 模式实现自动化流水线

**现状**：所有 Agent 切换需要人工手动触发
**优化**：用 `--print` + `--output-format json` 实现脚本化 Agent 调用

```bash
# 示例：自动化一个完整交付周期
code --print --output-format json "作为通用开发，按照 项目/项目-A/交接.md 执行任务"
# → 输出 JSON 结果，可被下一个脚本解析

# 接着自动触发评审
code --print --output-format json "作为评审调试，按照 项目/项目-A/交接.md 执行评审"
```

**影响**：从"人工切换 Agent"变为"脚本编排 Agent"，接近真正的自动化流水线

#### 2. 利用 Cron 实现周期性检查

**现状**：Agent 不会主动检查项目健康度
**优化**：为每个 active 项目创建定时检查任务

```
每天 9:57 检查所有 active 项目的交接文件是否过期
如果 active_agent 指向某角色但交接文件 >48h 未更新，自动写入提醒
```

**影响**：从被动等待变为主动监控

#### 3. 为 Agent 定义添加 `model` 差异化

**现状**：所有角色使用相同模型（opus）
**优化**：PM 用 sonnet（决策类任务足够），Dev/Review 用 opus（复杂编码/调试）

```
组合PM: model=sonnet（降低成本，PM 任务不需要最强推理）
通用开发: model=opus（编码实现需要强推理）
评审调试: model=opus（根因分析需要强推理）
测试工程师: model=haiku（测试执行模式化，不需要强推理）
```

**影响**：降低约 40-50% 的 token 成本

---

### 优先级 P1：中等投入，显著提升

#### 4. 利用 Hooks 实现自动状态校验

**现状**：Agent 自觉遵守规则，无强制校验
**优化**：配置 Post-tool-use Hook，在 Agent 写入 `项目状态.yaml` 后自动校验

```
Post-tool-use Hook:
  触发条件: 写入 项目/**/项目状态.yaml
  校验:
    - stage 在枚举值内
    - active_agent 在枚举值内
    - last_updated 是今天日期
  如果校验失败: 警告并建议修复
```

**影响**：防止状态文件损坏，提升数据质量

#### 5. 利用 Worktree 隔离实现并行 Agent

**现状**：Agent 串行执行，一次只能一个角色工作
**优化**：为 Dev 和 Review 使用 worktree 隔离并行执行

```
PM 分配任务后：
  Agent(Dev, isolation=worktree)  → 在 worktree-1 中实现
  同时可以准备下一个任务的上下文

Dev 完成后：
  Agent(Review, isolation=worktree) → 在 worktree-2 中评审
  同时 PM 可以处理其他项目
```

**影响**：真正意义上的多 Agent 并行，吞吐量翻倍

#### 6. 自定义 Skill 封装常用流程

**现状**：每个流程步骤都需要手动描述
**优化**：将常用流程封装为 Skill

```
/pilot-run 项目-A        → 自动执行 PM→Dev→Review→Test 完整周期
/project-init 项目-B    → 按初始化指南激活项目-B
/status-check           → 检查所有项目状态，生成摘要
/handoff 目标角色        → 写入交接文件并更新状态
```

**影响**：降低使用门槛，一键执行标准流程

---

### 优先级 P2：远期规划，架构升级

#### 7. MCP 集成外部工具

**场景**：
- 通过 MCP 连接 Jira/Linear，自动同步任务状态
- 通过 MCP 连接 CI/CD 系统，触发构建和部署
- 通过 MCP 连接数据库，自动验证数据变更

**影响**：从纯编码交付扩展到全流程 DevOps

#### 8. 构建蜂群模式（Swarm）

基于 Code 的并行子 Agent + Worktree 隔离，可以实现：

```
PM Agent（编排者）
├── Dev Agent #1 (worktree-1, background) → 实现功能 A
├── Dev Agent #2 (worktree-2, background) → 实现功能 B
├── Review Agent (worktree-3, background) → 评审上一个周期的变更
└── Test Agent (worktree-4, background) → 测试上一个周期的变更
```

PM Agent 作为编排者，通过 `run_in_background` 同时启动多个子 Agent，各自在独立 worktree 中工作，完成后 PM Agent 收集结果、合并分支、更新状态。

**影响**：从串行流水线升级为并行蜂群，多项目同步推进

#### 9. 构建自动化编排脚本

结合 Headless + Cron + Skills，构建完整的自动化系统：

```
# 每天早上 9:57 自动运行
cron → /status-check →
  如果有 ready 任务:
    → /pilot-run → 自动执行交付周期
  如果没有:
    → 生成每日状态报告
```

**影响**：从手动驱动变为半自动持续交付

---

## 四、总体评估

```
能力覆盖度:

官方原生能力 (你已在用的):     ████████░░ 80%
官方能力 (你未用的):           ████░░░░░░ 40%
你独有的超越能力:              ███████░░░ 70%

当前架构成熟度:
  Agent 定义:     ██████████ 100%
  Instructions:  ██████████ 100%
  项目记忆:       ████████░░  80%  ← 缺自动持久化
  交接协议:       ████████░░  80%  ← 缺自动化
  状态管理:       █████████░  90%  ← 缺校验
  异常处理:       ███████░░  80%  ← 缺自动化检测
  并行执行:       ██░░░░░░░░  20%  ← 最大缺口
  外部集成:       █░░░░░░░░░  10%  ← 未开始
  自动化:         ███░░░░░░░  30%  ← 仅 Cron 可用
```

## 五、建议优先级

| 优先级 | 优化项 | 投入 | 收益 |
|--------|--------|------|------|
| P0 | Headless 脚本化 | 小 | 大 — 自动化流水线基础 |
| P0 | 模型差异化 | 小 | 大 — 降低 50% 成本 |
| P0 | Cron 周期检查 | 小 | 中 — 主动监控 |
| P1 | Hooks 状态校验 | 中 | 中 — 数据质量保障 |
| P1 | Worktree 并行 | 中 | 大 — 吞吐量翻倍 |
| P1 | 自定义 Skill | 中 | 大 — 使用门槛降低 |
| P2 | MCP 外部集成 | 大 | 大 — 全流程 DevOps |
| P2 | 蜂群模式 | 大 | 大 — 多项目并行推进 |
| P2 | 自动化编排 | 大 | 大 — 持续交付 |

---

## 六、不推荐做的事

- **不把 Agent 定义迁移到 TypeScript 扩展** — Markdown 文件更轻量、可移植、Git 友好
- **不引入 LangGraph/CrewAI 等外部框架** — Code 原生子 Agent 能力已足够
- **不放弃文件记忆系统** — 它比任何对话上下文更持久、可审计
- **不把所有规则迁移到 settings.json** — 保持 `.github/instructions/` 的 Git 可追踪性
