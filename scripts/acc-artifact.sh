#!/bin/sh
# 判据：产物存在且非空，且末行 verdict 不是 unjudgeable。
# 退出码：0 通过 / 1 不通过 / 2 不可判（产物在但判不了）
[ $# -ge 1 ] || { echo "usage: acc-artifact.sh <path> [min_bytes]"; exit 2; }
p=$1; min=${2:-200}
[ -f "$p" ] || { echo "FAIL 产物不存在: $p"; exit 1; }
n=$(wc -c < "$p")
[ "$n" -ge "$min" ] || { echo "FAIL 产物过小 ${n}B < ${min}B: $p"; exit 1; }
last=$(grep -v '^[[:space:]]*$' "$p" | tail -1)
case "$last" in
  *unjudgeable*) echo "UNJUDGEABLE 席位自报不可判: $last"; exit 2 ;;
  *verdict:*fail*) echo "FAIL 席位自报不通过: $last"; exit 1 ;;
esac
echo "OK $p ${n}B / $last"
