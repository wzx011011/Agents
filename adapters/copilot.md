# GitHub Copilot 适配指南

## 环境特征
- 通过 VS Code 扩展运行
- 读取 `.github/copilot-instructions.md` 作为项目指令
- 没有原生 Agent 切换能力
- 没有原生任务队列

## 文件放置
- 将核心规则追加到 `.github/copilot-instructions.md`（用 WZX 标记）
- 项目记忆放在 `.memory/` 目录

## 适配策略
Copilot 没有原生的多角色切换能力。使用以下方式：
1. 在对话中明确指定当前角色："你现在是[角色名]，按照 .memory/交接.md 执行"
2. 手动切换角色时更新交接文件
3. 读取 `adapters/generic.md` 获取通用工作方式