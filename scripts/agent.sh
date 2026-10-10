#!/usr/bin/env bash
# Instala/quita el AGENTE en segundo plano (LaunchAgent de macOS): un vigilante casi sin consumo que
# arranca al iniciar sesión, copia a la entrada los audios de WhatsApp que elijas en la web y, cuando
# llega uno, enciende todo; tras unos minutos sin actividad lo apaga. Se configura en la web
# (Configuración → Segundo plano).
# Uso: scripts/agent.sh {install|uninstall|status}
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="com.transcriptor.agent"
AGENTS_DIR="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
PLIST="$AGENTS_DIR/$LABEL.plist"
STATE_DIR="${TRANSCRIPTOR_HOME:-$HOME/.transcriptor}"
DOMAIN="gui/$(id -u)"
# Lanzador propio (se compila al instalar desde scripts/agent-launcher.c): el permiso "Acceso total al
# disco" se le da a ESTE binario y no a /bin/bash. (Una copia de bash no sirve: macOS la mata por firma.)
LAUNCHER="$STATE_DIR/bin/transcriptor-agent"
OLD_COPY="$STATE_DIR/bin/transcriptor-bash"

xml() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' <<<"$1"; }

env_entries() {
  local k v
  for k in PORT DATA_PATH INBOX_PATH TRANSCRIPTOR_HOME OLLAMA_MODEL WHISPER_THREADS RETENTION_DAYS WHISPER_MODEL_FILE; do
    v="${!k:-}"
    [[ -n "$v" ]] && printf '    <key>%s</key><string>%s</string>\n' "$k" "$(xml "$v")"
  done
  printf '    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/Applications/Docker.app/Contents/Resources/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>\n'
}

build_launcher() {
  command -v clang >/dev/null || { echo "Falta clang: ejecuta  xcode-select --install  y vuelve a probar." >&2; exit 1; }
  rm -f "$LAUNCHER"
  clang -O2 -o "$LAUNCHER" "$ROOT/scripts/agent-launcher.c"
  codesign --force -s - -i com.transcriptor.agent "$LAUNCHER" >/dev/null 2>&1
}

install() {
  mkdir -p "$AGENTS_DIR" "$STATE_DIR/bin"
  rm -f "$OLD_COPY"
  build_launcher
  cat >"$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(xml "$LAUNCHER")</string>
    <string>$(xml "$ROOT/scripts/whatsapp.sh")</string>
    <string>agent</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
$(env_entries)
  </dict>
  <key>WorkingDirectory</key><string>$(xml "$ROOT")</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>ProcessType</key><string>Background</string>
  <key>Nice</key><integer>10</integer>
  <key>LowPriorityIO</key><true/>
  <key>StandardOutPath</key><string>$(xml "$STATE_DIR/whatsapp.log")</string>
  <key>StandardErrorPath</key><string>$(xml "$STATE_DIR/whatsapp.log")</string>
</dict>
</plist>
PLIST
  echo "Creado $PLIST"
  if command -v launchctl >/dev/null; then
    launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
    launchctl bootstrap "$DOMAIN" "$PLIST" 2>/dev/null || launchctl load -w "$PLIST"
    echo "Agente instalado: arranca solo al iniciar sesión (y ya está en marcha)."
  else
    echo "(launchctl no está disponible: solo se generó el archivo)"
  fi
  cat <<MSG

Dos cosas más, una sola vez:
 1. Permiso: Ajustes del Sistema → Privacidad y seguridad → Acceso total al disco → «+» → pulsa
    Cmd+Shift+G, escribe  $LAUNCHER  y añádelo (y actívalo).
    Es un programa propio de pocas líneas (scripts/agent-launcher.c), no todo bash.
    Si antes diste el permiso a /bin/bash o a «transcriptor-bash», ya puedes quitarlo.
 1b. Después de darle el permiso, reinicia el agente para que lo tome:
        launchctl kickstart -k gui/$(id -u)/$LABEL
 2. En la web: Configuración → elige los chats y activa «Escuchar en segundo plano».
Registro: $STATE_DIR/whatsapp.log   ·   Quitar el agente: make agente-off
MSG
}

uninstall() {
  if command -v launchctl >/dev/null; then
    launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || launchctl unload "$PLIST" >/dev/null 2>&1 || true
  fi
  rm -f "$PLIST" "$OLD_COPY" "$LAUNCHER"
  echo "Agente desinstalado."
}

status() {
  if [[ -f "$PLIST" ]]; then echo "Agente: instalado ($PLIST)"; else echo "Agente: no instalado (make agente)"; fi
  "$ROOT/scripts/whatsapp.sh" estado
}

case "${1:-}" in
  install) install ;;
  uninstall) uninstall ;;
  status) status ;;
  *) echo "Uso: $0 {install|uninstall|status}" >&2; exit 2 ;;
esac
