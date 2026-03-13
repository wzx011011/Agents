#!/bin/bash
# launch_instance.sh <instance-id> <task-id>
# 为指定任务构建并启动一个 headless Code CLI 实例。
# 用法: launch_instance.sh dev-项目A-001 TASK-20260313-001

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/atomic_write.sh"

INSTANCE_ID="$1"
TASK_ID="$2"

RUN_DIR="${WORKSPACE_ROOT}/.run"
CONFIG_FILE="${RUN_DIR}/orchestrator/config.yaml"
QUEUE_FILE="${RUN_DIR}/queue/inbox.yaml"
INSTANCE_DIR="${RUN_DIR}/instances/${INSTANCE_ID}"

# 创建实例目录
mkdir -p "$INSTANCE_DIR"

# --- 读取任务信息 ---
# 从 inbox.yaml 中提取任务（纯 bash，不依赖 yq）
TASK_BLOCK=""
IN_TASK=0
while IFS= read -r line; do
    if echo "$line" | grep -q "task_id:.*\"${TASK_ID}\""; then
        IN_TASK=1
    fi
    if [ "$IN_TASK" = 1 ]; then
        TASK_BLOCK="${TASK_BLOCK}${line}"$'\n'
        if echo "$line" | grep -q "^  - task_id:" && [ "$IN_TASK" = 1 ] && [ -n "$TASK_BLOCK" ]; then
            # 遇到下一个任务，停止
            break
        fi
    fi
done < "$QUEUE_FILE"

# 提取字段（简化版 bash 解析）
role=$(echo "$TASK_BLOCK" | grep "role:" | sed 's/.*role:[[:space:]]*//' | tr -d '"')
project=$(echo "$TASK_BLOCK" | grep "project:" | sed 's/.*project:[[:space:]]*//' | tr -d '"')
task_type=$(echo "$TASK_BLOCK" | grep "type:" | sed 's/.*type:[[:space:]]*//' | tr -d '"')
cwd_override=$(echo "$TASK_BLOCK" | grep "cwd_override:" | sed 's/.*cwd_override:[[:space:]]*//' | tr -d '"' | sed 's/null$//')

# 提取 prompt（多行，缩进处理）
prompt=$(echo "$TASK_BLOCK" | sed -n '/^ *prompt: |/,$ { /^ *prompt: |/d; p }' | head -c -1)

if [ -z "$role" ] || [ -z "$project" ]; then
    echo "ERROR: 无法解析任务 ${TASK_ID} 的 role 或 project" >&2
    exit 1
fi

# --- 读取模型配置 ---
MODEL="opus"
if [ -f "$CONFIG_FILE" ]; then
    case "$role" in
        组合PM) MODEL="sonnet" ;;
        通用开发) MODEL="opus" ;;
        评审调试) MODEL="opus" ;;
        测试工程师) MODEL="haiku" ;;
    esac
fi

# --- 确定 --cwd ---
if [ -n "$cwd_override" ]; then
    CWD="$cwd_override"
else
    CWD="$WORKSPACE_ROOT"
fi

# --- 加载 Agent 定义作为 system prompt ---
AGENT_DEF_FILE="${WORKSPACE_ROOT}/.github/agents/${role}.agent.md"
if [ -f "$AGENT_DEF_FILE" ]; then
    SYSTEM_PROMPT=$(cat "$AGENT_DEF_FILE")
else
    SYSTEM_PROMPT="你是${role}角色。按照交接文件中的指示执行任务。"
fi

# --- 构建 code CLI 命令 ---
CODE_CMD="code --print"
CODE_CMD="${CODE_CMD} --cwd \"${CWD}\""
CODE_CMD="${CODE_CMD} --output-format json"
CODE_CMD="${CODE_CMD} --model ${MODEL}"

# --- 写入实例元数据 ---
INSTANCE_META="instance_id: ${INSTANCE_ID}
role: \"${role}\"
project: \"${project}\"
task_id: \"${TASK_ID}\"
type: \"${task_type:-unknown}\"
cwd: \"${CWD}\"
model: \"${MODEL}\"
status: starting
started_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
exit_code: null
"

echo -n "$INSTANCE_META" | atomic_write.sh "${INSTANCE_DIR}/instance.yaml"

# --- 在后台启动实例 ---
# 启动 code --print 并将输出重定向到日志文件
# 使用子 shell 作为 watchdog

LOG_FILE="${INSTANCE_DIR}/orchestrator.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"
}

log "启动实例 ${INSTANCE_ID}: role=${role} project=${project} type=${task_type:-unknown}"

# 将完整命令写入文件，方便调试
echo "#!/bin/bash" > "${INSTANCE_DIR}/run.sh"
echo "code --print \\" >> "${INSTANCE_DIR}/run.sh"
echo "  --cwd \"${CWD}\" \\" >> "${INSTANCE_DIR}/run.sh"
echo "  --output-format json \\" >> "${INSTANCE_DIR}/run.sh"
echo "  --model ${MODEL} \\" >> "${INSTANCE_DIR}/run.sh"
echo "  \"${prompt}\"" >> "${INSTANCE_DIR}/run.sh"

# 更新实例状态为 running
sed -i "s/status: starting/status: running/" "${INSTANCE_DIR}/instance.yaml"

# 后台启动 code --print 进程
eval "code --print \
  --cwd \"${CWD}\" \
  --output-format json \
  --model ${MODEL} \
  \"${prompt}\"" \
  > "${INSTANCE_DIR}/stdout.log" 2> "${INSTANCE_DIR}/stderr.log" &

INSTANCE_PID=$!
echo "$INSTANCE_PID" > "${INSTANCE_DIR}/pid"

# 启动 watchdog 子进程
(
    while kill -0 "$INSTANCE_PID" 2>/dev/null; do
        date +%s > "${INSTANCE_DIR}/heartbeat"
        sleep 30
    done
    # 进程结束，记录退出码
    wait "$INSTANCE_PID" 2>/dev/null
    EXIT_CODE=$?
    echo "$EXIT_CODE" > "${INSTANCE_DIR}/exit_code"

    # 更新实例状态
    if [ "$EXIT_CODE" -eq 0 ]; then
        sed -i "s/status: running/status: completed/" "${INSTANCE_DIR}/instance.yaml"
    else
        sed -i "s/status: running/status: failed/" "${INSTANCE_DIR}/instance.yaml"
    fi

    log "实例 ${INSTANCE_ID} 已结束，exit_code=${EXIT_CODE}"
) &
WATCHDOG_PID=$!
echo "$WATCHDOG_PID" > "${INSTANCE_DIR}/watchdog.pid"

log "实例 ${INSTANCE_ID} 已启动: pid=${INSTANCE_PID} watchdog=${WATCHDOG_PID}"

# 输出实例 PID 给调用者
echo "${INSTANCE_PID}"
