#!/usr/bin/env bash
# 把仓库中的 skill 软链接到本机各 agent 的 skill 目录：
#   ~/.claude/skills  Claude Code
#   ~/.agents/skills  Codex 及其他兼容 Agent Skills 的工具
# 每一项都是指向本仓库的软链接，git pull 后即生效。新增、删除或改名 skill 后重新运行即可。
# deprecated/ 不会被链接。目标位置已存在同名的普通目录时会跳过（不删除），需要手动处理。
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DESTS=("$HOME/.claude/skills" "$HOME/.agents/skills")

names=(); srcs=()
while IFS= read -r -d '' skill_md; do
  src="$(dirname "$skill_md")"
  names+=("$(basename "$src")"); srcs+=("$src")
done < <(find "$REPO/skills" -name SKILL.md -not -path '*/deprecated/*' -not -path '*/evals/*' -print0)

for DEST in "${DESTS[@]}"; do
  if [ -L "$DEST" ]; then
    case "$(readlink -f "$DEST")" in
      "$REPO"|"$REPO"/*) echo "error: $DEST 是指向本仓库的软链接，请先删除它再运行" >&2; exit 1 ;;
    esac
  fi
  mkdir -p "$DEST"
  for i in "${!names[@]}"; do
    target="$DEST/${names[$i]}"
    if [ -e "$target" ] && [ ! -L "$target" ]; then
      echo "skip  ${names[$i]}: $target 已存在且不是软链接（未改动，如需替换请手动删除）" >&2
      continue
    fi
    ln -sfn "${srcs[$i]}" "$target"
    echo "linked ${names[$i]} -> ${srcs[$i]} ($DEST)"
  done
done
