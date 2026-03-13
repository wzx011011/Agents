# Code CLI 适配指南

## 环境特征
- 支持 `.github/agents/*.agent.md` 格式的 Agent 定义
- 支持 `.github/instructions/*.md` 格式的行为规则
- 内置 Agent 工具可启动子 Agent（subagent_type）
- 支持 run_in_background 并行执行
- 支持 TodoWrite 工具追踪任务
- 支持 EnterPlanMode / ExitPlanMode 规划模式

## 文件放置
将 wzx- 前缀的文件复制到目标项目：
- `agents/wzx-*.md` → 目标项目的 `.github/agents/`
- `instructions/wzx-*.md` → 目标项目的 `.github/instructions/`
- 项目记忆 → 目标项目的 `.memory/`

## 原生能力映射
| 架构概念 | Code CLI 原生能力 |
|---------|-----------------|
| 角色切换 | Agent 工具 + subagent_type |
| 并行执行 | Agent 工具 + run_in_background |
| 任务追踪 | TodoWrite |
| 项目状态 | 项目记忆文件（我们自定义） |
| 交接协议 | 交接.md（我们自定义） |
| 规划 | EnterPlanMode / ExitPlanMode |