#!/bin/bash
# acquire_lock.sh <lock-name> [timeout-seconds]
# 获取文件锁。成功返回 0，超时返回 1。
# 用法: acquire_lock.sh 项目-A 60

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOCKS_DIR="${WORKSPACE_ROOT}/.run/locks"

LOCK_NAME="$1"
TIMEOUT="${2:-60}"
LOCK_FILE="${LOCKS_DIR}/${LOCK_NAME}.lock"

mkdir -p "$LOCKS_DIR"

elapsed=0
interval=2

while [ "$elapsed" -lt "$TIMEOUT" ]; do
    if [ ! -f "$LOCK_FILE" ]; then
        # 锁空闲，尝试获取
        echo $$ > "${LOCK_FILE}.tmp.$$"
        if mv "${LOCK_FILE}.tmp.$$" "$LOCK_FILE" 2>/dev/null; then
            return 0
        fi
        # mv 失败，说明有竞争，重试
        rm -f "${LOCK_FILE}.tmp.$$" 2>/dev/null
    else
        # 锁被持有，检查持有者是否存活
        holder_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        if [ -n "$holder_pid" ] && ! kill -0 "$holder_pid" 2>/dev/null; then
            # 持有者已死亡，回收过期锁
            echo $$ > "${LOCK_FILE}.tmp.$$"
            if mv "${LOCK_FILE}.tmp.$$" "$LOCK_FILE" 2>/dev/null; then
                return 0
            fi
            rm -f "${LOCK_FILE}.tmp.$$" 2>/dev/null
        fi
    fi

    sleep "$interval"
    elapsed=$((elapsed + interval))
done

return 1
