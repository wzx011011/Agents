#!/bin/bash
# queue.sh <command> [args...]
# 任务队列操作和交接文件解析。
# 命令:
#   add <yaml-string>       — 添加任务到队列
#   list                    — 列出队列中的任务
#   next                    — 取下一个可执行任务
#   done <task-id>          — 标记任务完成
#   fail <task-id>          — 标记任务失败
#   retry <task-id>         — 重试失败的任务
#   parse-handoff <project> — 从交接文件解析下一步角色

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/atomic_write.sh"

RUN_DIR="${WORKSPACE_ROOT}/.run"
INBOX_FILE="${RUN_DIR}/queue/inbox.yaml"
ACTIVE_FILE="${RUN_DIR}/queue/active.yaml"
COMPLETED_DIR="${RUN_DIR}/queue/completed"
FAILED_DIR="${RUN_DIR}/queue/failed"
LOG_FILE="${RUN_DIR}/orchestrator/orchestrator.log"

mkdir -p "$COMPLETED_DIR" "$FAILED_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [queue] $*" >> "$LOG_FILE"
}

# --- 生成任务 ID ---
gen_task_id() {
    echo "TASK-$(date +%Y%m%d)-$(date +%s | tail -c 4)"
}

# --- command: add ---
cmd_add() {
    local TASK_DATA="$1"
    local TASK_ID
    TASK_ID=$(gen_task_id)

    acquire_lock_or_fail "inbox"

    # 在 queue: [] 中添加任务
    if grep -q "^queue: \[\]$" "$INBOX_FILE"; then
        # 队列为空，替换为第一个任务
        local entry="queue:
  - task_id: \"${TASK_ID}\"
${TASK_DATA}"
        echo "$entry" | atomic_write.sh "$INBOX_FILE"
    else
        # 在队列末尾追加任务（在下一个 task_id 前面插入）
        local entry="  - task_id: \"${TASK_ID}\"
${TASK_DATA}"
        echo "$entry" >> "$INBOX_FILE"
    fi

    release_lock_safe "inbox"

    log "任务已添加: ${TASK_ID}"
    echo "$TASK_ID"
}

# --- command: list ---
cmd_list() {
    echo "=== 待执行任务 ==="
    local in_queue=0
    while IFS= read -r line; do
        if echo "$line" | grep -q "^queue:"; then
            in_queue=1
            continue
        fi
        if [ "$in_queue" = 1 ]; then
            echo "$line"
        fi
    done < "$INBOX_FILE"

    echo ""
    echo "=== 执行中任务 ==="
    cat "$ACTIVE_FILE"
}

# --- command: next ---
# 取下一个可执行的任务（queued + 项目未锁定 + 角色未超限）
cmd_next() {
    local target_project="$1"
    local target_role="$2"
    local blocked_projects="${3:-}"

    # 从 inbox 中找匹配的任务
    local found_task_id=""
    local found=0

    while IFS= read -r line; do
        case "$line" in
            "  - task_id:"*)
                if [ "$found" = 1 ]; then break; fi
                if echo "$line" | grep -q "queued"; then
                    # 检查下一个字段是否匹配
                    found=1
                    found_task_id=$(echo "$line" | sed 's/.*task_id:[[:space:]]*//' | tr -d '"')
                fi
                ;;
            "    project:"*)
                if [ "$found" = 1 ]; then
                    local project
                    project=$(echo "$line" | sed 's/.*project:[[:space:]]*//' | tr -d '"')
                    if [ "$project" != "$target_project" ]; then
                        found=0
                    fi
                fi
                ;;
            "    role:"*)
                if [ "$found" = 1 ]; then
                    local role
                    role=$(echo "$line" | sed 's/.*role:[[:space:]]*//' | tr -d '"')
                    if [ "$role" != "$target_role" ]; then
                        found=0
                    fi
                fi
                ;;
            "    status:"*)
                if [ "$found" = 1 ]; then
                    local status
                    status=$(echo "$line" | sed 's/.*status:[[:space:]]*//')
                    if [ "$status" != "queued" ]; then
                        found=0
                    fi
                fi
                ;;
        esac
    done < "$INBOX_FILE"

    if [ -n "$found_task_id" ]; then
        echo "$found_task_id"
    fi
}

# --- command: done ---
cmd_done() {
    local TASK_ID="$1"
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # 归档到 completed
    extract_task_block "$TASK_ID" > "${COMPLETED_DIR}/${TASK_ID}.yaml"

    # 从 inbox 中移除
    remove_task_from_inbox "$TASK_ID"

    # 从 active 中移除
    remove_task_from_active "$TASK_ID"

    log "任务完成: ${TASK_ID}"
}

# --- command: fail ---
cmd_fail() {
    local TASK_ID="$1"
    local retry_count
    retry_count=$(get_task_field "$TASK_ID" "retry_count" || echo "0")

    if [ "$retry_count" -lt 2 ]; then
        # 重试
        update_task_field "$TASK_ID" "status" "queued"
        update_task_field "$TASK_ID" "retry_count" "$((retry_count + 1))"
        remove_task_from_active "$TASK_ID"
        log "任务重试: ${TASK_ID} (第 $((retry_count + 1)) 次)"
        echo "retry"
    else
        # 归档到 failed
        extract_task_block "$TASK_ID" > "${FAILED_DIR}/${TASK_ID}.yaml"
        remove_task_from_inbox "$TASK_ID"
        remove_task_from_active "$TASK_ID"
        log "任务永久失败: ${TASK_ID}"
        echo "failed"
    fi
}

# --- command: parse-handoff ---
# 从交接.md 中解析下一步角色
cmd_parse_handoff() {
    local project="$1"
    local handoff_file="${WORKSPACE_ROOT}/项目/${project}/交接.md"

    if [ ! -f "$handoff_file" ]; then
        echo ""
        return
    fi

    # 在"明确的下一步动作"或"下一步动作"部分查找角色名
    local next_action=""
    local in_section=0

    while IFS= read -r line; do
        # 检测下一步动作部分
        if echo "$line" | grep -qi "下一步动作\|明确的下一步"; then
            in_section=1
            continue
        fi
        if [ "$in_section" = 1 ]; then
            # 遇到下一个 ## 标题，结束
            if echo "$line" | grep -q "^##"; then
                break
            fi
            next_action="${next_action}${line}"$'\n'
        fi
    done < "$handoff_file"

    # 从下一步动作文本中提取目标角色
    local role=""
    for r in "组合PM" "通用开发" "评审调试" "测试工程师"; do
        if echo "$next_action" | grep -q "$r"; then
            role="$r"
            break
        fi
    done

    echo "$role"
}

# --- 辅助函数 ---

acquire_lock_or_fail() {
    local lock_name="$1"
    local lock_file="${RUN_DIR}/locks/${lock_name}.lock"

    local elapsed=0
    while [ "$elapsed" -lt 30 ]; do
        if [ ! -f "$lock_file" ]; then
            echo $$ > "${lock_file}.tmp.$$"
            if mv "${lock_file}.tmp.$$" "$lock_file" 2>/dev/null; then
                return 0
            fi
            rm -f "${lock_file}.tmp.$$" 2>/dev/null
        else
            local holder
            holder=$(cat "$lock_file" 2>/dev/null || echo "")
            if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
                echo $$ > "${lock_file}.tmp.$$"
                if mv "${lock_file}.tmp.$$" "$lock_file" 2>/dev/null; then
                    return 0
                fi
                rm -f "${lock_file}.tmp.$$" 2>/dev/null
            fi
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    return 1
}

release_lock_safe() {
    local lock_name="$1"
    local lock_file="${RUN_DIR}/locks/${lock_name}.lock"
    if [ -f "$lock_file" ]; then
        local holder
        holder=$(cat "$lock_file" 2>/dev/null || echo "")
        if [ "$holder" = "$$" ]; then
            rm -f "$lock_file"
        fi
    fi
}

extract_task_block() {
    local task_id="$1"
    local found=0
    local block=""

    while IFS= read -r line; do
        if echo "$line" | grep -q "task_id:.*\"${task_id}\""; then
            found=1
            block="${line}"$'\n'
            continue
        fi
        if [ "$found" = 1 ]; then
            if echo "$line" | grep -q "^  - task_id:"; then
                break
            fi
            block="${block}${line}"$'\n'
        fi
    done < "$INBOX_FILE"

    printf "%s" "$block"
}

remove_task_from_inbox() {
    local task_id="$1"
    local temp="${INBOX_FILE}.rm.$$"
    local found=0

    while IFS= read -r line; do
        if echo "$line" | grep -q "task_id:.*\"${task_id}\""; then
            found=1
            continue
        fi
        if [ "$found" = 1 ]; then
            if echo "$line" | grep -q "^  - task_id:"; then
                found=0
            fi
            continue
        fi
        echo "$line"
    done < "$INBOX_FILE" > "$temp"

    mv "$temp" "$INBOX_FILE"
}

remove_task_from_active() {
    local task_id="$1"
    local temp="${ACTIVE_FILE}.rm.$$"

    grep -v "\"${task_id}\"" "$ACTIVE_FILE" > "$temp" 2>/dev/null || true
    mv "$temp" "$ACTIVE_FILE"
}

get_task_field() {
    local task_id="$1"
    local field="$2"
    local found=0

    while IFS= read -r line; do
        if echo "$line" | grep -q "task_id:.*\"${task_id}\""; then
            found=1
            continue
        fi
        if [ "$found" = 1 ]; then
            if echo "$line" | grep -q "^  - task_id:"; then
                break
            fi
            if echo "$line" | grep -q "${field}:"; then
                echo "$line" | sed "s/.*${field}:[[:space:]]*//" | tr -d '"' | xargs
                return 0
            fi
        fi
    done < "$INBOX_FILE"

    return 1
}

update_task_field() {
    local task_id="$1"
    local field="$2"
    local value="$3"
    local temp="${INBOX_FILE}.upd.$$"
    local found=0

    while IFS= read -r line; do
        if echo "$line" | grep -q "task_id:.*\"${task_id}\""; then
            found=1
            echo "$line"
            continue
        fi
        if [ "$found" = 1 ]; then
            if echo "$line" | grep -q "^  - task_id:"; then
                found=0
            elif echo "$line" | grep -q "${field}:"; then
                echo "    ${field}: ${value}"
                continue
            fi
        fi
        echo "$line"
    done < "$INBOX_FILE" > "$temp"

    mv "$temp" "$INBOX_FILE"
}

# --- 主入口 ---
case "${1:-help}" in
    add)
        [ -z "${2:-}" ] && { echo "用法: queue.sh add <yaml-fields>"; exit 1; }
        cmd_add "$2"
        ;;
    list)
        cmd_list
        ;;
    next)
        cmd_next "${2:-}" "${3:-}" "${4:-}"
        ;;
    done)
        [ -z "${2:-}" ] && { echo "用法: queue.sh done <task-id>"; exit 1; }
        cmd_done "$2"
        ;;
    fail)
        [ -z "${2:-}" ] && { echo "用法: queue.sh fail <task-id>"; exit 1; }
        cmd_fail "$2"
        ;;
    retry)
        [ -z "${2:-}" ] && { echo "用法: queue.sh retry <task-id>"; exit 1; }
        cmd_fail "$2"
        ;;
    parse-handoff)
        [ -z "${2:-}" ] && { echo "用法: queue.sh parse-handoff <project>"; exit 1; }
        cmd_parse_handoff "$2"
        ;;
    help|*)
        echo "任务队列工具"
        echo "用法: queue.sh <command> [args]"
        echo ""
        echo "命令:"
        echo "  add <yaml-fields>         添加任务"
        echo "  list                      列出任务"
        echo "  next [project] [role]     取下一个可执行任务"
        echo "  done <task-id>            标记完成"
        echo "  fail <task-id>            标记失败"
        echo "  parse-handoff <project>   解析交接中的下一步角色"
        ;;
esac
