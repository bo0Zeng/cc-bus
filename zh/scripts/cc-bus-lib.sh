#!/usr/bin/env bash
# cc-bus-lib.sh — 路由管线的【唯一实现】,被 cc-send(兜底路径)与 cc-busd(守护进程)source。
# 约定:route_* 阀门返回 0=放行,返回 1=拦截(并已 route_log 记原因)。
# 本文件只提供函数、不自执行。BUS 由调用方设好(或此处按 CC_BUS_HOME 兜底)。
#
# 管线顺序(route_process):policy → rate → loop → dedup → deliver → nudge → log
# 阀门归属:F02=policy/nudge/deliver/log(+rate/loop/dedup 占位放行);F03 填 rate/loop/dedup。
#
# config 键(~/.cc-bus/config,sourceable KEY=VAL,全部有默认):
#   CCBUS_NUDGE_DEBOUNCE  同一收件人两次敲门最小间隔秒(默 2)         [F02]
#   CCBUS_POLICY_MODE     off=全放行 / on=按 policy.tsv 强制 ACL(默 off) [F02]
#   （CCBUS_TTL / MAX_REVISIT / RATE_* / DEDUP_WINDOW 由 F03 追加）
# policy.tsv 行:  <from-glob>\t<允许的 to-glob,逗号分隔>   (# 开头为注释)

: "${BUS:=${CC_BUS_HOME:-$HOME/.cc-bus}}"

route_load_config() {
  # shellcheck disable=SC1091
  [ -f "$BUS/config" ] && . "$BUS/config" || true
  : "${CCBUS_NUDGE_DEBOUNCE:=2}"        # F02
  : "${CCBUS_POLICY_MODE:=off}"         # F02
  : "${CCBUS_TTL:=0}"                   # F03,0=关
  : "${CCBUS_MAX_REVISIT:=0}"           # F03,0=关
  : "${CCBUS_RATE_PAIR:=0}"             # F03,0=关
  : "${CCBUS_RATE_GLOBAL:=0}"           # F03,0=关
  : "${CCBUS_RATE_WINDOW:=60}"          # F03
  : "${CCBUS_DEDUP_WINDOW:=0}"          # F03,0=关
  # 数字键防呆:config typo(非数字)回落安全值,避免 [ -ge ] 报错刷屏 + 静默关阀
  [[ "$CCBUS_NUDGE_DEBOUNCE" =~ ^[0-9]+$ ]] || CCBUS_NUDGE_DEBOUNCE=2
  [[ "$CCBUS_RATE_WINDOW"    =~ ^[0-9]+$ ]] || CCBUS_RATE_WINDOW=60
  local _k
  for _k in CCBUS_TTL CCBUS_MAX_REVISIT CCBUS_RATE_PAIR CCBUS_RATE_GLOBAL CCBUS_DEDUP_WINDOW; do
    [[ "${!_k}" =~ ^[0-9]+$ ]] || printf -v "$_k" '%s' 0
  done
}

route_log() { printf '[%s] %s\n' "$(date -Iseconds)" "$*" >> "$BUS/log/bus.log" 2>/dev/null || true; }

# 守护进程是否在跑:pidfile + kill-0 + cmdline 校验。
# 【不能用 flock 试锁判活】——那会让并发探测者自己短暂持锁、彼此 flock -n 失败而互相误判"在跑",
# 进而入队却无人处理→静默丢消息(多 cc-send 并发是常态)。改用只读探测:
#   pidfile 存在 且 PID 活(kill -0,不获取任何锁,无自竞态)且 /proc/<pid>/cmdline 确是 cc-busd(防 PID 复用)。
# 崩溃后 pidfile 残留:PID 已死→kill -0 失败→正确判"未运行";PID 被复用→cmdline 不含 cc-busd→仍判"未运行"。
daemon_running() {
  local pf="$BUS/cc-busd.pid" pid
  [ -f "$pf" ] || return 1
  pid=$(cat "$pf" 2>/dev/null) || return 1
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  grep -qa cc-busd "/proc/$pid/cmdline" 2>/dev/null
}

# 阀门1:ACL。off/无 policy.tsv → 放行;on → 首个匹配 from 的规则决定 to 是否允许。
route_policy_check() {
  local from="$1" to="$2" pf="$BUS/policy.tsv" mode="${CCBUS_POLICY_MODE:-off}"
  case "${mode,,}" in on|1|true|yes|enabled) ;; *) return 0;; esac   # 大小写不敏感;其余=全放行
  [ -f "$pf" ] || return 0
  local fglob allow g matched=0 ok=0
  while IFS=$'\t' read -r fglob allow; do
    [ -n "$fglob" ] || continue
    case "$fglob" in \#*) continue;; esac
    # shellcheck disable=SC2254
    if [[ "$from" == $fglob ]]; then
      matched=1
      # 用 read -ra 按逗号切,避免 globs=($allow) 对 "*" 做路径名展开(会把 * 展成文件名)
      local globs; IFS=',' read -ra globs <<< "$allow"
      for g in "${globs[@]}"; do
        g="${g// /}"; [ -n "$g" ] || continue
        # shellcheck disable=SC2254
        if [[ "$to" == $g ]]; then ok=1; break; fi
      done
      break
    fi
  done < "$pf"
  { [ "$matched" = 1 ] && [ "$ok" = 1 ]; } && return 0
  route_log "REJECT acl $from->$to"
  return 1
}

# 阀门2:限流(per-pair + global 固定窗口计数 + 熔断)。全 0=关(放行)。
route_rate_check() {
  local from="$1" to="$2"
  local rp="${CCBUS_RATE_PAIR:-0}" rg="${CCBUS_RATE_GLOBAL:-0}" rw="${CCBUS_RATE_WINDOW:-60}"
  [ "$rp" = 0 ] && [ "$rg" = 0 ] && return 0
  if [ "$rp" != 0 ]; then
    _rate_ok "$BUS/state/rate-${from}__${to}" "$rp" "$rw" || { route_log "THROTTLE pair $from->$to"; return 1; }
  fi
  if [ "$rg" != 0 ]; then
    _rate_ok "$BUS/state/rate-global" "$rg" "$rw" || { route_log "THROTTLE global $from->$to"; return 1; }
  fi
  return 0
}
# _rate_ok <file> <limit> <window> → 0=放行(并计数+1) / 1=超限。固定窗口,flock 串行。
_rate_ok() {
  local f="$1" limit="$2" win="$3" now
  now=$(date +%s)
  mkdir -p "$BUS/state"
  (
    flock 7
    start=0; cnt=0
    read -r start cnt 2>/dev/null < "$f" || true   # 2>/dev/null 须在 < 前才压得住"文件不存在"
    [[ "$start" =~ ^[0-9]+$ ]] || start=0
    [[ "$cnt" =~ ^[0-9]+$ ]] || cnt=0
    if [ $(( now - start )) -ge "$win" ]; then start=$now; cnt=0; fi
    if [ "$cnt" -ge "$limit" ]; then exit 1; fi
    printf '%s %s\n' "$start" "$((cnt+1))" > "$f"
    exit 0
  ) 7>>"$f.lock"
}

# 阀门3:近窗去重(同 from+text 在 DEDUP_WINDOW 秒内重复则拒)。0=关。
route_dedup_check() {
  local line="$1" dw="${CCBUS_DEDUP_WINDOW:-0}"
  [ "$dw" = 0 ] && return 0
  local from to text h now df rc
  from=$(printf '%s' "$line" | jq -r '.from // ""')
  to=$(printf '%s' "$line" | jq -r '.to // ""')
  text=$(printf '%s' "$line" | jq -r '.text // ""')
  h=$(printf '%s' "$from|$text" | cksum | awk '{print $1"-"$2}')
  now=$(date +%s)
  df="$BUS/state/dedup-$to"
  mkdir -p "$BUS/state"
  (
    flock 6
    tmp="$df.tmp.$$"; dup=0; : > "$tmp"
    if [ -f "$df" ]; then
      while read -r eh ets; do
        [[ "$ets" =~ ^[0-9]+$ ]] || continue
        [ $(( now - ets )) -lt "$dw" ] || continue      # 过期,剪掉
        printf '%s %s\n' "$eh" "$ets" >> "$tmp"
        [ "$eh" = "$h" ] && dup=1
      done < "$df"
    fi
    [ "$dup" = 0 ] && printf '%s %s\n' "$h" "$now" >> "$tmp"
    mv "$tmp" "$df" 2>/dev/null || true
    [ "$dup" = 0 ]                                       # 子壳退出码=是否非重复
  ) 6>>"$df.lock"
  rc=$?
  [ "$rc" = 0 ] && return 0
  route_log "COALESCE dup $from->$to"; return 1
}

# 阀门4:因果链灭环(hops>TTL 或 to 在 trace 出现≥MAX_REVISIT)。TTL/MAX_REVISIT 均 0=关。
# 诚实说明:此阀门无法区分"正经长对话"与"失控回环",仅作可选粗兜底;反 storm 首选限流。
route_loop_check() {
  local line="$1" ttl="${CCBUS_TTL:-0}" mr="${CCBUS_MAX_REVISIT:-0}"
  { [ "$ttl" = 0 ] && [ "$mr" = 0 ]; } && return 0
  local hops to trace t cnt parts
  hops=$(printf '%s' "$line" | jq -r '.hops // 0'); [[ "$hops" =~ ^[0-9]+$ ]] || hops=0
  if [ "$ttl" != 0 ] && [ "$hops" -gt "$ttl" ]; then route_log "DROP ttl hops=$hops"; return 1; fi
  if [ "$mr" != 0 ]; then
    to=$(printf '%s' "$line" | jq -r '.to // ""')
    trace=$(printf '%s' "$line" | jq -r '.trace // ""')
    cnt=0; parts=()
    IFS=',' read -ra parts <<< "$trace"      # read -ra 不做路径名展开(trace 可能来自不可信信封)
    for t in "${parts[@]}"; do [ "$t" = "$to" ] && cnt=$((cnt+1)); done
    if [ "$cnt" -ge "$mr" ]; then route_log "DROP loop to=$to revisit=$cnt"; return 1; fi
  fi
  return 0
}

# 投递:写收件人 inbox(真相源),加锁。返回非零=投递失败(调用方应退回重试)。
route_deliver() {
  local to="$1" line="$2"
  local inbox="$BUS/inbox/$to.jsonl"      # 独立行:同一 local 里引用刚赋的 $to 会取到旧值
  mkdir -p "$BUS/inbox" || return 1
  ( flock 9; printf '%s\n' "$line" >> "$inbox" ) 9>>"$inbox.lock" || return 1
  return 0
}

# 敲门(去抖):同一收件人 DEBOUNCE 秒内只敲一次;send-keys 到其 pane。
route_nudge() {
  local to="$1" from="$2"
  local nf="$BUS/state/nudge-$to" now last target   # 独立行:$to 已赋值后再拼路径
  now=$(date +%s)
  mkdir -p "$BUS/state"
  (
    flock 8
    last=$(cat "$nf" 2>/dev/null || echo 0); [[ "$last" =~ ^[0-9]+$ ]] || last=0
    if [ $(( now - last )) -ge "${CCBUS_NUDGE_DEBOUNCE:-2}" ]; then
      target=$(awk -F'\t' -v id="$to" '$1==id{t=$2} END{print t}' "$BUS/agents.tsv" 2>/dev/null || true)
      if [ -n "$target" ] && tmux send-keys -t "=$target" \
           "🔔 cc-bus: 你有来自 $from 的新消息,运行 cc-recv 读取并按内容处理" 2>/dev/null; then
        sleep 0.3
        tmux send-keys -t "=$target" Enter 2>/dev/null || true
        echo "$now" > "$nf"
      fi
    else
      route_log "NUDGE skip $to"
    fi
  ) 8>>"$nf.lock"
}

# 管线入口。返回码:0=已投递;10=被阀门拦截/坏信封(已消费,不投递不重试);1=投递出错(应退回重试)。
route_process() {
  local line="$1" from to
  from=$(printf '%s' "$line" | jq -r '.from // "?"' 2>/dev/null || echo "?")
  to=$(printf '%s' "$line" | jq -r '.to // "?"' 2>/dev/null || echo "?")
  # 路径穿越纵深防御:to/from 都会拼进文件路径(库是唯一实现,daemon 会读任意实例写的信封)
  case "$to"   in *[!A-Za-z0-9_-]*|'') route_log "DROP badname to=$to"; return 10;; esac
  case "$from" in *[!A-Za-z0-9_-]*|'') route_log "DROP badname from=$from"; return 10;; esac
  route_policy_check "$from" "$to" || return 10
  route_rate_check   "$from" "$to" || return 10
  route_loop_check   "$line"       || return 10
  route_dedup_check  "$line"       || return 10
  # msg-id 幂等:同 id 已在收件人 inbox → 跳过(reaper 退回重投的双投防护;正常唯一 id 永不命中)。
  # 只扫 inbox 尾部(重投的必是近期消息),避免 inbox 只增导致每次投递 O(n) 全量扫。
  local mid; mid=$(printf '%s' "$line" | jq -r '.id // ""')
  if [ -n "$mid" ] && [ -f "$BUS/inbox/$to.jsonl" ] \
     && tail -n 500 "$BUS/inbox/$to.jsonl" 2>/dev/null | grep -qF "\"id\":\"$mid\""; then
    route_log "DROP dupid $mid"; return 10
  fi
  route_deliver "$to" "$line" || { route_log "ERROR deliver $from->$to"; return 1; }
  route_nudge   "$to" "$from" || true
  route_log "DELIVER $from->$to"
  return 0
}
