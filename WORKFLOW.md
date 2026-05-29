# mysql-workspace — 実験ワークフロー

このディレクトリは **MySQL の改造ビルドを baseline と比較する** ための
完全に自己完結したワークスペース。spinlock や mutex まわりに手を入れて
性能差を見るのが主な用途。

すべての variant が **同じ cmake オプション** と **同じ runtime config
テンプレート** から作られることを保証し、「flag が違ったかも」「config が
違ったかも」を起こさないことが設計目標。

## ディレクトリ構成

```
src/mysql-server/        MySQL の git checkout。直接編集して実験する。
patches/<name>.patch     ソース変更を保存したパッチ (variant 1 つに 1 個)。
builds/<variant>/        cmake/make のビルドディレクトリ + ビルドログ。
installs/<variant>/      インストール先。data/, etc/, logs/, run/, tmp/ を含む。
scripts/                 操作用スクリプト群。すべてここを経由すること。
experiments/             ベンチマーク・perf データなどの自由領域。
```

## 自己完結性の保証

各 variant の mysqld / mysql / mysqladmin は必ず
`--defaults-file=installs/<variant>/etc/my.cnf` 付きで起動される。
`--defaults-file` は MySQL に「**このファイルだけを読む**」と指示する
オプションなので、以下は読まれない:

- `/etc/my.cnf`
- `/etc/mysql/my.cnf`
- `/etc/mysql/conf.d/*`
- `~/.my.cnf`

`etc/my.cnf` 内のすべてのパスは絶対パスで、install dir 配下に閉じ込めて
ある:

| key        | 値                                       |
|------------|------------------------------------------|
| basedir    | `installs/<variant>/`                    |
| datadir    | `installs/<variant>/data/`               |
| socket     | `installs/<variant>/run/mysqld.sock`     |
| pid-file   | `installs/<variant>/run/mysqld.pid`      |
| log-error  | `installs/<variant>/logs/mysqld.log`     |
| tmpdir     | `installs/<variant>/tmp/`                |
| port       | 3307 (既定。`--port` で override 可能)    |

使う `mysqld` バイナリは `installs/<variant>/bin/mysqld` (このワークスペース
でビルドしたもの) であって、システムの `/usr/sbin/mysqld` ではない。

port が 3307 で、socket もワークスペース内に閉じているので、システム
MySQL が 3306 + `/var/run/mysqld/mysqld.sock` で動いていても **干渉しない**。

## 一貫性の保証

「ちょっと違う flag で再ビルドした」「ちょっと違う my.cnf にしてしまった」
という事故を防ぐためのルール:

1. **コンパイル flag は `scripts/build.sh` にしか書かない。**
   全 variant がこのスクリプト経由でビルドされる。手動で `cmake` を
   叩かないこと。固定で渡している flag は:
   - `CMAKE_BUILD_TYPE=RelWithDebInfo` (最適化 + symbol)
   - `WITH_SSL=system`
   - `WITH_UNIT_TESTS=OFF`, `WITH_TEST_SUITE=OFF`
   - `DOWNLOAD_BOOST=1`, `WITH_BOOST=builds/boost_cache` (variant 間で共有)

2. **runtime config は `scripts/init-instance.sh` にしか書かない。**
   全 variant が同じ my.cnf テンプレート (パスだけ差し替え) で初期化される。
   `installs/<variant>/etc/my.cnf` を手で書き換えないこと。テンプレートを
   変えたい場合は `init-instance.sh` の `cat <<EOF` の中身を編集してから
   各 variant を再 init する。

3. **ソース変更は `patches/*.patch` にしか保存しない。**
   `build.sh --patch` がビルド前に `git apply` で当て、終了時に必ず
   `git apply -R` で戻す。これにより src ツリーは常に HEAD のクリーン
   状態に保たれ、「パッチが当たった状態の src」が他の variant の
   ビルドに混入することがない。

4. **各ビルドの入力情報を残す。** baseline では
   `builds/baseline/SETUP.md`, `host-info.txt`, `source-state.txt` を
   保存ずみ。今後の variant では `BUILD-INFO.txt` (commit, patch,
   cmake args, compiler version, 日時) と `applied.patch` を自動保存する。

## ワークフロー: ソースを直接編集して新しい variant を作る

```bash
# 1. src を自由に編集する
$EDITOR src/mysql-server/storage/innobase/include/log0files_governor.h

# 2. 編集をパッチに固める。-m で意図を残しておくと後で読み返せる。
scripts/make-patch.sh nospin-log-mutex \
  -m "log_files_mutex / writer_mutex の spin を skip させて影響を測る"
#   → patches/nospin-log-mutex.patch (先頭に意図コメント付き)
#   → src ツリーは git checkout で元のクリーンな状態に戻される

# 3. variant をビルド (baseline と同じ cmake flags が使われる)
scripts/build.sh nospin-log-mutex --patch nospin-log-mutex.patch

# 4. 専用 datadir + my.cnf を作る (baseline と同じテンプレート)
scripts/init-instance.sh nospin-log-mutex --port 3308

# 5. 起動 → ベンチ → 停止
scripts/start.sh nospin-log-mutex
scripts/connect.sh nospin-log-mutex -e "SHOW ENGINE INNODB MUTEX;"
# ... 計測 ...
scripts/stop.sh nospin-log-mutex
```

baseline (port 3307) と nospin-log-mutex (port 3308) を **同時起動** して
sysbench を両方に流し、結果を並べて比べるのが基本パターン。

## ワークフロー: 既にあるパッチを使う

```bash
# 例: 同梱の nospin-log-mutex.patch をそのまま使う
scripts/build.sh nospin-log-mutex --patch nospin-log-mutex.patch
scripts/init-instance.sh nospin-log-mutex --port 3308
scripts/start.sh nospin-log-mutex
```

## よく使う操作

| コマンド                                   | 用途                                |
|--------------------------------------------|-------------------------------------|
| `scripts/status.sh`                        | 全 variant の状態一覧               |
| `scripts/build.sh <v> [--patch p.patch]`   | variant をビルド / 再ビルド          |
| `scripts/init-instance.sh <v> [--port N]`  | 初回 datadir + my.cnf 作成          |
| `scripts/start.sh <v>` / `stop.sh <v>`     | mysqld 起動 / 停止                  |
| `scripts/connect.sh <v> [mysql args]`      | mysql client で接続                 |
| `scripts/make-patch.sh <name> -m "..."`    | src の編集をパッチ化 + ソース戻し   |
| `scripts/clean.sh <v>`                     | builds/<v> + installs/<v> を完全削除 |

スクリプトはすべて `--help` または `-h` で日本語の usage が読める。

## やってはいけないこと

- `cmake`, `make`, `mysqld --initialize` を直接叩かない。必ず scripts/
  経由で実行する。
- `installs/<variant>/etc/my.cnf` を手で編集しない (再 init で消える上、
  variant 間で条件がブレる)。テンプレートの方を編集する。
- `src/mysql-server` に直接 commit しない。同じ commit を pin した状態で、
  差分は `patches/*.patch` として表現する。
- システム MySQL を `apt install` しても **このワークスペースは無関係**
  だが、`mysql` を素で叩いた場合はシステム側に繋がる可能性がある点に注意。
  必ず `scripts/connect.sh` を使う。
