#!/bin/bash
# atomic_write.sh <file-path>
# 从 stdin 读取内容，原子写入目标文件。
# 用法: echo "content" | atomic_write.sh path/to/file.yaml

set -euo pipefail

TARGET="$1"
TEMP="${TARGET}.tmp.$$"

# 从 stdin 读取到临时文件
cat > "$TEMP"

# 原子重命名（同文件系统上 mv 是原子的）
mv "$TEMP" "$TARGET"
