#!/usr/bin/env bash
# Usage:
#   make-patch.sh <patch-name> [-m "説明"] [--keep|--revert] [--force]
#
# 概要:
#   src/mysql-server に直接加えた編集を patches/<patch-name>.patch に
#   保存し、ソースツリーを HEAD の状態に戻す。「直接編集 → パッチ化 →
#   ソースをクリーンに戻す」を 1 コマンドで安全に行うためのスクリプト。
#
#   build.sh は「クリーンなソース + パッチ」の組で variant をビルドする
#   前提なので、直接編集した状態のまま build.sh に渡してはいけない。
#   このスクリプトを通すことで、その不整合を防ぐ。
#
# 引数・オプション:
#   <patch-name>          作成するパッチの名前 (.patch は省略可)。
#                         patches/<patch-name>.patch に出力される。
#   -m, --message "..."   パッチ先頭に埋め込む説明文。「なぜこの変更を
#                         入れるか」を日本語で書いておくと、後で
#                         head patches/<patch-name>.patch だけで実験の
#                         意図が読み返せる。指定がなくても動くが推奨。
#   --keep                パッチ書き出し後にソースを元に戻さない。
#                         さらに編集を重ねる場合に使う。
#   --revert              パッチ書き出し後にソースを HEAD に戻す (既定)。
#   --force               同名のパッチが既にあっても上書きする。
#                         指定しない場合は安全のためエラー終了する。
#
# 使用例:
#   # mutex_enter を mutex_enter_nospin に書き換えた状態でキャプチャし、
#   # 説明付きでパッチを残す:
#   scripts/make-patch.sh nospin-log-mutex \
#     -m "log_files_mutex / writer_mutex の spin を skip させて影響を測る"
#
#   # 編集はそのまま残してパッチだけ出力:
#   scripts/make-patch.sh wip --keep
#
#   # 既存の patches/foo.patch を強制上書き:
#   scripts/make-patch.sh foo --force -m "条件を変えて再キャプチャ"
#
# 出力ファイルの構成:
#   patches/<patch-name>.patch の先頭に以下のメタ情報がコメントで入る。
#     # experiment: <patch-name>
#     # date:       2026-...
#     # author:     <whoami>
#     # src_commit: <git rev-parse HEAD>
#     # message:    <-m で指定した文>
#   その後ろに git diff の本体が続く。git apply は `diff --git` 行から
#   読むので、コメント部分は無視される。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC="$WORKSPACE/src/mysql-server"
PATCHES_DIR="$WORKSPACE/patches"

usage() {
  sed -n '/^# Usage:/,/^[^#]/p' "$0" | sed 's/^# \?//'
  exit 1
}

NAME=""
MODE="revert"   # revert | keep
FORCE="no"
MESSAGE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--message) MESSAGE="$2";    shift 2 ;;
    --keep)       MODE="keep";     shift   ;;
    --revert)     MODE="revert";   shift   ;;
    --force|-f)   FORCE="yes";     shift   ;;
    -h|--help)    usage ;;
    -*)           echo "ERROR: 未知のオプション: $1" >&2; usage ;;
    *)
      if [[ -z "$NAME" ]]; then
        NAME="$1"
      else
        echo "ERROR: 引数が多すぎます: $1" >&2; usage
      fi
      shift ;;
  esac
done

[[ -z "$NAME" ]] && { echo "ERROR: パッチ名が必要です" >&2; usage; }

# 末尾の .patch を取り除く (ユーザがどちらの形式で渡しても受け付ける)
NAME="${NAME%.patch}"
OUT="$PATCHES_DIR/$NAME.patch"

if [[ -e "$OUT" && "$FORCE" != "yes" ]]; then
  echo "ERROR: $OUT は既に存在します。" >&2
  echo "       --force を付けて上書きするか、別の名前を指定してください。" >&2
  exit 1
fi

# 現在の差分を取得 (空ならエラー)
DIFF="$(git -C "$SRC" diff)"
if [[ -z "$DIFF" ]]; then
  echo "ERROR: src ツリーに差分がありません。先に編集してから実行してください。" >&2
  exit 1
fi

mkdir -p "$PATCHES_DIR"

# メタ情報ヘッダ + diff 本体を出力
SRC_COMMIT="$(git -C "$SRC" rev-parse HEAD)"
{
  echo "# experiment: $NAME"
  echo "# date:       $(date -Iseconds)"
  echo "# author:     $(whoami)"
  echo "# src_commit: $SRC_COMMIT"
  if [[ -n "$MESSAGE" ]]; then
    echo "# message:    $MESSAGE"
  else
    echo "# message:    (未指定 — 次回は -m で実験の意図を残すこと)"
  fi
  echo ""
  printf '%s\n' "$DIFF"
} > "$OUT"

echo "パッチを書き出しました: $OUT"
echo "  対象ファイル数: $(grep -c '^diff --git' "$OUT")"
echo "  追加/削除行数:  $(grep -cE '^[-+][^-+]' "$OUT")"

case "$MODE" in
  revert)
    echo "--- ソースツリーを HEAD の状態に戻します"
    git -C "$SRC" checkout -- .
    if ! git -C "$SRC" diff --quiet; then
      echo "WARNING: checkout 後にも差分が残っています。状態を確認してください:" >&2
      git -C "$SRC" status --short >&2
      exit 1
    fi
    echo "ソースはクリーンになりました。"
    echo "次の手順: scripts/build.sh $NAME --patch $NAME.patch"
    ;;
  keep)
    echo "(--keep) ソースの編集はそのまま残しました。"
    echo "ビルドする時は src を git checkout で戻してから:"
    echo "  scripts/build.sh $NAME --patch $NAME.patch"
    ;;
esac
