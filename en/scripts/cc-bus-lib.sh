#!/usr/bin/env bash
# cc-bus-lib.sh — the single implementation of the routing pipeline, sourced by cc-send (fallback path) and cc-busd (daemon).
# Convention: route_* gates return 0=allow, 1=block (and route_log has already recorded the reason).
# This file only provides functions and does not execute itself. BUS is set by the caller (or falls back here based on CC_BUS_HOME).
#
# Pipeline order (route_process): policy → rate → loop → dedup → deliver → nudge → log
# Gate ownership: F02=policy/nudge/deliver/log (+rate/loop/dedup are placeholder pass-throughs); F03 fills in rate/loop/dedup.
#
# config keys (~/.cc-bus/config, sourceable KEY=VAL, all have defaults):
#   CCBUS_NUDGE_DEBOUNCE  minimum seconds between two knocks to the same recipient (default 2)  [F02]
#   CCBUS_POLICY_MODE     off=allow all / on=enforce ACL per policy.tsv (default off)  [F02]
#   (CCBUS_TTL / MAX_REVISIT / RATE_* / DEDUP_WINDOW added by F03)
# policy.tsv line:  <from-glob>\t<allowed to-glob, comma-separated>   (lines starting with # are comments)

: "${BUS:=${CC_BUS_HOME:-$HOME/.cc-bus}}"

route_load_config() {
  # shellcheck disable=SC1091
  [ -f "$BUS/config" ] && . "$BUS/config" || true
  : "${CCBUS_NUDGE_DEBOUNCE:=2}"        # F02
  : "${CCBUS_POLICY_MODE:=off}"         # F02
  : "${CCBUS_TTL:=0}"                   # F03, 0=off
  : "${CCBUS_MAX_REVISIT:=0}"           # F03, 0=off
  : "${CCBUS_RATE_PAIR:=0}"             # F03, 0=off
  : "${CCBUS_RATE_GLOBAL:=0}"           # F03, 0=off
  : "${CCBUS_RATE_WINDOW:=60}"          # F03
  : "${CCBUS_DEDUP_WINDOW:=0}"          # F03, 0=off
  # Numeric-key foolproofing: a config typo (non-numeric) falls back to a safe value, avoiding [ -ge ] error spam + a silently closed gate
  [[ "$CCBUS_NUDGE_DEBOUNCE" =~ ^[0-9]+$ ]] || CCBUS_NUDGE_DEBOUNCE=2
  [[ "$CCBUS_RATE_WINDOW"    =~ ^[0-9]+$ ]] || CCBUS_RATE_WINDOW=60
  local _k
  for _k in CCBUS_TTL CCBUS_MAX_REVISIT CCBUS_RATE_PAIR CCBUS_RATE_GLOBAL CCBUS_DEDUP_WINDOW; do
    [[ "${!_k}" =~ ^[0-9]+$ ]] || printf -v "$_k" '%s' 0
  done
}

route_log() { printf '[%s] %s\n' "$(date -Iseconds)" "$*" >> "$BUS/log/bus.log" 2>/dev/null || true; }

# Whether the daemon is running: pidfile + kill-0 + cmdline check.
# [Do NOT use a flock trial-lock to test liveness] — that would make concurrent probers each briefly hold the lock,
# so their flock -n calls fail against each other and they mistakenly conclude "it's running",
# and the message gets queued with nobody to process it → silently dropped (concurrent cc-send calls are the norm). Use a read-only probe instead:
#   pidfile exists AND the PID is alive (kill -0, acquires no lock, no self-race) AND /proc/<pid>/cmdline really is cc-busd (guards against PID reuse).
# A leftover pidfile after a crash: PID is dead → kill -0 fails → correctly judged "not running"; PID got reused → cmdline doesn't contain cc-busd → still judged "not running".
daemon_running() {
  local pf="$BUS/cc-busd.pid" pid
  [ -f "$pf" ] || return 1
  pid=$(cat "$pf" 2>/dev/null) || return 1
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  grep -qa cc-busd "/proc/$pid/cmdline" 2>/dev/null
}

# Gate 1: ACL. off/no policy.tsv → allow; on → the first rule matching from decides whether to is allowed.
route_policy_check() {
  local from="$1" to="$2" pf="$BUS/policy.tsv" mode="${CCBUS_POLICY_MODE:-off}"
  case "${mode,,}" in on|1|true|yes|enabled) ;; *) return 0;; esac   # case-insensitive; anything else = allow all
  [ -f "$pf" ] || return 0
  local fglob allow g matched=0 ok=0
  while IFS=$'\t' read -r fglob allow; do
    [ -n "$fglob" ] || continue
    case "$fglob" in \#*) continue;; esac
    # shellcheck disable=SC2254
    if [[ "$from" == $fglob ]]; then
      matched=1
      # Split on commas with read -ra, avoiding globs=($allow) doing pathname expansion on "*" (which would expand * into filenames)
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

# Gate 2: rate limiting (per-pair + global fixed-window counting + breaker). All 0 = off (allow).
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
# _rate_ok <file> <limit> <window> → 0=allow (and count+1) / 1=over limit. Fixed window, serialized with flock.
_rate_ok() {
  local f="$1" limit="$2" win="$3" now
  now=$(date +%s)
  mkdir -p "$BUS/state"
  (
    flock 7
    start=0; cnt=0
    read -r start cnt 2>/dev/null < "$f" || true   # 2>/dev/null must come before < to suppress the "file not found" error
    [[ "$start" =~ ^[0-9]+$ ]] || start=0
    [[ "$cnt" =~ ^[0-9]+$ ]] || cnt=0
    if [ $(( now - start )) -ge "$win" ]; then start=$now; cnt=0; fi
    if [ "$cnt" -ge "$limit" ]; then exit 1; fi
    printf '%s %s\n' "$start" "$((cnt+1))" > "$f"
    exit 0
  ) 7>>"$f.lock"
}

# Gate 3: near-window dedup (rejects if the same from+text repeats within DEDUP_WINDOW seconds). 0 = off.
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
        [ $(( now - ets )) -lt "$dw" ] || continue      # expired, trim it
        printf '%s %s\n' "$eh" "$ets" >> "$tmp"
        [ "$eh" = "$h" ] && dup=1
      done < "$df"
    fi
    [ "$dup" = 0 ] && printf '%s %s\n' "$h" "$now" >> "$tmp"
    mv "$tmp" "$df" 2>/dev/null || true
    [ "$dup" = 0 ]                                       # subshell exit code = whether it's not a duplicate
  ) 6>>"$df.lock"
  rc=$?
  [ "$rc" = 0 ] && return 0
  route_log "COALESCE dup $from->$to"; return 1
}

# Gate 4: causal-chain loop-cut (hops>TTL, or to appears in trace ≥MAX_REVISIT times). TTL/MAX_REVISIT both 0 = off.
# Honest caveat: this gate cannot distinguish a "legitimate long conversation" from a "runaway loop" — it's only an optional, coarse fallback; rate limiting is the preferred defense against storms.
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
    IFS=',' read -ra parts <<< "$trace"      # read -ra does no pathname expansion (trace may come from an untrusted envelope)
    for t in "${parts[@]}"; do [ "$t" = "$to" ] && cnt=$((cnt+1)); done
    if [ "$cnt" -ge "$mr" ]; then route_log "DROP loop to=$to revisit=$cnt"; return 1; fi
  fi
  return 0
}

# Deliver: write to the recipient's inbox (source of truth), with locking. Non-zero return = delivery failed (caller should requeue and retry).
route_deliver() {
  local to="$1" line="$2"
  local inbox="$BUS/inbox/$to.jsonl"      # Separate line: referencing the just-assigned $to within the same local statement would get the old value
  mkdir -p "$BUS/inbox" || return 1
  ( flock 9; printf '%s\n' "$line" >> "$inbox" ) 9>>"$inbox.lock" || return 1
  return 0
}

# Knock (debounce): only knock once per recipient within DEBOUNCE seconds; send-keys to their pane.
route_nudge() {
  local to="$1" from="$2"
  local nf="$BUS/state/nudge-$to" now last target   # Separate line: build the path only after $to is assigned
  now=$(date +%s)
  mkdir -p "$BUS/state"
  (
    flock 8
    last=$(cat "$nf" 2>/dev/null || echo 0); [[ "$last" =~ ^[0-9]+$ ]] || last=0
    if [ $(( now - last )) -ge "${CCBUS_NUDGE_DEBOUNCE:-2}" ]; then
      target=$(awk -F'\t' -v id="$to" '$1==id{t=$2} END{print t}' "$BUS/agents.tsv" 2>/dev/null || true)
      if [ -n "$target" ] && tmux send-keys -t "=$target" \
           "🔔 cc-bus: You have a new message from $from — run cc-recv to read it and act accordingly" 2>/dev/null; then
        sleep 0.3
        tmux send-keys -t "=$target" Enter 2>/dev/null || true
        echo "$now" > "$nf"
      fi
    else
      route_log "NUDGE skip $to"
    fi
  ) 8>>"$nf.lock"
}

# Pipeline entry point. Return codes: 0=delivered; 10=blocked by a gate/bad envelope (consumed, not delivered, not retried); 1=delivery error (should requeue and retry).
route_process() {
  local line="$1" from to
  from=$(printf '%s' "$line" | jq -r '.from // "?"' 2>/dev/null || echo "?")
  to=$(printf '%s' "$line" | jq -r '.to // "?"' 2>/dev/null || echo "?")
  # Defense in depth against path traversal: both to/from get concatenated into file paths (this library is the single implementation; the daemon reads envelopes written by any instance)
  case "$to"   in *[!A-Za-z0-9_-]*|'') route_log "DROP badname to=$to"; return 10;; esac
  case "$from" in *[!A-Za-z0-9_-]*|'') route_log "DROP badname from=$from"; return 10;; esac
  route_policy_check "$from" "$to" || return 10
  route_rate_check   "$from" "$to" || return 10
  route_loop_check   "$line"       || return 10
  route_dedup_check  "$line"       || return 10
  # msg-id idempotency: if the same id is already in the recipient's inbox → skip (guards against double delivery when the reaper requeues and resends; a normal unique id never hits this).
  # Only scan the tail of the inbox (a resend must be a recent message), avoiding an O(n) full scan on every delivery as the inbox only ever grows.
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
