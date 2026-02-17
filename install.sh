#!/usr/bin/env bash
set -euo pipefail

# --- Defaults (repo actual) ---
GITHUB_USER_DEFAULT="jarcos-al"
GITHUB_REPO_DEFAULT="ugreen-fix"
GITHUB_BRANCH_DEFAULT="main"

# Puedes sobreescribir si quieres:
GITHUB_USER="${GITHUB_USER:-$GITHUB_USER_DEFAULT}"
GITHUB_REPO="${GITHUB_REPO:-$GITHUB_REPO_DEFAULT}"
GITHUB_BRANCH="${GITHUB_BRANCH:-$GITHUB_BRANCH_DEFAULT}"

REPO_RAW_BASE="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${GITHUB_BRANCH}"

CT_ID="${UGREEN_CT_ID:-402}"
WEB_PORT="${UGREEN_WEB_PORT:-8088}"
WEB_TOKEN="${UGREEN_WEB_TOKEN:-}"  # opcional

need_root() {
  if [[ ${EUID:-0} -ne 0 ]]; then
    echo "Ejecuta como root." >&2
    exit 1
  fi
}

fetch() {
  local url="$1" dest="$2"
  echo ">> Descargando $url"
  curl -fsSL "$url" -o "$dest"
  chmod +x "$dest" 2>/dev/null || true
}

install_udev() {
  echo ">> Instalando udev rule"
  curl -fsSL "$REPO_RAW_BASE/files/99-ugreen-capture.rules" -o /etc/udev/rules.d/99-ugreen-capture.rules
  udevadm control --reload-rules
  udevadm trigger
}

install_scripts() {
  echo ">> Instalando scripts"
  fetch "$REPO_RAW_BASE/files/ugreen-reset-and-restart.sh" /usr/local/sbin/ugreen-reset-and-restart.sh
  fetch "$REPO_RAW_BASE/files/ugreen-web.py" /usr/local/sbin/ugreen-web.py
}

install_service() {
  echo ">> Instalando systemd service"
  curl -fsSL "$REPO_RAW_BASE/files/ugreen-web.service" -o /etc/systemd/system/ugreen-web.service

  mkdir -p /etc/systemd/system/ugreen-web.service.d
  cat > /etc/systemd/system/ugreen-web.service.d/override.conf <<EOF
[Service]
Environment=UGREEN_CT_ID=${CT_ID}
Environment=UGREEN_WEB_PORT=${WEB_PORT}
EOF

  if [[ -n "$WEB_TOKEN" ]]; then
    echo "Environment=UGREEN_WEB_TOKEN=${WEB_TOKEN}" >> /etc/systemd/system/ugreen-web.service.d/override.conf
  fi

  systemctl daemon-reload
  systemctl enable --now ugreen-web.service
}

main() {
  need_root

  echo "== UGREEN FIX INSTALLER =="
  echo "Repo: $REPO_RAW_BASE"
  echo "CT:   $CT_ID"
  echo "Port: $WEB_PORT"
  [[ -n "$WEB_TOKEN" ]] && echo "Token: (configurado)" || echo "Token: (no)"

  install_udev
  install_scripts
  install_service

  echo
  echo "✅ Instalado."
  echo "   Web:  http://<IP-HOST>:${WEB_PORT}/"
  if [[ -n "$WEB_TOKEN" ]]; then
    echo "   Con token: http://<IP-HOST>:${WEB_PORT}/?token=${WEB_TOKEN}"
  fi
  echo "   Script manual: /usr/local/sbin/ugreen-reset-and-restart.sh"
}

main

