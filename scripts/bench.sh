#!/usr/bin/env bash
# Usage:
#   bench.sh <variant> <phase> [オプション]
#
# 概要:
#   sysbench を使って MySQL variant の TPS/QPS/Latency を計測する。
#   socket・ユーザ・パスは variant 名から自動解決するので毎回書く必要はない。
#
#   ローカル実行時: sysbench は常にコア 6,7 (taskset -c 6,7) に固定して実行する。
#   リモート実行時: --remote-host で指定したホストに SSH して sysbench を実行する。
#   mysqld 側はコア 0-5 に固定 (scripts/start.sh 参照)。
#
# phase:
#   prepare   sbtest DB とテストテーブルを作成する。計測前に 1 回だけ実行。
#             テーブルは大きめ固定 (tables=10, table_size=100000) で作る。
#             run 側でその一部だけを使えばいいので、prepare のやり直しは
#             不要。table の構成を変えたい時は cleanup → prepare する。
#
#   run       ベンチマーク実行。--scenario が必須。
#             結果は experiments/results/<variant>/... に自動保存。
#             3 回実行して平均を取る。
#
#   cleanup   sysbench が作ったテーブルを削除する (sbtest DB 自体は残る)。
#
# run のオプション:
#   --scenario <high|low|realistic>  【必須】競合条件を選ぶ。
#     high:      threads=16, tables=1,  table_size=100    → 高競合（mutex 競合を引き出す）
#     low:       threads=16, tables=10, table_size=100000 → 低競合（スレッドが分散する）
#     realistic: threads=16, tables=8,  table_size=100000 → 論文標準 OLTP（スレッドスケーリング実験向け）
#
#   --threads N        スレッド数を上書き (scenario の値より優先)。
#   --tables N         使用テーブル数を上書き。
#   --table-size N     使用行数を上書き。prepare 時の値以下にすること。
#   --multiplier N     innodb_spin_wait_pause_multiplier を N に SET GLOBAL して
#                      計測後に元の値に戻す。デフォルトは変更なし。
#   --runs N           繰り返し回数 (デフォルト: 3)。
#   --time N           1 run の秒数 (デフォルト: 60)。
#   --workload <name>  sysbench ワークロード名 (デフォルト: oltp_read_write)。
#   --perf-schema      各 run 後に InnoDB mutex wait 情報を performance_schema
#                      から収集して perf<N>.txt と perf_schema.txt に保存する。
#   --tag <str>        結果ディレクトリ名に任意の識別子を追加する。
#
#   --- 2台構成オプション ---
#   --remote-host HOST   sysbench をこのホストに SSH して実行（省略: ローカル実行）。
#   --mysql-host  HOST   sysbench から MySQL に TCP 接続するホスト名/IP。
#                        --remote-host 指定時は必須。
#   --remote-cores CORES リモート側 taskset のコア指定（デフォルト: 0-5）。
#
#   --- Warmup オプション ---
#   --warmup-runs N      本番 run の前に実行する warmup run 数（デフォルト: 0）。
#                        warmup run はメトリクスに記録されない。
#   --warmup-time N      warmup 1 run の秒数（デフォルト: 30）。
#   --warmup-threads N   warmup 時のスレッド数（省略: --threads と同じ）。
#                        threads=4 など軽負荷時に BP を確実に温めるため
#                        warmup だけ高スレッド数で実行する用途に使う。
#   --warmup-stable      TPS が収束するまで warmup を繰り返す（固定 run 数より優先）。
#                        連続 2 run の TPS 変化が --warmup-stable-pct 以内になったら終了。
#   --warmup-stable-pct P  収束閾値（%、デフォルト: 5）。
#   --warmup-max-runs N    収束モード時の最大 warmup run 数（デフォルト: 10）。
#
# 使用例:
#   # 高競合シナリオで baseline を計測（ローカル）
#   scripts/bench.sh baseline prepare
#   scripts/bench.sh baseline run --scenario high
#
#   # 2台構成（gumma で sysbench、ann の MySQL に TCP 接続）
#   scripts/bench.sh baseline run --scenario realistic --threads 16 \
#     --remote-host gumma --mysql-host 192.168.23.70 \
#     --warmup-runs 2 --warmup-time 30
#
#   # multiplier を変えて比較
#   scripts/bench.sh baseline run --scenario high --multiplier 0
#   scripts/bench.sh baseline run --scenario high --multiplier 100
#
# 結果の保存先:
#   experiments/results/<variant>/<workload>/
#     table_num_<N>_table_size_<N>_threads_<N>[_multiplier_<N>][_<tag>]/
#       run1.txt, run2.txt, ...   sysbench 生出力
#       metrics.tsv               全 run の数値 (ヘッダ付き TSV)
#       summary.txt               パラメータ + 平均値
#       perf1.txt, ...            (--perf-schema 時) 各 run の mutex wait
#       perf_schema.txt           (--perf-schema 時) 全 run の平均

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  sed -n '/^# Usage:/,/^[^#]/p' "$0" | sed 's/^# \?//'
  exit 1
}

# --- 引数パース ---
VARIANT=""
PHASE=""
SCENARIO=""
WORKLOAD="oltp_read_write"
THREADS=""
TABLES=""
TABLE_SIZE=""
MULTIPLIER=""
RUNS=3
TIME=60
PERF_SCHEMA="no"
TAG=""
REMOTE_HOST=""
MYSQL_HOST=""
REMOTE_CORES="0-11"
WARMUP_RUNS=0
WARMUP_TIME=30
WARMUP_THREADS=""
WARMUP_STABLE="no"
WARMUP_STABLE_PCT=5
WARMUP_MAX_RUNS=10

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario)     SCENARIO="$2";     shift 2 ;;
    --workload)     WORKLOAD="$2";     shift 2 ;;
    --threads)      THREADS="$2";      shift 2 ;;
    --tables)       TABLES="$2";       shift 2 ;;
    --table-size)   TABLE_SIZE="$2";   shift 2 ;;
    --multiplier)   MULTIPLIER="$2";   shift 2 ;;
    --runs)         RUNS="$2";         shift 2 ;;
    --time)         TIME="$2";         shift 2 ;;
    --perf-schema)  PERF_SCHEMA="yes"; shift   ;;
    --tag)          TAG="$2";          shift 2 ;;
    --remote-host)  REMOTE_HOST="$2";  shift 2 ;;
    --mysql-host)   MYSQL_HOST="$2";   shift 2 ;;
    --remote-cores) REMOTE_CORES="$2"; shift 2 ;;
    --warmup-runs)        WARMUP_RUNS="$2";        shift 2 ;;
    --warmup-time)        WARMUP_TIME="$2";        shift 2 ;;
    --warmup-threads)     WARMUP_THREADS="$2";     shift 2 ;;
    --warmup-stable)      WARMUP_STABLE="yes";     shift   ;;
    --warmup-stable-pct)  WARMUP_STABLE_PCT="$2";  shift 2 ;;
    --warmup-max-runs)    WARMUP_MAX_RUNS="$2";    shift 2 ;;
    -h|--help)      usage ;;
    -*)             echo "ERROR: 未知のオプション: $1" >&2; usage ;;
    *)
      if   [[ -z "$VARIANT" ]]; then VARIANT="$1"
      elif [[ -z "$PHASE"   ]]; then PHASE="$1"
      else echo "ERROR: 引数が多すぎます: $1" >&2; usage
      fi
      shift ;;
  esac
done

[[ -z "$VARIANT" ]] && { echo "ERROR: variant 名が必要です" >&2; usage; }
[[ -z "$PHASE"   ]] && { echo "ERROR: phase (prepare/run/cleanup) が必要です" >&2; usage; }

INSTALL_DIR="$WORKSPACE/installs/$VARIANT"
SOCKET="$INSTALL_DIR/run/mysqld.sock"
MYSQL="$INSTALL_DIR/bin/mysql"
MYCNF="$INSTALL_DIR/etc/my.cnf"

# mysqld が起動しているか確認
if [[ ! -S "$SOCKET" ]]; then
  echo "ERROR: socket が見つかりません: $SOCKET" >&2
  echo "       先に scripts/start.sh $VARIANT を実行してください。" >&2
  exit 1
fi

# mysql クライアントのショートカット (--defaults-file 付き)
mysql_cmd() {
  "$MYSQL" --defaults-file="$MYCNF" -u root "$@"
}

# ------------------------------------------------------------------ prepare
do_prepare() {
  local PREP_TABLES=10
  local PREP_TABLE_SIZE=100000

  echo "================================================================"
  echo " variant     : $VARIANT"
  echo " phase       : prepare"
  echo " tables      : $PREP_TABLES  table_size: $PREP_TABLE_SIZE"
  echo "================================================================"

  echo "--- sbtest データベースを作成 (既存なら何もしない)"
  mysql_cmd -e "CREATE DATABASE IF NOT EXISTS sbtest;"

  echo "--- sysbench prepare (テーブル作成 + データ投入)"
  sysbench "$WORKLOAD" \
    --db-driver=mysql \
    --mysql-socket="$SOCKET" \
    --mysql-user=root \
    --mysql-db=sbtest \
    --tables="$PREP_TABLES" \
    --table-size="$PREP_TABLE_SIZE" \
    prepare

  echo ""
  echo "準備完了。次: scripts/bench.sh $VARIANT run --scenario high|low|realistic"
}

# --------------------------------------------------------------------- run
do_run() {
  # --- バリデーション ---
  [[ -z "$SCENARIO" ]] && { echo "ERROR: --scenario high|low|realistic が必要です" >&2; exit 1; }
  if [[ -n "$REMOTE_HOST" && -z "$MYSQL_HOST" ]]; then
    echo "ERROR: --remote-host 指定時は --mysql-host も必要です" >&2; exit 1
  fi

  # --- scenario の解決 ---
  case "$SCENARIO" in
    high)
      RUN_THREADS=${THREADS:-16}
      RUN_TABLES=${TABLES:-1}
      RUN_TABLE_SIZE=${TABLE_SIZE:-100}
      ;;
    low)
      RUN_THREADS=${THREADS:-16}
      RUN_TABLES=${TABLES:-10}
      RUN_TABLE_SIZE=${TABLE_SIZE:-100000}
      ;;
    realistic)
      RUN_THREADS=${THREADS:-16}
      RUN_TABLES=${TABLES:-8}
      RUN_TABLE_SIZE=${TABLE_SIZE:-100000}
      ;;
    *)
      echo "ERROR: --scenario は high / low / realistic を指定してください" >&2; exit 1 ;;
  esac

  # --- port 取得（TCP接続時に使用）---
  PORT="$(grep '^port' "$MYCNF" | head -1 | awk '{print $3}')"

  # --- multiplier の設定 ---
  ORIG_MULTIPLIER=""
  if [[ -n "$MULTIPLIER" ]]; then
    ORIG_MULTIPLIER="$(mysql_cmd -sNe \
      'SELECT @@GLOBAL.innodb_spin_wait_pause_multiplier;' 2>/dev/null)"
    mysql_cmd -e "SET GLOBAL innodb_spin_wait_pause_multiplier = ${MULTIPLIER};"
    echo "innodb_spin_wait_pause_multiplier: $ORIG_MULTIPLIER → $MULTIPLIER"
    trap 'mysql_cmd -e "SET GLOBAL innodb_spin_wait_pause_multiplier = ${ORIG_MULTIPLIER};" 2>/dev/null || true' EXIT
  fi

  # --- 結果ディレクトリの構築 ---
  local DIR_NAME="table_num_${RUN_TABLES}_table_size_${RUN_TABLE_SIZE}_threads_${RUN_THREADS}"
  [[ -n "$MULTIPLIER" ]] && DIR_NAME="${DIR_NAME}_multiplier_${MULTIPLIER}"
  [[ -n "$TAG"        ]] && DIR_NAME="${DIR_NAME}_${TAG}"
  RESULTS_DIR="$WORKSPACE/experiments/results/$VARIANT/$WORKLOAD/$DIR_NAME"
  mkdir -p "$RESULTS_DIR"

  # 既存の run*.txt と metrics.tsv を削除して前回実験との混入を防ぐ
  rm -f "$RESULTS_DIR"/run*.txt "$RESULTS_DIR/metrics.tsv" "$RESULTS_DIR/summary.txt"

  local SRC_COMMIT
  SRC_COMMIT="$(grep '^src_commit' "$INSTALL_DIR/BUILD-INFO.txt" 2>/dev/null \
    | cut -d= -f2 | tr -d ' ' || echo unknown)"
  local PATCH_FILE
  PATCH_FILE="$(grep '^patch_file' "$INSTALL_DIR/BUILD-INFO.txt" 2>/dev/null \
    | cut -d= -f2 | tr -d ' ' || echo unknown)"

  echo "================================================================"
  echo " variant     : $VARIANT"
  echo " phase       : run"
  echo " scenario    : $SCENARIO"
  echo " workload    : $WORKLOAD"
  echo " threads     : $RUN_THREADS  tables: $RUN_TABLES  table_size: $RUN_TABLE_SIZE"
  echo " multiplier  : ${MULTIPLIER:-(unchanged)}"
  echo " runs        : $RUNS  time: ${TIME}s"
  local warmup_threads_label=""
  [[ -n "$WARMUP_THREADS" ]] && warmup_threads_label=" (threads: $WARMUP_THREADS)"
  if [[ "$WARMUP_STABLE" == "yes" ]]; then
    echo " warmup      : 収束モード (閾値 ${WARMUP_STABLE_PCT}%, 最大 ${WARMUP_MAX_RUNS} run × ${WARMUP_TIME}s${warmup_threads_label})"
  else
    echo " warmup      : ${WARMUP_RUNS} run(s) × ${WARMUP_TIME}s${warmup_threads_label}"
  fi
  if [[ -n "$REMOTE_HOST" ]]; then
    echo " sysbench    : ssh $REMOTE_HOST (cores $REMOTE_CORES) → MySQL $MYSQL_HOST:$PORT"
  else
    echo " sysbench    : local (cores 6,7) → socket"
  fi
  echo " perf_schema : $PERF_SCHEMA"
  echo " results     : $RESULTS_DIR"
  echo "================================================================"

  # --- sysbench 共通引数（--threads / --time は warmup/本番で別途指定）---
  local SYSBENCH_BASE=(
    "$WORKLOAD"
    --db-driver=mysql
    --mysql-user=root
    --mysql-db=sbtest
    --tables="$RUN_TABLES"
    --table-size="$RUN_TABLE_SIZE"
  )
  if [[ -n "$REMOTE_HOST" ]]; then
    SYSBENCH_BASE+=(--mysql-host="$MYSQL_HOST" --mysql-port="$PORT")
  else
    SYSBENCH_BASE+=(--mysql-socket="$SOCKET")
  fi

  # warmup スレッド数（--warmup-threads 省略時は本番と同じ）
  local WARMUP_THREAD_COUNT="${WARMUP_THREADS:-$RUN_THREADS}"

  # sysbench 実行（ローカルまたは SSH 経由）
  _run_sysbench() {
    local outfile="$1"; shift
    # $@ = SYSBENCH_BASE + --time=N
    if [[ -n "$REMOTE_HOST" ]]; then
      # shellcheck disable=SC2029
      ssh "$REMOTE_HOST" \
        "taskset -c ${REMOTE_CORES} sysbench $(printf '%q ' "$@") run" \
        > "$outfile"
    else
      taskset -c 6,7 sysbench "$@" run > "$outfile"
    fi
  }

  # TPS 抽出ヘルパー
  _extract_tps() {
    awk '/transactions:/{for(i=1;i<=NF;i++){if($i~/^\(\[?[0-9.]+$/){gsub(/[^0-9.]/,"",$i);print $i;exit}}}' "$1"
  }

  # --- warmup runs ---
  if [[ "$WARMUP_STABLE" == "yes" ]]; then
    echo "--- warmup 開始 (収束モード: 閾値 ${WARMUP_STABLE_PCT}%, 最大 ${WARMUP_MAX_RUNS} run × ${WARMUP_TIME}s, threads=${WARMUP_THREAD_COUNT})"
    local prev_tps="" stable_count=0 wu_run=0
    while [[ "$wu_run" -lt "$WARMUP_MAX_RUNS" ]]; do
      wu_run=$((wu_run + 1))
      local wu_out
      wu_out="$(mktemp)"
      echo "    warmup ${wu_run}"
      _run_sysbench "$wu_out" "${SYSBENCH_BASE[@]}" --threads="$WARMUP_THREAD_COUNT" --time="$WARMUP_TIME"
      local cur_tps
      cur_tps="$(_extract_tps "$wu_out")"
      rm -f "$wu_out"
      if [[ -n "$prev_tps" ]]; then
        local converged
        converged="$(awk -v c="$cur_tps" -v p="$prev_tps" -v t="$WARMUP_STABLE_PCT" \
          'BEGIN{d=c-p; if(d<0)d=-d; pct=d/p*100; print (pct<t)?"yes":"no"}')"
        echo "    TPS=${cur_tps} (前回比 $(awk -v c="$cur_tps" -v p="$prev_tps" 'BEGIN{d=c-p;if(d<0)d=-d;printf "%.1f%%", d/p*100}') → ${converged})"
        if [[ "$converged" == "yes" ]]; then
          stable_count=$((stable_count + 1))
          if [[ "$stable_count" -ge 2 ]]; then
            echo "--- warmup 収束 (${wu_run} run 完了, TPS=${cur_tps})"
            break
          fi
        else
          stable_count=0
        fi
      else
        echo "    TPS=${cur_tps}"
      fi
      prev_tps="$cur_tps"
    done
    if [[ "$wu_run" -ge "$WARMUP_MAX_RUNS" && "$stable_count" -lt 2 ]]; then
      echo "--- warmup 最大 run 数 (${WARMUP_MAX_RUNS}) に達した (未収束のまま本番へ)"
    fi
  elif [[ "$WARMUP_RUNS" -gt 0 ]]; then
    echo "--- warmup 開始 (${WARMUP_RUNS} run × ${WARMUP_TIME}s, threads=${WARMUP_THREAD_COUNT})"
    for i in $(seq 1 "$WARMUP_RUNS"); do
      echo "    warmup ${i}/${WARMUP_RUNS}"
      _run_sysbench /dev/null "${SYSBENCH_BASE[@]}" --threads="$WARMUP_THREAD_COUNT" --time="$WARMUP_TIME"
    done
    echo "--- warmup 完了"
  fi

  # TSV ヘッダ
  printf "run\ttps\tqps\tlatency_avg_ms\tlatency_p95_ms\tlatency_min_ms\tlatency_max_ms\ttotal_time_s\terrors_per_sec\n" \
    > "$RESULTS_DIR/metrics.tsv"

  local perf_files=()

  for i in $(seq 1 "$RUNS"); do
    local RAW="$RESULTS_DIR/run${i}.txt"
    echo "--- run ${i}/${RUNS}"

    # perf_schema を使う場合: 計測前にカウンタをリセット
    if [[ "$PERF_SCHEMA" == "yes" ]]; then
      mysql_cmd -e \
        "TRUNCATE TABLE performance_schema.events_waits_summary_global_by_event_name;" \
        2>/dev/null
    fi

    # sysbench 実行
    _run_sysbench "$RAW" "${SYSBENCH_BASE[@]}" --threads="$RUN_THREADS" --time="$TIME"

    # perf_schema を使う場合: mutex wait を収集
    if [[ "$PERF_SCHEMA" == "yes" ]]; then
      local PERF_RAW="$RESULTS_DIR/perf${i}.txt"
      perf_files+=("$PERF_RAW")
      mysql_cmd --batch -e \
        "SELECT EVENT_NAME, COUNT_STAR,
                SUM_TIMER_WAIT / 1000000000 AS SUM_WAIT_MS,
                (SUM_TIMER_WAIT / COUNT_STAR) / 1000000000 AS AVG_WAIT_MS
         FROM performance_schema.events_waits_summary_global_by_event_name
         WHERE COUNT_STAR > 0 AND EVENT_NAME LIKE 'wait/synch/%/innodb/%'
         ORDER BY SUM_TIMER_WAIT DESC;" \
        > "$PERF_RAW" 2>/dev/null
    fi

    # sysbench 出力からメトリクスを抽出
    local tps qps avg p95 min max total_time eps
    tps="$(awk '/transactions:/{for(i=1;i<=NF;i++){if($i~/^\(\[?[0-9.]+$/){gsub(/[^0-9.]/,"",$i);print $i;exit}}}' "$RAW")"
    qps="$(awk '/queries:/{for(i=1;i<=NF;i++){if($i~/^\([0-9.]+$/){gsub(/[^0-9.]/,"",$i);print $i;exit}}}' "$RAW")"
    eps="$(awk '/ignored errors:/{for(i=1;i<=NF;i++){if($i~/^\([0-9.]+$/){gsub(/[^0-9.]/,"",$i);print $i;exit}}}' "$RAW")"
    total_time="$(awk '/total time:/{gsub(/s/,"",$3);print $3;exit}' "$RAW")"
    min="$(awk '/Latency \(ms\):/{flag=1;next} flag&&$1=="min:"   {print $2;exit}' "$RAW")"
    avg="$(awk '/Latency \(ms\):/{flag=1;next} flag&&$1=="avg:"   {print $2;exit}' "$RAW")"
    max="$(awk '/Latency \(ms\):/{flag=1;next} flag&&$1=="max:"   {print $2;exit}' "$RAW")"
    p95="$(awk '/Latency \(ms\):/{flag=1;next} flag&&$1=="95th"   {print $3;exit}' "$RAW")"

    if [[ -z "${tps}" || -z "${avg}" ]]; then
      echo "ERROR: run ${i} のメトリクス抽出に失敗しました。確認: $RAW" >&2
      exit 1
    fi

    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      "${i}" "${tps}" "${qps:-NA}" "${avg}" "${p95:-NA}" \
      "${min:-NA}" "${max:-NA}" "${total_time:-NA}" "${eps:-0}" \
      >> "$RESULTS_DIR/metrics.tsv"

    echo "    TPS=${tps}  QPS=${qps:-NA}  lat_avg=${avg}ms  lat_p95=${p95:-NA}ms"
  done

  # --- summary.txt の生成 ---
  {
    echo "# variant         : $VARIANT"
    echo "# date            : $(date -Iseconds)"
    echo "# workload        : $WORKLOAD"
    echo "# scenario        : $SCENARIO"
    echo "# threads         : $RUN_THREADS"
    echo "# tables          : $RUN_TABLES"
    echo "# table_size      : $RUN_TABLE_SIZE"
    echo "# multiplier      : ${MULTIPLIER:-(unchanged)}"
    echo "# runs            : $RUNS"
    echo "# time_per_run    : ${TIME}s"
    if [[ "$WARMUP_STABLE" == "yes" ]]; then
      echo "# warmup_mode     : stable (pct=${WARMUP_STABLE_PCT}%, max=${WARMUP_MAX_RUNS})"
    else
      echo "# warmup_runs     : $WARMUP_RUNS"
    fi
    echo "# warmup_time     : ${WARMUP_TIME}s"
    echo "# warmup_threads  : ${WARMUP_THREADS:-(same as run: $RUN_THREADS)}"
    echo "# perf_schema     : $PERF_SCHEMA"
    echo "# remote_host     : ${REMOTE_HOST:-(local)}"
    echo "# mysql_host      : ${MYSQL_HOST:-(socket)}"
    echo "# src_commit      : $SRC_COMMIT"
    echo "# patch_file      : $PATCH_FILE"
    if [[ -n "$REMOTE_HOST" ]]; then
      echo "# sysbench_cpus   : $REMOTE_CORES (on $REMOTE_HOST)"
    else
      echo "# sysbench_cpus   : 6,7"
    fi
    echo "# mysqld_cpus     : 0-7"
    echo ""
    echo "## Metrics (TSV)"
    cat "$RESULTS_DIR/metrics.tsv"
    echo ""

    awk -F'\t' '
      NR==1{next}
      {
        if($2!="NA"){tps+=$2; n_tps++}
        if($3!="NA"){qps+=$3; n_qps++}
        if($4!="NA"){lat+=$4; n_lat++}
        if($5!="NA"){p95+=$5; n_p95++}
        if($8!="NA"){tt+=$8;  n_tt++}
        if($9!="NA"){eps+=$9; n_eps++}
      }
      END{
        printf("## Averages\n")
        printf("runs=%d\n", NR-1)
        if(n_tps) printf("TPS_avg=%.4f\n",         tps/n_tps)
        if(n_qps) printf("QPS_avg=%.4f\n",         qps/n_qps)
        if(n_lat) printf("Latency_avg_ms=%.4f\n",  lat/n_lat)
        if(n_p95) printf("Latency_p95_ms=%.4f\n",  p95/n_p95)
        if(n_tt)  printf("Total_time_s=%.4f\n",    tt/n_tt)
        if(n_eps) printf("Errors_per_sec=%.4f\n",  eps/n_eps)
      }
    ' "$RESULTS_DIR/metrics.tsv"
  } > "$RESULTS_DIR/summary.txt"

  # --- perf_schema の集計 ---
  if [[ "$PERF_SCHEMA" == "yes" && ${#perf_files[@]} -gt 0 ]]; then
    {
      echo "## Performance Schema — InnoDB mutex wait (全 run の平均)"
      printf "%-50s\t%-15s\t%-15s\t%-15s\n" \
        "EVENT_NAME" "AVG_COUNT" "AVG_SUM_MS" "AVG_AVG_MS"
      awk -F'\t' '
        BEGIN { run_count=0 }
        FNR==1 { run_count++; next }
        {
          event=$1
          counts[event]+=$2; sum_waits[event]+=$3; avg_waits[event]+=$4
          event_list[event]=1
        }
        END {
          for(e in event_list)
            printf "%-50s\t%-15.2f\t%-15.4f\t%-15.4f\n",
              e, counts[e]/run_count, sum_waits[e]/run_count, avg_waits[e]/run_count
        }
      ' "${perf_files[@]}" | sort -k3 -rn
    } > "$RESULTS_DIR/perf_schema.txt"
  fi

  echo ""
  echo "================================================================"
  cat "$RESULTS_DIR/summary.txt" | grep -E '^(## Averages|runs=|TPS|QPS|Latency)'
  echo "結果: $RESULTS_DIR"
  echo "================================================================"
}

# ------------------------------------------------------------------ cleanup
do_cleanup() {
  echo "================================================================"
  echo " variant : $VARIANT"
  echo " phase   : cleanup"
  echo "================================================================"
  echo "--- sysbench cleanup: テーブルを削除します"
  sysbench "$WORKLOAD" \
    --db-driver=mysql \
    --mysql-socket="$SOCKET" \
    --mysql-user=root \
    --mysql-db=sbtest \
    --tables=10 \
    --table-size=100000 \
    cleanup
  echo "完了。再 prepare する場合: scripts/bench.sh $VARIANT prepare"
}

# --- phase ディスパッチ ---
case "$PHASE" in
  prepare) do_prepare ;;
  run)     do_run     ;;
  cleanup) do_cleanup ;;
  *) echo "ERROR: 未知の phase: $PHASE (prepare / run / cleanup のいずれか)" >&2; exit 1 ;;
esac
