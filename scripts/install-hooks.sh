#!/usr/bin/env bash
# 启用仓库自带的 git 钩子（.githooks/）。每次 clone 后运行一次即可。
set -euo pipefail
cd "$(dirname "$0")/.."
git config core.hooksPath .githooks
chmod +x .githooks/* scripts/*.sh
echo "已启用 .githooks（core.hooksPath=.githooks）：$(ls .githooks | tr '\n' ' ')"
[ -f .secrets-denylist ] || echo "提示：还没有 .secrets-denylist，可以每行写一个内部关键词正则（该文件不会被提交）"
