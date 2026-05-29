#!/usr/bin/env bash
# Usage:
#   stop.sh <variant>
#
# 概要:
#   指定 variant の mysqld を graceful に停止する。まず mysqladmin shutdown
#   を試み、30 秒待っても落ちない場合は SIGKILL で強制終了する。
#
# 引数:
#   <variant>   停止する variant (例: baseline)。
#
# 使用例:
#   scripts/stop.sh baseline
#
# PID ファイルが無い / プロセスが既に死んでいる場合は何もせず正常終了する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"

VARIANT="${1:-}"
[[ -z "$VARIANT" ]] && { echo "Usage: $0 <variant>"; exit 1; }

INSTALL_DIR="$WORKSPACE/installs/$VARIANT"
MYSQL="$INSTALL_DIR/bin/mysql"
MYCNF="$INSTALL_DIR/etc/my.cnf"
PIDFILE="$INSTALL_DIR/run/mysqld.pid"

if [[ ! -f "$PIDFILE" ]]; then
  echo "Instance '$VARIANT' is not running (no PID file)"
  exit 0
fi

PID="$(cat "$PIDFILE")"

if ! kill -0 "$PID" 2>/dev/null; then
  echo "Instance '$VARIANT' is not running (stale PID $PID)"
  rm -f "$PIDFILE"
  exit 0
fi

echo "Stopping MySQL instance: $VARIANT (pid $PID)"

# Graceful shutdown via mysqladmin
if [[ -x "$INSTALL_DIR/bin/mysqladmin" ]]; then
  "$INSTALL_DIR/bin/mysqladmin" \
    --defaults-file="$MYCNF" \
    -u root \
    shutdown 2>/dev/null || true
fi

# Wait for process to exit (up to 30 s)
for i in $(seq 1 30); do
  kill -0 "$PID" 2>/dev/null || break
  sleep 1
done

if kill -0 "$PID" 2>/dev/null; then
  echo "WARNING: mysqld did not stop gracefully, sending SIGKILL"
  kill -9 "$PID" 2>/dev/null || true
fi

rm -f "$PIDFILE"
echo "Instance '$VARIANT' stopped"
