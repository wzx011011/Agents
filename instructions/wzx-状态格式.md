# 状态格式

## YAML 结构规则
- 保持 YAML 结构稳定且简洁。
- 当项目状态变化时，更新 `current_goal`、`next_action`、`active_agent`、`review_state` 和 `test_state`。
- 避免在 YAML 文件里加入大段自由叙述。

## 字段枚举
- stage: discovery | planning | implementation | stabilization | complete
- active_agent: 组合PM | 通用开发 | 评审调试 | 测试工程师
- review_state: not-started | in-progress | passed | changes-requested
- test_state: not-started | in-progress | passed | failed | partial
- environment_state: unknown | partial | ready | broken
- status: active | paused | completed | archived
- priority: critical | high | medium | low