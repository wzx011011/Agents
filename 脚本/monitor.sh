#!/bin/bash
# monitor.sh
# 检查所有活跃实例的健康状态。
# 返回: 0 = 全部健康, 1 = 有异常

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RUN_DIR="${WORKSPACE_ROOT}/.run"
INSTANCES_DIR="${RUN_DIR}/instances"
CONFIG_FILE="${RUN_DIR}/orchestrator/config.yaml"
LOG_FILE="${RUN_DIR}/orchestrator/orchestrator.log"

STALE_HEARTBEAT_SECONDS=120

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [monitor] $*" >> "$LOG_FILE"
}

# 返回需要处理的实例列表（JSON 格式：status:instance_id）
changed_instances=""

check_instance() {
    local instance_dir="$1"
    local instance_id
    instance_id=$(basename "$instance_dir")

    # 读取实例状态
    local status
    status=$(grep "^status:" "${instance_dir}/instance.yaml" 2>/dev/null | sed 's/^status:[[:space:]]*//' || echo "unknown")

    # 只检查运行中的实例
    if [ "$status" != "running" ]; then
        return
    fi

    local pid=""
    if [ -f "${instance_dir}/pid" ]; then
        pid=$(cat "${instance_dir}/pid")
    fi

    if [ -z "$pid" ]; then
        log "实例 ${instance_id} 无 PID，标记为失败"
        sed -i 's/status: running/status: failed/' "${instance_dir}/instance.yaml"
        echo "failed:${instance_id}"
        return
    fi

    # 检查进程是否存活
    if ! kill -0 "$pid" 2>/dev/null; then
        # 进程已退出，读取退出码
        local exit_code
        exit_code=$(cat "${instance_dir}/exit_code" 2>/dev/null || echo "1")

        if [ "$exit_code" = "0" ]; then
            log "实例 ${instance_id} 已完成 (exit=0)"
            sed -i 's/status: running/status: completed/' "${instance_dir}/instance.yaml"
            echo "completed:${instance_id}"
        else
            log "实例 ${instance_id} 失败 (exit=${exit_code})"
            sed -i 's/status: running/status: failed/' "${instance_dir}/instance.yaml"
            echo "failed:${instance_id}"
        fi
        return
    fi

    # 检查心跳是否过期
    local heartbeat=""
    if [ -f "${instance_dir}/heartbeat" ]; then
        heartbeat=$(cat "${instance_dir}/heartbeat")
    fi

    if [ -n "$heartbeat" ]; then
        local now
        now=$(date +%s)
        local age=$((now - heartbeat))

        if [ "$age" -gt "$STALE_HEARTBEAT_SECONDS" ]; then
            log "实例 ${instance_id} 心跳过期 (${age}s)，标记为超时"
            sed -i 's/status: running/status: timed_out/' "${instance_dir}/instance.yaml"
            echo "timed_out:${instance_id}"
            return
        fi
    fi

    # 实例健康
    echo "running:${instance_id}"
}

# 检查所有实例
for dir in "${INSTANCES_DIR}"/*/; do
    [ -d "$dir" ] || continue
    result=$(check_instance "$dir")
    if [ -n "$result" ] && [ "$result" != "running:${dir%/}" ]; then
        changed_instances="${changed_instances}${result}"$'\n'
    fi
done

# 输出状态变化的实例（每行一个 status:instance_id）
if [ -n "$changed_instances" ]; then
    echo "$changed_instances"
fi
