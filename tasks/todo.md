# mysql-workspace TODO

## 実験・解析

- [ ] nospin variant との TPS 比較（baseline vs nospin-trx-mutex, nospin-page-wait-mutex 等）
- [ ] perf_schema 解析：`events_waits_summary_global_by_event_name` で mutex 種別ごとの wait time を定量化
- [ ] Flamegraph：`perf record` + スピンループのホットスポット特定
- [ ] threads=8,16 の warmup 再検証：m=0 で同様のノイズがあるか確認

## 再実験（gumma SMT 問題対応）

- [ ] gumma の SMT オン後の環境確認（`lscpu`、`nproc` で 12 コア見えているか）
- [ ] threads=16, 32 を SMT オン環境で再計測（影響が大きいのはこの 2 条件）
- [ ] threads=4, 8 は影響軽微のため再計測は任意

## インフラ・スクリプト

- [ ] run_realistic.sh に SMT オン後の REMOTE_CORES 確認ステップを追加（将来の事故防止）
