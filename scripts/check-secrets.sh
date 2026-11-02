#!/usr/bin/env bash
# 提交前扫描敏感信息（这是公开仓库）。发现可疑内容时以非 0 退出。
# 用法: scripts/check-secrets.sh            # 扫描 git 跟踪的文件和未跟踪文件（工作区）
#       scripts/check-secrets.sh --staged   # 只扫描暂存区内容（pre-commit 钩子使用，扫描的是真正会被提交的版本）
#       scripts/check-secrets.sh <路径...>   # 扫描指定路径
# 额外的内部关键词（例如内部域名、机房代号）可以写进 .secrets-denylist（每行一个正则，该文件已被 gitignore）。
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"; cd "$REPO"

DENYLIST="$REPO/.secrets-denylist"
fail(){ echo "check-secrets: $*（为安全起见，拦截本次提交）" >&2; exit 2; }
case "${1:-}" in
  --staged)
    # 把暂存区里新增或修改的文件导出到临时目录再扫描，这样工作区里未暂存的改动不会影响结果
    TMP=$(mktemp -d) || fail "无法创建临时目录"; trap 'rm -rf "$TMP"' EXIT
    git diff --cached --name-only -z --diff-filter=ACMR | git checkout-index --stdin -z --prefix="$TMP/" || fail "导出暂存区失败"
    cd "$TMP"; mapfile -t FILES < <(find . -type f -printf '%P\n')
    [ ${#FILES[@]} -eq 0 ] && { echo "check-secrets: 暂存区没有需要扫描的文件"; exit 0; } ;;
  -*) fail "未知参数: $1" ;;
  "") mapfile -t FILES < <(git ls-files -co --exclude-standard 2>/dev/null) || fail "git ls-files 失败" ;;
  *)  for x in "$@"; do [ -e "$x" ] || fail "路径不存在: $x"; done
      mapfile -t FILES < <(find "$@" -type f) ;;
esac

PATTERNS=(
  '\b10\.([0-9]{1,3}\.){2}[0-9]{1,3}\b'                       # 内网 IP 10/8
  '\b172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}\b'    # 172.16/12
  '\b192\.168\.[0-9]{1,3}\.[0-9]{1,3}\b'                      # 192.168/16
  '\b100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}\b'  # CGNAT/overlay
  'gh[pousr]_[A-Za-z0-9]{30,}'                                 # GitHub token
  'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.'                # JWT
  '(nbt|mica_pat|sk-ant|sk)_[A-Za-z0-9]{20,}'                  # 各类 API token
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  '(?i)(password|passwd|secret|token|license_key)\s*[=:]\s*["'"'"']?[^\s"'"'"'<>$*{]{6,}'
)
[ -f "$DENYLIST" ] && while IFS= read -r l; do [ -n "$l" ] && PATTERNS+=("$l"); done < "$DENYLIST"

hits=0
for p in "${PATTERNS[@]}"; do
  out=$(printf '%s\0' "${FILES[@]}" | xargs -0 -r grep -HnIP -- "$p" 2>/dev/null | grep -v '^scripts/check-secrets.sh:')
  if [ -n "$out" ]; then echo "== 匹配: $p"; echo "$out" | cut -c1-200; hits=1; fi
done
[ $hits = 0 ] && echo "check-secrets: OK（${#FILES[@]} 个文件）" || { echo "check-secrets: 发现可疑内容，请确认或脱敏后再提交（确认是误报时可以用 git commit --no-verify 跳过）" >&2; exit 1; }
