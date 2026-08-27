#!/bin/bash
# plan_uplink_poll_20260827.sh  v1
# plan-uplink 首测：机上轮询公网任务信箱，实现"地面->机上"的任务/配置上行。
# 原理：妙算3 机载 4G 已验证主动出站下载（E19/T-A8，wget 公网瓦片）。
#       上行反过来做：地面把任务放到公网固定 URL，机上每分钟拉取比对，
#       发现新任务 -> 校验口令 -> 执行 -> 全程落日志。
# 任务信箱：任何能放静态文件的公网位置（零成本方案=GitHub 仓库 raw 地址，
#           地面用浏览器编辑 task.txt 即完成"发送"）。
# 任务文件格式（纯文本，行首指令）：
#   TOKEN: tm2geo-uplink-v1      <- 必需，口令不对一律拒执行（防垃圾/防误触）
#   FETCH: <url> <机上目标文件名> <- 可选，下载一个文件到工作目录
#   CMD: <shell 命令>             <- 可选，执行一条命令（谨慎使用）
# 红线（沿用 E19_v4 纪律）：工作目录只 mkdir -p；不 rm 不 mv；
#   一切数据落在 /open_app/TM2GeoData/plan_uplink/ 下。
# 安装：见 README_plan_uplink_20260827.md（scp 网线推入 + cron @reboot）。
set -u
TASK_URL="${TASK_URL:-https://raw.githubusercontent.com/CHANGE_ME/CHANGE_ME/main/task.txt}"
INTERVAL="${INTERVAL:-60}"
BASE="${BASE:-/open_app/TM2GeoData/plan_uplink}"
LOG="$BASE/poll.log"
LAST_MD5_FILE="$BASE/last_task.md5"
TOKEN="tm2geo-uplink-v1"
ONCE=0
[ "${1:-}" = "--once" ] && ONCE=1

mkdir -p "$BASE"
log() { echo "$(date '+%F %T') $*" >> "$LOG"; }

poll_once() {
  local tmp="$BASE/task_latest.txt"
  if ! timeout 60 wget -q -O "$tmp" -T 30 -t 1 "$TASK_URL" 2>>"$LOG"; then
    log "POLL_FAIL download $TASK_URL"
    return 0
  fi
  local new_md5 old_md5
  new_md5=$(md5sum "$tmp" | awk '{print $1}')
  old_md5=$(cat "$LAST_MD5_FILE" 2>/dev/null || echo none)
  if [ "$new_md5" = "$old_md5" ]; then
    log "POLL_OK no_change md5=$new_md5"
    return 0
  fi
  log "NEW_TASK md5=$new_md5 (prev=$old_md5)"
  if ! grep -q "^TOKEN: $TOKEN\$" "$tmp"; then
    log "REJECT bad_or_missing_token md5=$new_md5"
    echo "$new_md5" > "$LAST_MD5_FILE"   # 记住坏任务，不反复报错
    return 0
  fi
  # FETCH 指令
  grep "^FETCH: " "$tmp" | while read -r _ url dest; do
    [ -z "$url" ] && continue
    dest=$(basename "$dest")
    if timeout 120 wget -q -O "$BASE/$dest" -T 60 -t 1 "$url" 2>>"$LOG"; then
      log "FETCH_OK $url -> $BASE/$dest md5=$(md5sum "$BASE/$dest" | awk '{print $1}')"
    else
      log "FETCH_FAIL $url"
    fi
  done
  # CMD 指令
  grep "^CMD: " "$tmp" | while read -r line; do
    cmd="${line#CMD: }"
    [ -z "$cmd" ] && continue
    log "CMD_RUN [$cmd]"
    out=$(eval "$cmd" 2>&1); rc=$?
    log "CMD_RC=$rc output=[${out:0:500}]"
  done
  echo "$new_md5" > "$LAST_MD5_FILE"
  log "TASK_DONE md5=$new_md5"
}

log "poll_daemon start url=$TASK_URL interval=${INTERVAL}s once=$ONCE"
if [ "$ONCE" = "1" ]; then poll_once; exit 0; fi
while true; do poll_once; sleep "$INTERVAL"; done
