# Claude Code 与 OpenClaw 迁移说明

这份说明用于把当前工作区中的 VS Code / Copilot 自定义结构迁移到 Claude Code 兼容结构，并同时产出一份便于 OpenClaw 复用的迁移包。

## 迁移目标

当前工作区的主要配置位于：

- `.github/copilot-instructions.md`
- `.github/agents/*.agent.md`
- `.github/instructions/**/*.instructions.md`
- `AGENTS.md`

目标是生成：

- `.claude/CLAUDE.md`
- `.claude/agents/*.md`
- `.claude/rules/**/*.md`
- `.claude/workflow.json`
- `migration/openclaw/` 下的一套兼容产物

## 兼容原则

### Claude Code

Claude Code 兼容层采用以下结构：

- `CLAUDE.md`：工作区级长期说明
- `.claude/agents/*.md`：Claude 子代理定义
- `.claude/rules/**/*.md`：Claude 规则文件
- `.claude/workflow.json`：结构化 agent 流转关系
- `.claude/settings.json`：可选 hooks 配置

VS Code 官方已经说明会读取 Claude 兼容文件，因此这层配置也能反向被 VS Code 复用。

### OpenClaw

OpenClaw 在不同版本和部署方式上，实际读取入口可能不同。为了降低迁移风险，这里采用“Claude 兼容导出 + OpenClaw 专用导出目录”的策略：

- 优先产出标准 `.claude/` 结构
- 同时在 `migration/openclaw/claude-compatible/` 下复制一份
- 再额外生成 `migration/openclaw/README.md` 和 `migration/openclaw/manifest.json`

这样做的好处是：

- 如果你的 OpenClaw 版本支持 Claude 兼容格式，可以直接复用
- 如果不完全兼容，也有一套结构化迁移包可手动映射
- 重复导出时不会清空手工维护的 `.claude/settings.json` 等目标端文件

## 字段映射规则

### 工作区说明

- 来源：`AGENTS.md` + `.github/copilot-instructions.md`
- 目标：`.claude/CLAUDE.md`

### Agent

- 来源：`.github/agents/*.agent.md`
- 目标：`.claude/agents/*.md`

处理方式：

- 保留 `name`
- 保留 `description`
- 将 `handoffs` 转存到 `.claude/workflow.json` 和 `migration/openclaw/workflow.json`
- 按角色写入最小够用的 `tools`
- 保留正文说明

### Instructions

- 来源：`.github/instructions/**/*.instructions.md`
- 目标：`.claude/rules/**/*.md`

处理方式：

- 把 `applyTo` 转成 Claude 兼容的 `paths`
- 保留 `name` 和 `description`
- 保留正文内容
- 保留原始 instructions 子目录结构，避免未来同名规则文件相互覆盖

## 推荐使用方式

### 只想生成 Claude Code 兼容目录

```powershell
powershell -ExecutionPolicy Bypass -File .\脚本\导出到ClaudeCode和OpenClaw.ps1 -Target Claude
```

### 同时生成 Claude Code 与 OpenClaw 迁移包

```powershell
powershell -ExecutionPolicy Bypass -File .\脚本\导出到ClaudeCode和OpenClaw.ps1 -Target Both
```

### 只生成 OpenClaw 迁移包

```powershell
powershell -ExecutionPolicy Bypass -File .\脚本\导出到ClaudeCode和OpenClaw.ps1 -Target OpenClaw
```

## 迁移后目录

```text
.claude/
  CLAUDE.md
  workflow.json
  agents/
    组合PM.md
    通用开发.md
    评审调试.md
    测试工程师.md
  rules/
    global/
      运行模型.md
      交接规则.md
      状态格式.md
    testing/
      验证策略.md

migration/
  openclaw/
    README.md
    manifest.json
    workflow.json
    claude-compatible/
      .claude/
        CLAUDE.md
        workflow.json
        agents/
        rules/
```

## 注意事项

- Claude 兼容 agent 格式与 VS Code 的 `.agent.md` 不完全相同，但 handoff 关系会被额外导出到 `workflow.json`。
- Claude 兼容 rules 使用 `paths`，不是 `applyTo`。
- 如果后续你引入 hooks，建议统一放到 `.claude/settings.json`，脚本重复运行时不会删除它。
- OpenClaw 的最终接入方式，请以你实际使用的 OpenClaw 版本文档为准；当前导出结果优先保证“可复用”和“可人工映射”。

## 当前建议

先把 `.claude/` 作为统一兼容层，把 OpenClaw 视为“消费这层兼容配置的第二个目标系统”。这样维护成本最低，不需要长期维护三套配置。
