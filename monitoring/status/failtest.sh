#!/usr/bin/env bash
# chiwa-lab 障害試験の計測スクリプト
#
# 障害試験（Enter を押した瞬間を T0 として、止まった時間・検知・復旧を秒で測る）
#   ./failtest.sh ping:1.1.1.1 VrrpFailover
#   ./failtest.sh tcp:192.168.20.45:3000 NodeDown
#   ./failtest.sh tcp:192.168.20.45:3000 -            … アラートを見ない
#
# 正常時の基準（何もしないで N 秒測る）
#   ./failtest.sh baseline ping:1.1.1.1 600
#
# 環境変数: AM=http://localhost:9093（Alertmanager） INTERVAL=0.5（確認の間隔・秒）
#           STABLE=420（復旧後、通知を待つ最長の秒数） MAXSEC=1800（最長の計測時間）
set -u
export TZ=${TZ:-Asia/Tokyo}   # 記録の時刻を日本時間にする
AM=${AM:-http://localhost:9093}
INTERVAL=${INTERVAL:-0.5}
STABLE=${STABLE:-420}
MAXSEC=${MAXSEC:-1800}

now(){ date +%s.%N; }
sub(){ awk -v a="$1" -v b="$2" 'BEGIN{printf "%.1f", a-b}'; }
iso(){ date -d "@${1%.*}" +%Y-%m-%dT%H:%M:%S%:z; }
http(){ if command -v curl >/dev/null; then curl -s -m 2 "$1"; else wget -q -T 2 -O- "$1"; fi; }

# 成功なら応答時間(ms)を出力、失敗なら何も出さない
check(){
  case $1 in
    ping:*) ping -c1 -W1 "${1#ping:}" 2>/dev/null | sed -n 's/.*time=\([0-9.]*\).*/\1/p' | head -1 ;;
    tcp:*)  local hp=${1#tcp:}; local h=${hp%:*} p=${hp##*:} s; s=$(now)
            if timeout 1 bash -c "</dev/tcp/$h/$p" 2>/dev/null; then awk -v a="$(now)" -v b="$s" 'BEGIN{printf "%.1f",(a-b)*1000}'; fi ;;
    *) echo "対象は ping:IP か tcp:IP:ポート で指定してください" >&2; exit 1 ;;
  esac
}

alert_on(){ # $1 = alertname
  [ "$1" = "-" ] && return 1
  http "$AM/api/v2/alerts?active=true&silenced=false&inhibited=false&filter=alertname%3D%22$1%22" | grep -q '"alertname"'
}

# ---------- 正常時の基準 ----------
if [ "${1:-}" = "baseline" ]; then
  TARGET=$2; DUR=${3:-600}
  echo "基準を測ります：$TARGET を ${DUR}秒（${INTERVAL}秒ごと）"
  start=$(now); sent=0; lost=0; sum=0; max=0
  while [ "$(sub "$(now)" "$start" | cut -d. -f1)" -lt "$DUR" ]; do
    r=$(check "$TARGET"); sent=$((sent+1))
    if [ -z "$r" ]; then lost=$((lost+1)); else
      sum=$(awk -v a="$sum" -v b="$r" 'BEGIN{print a+b}'); max=$(awk -v a="$max" -v b="$r" 'BEGIN{print (b>a)?b:a}'); fi
    printf "\r%d回 確認 / 失敗 %d" "$sent" "$lost"; sleep "$INTERVAL"
  done
  end=$(now); ok=$((sent-lost))
  avg=$(awk -v s="$sum" -v n="$ok" 'BEGIN{printf "%.1f", n?s/n:0}')
  loss=$(awk -v l="$lost" -v n="$sent" 'BEGIN{printf "%.2f", n?l*100/n:0}')
  echo; echo "==== tests.json の result / evidence に貼る ===="
  cat <<EOF
"result": {"date": "$(date -d "@${start%.*}" '+%Y-%m-%d %H:%M')", "detect_sec": null, "down_from_sec": null, "downtime_sec": 0, "recover_sec": null, "lost": $lost,
  "recovered_by": "",
  "extra": [{"label": "確認した回数", "value": "$sent回"}, {"label": "失敗", "value": "$lost回（$loss%）"},
            {"label": "平均の応答", "value": "${avg}ms"}, {"label": "最大の応答", "value": "${max}ms"}]},
"evidence": {"t0": "$(iso "$start")", "from": "$(iso "$start")", "to": "$(iso "$end")"},
EOF
  exit 0
fi

# ---------- 障害試験 ----------
TARGET=${1:?対象（ping:IP か tcp:IP:ポート）を指定してください}
ALERT=${2:--}
echo "対象: $TARGET   見るアラート: $ALERT   (${INTERVAL}秒ごとに確認)"
[ -n "$(check "$TARGET")" ] || { echo "今の時点で対象に届きません。正常な状態で始めてください"; exit 1; }
alert_on "$ALERT" && { echo "アラート $ALERT がすでに鳴っています。消えてから始めてください"; exit 1; }
echo
echo "Enter を押したらすぐに障害を起こしてください（Enter の瞬間が T0 になります）"
read -r
T0=$(now); echo "[T0] $(date '+%H:%M:%S') 計測開始"
down_from=""; down_to=""; detect=""; lost=0; ok_since=""; last_am=0

finish(){
  end=$(now)
  echo; echo "==== 結果 ===="
  [ -n "$down_from" ] && echo "止まり始め   T0 + ${down_from}秒" || echo "止まり始め   止まらなかった"
  [ -n "$down_to" ]   && echo "戻った       T0 + ${down_to}秒（止まっていたのは $(sub "$down_to" "$down_from")秒、失敗 ${lost}回）"
  [ -n "$detect" ]    && echo "通知（検知） T0 + ${detect}秒" || echo "通知（検知） 出なかった"
  dt=null; [ -n "$down_from" ] && [ -n "$down_to" ] && dt=$(sub "$down_to" "$down_from")
  [ -n "$down_from" ] && [ -z "$down_to" ] && dt=null
  echo; echo "==== tests.json の result / evidence に貼る ===="
  cat <<EOF
"result": {"date": "$(date -d "@${T0%.*}" '+%Y-%m-%d %H:%M')", "detect_sec": ${detect:-null}, "down_from_sec": ${down_from:-null}, "downtime_sec": $dt, "recover_sec": ${down_to:-null}, "lost": $lost,
  "recovered_by": "（どうやって戻ったかを書く）", "extra": []},
"evidence": {"t0": "$(iso "$T0")", "from": "$(iso "$(sub "$T0" 180)")", "to": "$(iso "$(awk -v e="$end" 'BEGIN{printf "%d", e+180}')")"},
EOF
  exit 0
}
trap finish INT

while :; do
  t=$(now); rel=$(sub "$t" "$T0"); r=$(check "$TARGET")
  if [ -z "$r" ]; then
    lost=$((lost+1)); ok_since=""
    if [ -z "$down_from" ]; then down_from=$rel; echo "[+${rel}s] 止まった"; fi
    if [ -n "$down_to" ]; then echo "[+${rel}s] また止まった"; down_to=""; fi
  else
    [ -z "$ok_since" ] && ok_since=$rel
    if [ -n "$down_from" ] && [ -z "$down_to" ]; then down_to=$rel; echo "[+${rel}s] 戻った（${r}ms）"; fi
  fi
  # Alertmanager は 2 秒ごとに見る
  if [ -z "$detect" ] && [ "$(sub "$t" "$last_am" | cut -d. -f1)" -ge 2 ]; then
    last_am=$t
    if alert_on "$ALERT"; then detect=$rel; echo "[+${rel}s] 通知が出た（$ALERT）"; fi
  fi
  # 終わる条件：戻ってから 30 秒安定 かつ 通知を確認済み／戻ってから STABLE 秒
  if [ -n "$down_to" ] && [ -n "$ok_since" ]; then
    st=$(sub "$rel" "$ok_since" | cut -d. -f1)
    { [ -n "$detect" ] || [ "$ALERT" = "-" ]; } && [ "$st" -ge 30 ] && finish
    [ "$st" -ge "$STABLE" ] && finish
  fi
  [ "$(echo "$rel" | cut -d. -f1)" -ge "$MAXSEC" ] && { echo "最長時間に達しました"; finish; }
  sleep "$INTERVAL"
done
