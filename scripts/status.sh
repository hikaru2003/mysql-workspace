#!/usr/bin/env bash
# Usage:
#   status.sh [variant]
#
# 概要:
#   各 variant のビルド・初期化・起動状態を一覧で表示する。引数を省略
#   すると installs/ 直下の全 variant を表示し、引数を渡すとその variant
#   だけを表示する。
#
#   表示項目:
#     built        bin/mysqld があるか (= ビルド済みか)
#     init         data/mysql ディレクトリがあるか (= 初期化済みか)
#     port         my.cnf に書かれた port
#     status       running / stopped / stale-pid
#     pid          (起動中なら) プロセス ID
#
# 使用例:
#   scripts/status.sh                     # 全 variant の状態
#   scripts/status.sh baseline            # baseline だけ表示

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALLS="$WORKSPACE/installs"

check_variant() {
  local variant="$1"
  local dir="$INSTALLS/$variant"
  local pidfile="$dir/run/mysqld.pid"
  local mycnf="$dir/etc/my.cnf"
  local socket="$dir/run/mysqld.sock"

  local built="no"
  [[ -x "$dir/bin/mysqld" ]] && built="yes"

  local initialized="no"
  [[ -d "$dir/data/mysql" ]] && initialized="yes"

  local status="stopped"
  local pid=""
  if [[ -f "$pidfile" ]]; then
    pid="$(cat "$pidfile")"
    if kill -0 "$pid" 2>/dev/null; then
      status="running"
    else
      status="stale-pid"
    fi
  fi

  local port=""
  [[ -f "$mycnf" ]] && port="$(grep -m1 '^port' "$mycnf" | awk '{print $3}')"

  printf "%-20s  built=%-3s  init=%-3s  port=%-5s  %s\n" \
    "$variant" "$built" "$initialized" "${port:-?}" "$status"
  [[ -n "$pid" ]] && printf "  └─ pid: %s\n" "$pid"
}

if [[ -n "${1:-}" ]]; then
  check_variant "$1"
else
  if [[ ! -d "$INSTALLS" ]] || [[ -z "$(ls -A "$INSTALLS" 2>/dev/null)" ]]; then
    echo "No variants found in $INSTALLS"
    echo "Run: scripts/build.sh <variant>"
    exit 0
  fi
  echo "Variant               built  init  port   status"
  echo "--------------------  -----  ----  -----  -------"
  for dir in "$INSTALLS"/*/; do
    check_variant "$(basename "$dir")"
  done
fi
