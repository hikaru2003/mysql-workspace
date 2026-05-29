#!/usr/bin/env bash
# Usage:
#   connect.sh <variant> [mysql client への引数...]
#
# 概要:
#   指定 variant の mysql client を起動して、その variant の mysqld に
#   接続する。--defaults-file で variant の my.cnf だけを読ませるので、
#   グローバルな /etc/my.cnf や ~/.my.cnf は参照しない。
#
#   2 つ目以降の引数はそのまま mysql client に渡される。
#
# 引数:
#   <variant>   接続先 variant (例: baseline)。
#   その他      mysql client に渡したいオプション (-e, -D, -u, など)。
#
# 使用例:
#   scripts/connect.sh baseline
#   scripts/connect.sh baseline -e "SHOW GLOBAL STATUS LIKE 'Innodb_row_lock%';"
#   scripts/connect.sh nospin-log-mutex -D mydb
#   scripts/connect.sh baseline -e "SHOW ENGINE INNODB MUTEX;"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE="$(cd "$SCRIPT_DIR/.." && pwd)"

VARIANT="${1:-}"
[[ -z "$VARIANT" ]] && { echo "Usage: $0 <variant> [mysql args...]"; exit 1; }
shift

INSTALL_DIR="$WORKSPACE/installs/$VARIANT"
MYSQL="$INSTALL_DIR/bin/mysql"
MYCNF="$INSTALL_DIR/etc/my.cnf"

[[ -x "$MYSQL" ]] || { echo "ERROR: mysql client not found: $MYSQL"; exit 1; }
[[ -f "$MYCNF"  ]] || { echo "ERROR: my.cnf not found: $MYCNF"; exit 1; }

# --defaults-file must be the first argument
exec "$MYSQL" --defaults-file="$MYCNF" -u root "$@"
