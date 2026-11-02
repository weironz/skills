#!/usr/bin/env bash
# 列出全部 skill：分组、名称、description 的前 80 个字符
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
find "$REPO/skills" -name SKILL.md -not -path '*/evals/*' | sort | while read -r f; do
  rel="${f#"$REPO"/skills/}"; bucket="${rel%%/*}"; name="$(basename "$(dirname "$f")")"
  desc="$(awk '/^---/{n++; next} n==1' "$f" | sed -n '/^description:/,/^[a-z_]*:/p' | grep -v '^[a-z_]*:' | tr -s ' \n' ' ' | cut -c1-80)"
  [ -z "$desc" ] && desc="$(grep -m1 '^description:' "$f" | cut -d: -f2- | cut -c1-80)"
  printf '%-14s %-32s %s\n' "$bucket" "$name" "$desc"
done
