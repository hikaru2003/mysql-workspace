#!/usr/bin/env bash
# Usage:
#   clean.sh <variant> [--build-only|--install-only] [--yes|-y]
#
# 概要:
#   指定 variant の builds/<variant> と installs/<variant> を削除して、
#   ゼロからビルドし直せる状態に戻す。インスタンスが起動中なら先に
#   stop.sh で停止してから削除する。
#
#   「以前のビルドキャッシュやデータディレクトリが残っていて結果に
#   ノイズが乗ってるかも」と疑った時の強リセット用。
#
# 引数・オプション:
#   <variant>         対象の variant 名 (例: baseline, nospin-log-mutex)。
#   --build-only      builds/<variant> だけ削除 (installs/ は残す)。
#                     再 cmake/make したいが datadir は維持したい時。
#   --install-only    installs/<variant> だけ削除 (builds/ は残す)。
#                     データを消して my.cnf を作り直したい時。
#                     ※ ビルド成果物 (bin/mysqld 等) も installs/ にあるので、
#                       --install-only でもバイナリは消える点に注意。
#   --yes, -y         確認プロンプトをスキップして即削除する。
#
# 使用例:
#   scripts/clean.sh nospin-log-mutex            # 確認あり、両方削除
#   scripts/clean.sh nospin-log-mutex --yes      # 確認なしで両方削除
#   scripts/clean.sh baseline --build-only       # build dir だけ削除
#
# 安全装置:
#   - 削除前に対象パスを表示して確認する (--yes 指定時を除く)。
#   - "." ".." "*" のような危険な variant 名は拒否する。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  sed -n '/^# Usage:/,/^[^#]/p' "$0" | sed 's/^# \?//'
  exit 1
}

VARIANT=""
SCOPE="both"   # both | build | install
ASSUME_YES="no"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build-only)   SCOPE="build";   shift ;;
    --install-only) SCOPE="install"; shift ;;
    --yes|-y)       ASSUME_YES="yes"; shift ;;
    -h|--help)      usage ;;
    -*)             echo "Unknown option: $1"; usage ;;
    *)
      if [[ -z "$VARIANT" ]]; then
        VARIANT="$1"
      else
        echo "Unexpected argument: $1"; usage
      fi
      shift ;;
  esac
done

[[ -z "$VARIANT" ]] && { echo "ERROR: variant name required"; usage; }
[[ "$VARIANT" == "." || "$VARIANT" == ".." || "$VARIANT" == "*" ]] && {
  echo "ERROR: refusing to clean variant name '$VARIANT'"; exit 1; }

BUILD_DIR="$WORKSPACE/builds/$VARIANT"
INSTALL_DIR="$WORKSPACE/installs/$VARIANT"
PIDFILE="$INSTALL_DIR/run/mysqld.pid"

# Stop mysqld if running (only relevant if installs/<variant> exists)
if [[ -f "$PIDFILE" ]]; then
  echo "--- Stopping running instance: $VARIANT"
  "$SCRIPT_DIR/stop.sh" "$VARIANT" || true
fi

TARGETS=()
case "$SCOPE" in
  both)    TARGETS=("$BUILD_DIR" "$INSTALL_DIR") ;;
  build)   TARGETS=("$BUILD_DIR") ;;
  install) TARGETS=("$INSTALL_DIR") ;;
esac

EXISTING=()
for t in "${TARGETS[@]}"; do
  [[ -e "$t" ]] && EXISTING+=("$t")
done

if [[ ${#EXISTING[@]} -eq 0 ]]; then
  echo "Nothing to clean for variant '$VARIANT' (scope=$SCOPE)."
  exit 0
fi

echo "About to remove:"
for t in "${EXISTING[@]}"; do
  echo "  $t"
done

if [[ "$ASSUME_YES" != "yes" ]]; then
  read -rp "Proceed? [y/N] " ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 0 ;;
  esac
fi

for t in "${EXISTING[@]}"; do
  echo "Removing $t"
  rm -rf "$t"
done

echo "Done. Rebuild with: scripts/build.sh $VARIANT [--patch ...]"
