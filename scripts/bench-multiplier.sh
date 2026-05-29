#!/usr/bin/env bash
# Usage:
#   bench-multiplier.sh <variant> [options]
#
# 概要:
#   innodb_spin_wait_pause_multiplier のみを変化させ、TPS への影響を測定する。
#   delay=6・spin_loops=30 は固定（simple_mysql 実験との対応を保つため）。
#
#   実行順序: 全 multiplier を 1 周するのを N 回繰り返す（ラウンドロビン）。
#     round1: m=0 → m=10 → m=25 → ...
#     round2: m=0 → m=10 → m=25 → ...
#   これにより「後に実行するほどバッファプールが温まって有利」というバイアスを排除する。
#
# 結果ディレクトリ構成:
#   experiments/results/<variant>/<hostname>/multiplier_experiment/
#     metrics.tsv          集計済み TSV（全 run 分）
#     raw/t<T>_m<M>_r<R>.txt  sysbench 生出力（threads=T, multiplier=M, round=R）
#
# オプション:
#   --server       NAME     サーバ識別名（必須。結果ディレクトリ名に使用）
#   --multipliers  <list>   カンマ区切り multiplier 値
#                           （デフォルト: 0,5,10,25,50,75,100,150,200,300,500）
#   --threads      <list>   カンマ区切りスレッド数（デフォルト: 4,8,16,32,64）
#   --mysqld-cores <range>  mysqld の taskset コア指定（デフォルト: 0-15）
#   --sysbench-cores <range> sysbench の taskset コア指定（デフォルト: 16-19）
#   --runs         N        ラウンド数（デフォルト: 5）
#   --time         T        1 run の秒数（デフォルト: 60）
#   --warmup-time  T        warmup 1 run の秒数（デフォルト: 30）
#   --tables       N        sysbench テーブル数（デフォルト: 8）
#   --table-size   N        sysbench テーブル行数（デフォルト: 100000）
#   --result-dir   DIR      結果保存先ルートディレクトリ
#                           （デフォルト: experiments/results/<variant>/<server>/multiplier_experiment）
#
# 使用例:
#   scripts/bench-multiplier.sh large-multiplier \
#     --server skylake01 \
#     --multipliers 0,5,10,25,50,75,100,150,200,300,500 \
#     --threads 4,8,16,32,64 \
#     --mysqld-cores 0-15 --sysbench-cores 16-19 \
#     --runs 5 --time 60

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"

# --- デフォルト値 ---
VARIANT="${1:-}"
[[ -z "$VARIANT" ]] && { echo "Usage: $0 <variant> [options]"; exit 1; }
shift

MULTIPLIERS="0,5,10,25,50,75,100,150,200,300,500"
THREADS="4,8,16,32,64"
MYSQLD_CORES="0-15"
SYSBENCH_CORES="16-19"
RUNS=5
TIME=60
WARMUP_TIME=30
TABLES=8
TABLE_SIZE=100000
SERVER=""
RESULT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --multipliers)    MULTIPLIERS="$2";    shift 2 ;;
    --threads)        THREADS="$2";        shift 2 ;;
    --mysqld-cores)   MYSQLD_CORES="$2";   shift 2 ;;
    --sysbench-cores) SYSBENCH_CORES="$2"; shift 2 ;;
    --runs)           RUNS="$2";           shift 2 ;;
    --time)           TIME="$2";           shift 2 ;;
    --warmup-time)    WARMUP_TIME="$2";    shift 2 ;;
    --tables)         TABLES="$2";         shift 2 ;;
    --table-size)     TABLE_SIZE="$2";     shift 2 ;;
    --server)         SERVER="$2";         shift 2 ;;
    --result-dir)     RESULT_DIR="$2";     shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

[[ -z "$SERVER" ]] && { echo "ERROR: --server NAME を指定してください（例: --server skylake01）"; exit 1; }

INSTALL_DIR="$WORKSPACE/installs/$VARIANT"
SOCKET="$INSTALL_DIR/run/mysqld.sock"
MYSQL="$INSTALL_DIR/bin/mysql"
SYSBENCH="${WORKSPACE}/bin/sysbench"

# sysbench バイナリ: ワークスペース同梱版を優先、なければ PATH から探す
if [[ ! -x "$SYSBENCH" ]]; then
  SYSBENCH="$(command -v sysbench 2>/dev/null || true)"
fi
[[ -x "$SYSBENCH" ]] || { echo "ERROR: sysbench not found"; exit 1; }
[[ -S "$SOCKET" ]] || { echo "ERROR: socket not found: $SOCKET (instance running?)"; exit 1; }

# multiplier 上限チェック
MAX_M=$(
  "$MYSQL" --socket="$SOCKET" -u root -sN \
    -e "SELECT VARIABLE_VALUE FROM performance_schema.global_variables
        WHERE VARIABLE_NAME='innodb_spin_wait_pause_multiplier';" 2>/dev/null || echo 50
)
ACTUAL_MAX=$(
  "$MYSQL" --socket="$SOCKET" -u root -sN \
    -e "SET GLOBAL innodb_spin_wait_pause_multiplier=10000;
        SELECT @@innodb_spin_wait_pause_multiplier;" 2>/dev/null | tail -1 || echo 100
)
"$MYSQL" --socket="$SOCKET" -u root -sN \
  -e "SET GLOBAL innodb_spin_wait_pause_multiplier=$MAX_M;" 2>/dev/null || true

if [[ "$ACTUAL_MAX" -lt 10000 ]]; then
  echo "WARNING: multiplier の上限が $ACTUAL_MAX です。100 を超える値は large-multiplier"
  echo "         パッチ適用済み variant が必要です（現在は $ACTUAL_MAX でクランプされます）。"
fi

# 結果ディレクトリ
if [[ -z "$RESULT_DIR" ]]; then
  RESULT_DIR="$WORKSPACE/experiments/results/$VARIANT/$SERVER/multiplier_experiment"
fi
RAW_DIR="$RESULT_DIR/raw"
mkdir -p "$RESULT_DIR" "$RAW_DIR"
METRICS_FILE="$RESULT_DIR/metrics.tsv"
SUMMARY_FILE="$RESULT_DIR/summary.txt"

# 前回の結果をクリア（metrics.tsv と raw/ を初期化）
rm -f "$METRICS_FILE" "$SUMMARY_FILE" "$RAW_DIR"/*.txt

# metrics.tsv ヘッダ
printf "server\tvariant\tthreads\tmultiplier\tround\ttps\tlat_avg_ms\tlat_p95_ms\n" \
  > "$METRICS_FILE"

mysql_set() {
  "$MYSQL" --socket="$SOCKET" -u root -sN -e "$1" 2>/dev/null
}

run_sysbench() {
  local threads="$1" time="$2"
  taskset -c "$SYSBENCH_CORES" "$SYSBENCH" oltp_read_write \
    --mysql-socket="$SOCKET" \
    --mysql-user=root \
    --tables="$TABLES" \
    --table-size="$TABLE_SIZE" \
    --threads="$threads" \
    --time="$time" \
    run 2>/dev/null
}

# TPS と latency を抽出する関数
parse_tps()     { grep "transactions:" | grep -oP '\d+\.\d+ per sec' | grep -oP '[\d.]+' | head -1; }
parse_lat_avg() { grep "avg:" | grep -oP '[\d.]+' | head -1; }
parse_lat_p95() { grep "95th percentile:" | grep -oP '[\d.]+' | head -1; }

IFS=',' read -ra MULTIPLIER_LIST <<< "$MULTIPLIERS"
IFS=',' read -ra THREAD_LIST    <<< "$THREADS"

echo "========================================"
echo " bench-multiplier"
echo "  server         : $SERVER"
echo "  variant        : $VARIANT"
echo "  multipliers    : $MULTIPLIERS"
echo "  threads        : $THREADS"
echo "  rounds         : $RUNS"
echo "  time/run       : ${TIME}s"
echo "  mysqld cores   : $MYSQLD_CORES"
echo "  sysbench cores : $SYSBENCH_CORES"
echo "  result dir     : $RESULT_DIR"
echo "========================================"

# mysqld の taskset を再確認（起動済み前提）
MYSQLD_PID=$(cat "$INSTALL_DIR/run/mysqld.pid" 2>/dev/null || echo "")
if [[ -n "$MYSQLD_PID" ]]; then
  taskset -cp "$MYSQLD_CORES" "$MYSQLD_PID" > /dev/null 2>&1 || true
fi

for THREAD in "${THREAD_LIST[@]}"; do
  echo ""
  echo "======== threads=$THREAD ========"

  # --- sysbench prepare（テーブルが存在しなければ） ---
  TABLE_COUNT=$(mysql_set "SELECT COUNT(*) FROM information_schema.tables
    WHERE table_schema='sbtest';" 2>/dev/null || echo 0)
  if [[ "$TABLE_COUNT" -lt "$TABLES" ]]; then
    echo "[prepare] sysbench prepare (tables=$TABLES, size=$TABLE_SIZE)..."
    mysql_set "CREATE DATABASE IF NOT EXISTS sbtest;"
    taskset -c "$SYSBENCH_CORES" "$SYSBENCH" oltp_read_write \
      --mysql-socket="$SOCKET" --mysql-user=root \
      --tables="$TABLES" --table-size="$TABLE_SIZE" \
      --threads="$THREAD" prepare 2>/dev/null
  fi

  # --- 初回 warmup（スレッド数変更後のバッファプール温め）---
  echo "[warmup] initial warmup (${WARMUP_TIME}s, m=50)..."
  mysql_set "SET GLOBAL innodb_spin_wait_pause_multiplier=50;
             SET GLOBAL innodb_spin_wait_delay=6;
             SET GLOBAL innodb_sync_spin_loops=30;"
  run_sysbench "$THREAD" "$WARMUP_TIME" > /dev/null

  # --- ラウンドロビン: round × multiplier ---
  for ((ROUND=1; ROUND<=RUNS; ROUND++)); do
    echo ""
    echo "  -- round $ROUND / $RUNS --"

    for M in "${MULTIPLIER_LIST[@]}"; do
      # multiplier 設定（delay・spin_loops は固定）
      mysql_set "SET GLOBAL innodb_spin_wait_pause_multiplier=$M;
                 SET GLOBAL innodb_spin_wait_delay=6;
                 SET GLOBAL innodb_sync_spin_loops=30;"

      ACTUAL_M=$(mysql_set "SELECT @@innodb_spin_wait_pause_multiplier;")
      echo -n "  m=$ACTUAL_M threads=$THREAD ... "

      # 本番 run（生データを保存: bench.sh に倣い run<N>.txt 形式）
      RAW_FILE="$RAW_DIR/t${THREAD}_m${ACTUAL_M}_r${ROUND}.txt"
      run_sysbench "$THREAD" "$TIME" > "$RAW_FILE" 2>&1

      TPS=$(parse_tps     < "$RAW_FILE")
      LAT_AVG=$(parse_lat_avg < "$RAW_FILE")
      LAT_P95=$(parse_lat_p95 < "$RAW_FILE")

      printf "TPS=%-8s lat_avg=%-6s lat_p95=%s\n" "$TPS" "${LAT_AVG}ms" "${LAT_P95}ms"

      # TSV に記録
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$SERVER" "$VARIANT" "$THREAD" "$ACTUAL_M" "$ROUND" "$TPS" "$LAT_AVG" "$LAT_P95" \
        >> "$METRICS_FILE"
    done
  done
done

# multiplier をデフォルトに戻す
mysql_set "SET GLOBAL innodb_spin_wait_pause_multiplier=50;
           SET GLOBAL innodb_spin_wait_delay=6;
           SET GLOBAL innodb_sync_spin_loops=30;"

# --- summary.txt 生成（bench.sh フォーマットに準拠）-----------------------
{
  echo "# server          : $SERVER"
  echo "# variant         : $VARIANT"
  echo "# date            : $(date -Iseconds)"
  echo "# multipliers     : $MULTIPLIERS"
  echo "# threads         : $THREADS"
  echo "# rounds          : $RUNS"
  echo "# time_per_run    : ${TIME}s"
  echo "# warmup_time     : ${WARMUP_TIME}s"
  echo "# tables          : $TABLES"
  echo "# table_size      : $TABLE_SIZE"
  echo "# mysqld_cores    : $MYSQLD_CORES"
  echo "# sysbench_cores  : $SYSBENCH_CORES"
  echo ""
  echo "## Metrics (TSV)"
  cat "$METRICS_FILE"
  echo ""
  echo "## Averages by (threads, multiplier)"
  printf "threads\tmultiplier\truns\ttps_avg\ttps_stddev\tlat_avg_ms\tlat_p95_ms\n"
  awk -F'\t' '
    NR==1 { next }
    {
      key = $3 SUBSEP $4
      n[key]++
      tps[key] += $6; tps2[key] += $6^2
      lat[key] += $7; p95[key]  += $8
      thr[key]=$3; mul[key]=$4
    }
    END {
      for (key in n) {
        cnt = n[key]
        avg = tps[key] / cnt
        sd  = (cnt > 1) ? sqrt(tps2[key]/cnt - avg^2) : 0
        printf "%s\t%s\t%d\t%.2f\t%.2f\t%.2f\t%.2f\n",
          thr[key], mul[key], cnt, avg, sd, lat[key]/cnt, p95[key]/cnt
      }
    }
  ' "$METRICS_FILE" | sort -t$'\t' -k1,1n -k2,2n
} > "$SUMMARY_FILE"

echo ""
echo "========================================"
echo " 完了"
echo "  summary : $SUMMARY_FILE"
echo "  metrics : $METRICS_FILE"
echo "  raw     : $RAW_DIR/"
echo "========================================"
