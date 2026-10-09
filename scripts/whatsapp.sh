#!/usr/bin/env bash
# Copia a la carpeta de entrada los audios que WhatsApp de escritorio (macOS) guarda en el disco,
# de los chats que elijas en la web (Configuración). No se conecta a WhatsApp ni a tu cuenta: solo
# lee los ficheros .opus que la propia app ya dejó en su carpeta (nunca abre sus bases de datos).
#
# Uso: scripts/whatsapp.sh {start|stop|agent|estado|vigilar}
#   start/stop  vigilante en segundo plano que acompaña a `make up` / `make down`
#   agent       vigilante SIEMPRE activo (lo instala `make agente`): casi no consume; cuando llega un
#               audio enciende todo y, tras unos minutos sin actividad, lo apaga (Configuración → Segundo plano)
#   estado      muestra qué vigila
#   vigilar     en primer plano, para ver qué hace (Ctrl+C para salir)
#
# La configuración la escribe la web en <DATA_PATH>/whatsapp.conf. El estado (para la web) se escribe
# en <DATA_PATH>/whatsapp-status.json. Necesita "Acceso total al disco" para el programa que lo ejecuta.
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
ROOT="$(dirname "$(dirname "$SELF")")"
STATE_DIR="${TRANSCRIPTOR_HOME:-$HOME/.transcriptor}"
DATA_PATH="${DATA_PATH:-$HOME/TranscriptorAudios}"
MEDIA="${WHATSAPP_MEDIA:-$HOME/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media}"
INBOX="${INBOX_PATH:-$DATA_PATH/entrada}"
PORT="${PORT:-4747}"
CONF="$DATA_PATH/whatsapp.conf"
STATUS="$DATA_PATH/whatsapp-status.json"
DETECT="$DATA_PATH/whatsapp-detect"
SEENFILE="$STATE_DIR/whatsapp-seen"
PIDFILE="$STATE_DIR/whatsapp.pid"      # vigilante que lanzó `make up`
AGENTPID="$STATE_DIR/agent.pid"        # agente siempre activo
AGENT_STARTED="$STATE_DIR/agent-started"       # existe si el agente encendió la app (y puede apagarla)
DOCKER_BY_AGENT="$STATE_DIR/agent-docker"      # existe si el agente abrió Docker Desktop
LOG="$STATE_DIR/whatsapp.log"
POLL="${WHATSAPP_POLL:-5}"             # segundos entre sondeos con todo encendido
POLL_IDLE="${WHATSAPP_POLL_IDLE:-15}"  # ... con el agente y todo apagado, o sin nada configurado
export PATH="${PATH:-/usr/bin:/bin}:/opt/homebrew/bin:/usr/local/bin:/Applications/Docker.app/Contents/Resources/bin:/usr/sbin:/sbin"
mkdir -p "$STATE_DIR"

# stat/date: GNU primero (en GNU `stat -f` no falla, solo hace otra cosa) y luego BSD (macOS).
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
statms() { stat -c '%Y %s' "$1" 2>/dev/null || stat -f '%m %z' "$1" 2>/dev/null; }
stamp() { date -r "$1" '+%Y-%m-%d %H.%M.%S' 2>/dev/null || date -d "@$1" '+%Y-%m-%d %H.%M.%S'; }
touch_epoch() { touch -t "$(date -r "$2" '+%Y%m%d%H%M.%S' 2>/dev/null || date -d "@$2" '+%Y%m%d%H%M.%S')" "$1"; }
alive() { [[ -f "$1" ]] && kill -0 "$(cat "$1")" 2>/dev/null; }
log() { echo "$(date '+%F %T') $*"; }

# --- Configuración (la escribe la web) --------------------------------------------------------
HAVE_CONF=0; CONF_M=""; C_MODE=off; C_CHATS=""; C_BACKLOG=60; BG_ENABLED=0; IDLE_MIN=10; QUIT_DOCKER=0
conf_get() { sed -n "s/^$1=//p" "$CONF" 2>/dev/null | tail -1 | tr -d '\r'; }
reload_conf() { # devuelve 0 si la configuración cambió
  local m; m="$(mtime "$CONF")" || m=""
  [[ "$m" == "$CONF_M" ]] && return 1
  CONF_M="$m"
  if [[ -z "$m" ]]; then HAVE_CONF=0; C_MODE=off; C_CHATS=""; BG_ENABLED=0; return 0; fi
  HAVE_CONF=1
  C_MODE="$(conf_get WHATSAPP_MODE)"; C_CHATS="$(conf_get WHATSAPP_CHATS)"
  C_BACKLOG="$(conf_get WHATSAPP_BACKLOG_MIN)"; BG_ENABLED="$(conf_get BACKGROUND_ENABLED)"
  IDLE_MIN="$(conf_get BACKGROUND_IDLE_MIN)"; QUIT_DOCKER="$(conf_get BACKGROUND_QUIT_DOCKER)"
  [[ "$C_BACKLOG" =~ ^[0-9]+$ ]] || C_BACKLOG=60
  [[ "$IDLE_MIN" =~ ^[0-9]+$ && "$IDLE_MIN" -ge 1 ]] || IDLE_MIN=10
  return 0
}
# "all" (un solo valor), o la lista de ids, o nada.
chat_list() {
  case "$C_MODE" in
    all) echo all ;;
    chats) printf '%s\n' "$C_CHATS" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$' ;;
  esac
}

# --- Estado para la web ------------------------------------------------------------------------
HOST_KIND=stack; STACK=on; ERROR=""; LAST_CHAT=""; LAST_AT=0; DET_CHAT=""; DET_AT=0; COPIED=0
LAST_BODY=""; LAST_WRITE=0
clean() { printf '%s' "$1" | tr -d '"\\\n\r' | cut -c1-280; }
write_status() { # $1 = ahora
  local body
  body="\"host\":\"$HOST_KIND\",\"stack\":\"$STACK\",\"error\":\"$(clean "$ERROR")\",\"lastChat\":\"$(clean "$LAST_CHAT")\",\"lastAt\":$LAST_AT,\"detected\":\"$(clean "$DET_CHAT")\",\"detectedAt\":$DET_AT,\"copied\":$COPIED"
  if [[ "$body" != "$LAST_BODY" || $(($1 - LAST_WRITE)) -ge 30 ]]; then
    printf '{%s,"updatedAt":%s}\n' "$body" "$1" >"$STATUS.tmp" 2>/dev/null && mv "$STATUS.tmp" "$STATUS"
    LAST_BODY="$body"; LAST_WRITE="$1"
  fi
}

can_read_media() { ls "$MEDIA" >/dev/null 2>&1; }
no_access_msg() { echo "Falta permiso: Ajustes del Sistema → Privacidad y seguridad → Acceso total al disco → activa ${BASH:-bash} (o Terminal, si lo ejecutas desde ahí)."; }

# --- Copia ------------------------------------------------------------------------------------
# Copia un audio a la entrada con un nombre legible (fecha y hora), en dos pasos para que la app
# no lo tome a medias (los ficheros que empiezan por punto se ignoran).
deliver() { # origen mtime
  local name dst n=1
  name="WhatsApp $(stamp "$2")"
  dst="$INBOX/$name.opus"
  while [[ -e "$dst" || -e "$INBOX/procesados/$name.opus" ]]; do n=$((n + 1)); dst="$INBOX/$name ($n).opus"; done
  cp -p "$1" "$INBOX/.$name.part" && mv "$INBOX/.$name.part" "$dst" && log "copiado: $dst"
}

SEEN_MEM=$'\n'
MARK="$STATE_DIR/whatsapp-mark"
# Copia los audios nuevos. Un solo `find` por sondeo, solo con lo posterior a la marca: no se
# examinan los miles de ficheros viejos. Devuelve cuántos copió en NEW_COPIED.
scan_copy() { # $1 = ahora, $2 = inicio (epoch)
  NEW_COPIED=0
  local chats dirs=() chat f ms m s
  chats="$(chat_list)"
  [[ -n "$chats" ]] || return 0
  if printf '%s\n' "$chats" | grep -qx all; then dirs=("$MEDIA"); else
    while IFS= read -r chat; do [[ -d "$MEDIA/$chat" ]] && dirs+=("$MEDIA/$chat"); done <<<"$chats"
  fi
  [[ ${#dirs[@]} -gt 0 ]] || return 0
  touch_epoch "$MARK" "$2" 2>/dev/null || return 0
  while IFS= read -r f; do
    [[ -n "$f" && "$SEEN_MEM" != *$'\n'"$f"$'\n'* ]] || continue
    ms="$(statms "$f")" || continue
    m="${ms% *}"; s="${ms#* }"
    [[ "${s:-0}" -gt 0 && $(($1 - m)) -ge 3 ]] || continue   # vacío o aún escribiéndose
    if deliver "$f" "$m"; then
      SEEN_MEM+="$f"$'\n'; echo "$f" >>"$SEENFILE"
      NEW_COPIED=$((NEW_COPIED + 1)); COPIED=$((COPIED + 1)); LAST_AT="$1"
      chat="${f#"$MEDIA"/}"; LAST_CHAT="${chat%%/*}"
    fi
  done < <(find "${dirs[@]}" -type f -name '*.opus' -newer "$MARK" 2>/dev/null)
}

# Detección de chat: mientras la web lo pide (unos minutos), mira todos los chats y anota el de
# su audio más reciente, para que se elija reproduciendo un audio suyo.
detect_active() { # $1 = ahora
  [[ -f "$DETECT" ]] || return 1
  local t; t="$(tr -dc '0-9' <"$DETECT")"
  [[ -n "$t" && $(($1 - t)) -le 180 ]] && return 0
  rm -f "$DETECT"; return 1
}
detect_scan() { # $1 = ahora
  local f m best=0 bestf=""
  while IFS= read -r f; do
    m="$(mtime "$f")" || continue
    [[ "$m" -gt "$best" ]] && { best="$m"; bestf="$f"; }
  done < <(find "$MEDIA" -type f -name '*.opus' -mmin -3 2>/dev/null)
  [[ -n "$bestf" ]] || return 0
  bestf="${bestf#"$MEDIA"/}"; DET_CHAT="${bestf%%/*}"; DET_AT="$best"
}

# --- Encender / apagar todo (agente) ----------------------------------------------------------
stack_on() { curl -fs -m 2 -o /dev/null "http://127.0.0.1:$PORT/api/health"; }
busy_sessions() { curl -fs -m 3 "http://127.0.0.1:$PORT/api/sessions" 2>/dev/null | grep -o '"busy":true' | wc -l | tr -d ' '; }

start_stack() {
  log "agente: llegó un audio, enciendo todo"
  if ! docker info >/dev/null 2>&1; then touch "$DOCKER_BY_AGENT"; fi
  if "$ROOT/scripts/boot.sh" >>"$LOG" 2>&1; then touch "$AGENT_STARTED"; else
    ERROR="No pude encender la app (Docker). Detalles: $LOG"; log "agente: falló el arranque"
  fi
}
stop_stack() {
  log "agente: sin actividad, apago todo"
  (cd "$ROOT" && make down) >>"$LOG" 2>&1
  rm -f "$AGENT_STARTED"
  if [[ "$QUIT_DOCKER" == 1 && -f "$DOCKER_BY_AGENT" ]]; then
    # Solo se cierra Docker Desktop si lo abrimos nosotros y no queda ningún otro contenedor en marcha.
    if [[ -z "$(docker ps -q 2>/dev/null)" ]]; then
      log "agente: cierro Docker Desktop"; osascript -e 'quit app "Docker"' >>"$LOG" 2>&1 || true
    fi
  fi
  rm -f "$DOCKER_BY_AGENT"
}

# --- Bucle principal ----------------------------------------------------------------------------
run_loop() { # $1 = stack | agent
  HOST_KIND="$1"
  touch "$SEENFILE"
  SEEN_MEM+="$(cat "$SEENFILE")"$'\n'
  local now start last_act sleep_s
  now="$(date +%s)"; last_act="$now"; start="$now"
  log "vigilante ($HOST_KIND) en marcha → $INBOX"
  while :; do
    now="$(date +%s)"
    if reload_conf; then
      start=$((now - C_BACKLOG * 60))   # al cambiar la configuración, vuelve a mirar hacia atrás
      log "configuración: modo=$C_MODE chats=$C_CHATS atrás=${C_BACKLOG}min segundo plano=$BG_ENABLED"
    fi
    local chats detect=0; chats="$(chat_list)"
    detect_active "$now" && detect=1
    ERROR=""
    if [[ -n "$chats" || $detect == 1 ]]; then
      if can_read_media; then
        mkdir -p "$INBOX"
        scan_copy "$now" "$start"
        [[ $detect == 1 ]] && detect_scan "$now"
      else
        ERROR="$(no_access_msg)"; NEW_COPIED=0
      fi
    else
      NEW_COPIED=0
    fi

    if [[ "$HOST_KIND" == agent ]]; then
      if stack_on; then STACK=on; else STACK=off; fi
      if [[ "$BG_ENABLED" == 1 ]]; then
        if [[ $NEW_COPIED -gt 0 ]]; then
          last_act="$now"
          [[ $STACK == off ]] && { start_stack; now="$(date +%s)"; last_act="$now"; stack_on && STACK=on; }
        fi
        if [[ $STACK == on && -f "$AGENT_STARTED" ]]; then
          [[ "$(busy_sessions)" -gt 0 ]] && last_act="$now"
          if [[ $((now - last_act)) -ge $((IDLE_MIN * 60)) ]]; then stop_stack; STACK=off; fi
        fi
      fi
    fi

    write_status "$now"
    if [[ $detect == 1 ]]; then sleep_s=2
    elif [[ -z "$chats" ]]; then sleep_s="$POLL_IDLE"
    elif [[ "$HOST_KIND" == agent && $STACK == off ]]; then sleep_s="$POLL_IDLE"
    else sleep_s="$POLL"; fi
    sleep "$sleep_s" & wait $!   # en segundo plano + wait: las señales (apagar) se atienden al instante
  done
}

agent() {
  alive "$AGENTPID" && { echo "El agente ya está en marcha (pid $(cat "$AGENTPID"))."; exit 0; }
  echo $$ >"$AGENTPID"
  trap 'rm -f "$AGENTPID"; exit 0' INT TERM
  trap 'rm -f "$AGENTPID"' EXIT
  run_loop agent
}

start() {
  alive "$AGENTPID" && return 0   # el agente ya vigila (y copia) por su cuenta
  alive "$PIDFILE" && return 0
  nohup perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die "$!"' -- "$SELF" vigilar >>"$LOG" 2>&1 &
  echo $! >"$PIDFILE"
}

stop() {
  alive "$PIDFILE" && kill "$(cat "$PIDFILE")" && echo "Copia de audios de WhatsApp detenida"
  rm -f "$PIDFILE"
}

estado() {
  reload_conf
  case "$C_MODE" in
    all) echo "Vigila: TODOS los chats" ;;
    chats) echo "Chats vigilados:"; chat_list | sed 's/^/  /' ;;
    *) echo "No vigila ningún chat (actívalo en la web: Configuración)." ;;
  esac
  echo "Al configurar, mira hacia atrás ${C_BACKLOG} min · segundo plano: $([[ "$BG_ENABLED" == 1 ]] && echo sí || echo no)"
  if alive "$AGENTPID"; then echo "Agente: en marcha (pid $(cat "$AGENTPID"))"
  elif alive "$PIDFILE"; then echo "Vigilante de make up: en marcha (pid $(cat "$PIDFILE"))"
  else echo "Vigilante: apagado"; fi
  can_read_media && echo "Carpeta de WhatsApp: legible" || echo "Carpeta de WhatsApp: SIN PERMISO. $(no_access_msg)"
}

case "${1:-}" in
  start) start ;;
  stop) stop ;;
  agent) agent ;;
  estado) estado ;;
  vigilar) run_loop stack ;;
  *) echo "Uso: $0 {start|stop|agent|estado|vigilar}" >&2; exit 2 ;;
esac
