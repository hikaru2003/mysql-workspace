#!/usr/bin/env bash
# Usage:
#   setup-server.sh <variant> [options]
#
# 概要:
#   各サーバ上で実行するセットアップスクリプト。
#   ワークスペース（mysql-workspace/）が展開済みの状態で実行する。
#   ann で実行するのではなく、セットアップ対象の各サーバ上で実行すること。
#
# 前提条件:
#   - ワークスペース（git clone または rsync）が展開済み
#   - installs/<variant>/bin/mysqld が存在する
#   - bin/sysbench（ラッパー）と bin/sysbench.bin が存在する（リポジトリに含まれる）
#
# sysbench バイナリについて:
#   bin/sysbench.bin + lib/libmysqlclient.so.24 がリポジトリに含まれる。
#   bin/sysbench はラッパースクリプトで LD_LIBRARY_PATH を設定して呼ぶ。
#   全サーバで同一バイナリを使うことで実験の再現性を確保する。
#
# オプション:
#   --port         PORT    MySQL ポート番号（デフォルト: 3307）
#   --mysqld-cores RANGE   mysqld の taskset コア指定（デフォルト: 0-15）
#   --sysbench-cores RANGE sysbench の taskset コア指定（prepare 時）（デフォルト: 16-19）
#   --prepare              セットアップ後に sysbench prepare を実行
#   --tables       N       sysbench テーブル数（デフォルト: 8）
#   --table-size   N       sysbench テーブル行数（デフォルト: 100000）
#
# 使用例:
#   scripts/setup-server.sh large-multiplier --prepare
#   scripts/setup-server.sh large-multiplier --prepare --mysqld-cores 0-15 --sysbench-cores 16-19

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"

VARIANT=""
PORT=3307
MYSQLD_CORES="0-15"
SYSBENCH_CORES="16-19"
DO_PREPARE=false
TABLES=8
TABLE_SIZE=100000

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)            PORT="$2";           shift 2 ;;
    --mysqld-cores)    MYSQLD_CORES="$2";   shift 2 ;;
    --sysbench-cores)  SYSBENCH_CORES="$2"; shift 2 ;;
    --prepare)         DO_PREPARE=true;     shift ;;
    --tables)          TABLES="$2";         shift 2 ;;
    --table-size)      TABLE_SIZE="$2";     shift 2 ;;
    -h|--help)
      sed -n '/^# Usage:/,/^[^#]/p' "$0" | sed 's/^# \?//'; exit 0 ;;
    -*)
      echo "Unknown option: $1"; exit 1 ;;
    *)
      [[ -z "$VARIANT" ]] && VARIANT="$1" || { echo "Unexpected: $1"; exit 1; }
      shift ;;
  esac
done

[[ -z "$VARIANT" ]] && { echo "Usage: $0 <variant> [options]"; exit 1; }

INSTALL_DIR="$WORKSPACE/installs/$VARIANT"
MYSQLD="$INSTALL_DIR/bin/mysqld"
SOCKET="$INSTALL_DIR/run/mysqld.sock"
SYSBENCH="$WORKSPACE/bin/sysbench"

echo "================================================================"
echo " setup-server.sh"
echo "  variant      : $VARIANT"
echo "  workspace    : $WORKSPACE"
echo "  port         : $PORT"
echo "  mysqld cores : $MYSQLD_CORES"
echo "================================================================"

# --- 1. ランタイム依存パッケージのインストール --------------------------------
echo ""
echo "[1/5] Installing runtime dependencies..."
if command -v apt &>/dev/null; then
  # Ubuntu 24.04: libaio1 → libaio1t64、libssl3 → libssl3t64、libcurl4 → libcurl4t64
  sudo apt install -y -q \
    libaio1t64 \
    libssl3t64 \
    libnuma1 \
    libcurl4t64 \
    libtinfo6 \
    git-lfs \
    2>/dev/null || \
  sudo apt install -y -q \
    libaio1 \
    libssl3 \
    libnuma1 \
    libcurl4 \
    libtinfo6 \
    git-lfs \
    2>/dev/null || true
  echo "  apt dependencies done."
else
  echo "  WARNING: apt not found. Skip package install (non-Debian OS?)."
fi

# --- 2. Git LFS オブジェクト取得（clone 直後にLFSポインタのままの場合に対応）---
if git -C "$WORKSPACE" rev-parse --is-inside-work-tree &>/dev/null; then
  if git lfs version &>/dev/null 2>&1; then
    echo "  Pulling Git LFS objects..."
    git -C "$WORKSPACE" lfs pull 2>/dev/null || true
  fi
fi

# --- mysqld バイナリ確認 ----------------------------------------------------
[[ -x "$MYSQLD" ]] || {
  echo "ERROR: mysqld not found or not executable: $MYSQLD"
  echo "       git lfs pull を実行してLFSオブジェクトを取得してください。"
  exit 1
}

# --- 3. sysbench バイナリ確認 -----------------------------------------------
echo ""
echo "[2/5] Checking sysbench..."
[[ -x "$WORKSPACE/bin/sysbench.bin" ]] || {
  echo "ERROR: bin/sysbench.bin が見つかりません。"
  echo "       ワークスペースが正しく転送されているか確認してください。"
  exit 1
}
[[ -f "$WORKSPACE/lib/libmysqlclient.so.24" ]] || {
  echo "ERROR: lib/libmysqlclient.so.24 が見つかりません。"
  exit 1
}
echo "  OK: $($SYSBENCH --version)"

# --- 4. MySQL インスタンス初期化 --------------------------------------------
echo ""
echo "[3/5] Initializing MySQL instance..."
if [[ -f "$INSTALL_DIR/data/ibdata1" ]]; then
  echo "  Already initialized (data/ibdata1 exists). Skipping."
  if [[ ! -f "$INSTALL_DIR/etc/my.cnf" ]]; then
    echo "  my.cnf missing (gitignored). Regenerating..."
    "$SCRIPT_DIR/init-instance.sh" "$VARIANT" --port "$PORT" --skip-initialize
  fi
else
  "$SCRIPT_DIR/init-instance.sh" "$VARIANT" --port "$PORT"
fi

# --- 5. MySQL 起動・接続確認 ------------------------------------------------
echo ""
echo "[4/5] Starting MySQL..."
if [[ -S "$SOCKET" ]]; then
  echo "  Already running."
else
  nohup taskset -c "$MYSQLD_CORES" "$MYSQLD" \
    --defaults-file="$INSTALL_DIR/etc/my.cnf" \
    --user="$(whoami)" \
    >> "$INSTALL_DIR/logs/mysqld.log" 2>&1 &

  echo -n "  Waiting for socket"
  for i in $(seq 1 30); do
    [[ -S "$SOCKET" ]] && break
    echo -n "."
    sleep 1
  done
  echo ""
  [[ -S "$SOCKET" ]] || { echo "ERROR: MySQL did not start. Check: tail -30 $INSTALL_DIR/logs/mysqld.log"; exit 1; }
fi

MYSQL="$INSTALL_DIR/bin/mysql"
ACTUAL_M=$("$MYSQL" --socket="$SOCKET" -u root -sN \
  -e "SELECT @@innodb_spin_wait_pause_multiplier;" 2>/dev/null || echo "?")
MAX_M=$("$MYSQL" --socket="$SOCKET" -u root -sN \
  -e "SET GLOBAL innodb_spin_wait_pause_multiplier=10000;
      SELECT @@innodb_spin_wait_pause_multiplier;" 2>/dev/null | tail -1 || echo "?")
"$MYSQL" --socket="$SOCKET" -u root -sN \
  -e "SET GLOBAL innodb_spin_wait_pause_multiplier=50;" 2>/dev/null || true

echo "  Connected. multiplier current=$ACTUAL_M, max settable=$MAX_M"
if [[ "$MAX_M" != "10000" ]]; then
  echo "  WARNING: large-multiplier パッチが効いていません（max=$MAX_M）。"
  echo "           large-multiplier variant を使っているか確認してください。"
fi

# --- 6. sysbench prepare ---------------------------------------------------
if $DO_PREPARE; then
  echo ""
  echo "[5/5] Running sysbench prepare..."
  "$MYSQL" --socket="$SOCKET" -u root -e "CREATE DATABASE IF NOT EXISTS sbtest;" 2>/dev/null
  TABLE_COUNT=$("$MYSQL" --socket="$SOCKET" -u root -sN \
    -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='sbtest';" 2>/dev/null || echo 0)
  if [[ "$TABLE_COUNT" -ge "$TABLES" ]]; then
    echo "  Tables already exist ($TABLE_COUNT >= $TABLES). Skipping prepare."
  else
    taskset -c "$SYSBENCH_CORES" "$SYSBENCH" oltp_read_write \
      --mysql-socket="$SOCKET" \
      --mysql-user=root \
      --mysql-db=sbtest \
      --tables="$TABLES" \
      --table-size="$TABLE_SIZE" \
      --threads=4 \
      prepare
    echo "  Prepare done (tables=$TABLES, table_size=$TABLE_SIZE)."
  fi
else
  echo ""
  echo "[5/5] Skipping sysbench prepare (--prepare not specified)."
fi

# --- 完了 ------------------------------------------------------------------
echo ""
echo "================================================================"
echo " Setup complete: $VARIANT"
echo ""
echo "  Benchmark:"
echo "    scripts/bench-multiplier.sh $VARIANT \\"
echo "      --multipliers 50,100,200,500,1000,2000,5000 \\"
echo "      --threads 4,8,16,32,64 \\"
echo "      --mysqld-cores $MYSQLD_CORES \\"
echo "      --sysbench-cores $SYSBENCH_CORES \\"
echo "      --runs 5 --time 60"
echo ""
echo "  Connect:"
echo "    scripts/connect.sh $VARIANT"
echo "================================================================"
