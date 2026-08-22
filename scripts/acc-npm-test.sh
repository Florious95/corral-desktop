#!/bin/sh
# 棘轮判据：npm test 通过数只增不减。基线由 $1 给（默认 97）。
# ⛔ 退出码不许经管道 —— 先落文件再读。
base=${1:-97}
log=$(mktemp -t acc-npm-test) || exit 2
npm test >"$log" 2>&1
rc=$?
if [ $rc -ne 0 ]; then echo "FAIL npm test rc=$rc"; tail -20 "$log"; rm -f "$log"; exit 1; fi
pass=$(grep -oE '[0-9]+ (passing|passed)' "$log" | grep -oE '^[0-9]+' | tail -1)
rm -f "$log"
[ -n "$pass" ] || { echo "UNJUDGEABLE 读不到通过数，量具坏了不是产品坏了"; exit 2; }
[ "$pass" -ge "$base" ] || { echo "FAIL 棘轮倒退 $pass < $base"; exit 1; }
echo "OK npm test $pass >= $base"
