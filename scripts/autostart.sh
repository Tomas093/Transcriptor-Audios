#!/usr/bin/env bash
# Instala/quita un LaunchAgent de macOS que ejecuta `make up` al iniciar sesión.
# Uso: scripts/autostart.sh {install|uninstall|status}
# Toma PORT, DATA_PATH, OLLAMA_MODEL, WHISPER_THREADS y RETENTION_DAYS del entorno si están definidos.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="com.transcriptor.autostart"
AGENTS_DIR="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
PLIST="$AGENTS_DIR/$LABEL.plist"
STATE_DIR="${TRANSCRIPTOR_HOME:-$HOME/.transcriptor}"
DOMAIN="gui/$(id -u)"

xml() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"; }

env_entries() {
  local k v
  for k in PORT DATA_PATH OLLAMA_MODEL WHISPER_THREADS RETENTION_DAYS; do
    v="${!k:-}"
    [[ -n "$v" ]] && printf '    <key>%s</key><string>%s</string>\n' "$k" "$(xml "$v")"
  done
  printf '    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/Applications/Docker.app/Contents/Resources/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>\n'
}

install() {
  mkdir -p "$AGENTS_DIR" "$STATE_DIR"
  cat >"$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$(xml "$ROOT/scripts/boot.sh")</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
$(env_entries)
  </dict>
  <key>WorkingDirectory</key><string>$(xml "$ROOT")</string>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>$(xml "$STATE_DIR/autostart.log")</string>
  <key>StandardErrorPath</key><string>$(xml "$STATE_DIR/autostart.log")</string>
</dict>
</plist>
PLIST
  echo "Creado $PLIST"
  if command -v launchctl >/dev/null; then
    launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
    launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null || launchctl load -w "$PLIST"
    echo "Arranque automático activado: se levanta solo al iniciar sesión (y ahora mismo)."
    echo "Registro: $STATE_DIR/autostart.log   ·   Desactivar: make autostart-off"
  else
    echo "(launchctl no está disponible: solo se generó el archivo)"
  fi
}

uninstall() {
  if command -v launchctl >/dev/null; then
    launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || launchctl unload "$PLIST" >/dev/null 2>&1 || true
  fi
  rm -f "$PLIST"
  echo "Arranque automático desactivado."
}

status() {
  if [[ -f "$PLIST" ]]; then echo "Arranque automático: activado ($PLIST)"; else echo "Arranque automático: desactivado"; fi
}

case "${1:-}" in
  install) install ;;
  uninstall) uninstall ;;
  status) status ;;
  *) echo "Uso: $0 {install|uninstall|status}" >&2; exit 2 ;;
esac
