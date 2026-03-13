#!/bin/bash
# release_lock.sh <lock-name>
# 释放文件锁。仅当持有者是当前进程时才释放。
# 用法: release_lock.sh 项目-A

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOCKS_DIR="${WORKSPACE_ROOT}/.run/locks"

LOCK_NAME="$1"
LOCK_FILE="${LOCKS_DIR}/${LOCK_NAME}.lock"

if [ -f "$LOCK_FILE" ]; then
    holder_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
    if [ "$holder_pid" = "$$" ]; then
        rm -f "$LOCK_FILE"
    fi
fi
