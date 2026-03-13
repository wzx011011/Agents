# WZX 多 Agent 交付系统

工具无关的多 Agent 交付架构。定义角色、规则和项目记忆，可适配 Code CLI、OpenClaw/ZCode、GitHub Copilot 或任何 AI coding 工具。

## 快速开始

### 方式 1：在架构仓库中直接使用

```
1. 告诉 AI："读取 agents/ 下的角色定义，按照组合PM的角色执行工作"
2. AI 自动读取角色定义和指令规则
3. 按照 projects/ 下的项目记忆开始工作
```

### 方式 2：迁移到目标项目

```bash
# 1. 创建目标目录结构
cd <目标项目>
mkdir -p .github/agents .github/instructions .memory

# 2. 复制 Agent 定义（wzx- 前缀避免冲突）
cp <架构仓库>/agents/wzx-*.md .github/agents/

# 3. 复制行为规则（wzx- 前缀避免冲突）
cp <架构仓库>/instructions/wzx-*.md .github/instructions/

# 4. 初始化项目记忆
cp <架构仓库>/projects/_template/* .memory/

# 5. 如果有 copilot-instructions.md，追加规则
echo "" >> .github/copilot-instructions.md
echo "<!-- WZX 多Agent 交付系统 -->" >> .github/copilot-instructions.md
cat <架构仓库>/instructions/wzx-运行模型.md >> .github/copilot-instructions.md
echo "<!-- /WZX -->" >> .github/copilot-instructions.md
```

### 方式 3：自动检测环境

```
告诉 AI："读取 adapters/detection.md，检测环境并按适配指南开始工作"
AI 自动识别当前工具（Code CLI / ZCode / Copilot / 通用）并选择最佳方式。
```

## 目录结构

```
agents/                    Agent 角色定义（工具无关）
  wzx-组合PM.md
  wzx-通用开发.md
  wzx-评审调试.md
  wzx-测试工程师.md

instructions/              行为规则（工具无关）
  wzx-运行模型.md
  wzx-交接规则.md
  wzx-状态格式.md
  wzx-验证策略.md
  wzx-升级路径.md

adapters/                  工具适配层
  detection.md             环境检测指南
  code-cli.md              Code CLI 适配
  openclaw.md              OpenClaw/ZCode 适配
  copilot.md               GitHub Copilot 适配
  generic.md               通用适配

templates/                  标准模板
  项目简报模板.md
  项目状态模板.yaml
  交接模板.md
  当前上下文模板.md
  待办列表模板.yaml
  测试报告模板.md
  项目初始化指南.md
  ...

portfolio/                 组合级管理
  组合索引.md
  组合路线图.yaml
  依赖关系.yaml

projects/                  项目记忆
  _template/               新项目模板
  项目-A/ ~ 项目-E/        已有项目
```

## 角色与交接

```
组合PM → 通用开发 → 评审调试 → 测试工程师 → 组合PM
   ↑                                      │
   └──────────────────────────────────────┘
                  驳回/失败回退
```

- **组合PM**: 优先级管理、任务分配、状态维护
- **通用开发**: 编码实现、环境搭建、文档维护
- **评审调试**: 代码评审、缺陷隔离、根因分析
- **测试工程师**: 验证执行、报告维护、缺口记录

## 项目记忆文件

每个项目维护 6 个核心文件：

| 文件 | 维护者 | 用途 |
|------|--------|------|
| 项目简报.md | PM | 项目技术栈、范围、目标 |
| 项目状态.yaml | PM | 结构化状态（stage/agent/progress） |
| 待办列表.yaml | PM | 任务队列（ready/in-progress/done） |
| 当前上下文.md | Dev | 当前进展、关键文件、决策 |
| 交接.md | 全部 | 跨角色交接（3 分钟恢复） |
| 验证/最新测试报告.md | Test | 验证结果和缺口 |

## 迁移分层

| 层次 | 操作 | 频率 |
|------|------|------|
| 用户级 | 复制 agents/ 和 instructions/ 到目标项目 | 每 PC 一次 |
| 项目级 | 初始化 .memory/ 目录，填写简报和状态 | 每项目一次 |
| 会话级 | AI 自动检测环境，读取记忆文件开始工作 | 自动 |

## 前缀约定

架构的自定义文件使用 `wzx` 前缀，与工具原生文件共存：
- Agent 定义：`wzx-组合PM.agent.md`
- 行为规则：`wzx-交接规则.md`
- Skills、MCP 配置同理

无法前缀区分的文件（如 `copilot-instructions.md`）采用追加策略。
