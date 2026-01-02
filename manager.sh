#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

# Load config (allow local overrides)
source "$HERE/manager.conf"
if [[ -f "$HERE/manager.local.conf" ]]; then
  # shellcheck disable=SC1091
  source "$HERE/manager.local.conf"
fi

mkdir -p "$LOGDIR"

have() { command -v "$1" >/dev/null 2>&1; }

now_ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

log() {
  echo "[$(now_ts)] $*" | tee -a "$LOGDIR/manager.log" >/dev/null
}

# Read max temperature in Celsius from thermal zones (works on most Android/Linux kernels)
read_temp_c() {
  local max=0
  local found=0
  for f in /sys/class/thermal/thermal_zone*/temp; do
    [[ -r "$f" ]] || continue
    local raw
    raw="$(cat "$f" 2>/dev/null || true)"
    [[ -n "$raw" ]] || continue
    found=1
    # raw is often millidegrees
    local c
    if [[ "$raw" -gt 1000 ]]; then
      c=$(( raw / 1000 ))
    else
      c=$raw
    fi
    if [[ "$c" -gt "$max" ]]; then max="$c"; fi
  done
  if [[ "$found" -eq 0 ]]; then
    echo "-1"
  else
    echo "$max"
  fi
}

pid_running() {
  [[ -f "$PIDFILE" ]] || return 1
  local pid
  pid="$(cat "$PIDFILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

write_state() {
  # key=value per line
  cat > "$STATEFILE" <<EOF
TS=$(now_ts)
PID=$(cat "$PIDFILE" 2>/dev/null || echo "")
TEMP_C=$(read_temp_c)
EOF
}

# Query ccminer API (summary) using perl script if present
api_summary() {
  if [[ -x "$HERE/monitoring/api.pl" ]]; then
    "$HERE/monitoring/api.pl" --cmd summary --address 127.0.0.1 --port "$API_PORT" 2>/dev/null || true
  else
    echo ""
  fi
}

parse_khs() {
  # Extract KHS=... from ccminer summary response
  local s="$1"
  if [[ "$s" =~ KHS=([0-9.]+) ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo "0"
  fi
}

start_miner() {
  if pid_running; then
    log "miner already running (pid=$(cat "$PIDFILE"))"
    return 0
  fi

  if [[ ! -x "$CCMINER_BIN" ]]; then
    echo "ERROR: CCMINER_BIN not executable: $CCMINER_BIN" >&2
    exit 1
  fi
  if [[ ! -f "$CCMINER_CONFIG" ]]; then
    echo "ERROR: CCMINER_CONFIG not found: $CCMINER_CONFIG" >&2
    exit 1
  fi

  local cmd=("$CCMINER_BIN" -c "$CCMINER_CONFIG")

  # Start in screen if available, else background
  if have screen; then
    # kill stale screen
    screen -S "$SCREEN_NAME" -X quit >/dev/null 2>&1 || true
    log "starting miner in screen:$SCREEN_NAME (cpuset=$CPUSET api_port=$API_PORT)"
    screen -dmS "$SCREEN_NAME" bash -lc '
      set -e
      cd "'"$HERE"'"
      # pin to selected cores if taskset exists
      if command -v taskset >/dev/null 2>&1; then
        taskset -c "'"$CPUSET"'" "'"$CCMINER_BIN"'" -c "'"$CCMINER_CONFIG"'" 2>&1 | tee -a "'"$LOGDIR"'/miner.log"
      else
        "'"$CCMINER_BIN"'" -c "'"$CCMINER_CONFIG"'" 2>&1 | tee -a "'"$LOGDIR"'/miner.log"
      fi
    '
    # Try to find pid of ccminer started by screen
    sleep 1
    local pid
    pid="$(pgrep -f "$(basename "$CCMINER_BIN") .* -c $(basename "$CCMINER_CONFIG")" | head -n1 || true)"
    if [[ -z "$pid" ]]; then
      pid="$(pgrep -f "$(basename "$CCMINER_BIN")" | head -n1 || true)"
    fi
    echo "${pid:-}" > "$PIDFILE"
  else
    log "starting miner in background (no screen) (cpuset=$CPUSET api_port=$API_PORT)"
    if have taskset; then
      ( taskset -c "$CPUSET" "$CCMINER_BIN" -c "$CCMINER_CONFIG" >>"$LOGDIR/miner.log" 2>&1 & echo $! > "$PIDFILE" )
    else
      ( "$CCMINER_BIN" -c "$CCMINER_CONFIG" >>"$LOGDIR/miner.log" 2>&1 & echo $! > "$PIDFILE" )
    fi
  fi

  write_state
  log "started (pid=$(cat "$PIDFILE" 2>/dev/null || echo ""))"
}

stop_miner() {
  if pid_running; then
    local pid
    pid="$(cat "$PIDFILE")"
    log "stopping miner pid=$pid"
    kill "$pid" 2>/dev/null || true
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
  fi
  if have screen; then
    screen -S "$SCREEN_NAME" -X quit >/dev/null 2>&1 || true
  fi
  rm -f "$PIDFILE"
  write_state
  log "stopped"
}

pause_miner() {
  if pid_running; then
    local pid
    pid="$(cat "$PIDFILE")"
    kill -STOP "$pid" 2>/dev/null || true
    log "paused pid=$pid"
  fi
}

resume_miner() {
  if pid_running; then
    local pid
    pid="$(cat "$PIDFILE")"
    kill -CONT "$pid" 2>/dev/null || true
    log "resumed pid=$pid"
  fi
}

status_json() {
  local temp khs up pid state
  temp="$(read_temp_c)"
  pid="$(cat "$PIDFILE" 2>/dev/null || echo "")"
  if pid_running; then state="running"; else state="stopped"; fi
  local sum
  sum="$(api_summary)"
  khs="$(parse_khs "$sum")"
  up="$(awk -F= '/UPTIME=/{print $2}' <<<"$sum" | head -n1 | tr -d ';|' || true)"

  jq -n     --arg ts "$(now_ts)"     --arg state "$state"     --arg pid "$pid"     --arg temp_c "$temp"     --arg khs "$khs"     --arg uptime "${up:-}"     '{ts:$ts,state:$state,pid:$pid,temp_c:($temp_c|tonumber),khs:($khs|tonumber),uptime:$uptime}'
}

healthcheck() {
  # Ensures: miner running, not thermally cooking, not stale hashing
  local temp
  temp="$(read_temp_c)"
  local sum khs
  sum="$(api_summary)"
  khs="$(parse_khs "$sum")"

  # Track last-good timestamp
  local last_ok=0 last_state="unknown"
  if [[ -f "$STATEFILE" ]]; then
    last_ok="$(awk -F= '/LAST_OK_EPOCH=/{print $2}' "$STATEFILE" 2>/dev/null || echo 0)"
    last_state="$(awk -F= '/LAST_STATE=/{print $2}' "$STATEFILE" 2>/dev/null || echo unknown)"
  fi
  local now
  now="$(date +%s)"

  # Start if not running
  if ! pid_running; then
    log "healthcheck: miner not running -> start"
    start_miner
    last_ok="$now"
  fi

  # Thermal handling
  if [[ "$temp" -ge "$MAX_TEMP_C" && "$temp" -ne -1 ]]; then
    log "healthcheck: temp ${temp}C >= ${MAX_TEMP_C}C -> pause ${COOL_PAUSE_SECONDS}s"
    pause_miner
    echo "LAST_STATE=paused" >> "$STATEFILE" 2>/dev/null || true
    sleep "$COOL_PAUSE_SECONDS"
    # resume only if cooled enough
    temp="$(read_temp_c)"
    if [[ "$temp" -le "$RESUME_TEMP_C" || "$temp" -eq -1 ]]; then
      resume_miner
      log "healthcheck: cooled to ${temp}C -> resume"
    else
      log "healthcheck: still hot (${temp}C) -> remain paused"
    fi
    write_state
    return 0
  fi

  # Stale hashing detection
  # If KHS below threshold, increment stale timer and restart when exceeded
  if awk "BEGIN{exit !($khs < $MIN_KHS)}"; then
    if [[ "$last_ok" -eq 0 ]]; then last_ok="$now"; fi
    local delta=$(( now - last_ok ))
    if [[ "$delta" -ge "$STALE_SECONDS" ]]; then
      log "healthcheck: stale hashrate khs=$khs for ${delta}s -> restart"
      stop_miner
      sleep 2
      start_miner
      last_ok="$now"
    else
      log "healthcheck: low hashrate khs=$khs (${delta}/${STALE_SECONDS}s)"
    fi
  else
    last_ok="$now"
  fi

  # Persist state
  # rewrite with extras
  cat > "$STATEFILE" <<EOF
TS=$(now_ts)
PID=$(cat "$PIDFILE" 2>/dev/null || echo "")
TEMP_C=$(read_temp_c)
KHS=$khs
LAST_OK_EPOCH=$last_ok
LAST_STATE=running
EOF
}

watchdog() {
  log "watchdog started (interval=${CHECK_INTERVAL}s)"
  while true; do
    healthcheck || true
    sleep "$CHECK_INTERVAL"
  done
}

usage() {
  cat <<EOF
Usage: ./manager.sh <command>

Commands:
  start         Start miner (screen if available)
  stop          Stop miner
  restart       Stop then start
  status        Print JSON status (state/temp/khs)
  temp          Print max temp (C)
  healthcheck   Run single watchdog check (start/pause/restart as needed)
  watchdog      Run watchdog loop (run under screen or at boot)
EOF
}

cmd="${1:-}"
case "$cmd" in
  start) start_miner ;;
  stop) stop_miner ;;
  restart) stop_miner; sleep 1; start_miner ;;
  status) status_json ;;
  temp) read_temp_c ;;
  healthcheck) healthcheck ;;
  watchdog) watchdog ;;
  *) usage; exit 1 ;;
esac
