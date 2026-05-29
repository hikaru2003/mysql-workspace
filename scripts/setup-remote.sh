#!/usr/bin/env bash
# Usage:
#   setup-remote.sh <variant> <remote_ip_or_%>
#
# 概要:
#   指定 variant の MySQL に、リモートホストからの接続を許可する root ユーザーを作成する。
#   2台構成（ann: mysqld / gumma: sysbench）で実験する前に 1 回だけ実行すること。
#
# 引数:
#   <variant>          対象 variant (例: baseline)
#   <remote_ip_or_%>   接続を許可するホスト。IP アドレスまたは '%'（全ホスト）
#
# 使用例:
#   scripts/setup-remote.sh baseline 192.168.1.10
#   scripts/setup-remote.sh baseline %
#
# 注意:
#   my.cnf に bind-address = 0.0.0.0 が設定されていること。
#   変更後は mysqld の再起動が必要（stop.sh → start.sh）。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"

VARIANT="${1:-}"
REMOTE_IP="${2:-}"

[[ -z "$VARIANT"   ]] && { echo "Usage: $0 <variant> <remote_ip_or_%>"; exit 1; }
[[ -z "$REMOTE_IP" ]] && { echo "Usage: $0 <variant> <remote_ip_or_%>"; exit 1; }

INSTALL_DIR="$WORKSPACE/installs/$VARIANT"
MYSQL="$INSTALL_DIR/bin/mysql"
MYCNF="$INSTALL_DIR/etc/my.cnf"
SOCKET="$INSTALL_DIR/run/mysqld.sock"

if [[ ! -S "$SOCKET" ]]; then
  echo "ERROR: socket が見つかりません: $SOCKET" >&2
  echo "       先に scripts/start.sh $VARIANT を実行してください。" >&2
  exit 1
fi

echo "variant    : $VARIANT"
echo "remote_ip  : $REMOTE_IP"
echo ""

"$MYSQL" --defaults-file="$MYCNF" -u root <<SQL
CREATE USER IF NOT EXISTS 'root'@'${REMOTE_IP}' IDENTIFIED BY '';
GRANT ALL PRIVILEGES ON *.* TO 'root'@'${REMOTE_IP}' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SELECT User, Host FROM mysql.user WHERE User='root' ORDER BY Host;
SQL

echo ""
echo "完了。gumma から接続確認:"
echo "  mysql -h <ann_ip> -P $(grep '^port' "$MYCNF" | head -1 | awk '{print $3}') -u root -e 'SELECT 1;'"
