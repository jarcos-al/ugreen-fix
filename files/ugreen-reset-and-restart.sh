#!/usr/bin/env bash
set -euo pipefail

LOG="/var/log/ugreen-fix.log"
VID="345f"
PID="2131"

CT_ID="${UGREEN_CT_ID:-402}"
CT_RESTART_MODE="${UGREEN_CT_RESTART_MODE:-reboot}"   # reboot | restart-service | stop-start | none
CT_SERVICE="${UGREEN_CT_SERVICE:-ugreen-capture}"     # servicio dentro del CT

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG" >/dev/null; }

need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Este script necesita root." >&2
    exit 1
  fi
}

find_usb_sysdev() {
  for d in /sys/bus/usb/devices/*; do
    [[ -f "$d/idVendor" && -f "$d/idProduct" ]] || continue
    local v p
    v="$(cat "$d/idVendor" 2>/dev/null || true)"
    p="$(cat "$d/idProduct" 2>/dev/null || true)"
    if [[ "$v" == "$VID" && "$p" == "$PID" ]]; then
      echo "$d"
      return 0
    fi
  done
  return 1
}

toggle_authorized() {
  local sysdev="$1"
  local auth="$sysdev/authorized"
  [[ -w "$auth" ]] || { log "ERROR: no puedo escribir en $auth (¿permisos?)"; return 2; }
  log "Toggling authorized en $auth"
  echo 0 > "$auth"
  sleep 2
  echo 1 > "$auth"
  sleep 2
}

pct_exec_quiet() {
  local cmd="$*"
  pct exec "$CT_ID" -- bash -lc "$cmd" >/dev/null 2>&1 || return 1
}

restart_ct_logic() {
  case "$CT_RESTART_MODE" in
    none)
      log "CT_RESTART_MODE=none, no toco el CT."
      ;;
    restart-service)
      log "Reiniciando servicio dentro del CT: $CT_SERVICE"
      pct exec "$CT_ID" -- systemctl restart "$CT_SERVICE"
      ;;
    stop-start)
      log "Haciendo stop/start del CT $CT_ID"
      pct stop "$CT_ID" || true
      sleep 2
      pct start "$CT_ID"
      ;;
    reboot|*)
      log "Haciendo reboot del CT $CT_ID"
      pct reboot "$CT_ID"
      ;;
  esac
}

main() {
  need_root
  touch "$LOG"
  chmod 0644 "$LOG"

  log "=== UGREEN FIX START ==="
  log "CT_ID=$CT_ID CT_RESTART_MODE=$CT_RESTART_MODE CT_SERVICE=$CT_SERVICE"

  local sysdev
  if ! sysdev="$(find_usb_sysdev)"; then
    log "ERROR: no encuentro UGREEN ($VID:$PID) en /sys/bus/usb/devices"
    exit 1
  fi
  log "Encontrado dispositivo en $sysdev"

  # (opcional) intenta parar el servicio dentro del CT antes del reset para evitar estados raros
  if pct status "$CT_ID" >/dev/null 2>&1; then
    log "Parando servicio dentro del CT (best effort): $CT_SERVICE"
    pct_exec_quiet "systemctl stop $CT_SERVICE" || true
  fi

  toggle_authorized "$sysdev"

  # Espera a que udev asiente el /dev/video-ugreen
  log "Esperando /dev/video-ugreen..."
  for i in {1..20}; do
    [[ -e /dev/video-ugreen ]] && break
    sleep 0.2
  done
  [[ -e /dev/video-ugreen ]] && log "OK: /dev/video-ugreen presente" || log "WARN: /dev/video-ugreen no aparece (aún)"

  restart_ct_logic

  log "=== UGREEN FIX END ==="
}

main "$@"
