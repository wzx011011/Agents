#!/bin/bash
# scheduler.sh
# 编排器调度循环。轮询任务队列，启动实例，检测完成。
# 通常由 orchestrator.sh 启动，也可独立运行。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
source "${SCRIPT_DIR}/acquire_lock.sh"
source "${SCRIPT_DIR}/release_lock.sh"
source "${SCRIPT_DIR}/atomic_write.sh"

RUN_DIR="${WORKSPACE_ROOT}/.run"
INSTANCES_DIR="${RUN_DIR}/instances"
CONFIG_FILE="${RUN_DIR}/orchestrator/config.yaml"
STATE_FILE="${RUN_DIR}/orchestrator/state.yaml"
LOG_FILE="${RUN_DIR}/orchestrator/orchestrator.log"
NOTIFICATIONS_FILE="${RUN_DIR}/notifications.txt"

# 配置默认值
MAX_PARALLEL=4
POLL_INTERVAL=15
MAX_RETRIES=2

# 读取配置（简单解析）
if [ -f "$CONFIG_FILE" ]; then
    MAX_PARALLEL=$(grep "max_parallel_instances:" "$CONFIG_FILE" | sed 's/.*max_parallel_instances:[[:space:]]*//' || echo "4")
    POLL_INTERVAL=$(grep "poll_interval_seconds:" "$CONFIG_FILE" | sed 's/.*poll_interval_seconds:[[:space:]]*//' || echo "15")
    MAX_RETRIES=$(grep "max_retries:" "$CONFIG_FILE" | tail -1 | sed 's/.*max_retries:[[:space:]]*//' || echo "2")
fi

mkdir -p "$(dirname "$LOG_FILE")"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [scheduler] $*" >> "$LOG_FILE"
}

notify() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$NOTIFICATIONS_FILE"
}

# --- 统计运行中的实例数 ---
count_running_instances() {
    local count=0
    for dir in "${INSTANCES_DIR}"/*/; do
        [ -d "$dir" ] || continue
        local status
        status=$(grep "^status:" "${dir}instance.yaml" 2>/dev/null | sed 's/^status:[[:space:]]*//' || echo "unknown")
        if [ "$status" = "running" ]; then
            count=$((count + 1))
        fi
    done
    echo "$count"
}

# --- 统计某角色运行中的实例数 ---
count_running_by_role() {
    local target_role="$1"
    local count=0
    for dir in "${INSTANCES_DIR}"/*/; do
        [ -d "$dir" ] || continue
        local status
        status=$(grep "^status:" "${dir}instance.yaml" 2>/dev/null | sed 's/^status:[[:space:]]*//' || echo "unknown")
        if [ "$status" != "running" ]; then continue; fi
        local role
        role=$(grep "^role:" "${dir}instance.yaml" 2>/dev/null | head -1 | sed 's/^role:[[:space:]]*//' | tr -d '"' || echo "")
        if [ "$role" = "$target_role" ]; then
            count=$((count + 1))
        fi
    done
    echo "$count"
}

# --- 检查项目是否锁定 ---
is_project_locked() {
    local project="$1"
    local lock_file="${RUN_DIR}/locks/${project}.lock"
    if [ -f "$lock_file" ]; then
        local holder
        holder=$(cat "$lock_file" 2>/dev/null || echo "")
        if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
            return 0  # 已锁定
        fi
    fi
    return 1  # 未锁定
}

# --- 从 inbox 中找下一个可执行任务 ---
find_next_task() {
    local inbox_file="${RUN_DIR}/queue/inbox.yaml"
    local found=0
    local task_id="" task_role="" task_project="" task_status="" task_deps=""

    while IFS= read -r line; do
        if echo "$line" | grep -q "^  - task_id:"; then
            # 输出上一个找到的任务（如果有）
            if [ "$found" = 1 ] && [ "$task_status" = "queued" ]; then
                echo "${task_id}|${task_role}|${task_project}"
                return 0
            fi
            # 开始新任务
            task_id=$(echo "$line" | sed 's/.*task_id:[[:space:]]*//' | tr -d '"')
            task_role=""
            task_project=""
            task_status=""
            task_deps=""
            found=1
            continue
        fi
        if [ "$found" = 1 ]; then
            case "$line" in
                "    role:"*)  task_role=$(echo "$line" | sed 's/.*role:[[:space:]]*//' | tr -d '"') ;;
                "    project:"*) task_project=$(echo "$line" | sed 's/.*project:[[:space:]]*//' | tr -d '"') ;;
                "    status:"*) task_status=$(echo "$line" | sed 's/.*status:[[:space:]]*//') ;;
                "    depends_on:"*) task_deps=$(echo "$line" | sed 's/.*depends_on:[[:space:]]*//') ;;
            esac
        fi
    done < "$inbox_file"

    # 处理最后一个任务
    if [ "$found" = 1 ] && [ "$task_status" = "queued" ]; then
        echo "${task_id}|${task_role}|${task_project}"
    fi
}

# --- 处理已完成的实例 ---
handle_completed_instance() {
    local instance_id="$1"
    local instance_dir="${INSTANCES_DIR}/${instance_id}"
    local project role task_id

    project=$(grep "^project:" "${instance_dir}/instance.yaml" 2>/dev/null | head -1 | sed 's/^project:[[:space:]]*//' | tr -d '"' || echo "")
    role=$(grep "^role:" "${instance_dir}/instance.yaml" 2>/dev/null | head -1 | sed 's/^role:[[:space:]]*//' | tr -d '"' || echo "")
    task_id=$(grep "^task_id:" "${instance_dir}/instance.yaml" 2>/dev/null | head -1 | sed 's/^task_id:[[:space:]]*//' | tr -d '"' || echo "")

    log "处理完成实例: ${instance_id} (role=${role} project=${project} task=${task_id})"

    # 1. 标记任务完成
    if [ -n "$task_id" ]; then
        # 从 inbox 移除，归档到 completed
        local completed_dir="${RUN_DIR}/queue/completed"
        mkdir -p "$completed_dir"
        if [ -f "${RUN_DIR}/queue/inbox.yaml" ]; then
            extract_task_to_file "$task_id" "${completed_dir}/${task_id}.yaml"
            remove_task "$task_id"
        fi
    fi

    # 2. 释放项目锁
    if [ -n "$project" ]; then
        release_lock.sh "$project"
        log "释放项目锁: ${project}"
    fi

    # 3. 解析交接文件，为下一角色创建任务
    if [ -n "$project" ]; then
        local next_role
        next_role=$(parse_handoff "$project")
        if [ -n "$next_role" ]; then
            create_next_task "$project" "$next_role"
            log "为下一角色创建任务: project=${project} role=${next_role}"
        else
            log "无法从交接文件解析下一步角色: ${project}"
            notify "WARNING: 无法解析 ${project} 的下一步角色，需要人工检查交接文件"
        fi
    fi

    # 4. 更新全局状态计数
    update_state_count "completed" 1
}

# --- 处理失败的实例 ---
handle_failed_instance() {
    local instance_id="$1"
    local instance_dir="${INSTANCES_DIR}/${instance_id}"
    local project role task_id

    project=$(grep "^project:" "${instance_dir}/instance.yaml" 2>/dev/null | head -1 | sed 's/^project:[[:space:]]*//' | tr -d '"' || echo "")
    role=$(grep "^role:" "${instance_dir}/instance.yaml" 2>/dev/null | head -1 | sed 's/^role:[[:space:]]*//' | tr -d '"' || echo "")
    task_id=$(grep "^task_id:" "${instance_dir}/instance.yaml" 2>/dev/null | head -1 | sed 's/^task_id:[[:space:]]*//' | tr -d '"' || echo "")

    log "处理失败实例: ${instance_id} (role=${role} project=${project})"

    # 释放项目锁
    if [ -n "$project" ]; then
        release_lock.sh "$project"
    fi

    # 检查重试
    if [ -n "$task_id" ]; then
        local retry_count
        retry_count=$(get_task_retry_count "$task_id" || echo "0")
        if [ "$retry_count" -lt "$MAX_RETRIES" ]; then
            # 重试：更新状态为 queued
            update_task_status "$task_id" "queued"
            increment_retry "$task_id"
            log "任务 ${task_id} 将重试 (第 $((retry_count + 1)) 次)"
        else
            # 永久失败
            local failed_dir="${RUN_DIR}/queue/failed"
            mkdir -p "$failed_dir"
            extract_task_to_file "$task_id" "${failed_dir}/${task_id}.yaml"
            remove_task "$task_id"
            log "任务 ${task_id} 永久失败"
            notify "FAILED: 任务 ${task_id} (role=${role} project=${project}) 已达最大重试次数"
            update_state_count "failed" 1
        fi
    fi
}

# --- 处理超时实例 ---
handle_timed_out_instance() {
    local instance_id="$1"
    local instance_dir="${INSTANCES_DIR}/${instance_id}"

    log "处理超时实例: ${instance_id}"

    local pid=""
    if [ -f "${instance_dir}/pid" ]; then
        pid=$(cat "${instance_dir}/pid")
    fi

    # 终止进程
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill -TERM "$pid" 2>/dev/null || true
        sleep 5
        if kill -0 "$pid" 2>/dev/null; then
            kill -9 "$pid" 2>/dev/null || true
        fi
    fi

    # 终止 watchdog
    local watchdog_pid=""
    if [ -f "${instance_dir}/watchdog.pid" ]; then
        watchdog_pid=$(cat "${instance_dir}/watchdog.pid")
        if [ -n "$watchdog_pid" ] && kill -0 "$watchdog_pid" 2>/dev/null; then
            kill -TERM "$watchdog_pid" 2>/dev/null || true
        fi
    fi

    # 标记为失败，走失败处理
    sed -i 's/status: timed_out/status: failed/' "${instance_dir}/instance.yaml"
    handle_failed_instance "$instance_id"
}

# --- 队列辅助函数 ---

extract_task_to_file() {
    local task_id="$1"
    local output_file="$2"
    local found=0

    while IFS= read -r line; do
        if echo "$line" | grep -q "task_id:.*\"${task_id}\""; then
            found=1
            echo "- ${line}"
            continue
        fi
        if [ "$found" = 1 ]; then
            if echo "$line" | grep -q "^  - task_id:"; then break; fi
            echo "  ${line}"
        fi
    done < "${RUN_DIR}/queue/inbox.yaml" > "$output_file"
}

remove_task() {
    local task_id="$1"
    local inbox="${RUN_DIR}/queue/inbox.yaml"
    local temp="${inbox}.rm.$$"
    local found=0

    while IFS= read -r line; do
        if echo "$line" | grep -q "task_id:.*\"${task_id}\""; then
            found=1
            continue
        fi
        if [ "$found" = 1 ]; then
            if echo "$line" | grep -q "^  - task_id:"; then found=0; fi
            continue
        fi
        echo "$line"
    done < "$inbox" > "$temp"
    mv "$temp" "$inbox"
}

get_task_retry_count() {
    local task_id="$1"
    local found=0
    while IFS= read -r line; do
        if echo "$line" | grep -q "task_id:.*\"${task_id}\""; then found=1; continue; fi
        if [ "$found" = 1 ]; then
            if echo "$line" | grep -q "^  - task_id:"; then break; fi
            if echo "$line" | grep -q "retry_count:"; then
                echo "$line" | sed 's/.*retry_count:[[:space:]]*//' | xargs
                return 0
            fi
        fi
    done < "${RUN_DIR}/queue/inbox.yaml"
}

update_task_status() {
    local task_id="$1"
    local new_status="$2"
    local inbox="${RUN_DIR}/queue/inbox.yaml"
    local temp="${inbox}.upd.$$"
    local found=0

    while IFS= read -r line; do
        if echo "$line" | grep -q "task_id:.*\"${task_id}\""; then
            found=1
            echo "$line"
            continue
        fi
        if [ "$found" = 1 ]; then
            if echo "$line" | grep -q "^  - task_id:"; then found=0; fi
            elif echo "$line" | grep -q "status:"; then
                echo "    status: ${new_status}"
                continue
            fi
        fi
        echo "$line"
    done < "$inbox" > "$temp"
    mv "$temp" "$inbox"
}

increment_retry() {
    local task_id="$1"
    local inbox="${RUN_DIR}/queue/inbox.yaml"
    local temp="${inbox}.retry.$$"
    local found=0

    while IFS= read -r line; do
        if echo "$line" | grep -q "task_id:.*\"${task_id}\""; then
            found=1
            echo "$line"
            continue
        fi
        if [ "$found" = 1 ]; then
            if echo "$line" | grep -q "^  - task_id:"; then found=0; fi
            elif echo "$line" | grep -q "retry_count:"; then
                local count
                count=$(echo "$line" | sed 's/.*retry_count:[[:space:]]*//')
                echo "    retry_count: $((count + 1))"
                continue
            fi
        fi
        echo "$line"
    done < "$inbox" > "$temp"
    mv "$temp" "$inbox"
}

# --- 交接解析 ---
parse_handoff() {
    local project="$1"
    local handoff_file="${WORKSPACE_ROOT}/项目/${project}/交接.md"

    if [ ! -f "$handoff_file" ]; then echo ""; return; fi

    local next_action="" in_section=0
    while IFS= read -r line; do
        if echo "$line" | grep -qi "下一步动作\|明确的下一步"; then in_section=1; continue; fi
        if [ "$in_section" = 1 ]; then
            if echo "$line" | grep -q "^## "; then break; fi
            next_action="${next_action}${line}"$'\n'
        fi
    done < "$handoff_file"

    for r in "组合PM" "通用开发" "评审调试" "测试工程师"; do
        if echo "$next_action" | grep -q "$r"; then echo "$r"; return; fi
    done
}

# --- 为下一角色创建任务 ---
create_next_task() {
    local project="$1"
    local role="$2"
    local task_id
    task_id="TASK-$(date +%Y%m%d)-$(date +%s | tail -c 4)"
    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # 确定任务类型和 cwd（基于项目状态）
    local task_type="ops"
    local cwd_override="$WORKSPACE_ROOT"
    local state_file="${WORKSPACE_ROOT}/项目/${project}/项目状态.yaml"
    if [ -f "$state_file" ]; then
        local repo_path
        repo_path=$(grep "repo_path:" "$state_file" 2>/dev/null | head -1 | sed 's/.*repo_path:[[:space:]]*//' | tr -d '"' | sed 's/null$//' || echo "")
        if [ -n "$repo_path" ]; then
            task_type="repo"
            cwd_override="$repo_path"
        fi
    fi

    # 构建角色提示
    local prompt=""
    case "$role" in
        组合PM)
            prompt="你是组合PM角色。1. 读取 组合/组合索引.md 和 项目/${project}/项目状态.yaml。2. 读取交接.md 中的当前状态和已完成工作。3. 决定下一步任务分配，更新待办列表和项目状态。4. 在交接.md 中写入明确的下一步动作。"
            ;;
        通用开发)
            if [ "$task_type" = "repo" ]; then
                prompt="你是通用开发角色。1. 读取 项目/${project}/交接.md 中的下一步动作。2. 按照交接中的指示执行实现工作。3. 完成后更新 项目/${project}/当前上下文.md 和 项目/${project}/交接.md。4. 在交接中指向下一个角色。"
            else
                prompt="你是通用开发角色，执行系统运维任务。1. 读取 项目/${project}/交接.md 中的下一步动作。2. 按照交接中的指示执行操作。3. 完成后更新 项目/${project}/当前上下文.md 和 项目/${project}/交接.md。"
            fi
            ;;
        评审调试)
            prompt="你是评审调试角色。1. 读取 项目/${project}/项目状态.yaml、当前上下文.md 和交接.md。2. 对当前变更进行代码评审。3. 将发现写入 当前上下文.md 和交接.md。4. 根据结果指向 通用开发（有问题）或 测试工程师（通过）。"
            ;;
        测试工程师)
            prompt="你是测试工程师角色。1. 读取 项目/${project}/交接.md 中的验证范围。2. 执行验证并更新 项目/${project}/验证/最新测试报告.md。3. 将结果写入交接.md，指向 组合PM。"
            ;;
    esac

    # 添加任务到 inbox
    local task_entry="  - task_id: \"${task_id}\"
    project: \"${project}\"
    role: \"${role}\"
    priority: 1
    type: \"${task_type}\"
    cwd_override: \"${cwd_override}\"
    prompt: |
${prompt}
    status: \"queued\"
    retry_count: 0
    max_retries: ${MAX_RETRIES}
    depends_on: []
    created_at: \"${timestamp}\"
    assigned_at: null
    started_at: null
    completed_at: null"

    local inbox="${RUN_DIR}/queue/inbox.yaml"
    if grep -q "^queue: \[\]$" "$inbox"; then
        echo "queue:
${task_entry}" | atomic_write.sh "$inbox"
    else
        echo "$task_entry" >> "$inbox"
    fi
}

# --- 更新全局状态 ---
update_state_count() {
    local field="$1"
    local delta="$2"
    if [ ! -f "$STATE_FILE" ]; then return; fi

    local current
    case "$field" in
        completed)
            current=$(grep "tasks_completed_total:" "$STATE_FILE" | sed 's/.*tasks_completed_total:[[:space:]]*//' || echo "0")
            sed -i "s/tasks_completed_total: ${current}/tasks_completed_total: $((current + delta))/" "$STATE_FILE"
            ;;
        failed)
            current=$(grep "tasks_failed_total:" "$STATE_FILE" | sed 's/.*tasks_failed_total:[[:space:]]*//' || echo "0")
            sed -i "s/tasks_failed_total: ${current}/tasks_failed_total: $((current + delta))/" "$STATE_FILE"
            ;;
    esac
}

# --- 主调度循环 ---
main_loop() {
    log "调度器启动"
    echo "调度器已启动，轮询间隔 ${POLL_INTERVAL}s"

    while true; do
        # 检查编排器是否仍在运行
        if [ -f "${RUN_DIR}/orchestrator/state.yaml" ]; then
            local orchestrator_status
            orchestrator_status=$(grep "^  status:" "${RUN_DIR}/orchestrator/state.yaml" | sed 's/^  status:[[:space:]]*//' || echo "unknown")
            if [ "$orchestrator_status" = "stopping" ] || [ "$orchestrator_status" = "stopped" ]; then
                log "编排器状态为 ${orchestrator_status}，调度器退出"
                break
            fi
        fi

        # --- Phase 1: 检查所有实例 ---
        for dir in "${INSTANCES_DIR}"/*/; do
            [ -d "$dir" ] || continue
            local iid
            iid=$(basename "$dir")
            local status
            status=$(grep "^status:" "${dir}instance.yaml" 2>/dev/null | sed 's/^status:[[:space:]]*//' || echo "unknown")

            case "$status" in
                completed)
                    handle_completed_instance "$iid"
                    ;;
                failed)
                    handle_failed_instance "$iid"
                    ;;
                timed_out)
                    handle_timed_out_instance "$iid"
                    ;;
            esac
        done

        # --- Phase 2: 从队列取任务并启动实例 ---
        local running_count
        running_count=$(count_running_instances)

        if [ "$running_count" -lt "$MAX_PARALLEL" ]; then
            local task_info
            task_info=$(find_next_task)
            if [ -n "$task_info" ]; then
                local tid trot tproj
                tid=$(echo "$task_info" | cut -d'|' -f1)
                trot=$(echo "$task_info" | cut -d'|' -f2)
                tproj=$(echo "$task_info" | cut -d'|' -f3)

                # 检查项目锁
                if ! is_project_locked "$tproj"; then
                    # 检查角色限制
                    local role_count
                    role_count=$(count_running_by_role "$trot")
                    local role_limit=1
                    case "$trot" in
                        通用开发) role_limit=2 ;;
                    esac

                    if [ "$role_count" -lt "$role_limit" ]; then
                        # 获取项目锁
                        if acquire_lock.sh "$tproj" 30; then
                            log "启动实例: task=${tid} role=${trot} project=${tproj}"

                            # 构建实例 ID
                            local instance_id="${trot}-${tproj}-$(date +%s)"

                            # 启动实例
                            local launch_dir="${INSTANCES_DIR}/${instance_id}"
                            mkdir -p "$launch_dir"

                            # 写入实例元数据
                            local cwd_override=""
                            local task_type=""
                            while IFS= read -r line; do
                                case "$line" in
                                    "    cwd_override:"*) cwd_override=$(echo "$line" | sed 's/.*cwd_override:[[:space:]]*//' | tr -d '"') ;;
                                    "    type:"*) task_type=$(echo "$line" | sed 's/.*type:[[:space:]]*//' | tr -d '"') ;;
                                esac
                            done <<< "$(extract_task_to_file "$tid" /dev/stdout)"

                            if [ -z "$cwd_override" ]; then cwd_override="$WORKSPACE_ROOT"; fi
                            if [ -z "$task_type" ]; then task_type="unknown"; fi

                            local model="opus"
                            case "$trot" in
                                组合PM) model="sonnet" ;;
                                测试工程师) model="haiku" ;;
                            esac

                            # 提取 prompt
                            local prompt=""
                            local in_prompt=0
                            while IFS= read -r line; do
                                case "$line" in
                                    "    prompt: |"*) in_prompt=1; continue ;;
                                esac
                                if [ "$in_prompt" = 1 ]; then
                                    if echo "$line" | grep -q "^    [a-z]"; then break; fi
                                    prompt="${prompt}${line}"$'\n'
                                fi
                            done < "${RUN_DIR}/queue/inbox.yaml"

                            # 写入 instance.yaml
                            cat > "${launch_dir}/instance.yaml" <<EOF
instance_id: ${instance_id}
role: "${trot}"
project: "${tproj}"
task_id: "${tid}"
type: "${task_type}"
cwd: "${cwd_override}"
model: "${model}"
status: starting
started_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
exit_code: null
EOF

                            # 后台启动 code --print
                            cd "$cwd_override"
                            eval "code --print \
                              --cwd \"${cwd_override}\" \
                              --output-format json \
                              --model ${model} \
                              \"${prompt}\"" \
                              > "${launch_dir}/stdout.log" 2> "${launch_dir}/stderr.log" &
                            local pid=$!
                            cd "$WORKSPACE_ROOT"

                            echo "$pid" > "${launch_dir}/pid"
                            sed -i 's/status: starting/status: running/' "${launch_dir}/instance.yaml"

                            # 启动 watchdog
                            (
                                while kill -0 "$pid" 2>/dev/null; do
                                    date +%s > "${launch_dir}/heartbeat"
                                    sleep 30
                                done
                                wait "$pid" 2>/dev/null
                                local ec=$?
                                echo "$ec" > "${launch_dir}/exit_code"
                                if [ "$ec" -eq 0 ]; then
                                    sed -i 's/status: running/status: completed/' "${launch_dir}/instance.yaml"
                                else
                                    sed -i 's/status: running/status: failed/' "${launch_dir}/instance.yaml"
                                fi
                                log "实例 ${instance_id} 结束 exit_code=${ec}"
                            ) &
                            echo "$!" > "${launch_dir}/watchdog.pid"

                            # 更新任务状态
                            update_task_status "$tid" "running"

                            running_count=$((running_count + 1))
                            log "实例已启动: ${instance_id} pid=${pid}"
                        else
                            log "无法获取项目锁: ${tproj}"
                        fi
                    fi
                fi
            fi
        fi

        # --- Phase 3: 更新全局状态 ---
        local now_ts
        now_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        if [ -f "$STATE_FILE" ]; then
            sed -i "s/^  last_cycle_at:.*/  last_cycle_at: ${now_ts}/" "$STATE_FILE"
            local cycles
            cycles=$(grep "cycles_completed:" "$STATE_FILE" | sed 's/.*cycles_completed:[[:space:]]*//' || echo "0")
            sed -i "s/^  cycles_completed: ${cycles}/  cycles_completed: $((cycles + 1))/" "$STATE_FILE"
        fi

        sleep "$POLL_INTERVAL"
    done

    log "调度器已退出"
}

# --- 入口 ---
case "${1:-run}" in
    run)
        main_loop
        ;;
    once)
        # 单次执行（用于调试）
        echo "=== 检查实例 ==="
        for dir in "${INSTANCES_DIR}"/*/; do
            [ -d "$dir" ] || continue
            local iid
            iid=$(basename "$dir")
            local st
            st=$(grep "^status:" "${dir}instance.yaml" 2>/dev/null | sed 's/^status:[[:space:]]*//' || echo "unknown")
            echo "  ${iid}: ${st}"
        done
        echo ""
        echo "=== 队列状态 ==="
        echo "  运行中实例: $(count_running_instances)"
        echo "  下一个任务: $(find_next_task || echo 无)"
        ;;
    *)
        echo "用法: scheduler.sh [run|once]"
        ;;
esac
