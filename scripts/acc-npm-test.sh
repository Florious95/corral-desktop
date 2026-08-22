#!/bin/sh
# npm test 判据。⛔ 退出码不许经管道 —— 先落文件再读。
#   $1 = 通过数下限（棘轮基线）。给 0 或省略 = 不设下限，只要求"全绿"
#        （回退类改动会合法地减少测试数，此时用 0，并在产物里写明退了哪几条）。
# 输出格式是 node:test 的 TAP：`# pass N` / `# fail N`。
# 退出码：0 通过 / 1 不通过 / 2 不可判（量具读不出来，不是产品坏了）
base=${1:-0}
log=$(mktemp -t acc-npm-test) || { echo "UNJUDGEABLE mktemp 失败"; exit 2; }
npm test >"$log" 2>&1
rc=$?
pass=$(grep -E '^# pass [0-9]+' "$log" | tail -1 | awk '{print $3}')
fail=$(grep -E '^# fail [0-9]+' "$log" | tail -1 | awk '{print $3}')
if [ -z "$pass" ] || [ -z "$fail" ]; then
  echo "UNJUDGEABLE 读不到 '# pass'/'# fail' 计数行（npm test rc=$rc）——量具坏了，不是产品坏了"
  tail -15 "$log"; rm -f "$log"; exit 2
fi
rm -f "$log"
[ "$fail" -eq 0 ] || { echo "FAIL 有测试红：# fail $fail（# pass $pass）"; exit 1; }
[ "$rc" -eq 0 ] || { echo "FAIL npm test rc=$rc 而 # fail 0 —— 退出码与计数打架，按红处理"; exit 1; }
if [ "$base" -gt 0 ] && [ "$pass" -lt "$base" ]; then
  echo "FAIL 棘轮倒退 # pass $pass < 基线 $base"; exit 1
fi
echo "OK # pass $pass / # fail 0（基线 ${base}，0=只要求全绿）"
