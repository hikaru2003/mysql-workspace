#!/usr/bin/env bash
# Usage:
#   start.sh <variant>
#
# 概要:
#   指定 variant の mysqld を起動する。--defaults-file で variant 専用の
#   my.cnf だけを読ませるので、/etc/my.cnf 等は一切参照されない。
#
#   起動後、socket (installs/<variant>/run/mysqld.sock) が生えるのを最大
#   30 秒待ち、生えれば成功とみなす。生えなければ error log の場所を
#   表示して終了する。
#
# 引数:
#   <variant>   起動する variant (例: baseline)。先に
#               scripts/init-instance.sh で初期化済みであること。
#
# 使用例:
#   scripts/start.sh baseline
#   scripts/status.sh baseline           # 起動確認
#   scripts/connect.sh baseline          # mysql client で接続
#
# 既に起動中なら何もしないで成功扱いで終わる (PID 確認による多重起動防止)。
# 古い PID ファイルが残っていれば自動で削除する。
#
# CPU 固定:
#   mysqld は taskset -c 0-7 で全 12 論理コアに固定して起動する。
#   sysbench は gumma サーバで実行するため ann 側の干渉はない。
#
# 出力先:
#   error log : installs/<variant>/logs/mysqld.log
#   PID file  : installs/<variant>/run/mysqld.pid
#   socket    : installs/<variant>/run/mysqld.sock

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"

VARIANT="${1:-}"
[[ -z "$VARIANT" ]] && { echo "Usage: $0 <variant>"; exit 1; }

INSTALL_DIR="$WORKSPACE/installs/$VARIANT"
MYSQLD="$INSTALL_DIR/bin/mysqld"
MYCNF="$INSTALL_DIR/etc/my.cnf"
PIDFILE="$INSTALL_DIR/run/mysqld.pid"
LOGFILE="$INSTALL_DIR/logs/mysqld.log"

[[ -x "$MYSQLD" ]] || { echo "ERROR: mysqld not found: $MYSQLD"; exit 1; }
[[ -f "$MYCNF"  ]] || { echo "ERROR: my.cnf not found: $MYCNF (run init-instance.sh first)"; exit 1; }

if [[ -f "$PIDFILE" ]]; then
  PID="$(cat "$PIDFILE")"
  if kill -0 "$PID" 2>/dev/null; then
    echo "Instance '$VARIANT' is already running (pid $PID)"
    exit 0
  else
    echo "Stale PID file found, removing"
    rm -f "$PIDFILE"
  fi
fi

echo "Starting MySQL instance: $VARIANT"
echo "  Config : $MYCNF"
echo "  Log    : $LOGFILE"
echo "  CPUs   : 0-7 (taskset)"

# mysqld を全 12 論理コア (0-7) に固定して起動。
# --defaults-file は mysqld への最初の引数でなければならないため、
# taskset の後に続ける。
taskset -c 0-7 "$MYSQLD" \
  --defaults-file="$MYCNF" \
  --user="$(whoami)" \
  --daemonize

# Wait for socket to appear (up to 30 s)
SOCKET="$INSTALL_DIR/run/mysqld.sock"
for i in $(seq 1 30); do
  [[ -S "$SOCKET" ]] && break
  sleep 1
done

if [[ -S "$SOCKET" ]]; then
  PID="$(cat "$PIDFILE" 2>/dev/null || echo '?')"
  echo "Instance '$VARIANT' started (pid $PID)"
  echo "  Connect: $SCRIPT_DIR/connect.sh $VARIANT"
else
  echo "ERROR: mysqld did not start within 30s — check log:"
  echo "  tail -30 $LOGFILE"
  exit 1
fi
