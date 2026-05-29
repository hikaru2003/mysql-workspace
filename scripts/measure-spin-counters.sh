#!/usr/bin/env bash
# 概要:
#   InnoDB のロック競合統計を sysbench 実行前後でスナップショットし、
#   mutex/rwlock ごとの競合回数・待ち時間を計算する。
#
#   注: MySQL 8.x では innodb_rwlock_*_spin_rounds 等のスピンカウンタが
#   deprecated（常に 0）のため、performance_schema.events_waits_summary
#   からロック競合数と待ち時間を取得する方式を採用する。
#
# 使い方:
#   scripts/measure-spin-counters.sh [variant] [threads] [time]
#
# 引数:
#   variant   対象 variant（デフォルト: baseline）
#   threads   sysbench スレッド数（デフォルト: 16）
#   time      sysbench 計測秒数（デフォルト: 60）
#
# 使用例:
#   scripts/measure-spin-counters.sh baseline 16 60

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"

VARIANT="${1:-baseline}"
THREADS="${2:-16}"
TIME="${3:-60}"

SOCKET="$WORKSPACE/installs/$VARIANT/run/mysqld.sock"
MYSQL="$WORKSPACE/installs/$VARIANT/bin/mysql"

[[ -S "$SOCKET" ]] || { echo "ERROR: socket not found: $SOCKET (instance running?)"; exit 1; }

mysql_q() {
  "$MYSQL" --socket="$SOCKET" -u root -sN -e "$1"
}

# performance_schema の InnoDB 関連 wait イベントを取得（上位20件）
snapshot_ps() {
  mysql_q "
    SELECT EVENT_NAME,
           COUNT_STAR,
           SUM_TIMER_WAIT,
           MIN_TIMER_WAIT,
           AVG_TIMER_WAIT,
           MAX_TIMER_WAIT
    FROM performance_schema.events_waits_summary_global_by_event_name
    WHERE (EVENT_NAME LIKE 'wait/synch/%/innodb/%'
        OR EVENT_NAME LIKE 'wait/synch/%/sql/%')
      AND COUNT_STAR > 0
    ORDER BY COUNT_STAR DESC
    LIMIT 20;
  "
}

echo "========================================"
echo " InnoDB lock contention measurement"
echo "  variant : $VARIANT"
echo "  threads : $THREADS"
echo "  time    : ${TIME}s"
echo "========================================"
echo ""
echo "注: MySQL 8.x では spin_rounds/os_waits カウンタが deprecated のため"
echo "    performance_schema.events_waits_summary の前後デルタを使用する。"
echo "    COUNT_STAR = ロック取得時に競合が発生した回数（≒ spin_waits）"
echo ""

# --- before スナップショット ---
echo "[before] taking snapshot..."
TMP_BEFORE=$(mktemp)
snapshot_ps > "$TMP_BEFORE"

# --- sysbench 実行 ---
echo "[sysbench] starting ($THREADS threads, ${TIME}s)..."
taskset -c 6,7 sysbench oltp_read_write \
  --mysql-socket="$SOCKET" \
  --mysql-user=root \
  --tables=8 \
  --table-size=100000 \
  --threads="$THREADS" \
  --time="$TIME" \
  --report-interval=10 \
  run 2>&1 | grep -E "thds:|tps:|transactions|total time|approx"

echo ""

# --- after スナップショット ---
echo "[after] taking snapshot..."
TMP_AFTER=$(mktemp)
snapshot_ps > "$TMP_AFTER"

# --- デルタ計算 ---
echo ""
echo "========================================"
echo " Delta (after - before)  [ピコ秒単位 → ms に換算]"
echo "========================================"
printf "%-50s %12s %12s %12s\n" "EVENT_NAME" "COUNT_delta" "SUM_wait_ms" "AVG_wait_us"
printf "%-50s %12s %12s %12s\n" "----------" "-----------" "-----------" "-----------"

# after の各行に対して before の値を引く
while IFS=$'\t' read -r ev_name cnt sum_t min_t avg_t max_t; do
  # before の同じイベントを検索
  before_line=$(grep "^${ev_name}"$'\t' "$TMP_BEFORE" || echo "")
  if [[ -n "$before_line" ]]; then
    b_cnt=$(echo "$before_line" | cut -f2)
    b_sum=$(echo "$before_line" | cut -f3)
  else
    b_cnt=0
    b_sum=0
  fi

  d_cnt=$(( cnt - b_cnt ))
  d_sum=$(( sum_t - b_sum ))

  [[ "$d_cnt" -le 0 ]] && continue

  # ps → ms, ps → μs 換算（1ms = 1e9 ps, 1μs = 1e6 ps）
  sum_ms=$(awk "BEGIN { printf \"%.2f\", $d_sum / 1e9 }")
  avg_us=$(awk "BEGIN { if ($d_cnt > 0) printf \"%.2f\", ($d_sum / $d_cnt) / 1e6; else print \"0\" }")

  # イベント名を短縮（wait/synch/mutex/innodb/ → m: 等）
  short=$(echo "$ev_name" \
    | sed 's|wait/synch/mutex/innodb/|m:|' \
    | sed 's|wait/synch/sxlock/innodb/|sx:|' \
    | sed 's|wait/synch/rwlock/innodb/|rw:|' \
    | sed 's|wait/synch/mutex/sql/|sql:|')

  printf "%-50s %12d %12s %12s\n" "$short" "$d_cnt" "${sum_ms}ms" "${avg_us}μs"
done < "$TMP_AFTER"

# --- サマリ ---
echo ""
echo "========================================"
echo " InnoDB mutex/rwlock 合計"
echo "========================================"

# innodb のみ合算
total_cnt=$(while IFS=$'\t' read -r ev_name cnt sum_t _rest; do
  b_cnt=$(grep "^${ev_name}"$'\t' "$TMP_BEFORE" | cut -f2 || echo 0)
  echo $(( cnt - b_cnt ))
done < <(grep "innodb" "$TMP_AFTER") | awk '{s+=$1} END {print s+0}')

total_sum=$(while IFS=$'\t' read -r ev_name cnt sum_t _rest; do
  b_sum=$(grep "^${ev_name}"$'\t' "$TMP_BEFORE" | cut -f3 || echo 0)
  echo $(( sum_t - b_sum ))
done < <(grep "innodb" "$TMP_AFTER") | awk '{s+=$1} END {print s+0}')

total_sum_ms=$(awk "BEGIN { printf \"%.1f\", $total_sum / 1e9 }")
echo "  InnoDB ロック競合総数 : $total_cnt"
echo "  InnoDB ロック待ち時間 : ${total_sum_ms}ms"

echo ""
echo "===== 解釈 ====="
echo "  COUNT_STAR デルタ ≈ spin ループ開始数（spin_waits の代替）"
echo "  spin_rounds / OS waits は MySQL 8.x では直接取得不可（deprecated）"
echo "  yield vs sleep の正確な比は eBPF uprobe または"
echo "  カスタム TLS カウンタが必要（perf sys_enter_sched_yield で取得済み）"

rm -f "$TMP_BEFORE" "$TMP_AFTER"
