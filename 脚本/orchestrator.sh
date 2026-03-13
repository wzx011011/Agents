#!/bin/bash
# orchestrator.sh <command> [args]
# 多实例 Headless 编排器主入口。
# 命令:
#   start                   启动编排器
#   stop                    优雅关闭
#   status                  查看状态
#   add-task [options]      手动添加任务
#   resume-project <project> 解除项目阻塞

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RUN_DIR="${WORKSPACE_ROOT}/.run"
STATE_FILE="${RUN_DIR}/orchestrator/state.yaml"
CONFIG_FILE="${RUN_DIR}/orchestrator/config.yaml"
LOG_FILE="${RUN_DIR}/orchestrator/orchestrator.log"
PID_FILE="${RUN_DIR}/orchestrator/orchestrator.pid"
NOTIFICATIONS_FILE="${RUN_DIR}/notifications.txt"

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$PID_FILE")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [orchestrator] $*" | tee -a "$LOG_FILE"
}

# --- command: start ---
cmd_start() {
    # 检查是否已在运行
    if [ -f "$PID_FILE" ]; then
        local existing_pid
        existing_pid=$(cat "$PID_FILE")
        if kill -0 "$existing_pid" 2>/dev/null; then
            echo "编排器已在运行 (pid=${existing_pid})"
            return 0
        else
            echo "发现过期 PID 文件，清理中..."
            rm -f "$PID_FILE"
        fi
    fi

    # 初始化状态文件
    if [ ! -f "$STATE_FILE" ]; then
        cat > "$STATE_FILE" <<'EOF'
orchestrator:
  status: "stopped"
  started_at: null
  last_cycle_at: null
  cycles_completed: 0
  tasks_completed_total: 0
  tasks_failed_total: 0

active_instances: []

project_locks:
  项目-A: null
  项目-B: null
  项目-C: null
  项目-D: null
  项目-E: null
EOF
    fi

    # 更新状态为 running
    local now_ts
    now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    sed -i "s/^  status: .*/  status: running/" "$STATE_FILE"
    sed -i "s/^  started_at: .*/  started_at: ${now_ts}/" "$STATE_FILE"

    # 清理过期锁
    for lock in "${RUN_DIR}/locks/"*.lock; do
        [ -f "$lock" ] || continue
        local holder
        holder=$(cat "$lock" 2>/dev/null || echo "")
        if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then
            rm -f "$lock"
            log "清理过期锁: $(basename "$lock")"
        fi
    done

    # 后台启动调度器
    bash "${SCRIPT_DIR}/scheduler.sh" run &
    SCHEDULER_PID=$!
    echo "$SCHEDULER_PID" > "$PID_FILE"

    log "编排器已启动 (pid=${SCHEDULER_PID})"
    echo "编排器已启动 (pid=${SCHEDULER_PID})"
    echo "使用 'bash 脚本/orchestrator.sh status' 查看状态"
}

# --- command: stop ---
cmd_stop() {
    if [ ! -f "$PID_FILE" ]; then
        echo "编排器未在运行"
        return 0
    fi

    local pid
    pid=$(cat "$PID_FILE")

    if ! kill -0 "$pid" 2>/dev/null; then
        echo "编排器进程已退出，清理状态..."
        rm -f "$PID_FILE"
        sed -i 's/^  status: .*/  status: stopped/' "$STATE_FILE"
        return 0
    fi

    log "正在停止编排器 (pid=${pid})..."

    # 更新状态为 stopping
    sed -i 's/^  status: .*/  status: stopping/' "$STATE_FILE"

    # 发送 SIGTERM
    kill -TERM "$pid" 2>/dev/null || true

    # 等待调度器退出
    local waited=0
    while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 30 ]; do
        sleep 2
        waited=$((waited + 2))
    done

    # 强制终止
    if kill -0 "$pid" 2>/dev/null; then
        log "强制终止调度器..."
        kill -9 "$pid" 2>/dev/null || true
    fi

    # 停止所有运行中的实例
    for dir in "${RUN_DIR}/instances/"*/; do
        [ -d "$dir" ] || continue
        local status
        status=$(grep "^status:" "${dir}instance.yaml" 2>/dev/null | sed 's/^status:[[:space:]]*//' || echo "unknown")
        if [ "$status" = "running" ]; then
            local iid
            iid=$(basename "$dir")
            bash "${SCRIPT_DIR}/instance_mgr.sh" stop "$iid" 2>/dev/null || true
        fi
    done

    # 清理
    rm -f "$PID_FILE"
    sed -i 's/^  status: .*/  status: stopped/' "$STATE_FILE"

    # 释放所有锁
    for lock in "${RUN_DIR}/locks/"*.lock; do
        [ -f "$lock" ] || continue
        rm -f "$lock"
    done

    log "编排器已停止"
    echo "编排器已停止"
}

# --- command: status ---
cmd_status() {
    echo "=== 编排器状态 ==="

    if [ -f "$PID_FILE" ]; then
        local pid
        pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            echo "状态: 运行中 (pid=${pid})"
        else
            echo "状态: 已停止 (PID 文件存在但进程已退出)"
        fi
    else
        echo "状态: 未启动"
    fi

    echo ""

    if [ -f "$STATE_FILE" ]; then
        echo "=== 统计 ==="
        local cycles completed failed
        cycles=$(grep "cycles_completed:" "$STATE_FILE" | sed 's/.*cycles_completed:[[:space:]]*//')
        completed=$(grep "tasks_completed_total:" "$STATE_FILE" | sed 's/.*tasks_completed_total:[[:space:]]*//')
        failed=$(grep "tasks_failed_total:" "$STATE_FILE" | sed 's/.*tasks_failed_total:[[:space:]]*//')
        echo "  调度循环: ${cycles}"
        echo "  已完成任务: ${completed}"
        echo "  失败任务: ${failed}"
    fi

    echo ""
    echo "=== 项目锁 ==="
    for project in 项目-A 项目-B 项目-C 项目-D 项目-E; do
        local lock_file="${RUN_DIR}/locks/${project}.lock"
        if [ -f "$lock_file" ]; then
            local holder
            holder=$(cat "$lock_file" 2>/dev/null || echo "?")
            if kill -0 "$holder" 2>/dev/null; then
                echo "  ${project}: 已锁定 (pid=${holder})"
            else
                echo "  ${project}: 过期锁 (pid=${holder} 已死)"
            fi
        else
            echo "  ${project}: 空闲"
        fi
    done

    echo ""
    echo "=== 活跃实例 ==="
    local found=0
    for dir in "${RUN_DIR}/instances/"*/; do
        [ -d "$dir" ] || continue
        local status
        status=$(grep "^status:" "${dir}instance.yaml" 2>/dev/null | sed 's/^status:[[:space:]]*//' || echo "unknown")
        if [ "$status" = "running" ]; then
            local iid role project pid
            iid=$(basename "$dir")
            role=$(grep "^role:" "${dir}instance.yaml" 2>/dev/null | head -1 | sed 's/^role:[[:space:]]*//' | tr -d '"' || echo "?")
            project=$(grep "^project:" "${dir}instance.yaml" 2>/dev/null | head -1 | sed 's/^project:[[:space:]]*//' | tr -d '"' || echo "?")
            pid=$(cat "${dir}pid" 2>/dev/null || echo "?")
            local runtime=""
            if [ -f "${dir}/heartbeat" ]; then
                local hb
                hb=$(cat "${dir}/heartbeat")
                local now
                now=$(date +%s)
                local mins=$(( (now - hb) / 60 ))
                runtime="${mins} 分钟"
            fi
            echo "  ${iid} | ${role} | ${project} | pid=${pid} | ${runtime:-刚启动}"
            found=1
        fi
    done
    [ "$found" = 0 ] && echo "  (无)"

    echo ""
    echo "=== 待执行任务 ==="
    if [ -f "${RUN_DIR}/queue/inbox.yaml" ]; then
        local task_count=0
        local in_queue=0
        while IFS= read -r line; do
            if echo "$line" | grep -q "^queue:"; then in_queue=1; continue; fi
            if [ "$in_queue" = 1 ]; then
                if echo "$line" | grep -q "task_id:"; then
                    task_count=$((task_count + 1))
                    local tid
                    tid=$(echo "$line" | sed 's/.*task_id:[[:space:]]*//' | tr -d '"')
                fi
                if echo "$line" | grep -q "role:"; then
                    local trot
                    trot=$(echo "$line" | sed 's/.*role:[[:space:]]*//' | tr -d '"')
                    echo "  任务 (role=${trot})"
                fi
            fi
        done < "${RUN_DIR}/queue/inbox.yaml"
        [ "$task_count" = 0 ] && echo "  (空)"
    fi

    echo ""
    if [ -f "$NOTIFICATIONS_FILE" ] && [ -s "$NOTIFICATIONS_FILE" ]; then
        echo "=== 通知 ==="
        tail -10 "$NOTIFICATIONS_FILE" | while IFS= read -r line; do
            echo "  ${line}"
        done
    fi
}

# --- command: add-task ---
cmd_add_task() {
    local project="" role="" type="" prompt=""

    # 解析参数
    while [ $# -gt 0 ]; do
        case "$1" in
            --project) project="$2"; shift 2 ;;
            --role) role="$2"; shift 2 ;;
            --type) type="$2"; shift 2 ;;
            --prompt) prompt="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [ -z "$project" ] || [ -z "$role" ] || [ -z "$prompt" ]; then
        echo "用法: orchestrator.sh add-task --project <项目> --role <角色> [--type repo|ops] --prompt \"提示\""
        echo ""
        echo "可用角色: 组合PM, 通用开发, 评审调试, 测试工程师"
        echo "可用项目: 项目-A, 项目-B, 项目-C, 项目-D, 项目-E"
        return 1
    fi

    [ -z "$type" ] && type="ops"

    local task_id
    task_id="TASK-$(date +%Y%m%d)-$(date +%s | tail -c 4)"
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    local cwd_override="$WORKSPACE_ROOT"
    if [ "$type" = "repo" ]; then
        # 尝试从项目状态获取 repo_path
        local state_file="${WORKSPACE_ROOT}/项目/${project}/项目状态.yaml"
        if [ -f "$state_file" ]; then
            local repo_path
            repo_path=$(grep "repo_path:" "$state_file" 2>/dev/null | head -1 | sed 's/.*repo_path:[[:space:]]*//' | tr -d '"' | sed 's/null$//' || echo "")
            [ -n "$repo_path" ] && cwd_override="$repo_path"
        fi
    fi

    local inbox="${RUN_DIR}/queue/inbox.yaml"
    local task_entry="  - task_id: \"${task_id}\"
    project: \"${project}\"
    role: \"${role}\"
    priority: 1
    type: \"${type}\"
    cwd_override: \"${cwd_override}\"
    prompt: |
${prompt}
    status: \"queued\"
    retry_count: 0
    max_retries: 2
    depends_on: []
    created_at: \"${timestamp}\"
    assigned_at: null
    started_at: null
    completed_at: null"

    if grep -q "^queue: \[\]$" "$inbox"; then
        echo "queue:
${task_entry}" > "$inbox"
    else
        echo "$task_entry" >> "$inbox"
    fi

    log "手动添加任务: ${task_id} (role=${role} project=${project} type=${type})"
    echo "任务已添加: ${task_id}"
    echo "  项目: ${project}"
    echo "  角色: ${role}"
    echo "  类型: ${type}"
}

# --- command: resume-project ---
cmd_resume_project() {
    local project="$1"
    local lock_file="${RUN_DIR}/locks/${project}.lock"

    if [ -f "$lock_file" ]; then
        rm -f "$lock_file"
        log "已释放项目锁: ${project}"
        echo "已释放 ${project} 的锁，编排器将在下一个循环中重新分配任务"
    else
        echo "${project} 没有被锁定"
    fi

    # 清除通知
    if [ -f "$NOTIFICATIONS_FILE" ]; then
        sed -i "/${project}/d" "$NOTIFICATIONS_FILE"
    fi
}

# --- 主入口 ---
case "${1:-help}" in
    start)
        cmd_start
        ;;
    stop)
        cmd_stop
        ;;
    status)
        cmd_status
        ;;
    add-task)
        shift
        cmd_add_task "$@"
        ;;
    resume-project)
        [ -z "${2:-}" ] && { echo "用法: orchestrator.sh resume-project <项目>"; exit 1; }
        cmd_resume_project "$2"
        ;;
    help|*)
        echo "多实例 Headless 编排器"
        echo ""
        echo "用法: orchestrator.sh <command> [args]"
        echo ""
        echo "命令:"
        echo "  start                         启动编排器（后台运行调度循环）"
        echo "  stop                          优雅关闭所有实例和编排器"
        echo "  status                        查看编排器、实例、队列和锁的状态"
        echo "  add-task --project P --role R [--type T] --prompt \"...\""
        echo "                                手动添加任务到队列"
        echo "  resume-project <项目>         释放项目锁并清除相关通知"
        echo ""
        echo "示例:"
        echo "  bash 脚本/orchestrator.sh start"
        echo "  bash 脚本/orchestrator.sh status"
        echo "  bash 脚本/orchestrator.sh add-task --project 项目-A --role 通用开发 --type repo --prompt '实现登录功能'"
        echo "  bash 脚本/orchestrator.sh stop"
        ;;
esac
