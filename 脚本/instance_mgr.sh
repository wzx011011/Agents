#!/bin/bash
# instance_mgr.sh <command> [args...]
# 实例生命周期管理。
# 命令:
#   start <task-id>         — 为任务启动实例
#   stop <instance-id>      — 停止实例
#   status [instance-id]    — 查看实例状态
#   list                    — 列出所有实例
#   cleanup                 — 清理已完成的实例目录

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/acquire_lock.sh"
source "${SCRIPT_DIR}/release_lock.sh"
source "${SCRIPT_DIR}/atomic_write.sh"

RUN_DIR="${WORKSPACE_ROOT}/.run"
INSTANCES_DIR="${RUN_DIR}/instances"
LOG_FILE="${RUN_DIR}/orchestrator/orchestrator.log"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [instance_mgr] $*" >> "$LOG_FILE"
}

# --- command: start ---
cmd_start() {
    local TASK_ID="$1"
    local QUEUE_FILE="${RUN_DIR}/queue/inbox.yaml"

    # 从任务信息生成实例 ID
    local role="" project=""
    while IFS= read -r line; do
        if echo "$line" | grep -q "task_id:.*\"${TASK_ID}\""; then
            role=$(echo "$line" | grep "role:" | head -1 | sed 's/.*role:[[:space:]]*//' | tr -d '"')
            project=$(echo "$line" | grep "project:" | head -1 | sed 's/.*project:[[:space:]]*//' | tr -d '"')
            break
        fi
    done < "$QUEUE_FILE"

    # 如果没有在同一块找到，重新扫描
    if [ -z "$role" ]; then
        local found=0
        while IFS= read -r line; do
            case "$line" in
                "  - task_id:"*)
                    found=0
                    if echo "$line" | grep -q "\"${TASK_ID}\""; then found=1; fi
                    ;;
                "    role:"*)
                    if [ "$found" = 1 ]; then role=$(echo "$line" | sed 's/.*role:[[:space:]]*//' | tr -d '"'); fi
                    ;;
                "    project:"*)
                    if [ "$found" = 1 ]; then project=$(echo "$line" | sed 's/.*project:[[:space:]]*//' | tr -d '"'); fi
                    ;;
            esac
        done < "$QUEUE_FILE"
    fi

    if [ -z "$role" ] || [ -z "$project" ]; then
        echo "ERROR: 无法找到任务 ${TASK_ID} 的 role 或 project" >&2
        return 1
    fi

    local INSTANCE_ID="${role}-${project}-$(date +%s)"

    # 获取项目锁
    if ! acquire_lock.sh "$project" 60; then
        echo "ERROR: 项目 ${project} 已被锁定，无法启动实例" >&2
        return 1
    fi

    # 启动实例
    local pid
    pid=$(bash "${SCRIPT_DIR}/launch_instance.sh" "$INSTANCE_ID" "$TASK_ID")
    echo "实例已启动: ${INSTANCE_ID} (pid=${pid})"
    log "实例已启动: ${INSTANCE_ID} pid=${pid} task=${TASK_ID} role=${role} project=${project}"
}

# --- command: stop ---
cmd_stop() {
    local INSTANCE_ID="$1"
    local INSTANCE_DIR="${INSTANCES_DIR}/${INSTANCE_ID}"

    if [ ! -d "$INSTANCE_DIR" ]; then
        echo "ERROR: 实例 ${INSTANCE_ID} 不存在" >&2
        return 1
    fi

    local pid=""
    if [ -f "${INSTANCE_DIR}/pid" ]; then
        pid=$(cat "${INSTANCE_DIR}/pid")
    fi

    local watchdog_pid=""
    if [ -f "${INSTANCE_DIR}/watchdog.pid" ]; then
        watchdog_pid=$(cat "${INSTANCE_DIR}/watchdog.pid")
    fi

    # 发送 SIGTERM
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
        log "发送 SIGTERM 到实例 ${INSTANCE_ID} (pid=${pid})"

        # 等待最多 30 秒
        local waited=0
        while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 30 ]; do
            sleep 2
            waited=$((waited + 2))
        done

        # 强制终止
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
            log "强制终止实例 ${INSTANCE_ID} (pid=${pid})"
        fi
    fi

    # 终止 watchdog
    if [ -n "$watchdog_pid" ] && kill -0 "$watchdog_pid" 2>/dev/null; then
        kill -TERM "$watchdog_pid" 2>/dev/null || true
    fi

    # 更新状态
    sed -i "s/status: running/status: stopped/" "${INSTANCE_DIR}/instance.yaml" 2>/dev/null || true

    # 释放项目锁
    local project=""
    project=$(grep "project:" "${INSTANCE_DIR}/instance.yaml" 2>/dev/null | head -1 | sed 's/.*project:[[:space:]]*//' | tr -d '"')
    if [ -n "$project" ]; then
        release_lock.sh "$project"
    fi

    echo "实例已停止: ${INSTANCE_ID}"
    log "实例已停止: ${INSTANCE_ID}"
}

# --- command: status ---
cmd_status() {
    if [ -n "${1:-}" ]; then
        local INSTANCE_DIR="${INSTANCES_DIR}/${1}"
        if [ -d "$INSTANCE_DIR" ]; then
            cat "${INSTANCE_DIR}/instance.yaml"
            echo ""
            if [ -f "${INSTANCE_DIR}/exit_code" ]; then
                echo "Exit code: $(cat ${INSTANCE_DIR}/exit_code)"
            fi
        else
            echo "实例 ${1} 不存在"
        fi
    else
        # 显示所有实例概览
        echo "=== 运行中实例 ==="
        local found=0
        for dir in "${INSTANCES_DIR}"/*/; do
            [ -d "$dir" ] || continue
            local status
            status=$(grep "status:" "${dir}instance.yaml" 2>/dev/null | head -1 | sed 's/.*status:[[:space:]]*//' || echo "unknown")
            if [ "$status" = "running" ]; then
                local iid role project pid
                iid=$(basename "$dir")
                role=$(grep "role:" "${dir}instance.yaml" 2>/dev/null | head -1 | sed 's/.*role:[[:space:]]*//' | tr -d '"' || echo "?")
                project=$(grep "project:" "${dir}instance.yaml" 2>/dev/null | head -1 | sed 's/.*project:[[:space:]]*//' | tr -d '"' || echo "?")
                pid=$(cat "${dir}pid" 2>/dev/null || echo "?")
                echo "  ${iid} | role=${role} | project=${project} | pid=${pid}"
                found=1
            fi
        done
        if [ "$found" = 0 ]; then
            echo "  (无)"
        fi

        echo ""
        echo "=== 最近完成的实例 ==="
        found=0
        for dir in "${INSTANCES_DIR}"/*/; do
            [ -d "$dir" ] || continue
            local status
            status=$(grep "status:" "${dir}instance.yaml" 2>/dev/null | head -1 | sed 's/.*status:[[:space:]]*//' || echo "unknown")
            if [ "$status" = "completed" ] || [ "$status" = "failed" ]; then
                local iid role project
                iid=$(basename "$dir")
                role=$(grep "role:" "${dir}instance.yaml" 2>/dev/null | head -1 | sed 's/.*role:[[:space:]]*//' | tr -d '"' || echo "?")
                project=$(grep "project:" "${dir}instance.yaml" 2>/dev/null | head -1 | sed 's/.*project:[[:space:]]*//' | tr -d '"' || echo "?")
                local exit_code
                exit_code=$(cat "${dir}exit_code" 2>/dev/null || echo "?")
                echo "  ${iid} | role=${role} | project=${project} | exit=${exit_code}"
                found=1
            fi
        done
        if [ "$found" = 0 ]; then
            echo "  (无)"
        fi
    fi
}

# --- command: list ---
cmd_list() {
    cmd_status
}

# --- command: cleanup ---
cmd_cleanup() {
    local count=0
    for dir in "${INSTANCES_DIR}"/*/; do
        [ -d "$dir" ] || continue
        local status
        status=$(grep "status:" "${dir}instance.yaml" 2>/dev/null | head -1 | sed 's/.*status:[[:space:]]*//' || echo "unknown")
        if [ "$status" = "completed" ] || [ "$status" = "failed" ] || [ "$status" = "stopped" ]; then
            rm -rf "$dir"
            count=$((count + 1))
        fi
    done
    echo "已清理 ${count} 个已结束的实例目录"
    log "清理了 ${count} 个实例目录"
}

# --- 主入口 ---
case "${1:-help}" in
    start)
        [ -z "${2:-}" ] && { echo "用法: instance_mgr.sh start <task-id>"; exit 1; }
        cmd_start "$2"
        ;;
    stop)
        [ -z "${2:-}" ] && { echo "用法: instance_mgr.sh stop <instance-id>"; exit 1; }
        cmd_stop "$2"
        ;;
    status)
        cmd_status "${2:-}"
        ;;
    list)
        cmd_list
        ;;
    cleanup)
        cmd_cleanup
        ;;
    help|*)
        echo "实例管理工具"
        echo "用法: instance_mgr.sh <command> [args]"
        echo ""
        echo "命令:"
        echo "  start <task-id>       为任务启动实例"
        echo "  stop <instance-id>    停止实例"
        echo "  status [instance-id]  查看实例状态"
        echo "  list                  列出所有实例"
        echo "  cleanup               清理已完成的实例"
        ;;
esac
