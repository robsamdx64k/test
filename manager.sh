#!/usr/bin/env bash
set -euo pipefail

CONF="$HOME/ccminer/manager.conf"
LOCAL_CONF="$HOME/ccminer/manager.local.conf"

if [[ -f "$CONF" ]]; then
  # shellcheck disable=SC1090
  source "$CONF"
fi
if [[ -f "$LOCAL_CONF" ]]; then
  # shellcheck disable=SC1090
  source "$LOCAL_CONF"
fi

mkdir -p "${LOG_DIR:-$HOME/ccminer/logs}"

log() { printf "[%s] %s\n" "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$HOME/ccminer/manager.log" >/dev/null; }
die() { log "ERROR: $*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

screen_exists() { screen -ls 2>/dev/null | grep -q "\.${SCREEN_NAME}[[:space:]]"; }
screen_kill() { screen -S "${SCREEN_NAME}" -X quit >/dev/null 2>&1 || true; screen -wipe >/dev/null 2>&1 || true; }

read_temp_c() {
  local max=0
  for f in /sys/class/thermal/thermal_zone*/temp; do
    [[ -r "$f" ]] || continue
    local v
    v="$(cat "$f" 2>/dev/null || echo 0)"
    if [[ "$v" =~ ^[0-9]+$ ]]; then
      if (( v > 1000 )); then v=$((v/1000)); fi
      (( v > max )) && max=$v
    fi
  done
  echo "$max"
}

start_miner() {
  [[ -x "$CCMINER_BIN" ]] || die "ccminer not executable at: $CCMINER_BIN"
  [[ -f "$CONFIG_JSON" ]] || die "config.json missing at: $CONFIG_JSON"

  mkdir -p "$LOG_DIR"
  touch "$LOG_FILE"

  screen_kill

  local cmd="$CCMINER_BIN -c $CONFIG_JSON $EXTRA_ARGS"
  if [[ -n "${CPUSET:-}" ]]; then
    if have taskset; then
      cmd="taskset -c ${CPUSET} $cmd"
    else
      log "taskset not found; CPUSET ignored"
    fi
  fi
  if have stdbuf; then
    cmd="stdbuf -oL -eL $cmd"
  fi

  log "Starting miner in screen session '${SCREEN_NAME}'"
  screen -dmS "${SCREEN_NAME}"
  screen -S "${SCREEN_NAME}" -X stuff "bash -lc '$cmd >> "$LOG_FILE" 2>&1'\n" >/dev/null 2>&1 || true
  log "Mining started. Log: $LOG_FILE"
}

stop_miner() { log "Stopping miner"; screen_kill; }

status() {
  local temp
  temp="$(read_temp_c)"
  if screen_exists; then echo "status=running"; else echo "status=stopped"; fi
  echo "temp_c=$temp"
  if [[ -f "$LOG_FILE" ]]; then
    echo "log_last_update_epoch=$(stat -c %Y "$LOG_FILE" 2>/dev/null || echo 0)"
    echo "log_file=$LOG_FILE"
  fi
}

watchdog_loop() {
  log "Watchdog starting (interval=${WATCHDOG_INTERVAL_SEC}s stale=${STALE_LOG_SEC}s max=${MAX_TEMP_C}C resume=${RESUME_TEMP_C}C)"
  echo $$ > "${PID_FILE}"
  trap 'rm -f "${PID_FILE}"; log "Watchdog exiting"; exit 0' INT TERM EXIT

  local last_restart=0
  while true; do
    local now temp
    now="$(date +%s)"
    temp="$(read_temp_c)"

    if (( temp >= MAX_TEMP_C )); then
      if screen_exists; then
        log "Thermal high (${temp}C >= ${MAX_TEMP_C}C). Pausing miner."
        stop_miner
      fi
      while true; do
        sleep "${THERMAL_POLL_SEC}"
        temp="$(read_temp_c)"
        if (( temp <= RESUME_TEMP_C )); then
          log "Thermal recovered (${temp}C <= ${RESUME_TEMP_C}C). Resuming miner."
          break
        fi
      done
      start_miner
      last_restart="$now"
      sleep "${RESTART_COOLDOWN_SEC}"
      continue
    fi

    if ! screen_exists; then
      if (( now - last_restart >= RESTART_COOLDOWN_SEC )); then
        log "Miner not running; starting."
        start_miner
        last_restart="$now"
      fi
      sleep "${WATCHDOG_INTERVAL_SEC}"
      continue
    fi

    if [[ -f "$LOG_FILE" ]]; then
      local mtime
      mtime="$(stat -c %Y "$LOG_FILE" 2>/dev/null || echo 0)"
      if (( now - mtime >= STALE_LOG_SEC )); then
        if (( now - last_restart >= RESTART_COOLDOWN_SEC )); then
          log "Miner log stale (${now-mtime}s). Restarting."
          stop_miner
          start_miner
          last_restart="$now"
        fi
      fi
    fi

    sleep "${WATCHDOG_INTERVAL_SEC}"
  done
}

case "${1:-}" in
  start) start_miner ;;
  stop) stop_miner ;;
  restart) stop_miner; sleep 1; start_miner ;;
  status) status ;;
  watchdog) watchdog_loop ;;
  *) echo "Usage: $0 {start|stop|restart|status|watchdog}"; exit 1 ;;
esac
