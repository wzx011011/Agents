# 环境检测指南

## 检测步骤
1. 检查当前是否在 VS Code 中运行
2. 检查项目根目录是否存在 `.github/agents/` 目录
3. 检查是否存在 `AGENTS.md` 或 `AGENT.md` 文件
4. 检查当前工具的输出格式和可用命令

## 检测结果映射
- 有 `.github/agents/` 且支持 Agent 工具 → Code CLI 环境 → 读取 adapters/code-cli.md
- 在 ZCode/OpenClaw 中运行 → 读取 adapters/openclaw.md
- 有 GitHub Copilot 扩展活跃 → 读取 adapters/copilot.md
- 无法确定 → 读取 adapters/generic.md