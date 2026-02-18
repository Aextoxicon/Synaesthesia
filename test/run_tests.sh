#!/bin/bash
# 测试运行脚本

# 获取脚本所在目录的父目录（项目根目录）
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

# 切换到项目根目录
cd "$PROJECT_ROOT"

echo "运行所有单元测试..."
echo "当前工作目录: $(pwd)"
flutter test test/unit/

if [ $? -eq 0 ]; then
    echo "所有测试通过！"
else
    echo "测试失败，请检查错误信息。"
    exit 1
fi