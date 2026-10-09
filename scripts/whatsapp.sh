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
# La configuración la escribe la web en <DATA_PATH>/whatsapp.conf; mientras no se guarde nada ahí,
# valen las variables del .env (WHATSAPP_CHATS, WHATSAPP_BACKLOG_MIN, BACKGROUND_*). El estado (para la
# web) se escribe en <DATA_PATH>/whatsapp-status.json. Necesita "Acceso total al disco" para el programa
# que lo ejecuta (el agente: ~/.transcriptor/bin/transcriptor-agent).
#
# Consumo: el bucle casi no lanza procesos. Por sondeo solo corre un `find` (y nada más si no hay audios
# nuevos); la hora sale de $SECONDS, la configuración se mira con `-nt` y la espera es un `read -t`.
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
POLL="${WHATSAPP_POLL:-10}"            # segundos entre sondeos con todo encendido
POLL_IDLE="${WHATSAPP_POLL_IDLE:-30}"  # ... con el agente y todo apagado, o sin nada configurado
# Valores por defecto del .env del proyecto (el agente lo lanza launchd, que no pasa por make).
if [[ -f "$ROOT/.env" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^(WHATSAPP_CHATS|WHATSAPP_BACKLOG_MIN|BACKGROUND_ENABLED|BACKGROUND_IDLE_MIN|BACKGROUND_QUIT_DOCKER)=(.*)$ ]]; then
      k="${BASH_REMATCH[1]}"; [[ -z "${!k:-}" ]] && export "$k=${BASH_REMATCH[2]}"
    fi
  done <"$ROOT/.env"
fi
export PATH="${PATH:-/usr/bin:/bin}:/opt/homebrew/bin:/usr/local/bin:/Applications/Docker.app/Contents/Resources/bin:/usr/sbin:/sbin"
mkdir -p "$STATE_DIR"

# stat/date: GNU primero (en GNU `stat -f` no falla, solo hace otra cosa) y luego BSD (macOS).
# Hora de cambio (ctime), no de modificación: WhatsApp conserva la fecha original al reenviar un
# audio (lo copia con su mtime viejo), pero el ctime sí cambia cuando aparece el archivo nuevo.
ctime() { stat -c %Z "$1" 2>/dev/null || stat -f %c "$1" 2>/dev/null; }
statms() { stat -c '%Z %s' "$1" 2>/dev/null || stat -f '%c %z' "$1" 2>/dev/null; }
stamp() { date -r "$1" '+%Y-%m-%d %H.%M.%S' 2>/dev/null || date -d "@$1" '+%Y-%m-%d %H.%M.%S'; }
alive() { local p; [[ -f "$1" ]] && read -r p <"$1" 2>/dev/null && kill -0 "$p" 2>/dev/null; }   # sin procesos: read y kill son internos
log() { echo "$(date '+%F %T') $*"; }

# --- Configuración -----------------------------------------------------------------------------
# Lo guardado en la web (whatsapp.conf) manda; si no hay nada guardado, valen las variables del .env.
HAVE_CONF=0; C_MODE=off; C_CHATS=""; C_BACKLOG=60; BG_ENABLED=0; IDLE_MIN=10; QUIT_DOCKER=0; CHATS=""
CONF_STAMP="$STATE_DIR/whatsapp-conf.stamp"
conf_get() { sed -n "s/^$1=//p" "$CONF" 2>/dev/null | tail -1 | tr -d '\r'; }
reload_conf() { # devuelve 0 si la configuración cambió
  if [[ -f "$CONF" ]]; then
    # -nt es interno de bash: comprobar si cambió no lanza ningún proceso.
    [[ $HAVE_CONF == 1 && ! "$CONF" -nt "$CONF_STAMP" ]] && return 1
    touch -r "$CONF" "$CONF_STAMP" 2>/dev/null
    HAVE_CONF=1
    C_MODE="$(conf_get WHATSAPP_MODE)"; C_CHATS="$(conf_get WHATSAPP_CHATS)"
    C_BACKLOG="$(conf_get WHATSAPP_BACKLOG_MIN)"; BG_ENABLED="$(conf_get BACKGROUND_ENABLED)"
    IDLE_MIN="$(conf_get BACKGROUND_IDLE_MIN)"; QUIT_DOCKER="$(conf_get BACKGROUND_QUIT_DOCKER)"
  else
    [[ $HAVE_CONF == 2 ]] && return 1
    HAVE_CONF=2
    C_CHATS="${WHATSAPP_CHATS:-}"; C_CHATS="${C_CHATS// /}"
    case "$C_CHATS" in all) C_MODE=all ;; "") C_MODE=off ;; *) C_MODE=chats ;; esac
    C_BACKLOG="${WHATSAPP_BACKLOG_MIN:-60}"; BG_ENABLED="${BACKGROUND_ENABLED:-0}"
    IDLE_MIN="${BACKGROUND_IDLE_MIN:-10}"; QUIT_DOCKER="${BACKGROUND_QUIT_DOCKER:-0}"
  fi
  [[ "$C_BACKLOG" =~ ^[0-9]+$ ]] || C_BACKLOG=60
  [[ "$IDLE_MIN" =~ ^[0-9]+$ && "$IDLE_MIN" -ge 1 ]] || IDLE_MIN=10
  # Lista de chats ya resuelta (un id por línea, o "all"), para no recalcularla en cada sondeo.
  case "$C_MODE" in
    all) CHATS=all ;;
    chats) CHATS="$(printf '%s\n' "$C_CHATS" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$')" ;;
    *) CHATS="" ;;
  esac
  return 0
}
chat_list() { [[ -n "$CHATS" ]] && printf '%s\n' "$CHATS"; }
conf_source() { [[ $HAVE_CONF == 1 ]] && echo "web ($CONF)" || echo ".env (aún no se guardó nada en la web)"; }

# --- Estado para la web ------------------------------------------------------------------------
HOST_KIND=stack; STACK=on; ERROR=""; LAST_CHAT=""; LAST_AT=0; DET_CHAT=""; DET_AT=0; COPIED=0
LAST_BODY=""; LAST_WRITE=0
clean() { printf '%s' "$1" | tr -d '"\\\n\r' | cut -c1-280; }
write_status() { # $1 = ahora
  local body
  body="\"host\":\"$HOST_KIND\",\"stack\":\"$STACK\",\"error\":\"$(clean "$ERROR")\",\"lastChat\":\"$(clean "$LAST_CHAT")\",\"lastAt\":$LAST_AT,\"detected\":\"$(clean "$DET_CHAT")\",\"detectedAt\":$DET_AT,\"copied\":$COPIED"
  # La web da al vigilante por caído si el estado tiene más de 90 s: se reescribe cada ~50 s.
  if [[ "$body" != "$LAST_BODY" || $(($1 - LAST_WRITE)) -ge 50 ]]; then
    printf '{%s,"updatedAt":%s}\n' "$body" "$1" >"$STATUS.tmp" 2>/dev/null && mv "$STATUS.tmp" "$STATUS"
    LAST_BODY="$body"; LAST_WRITE="$1"
  fi
}

READ_ERR=""
can_read_media() { READ_ERR="$(ls "$MEDIA" 2>&1 >/dev/null)"; [[ -z "$READ_ERR" ]]; }
no_access_msg() {
  if [[ "$READ_ERR" == *"not permitted"* || "$READ_ERR" == *"Operation not"* ]]; then
    if [[ "$HOST_KIND" == agent ]]; then
      echo "Falta permiso de Acceso total al disco para transcriptor-agent ($STATE_DIR/bin/transcriptor-agent): Ajustes del Sistema → Privacidad y seguridad. Después: launchctl kickstart -k gui/$(id -u)/com.transcriptor.agent"
    else
      echo "Falta permiso de Acceso total al disco para el programa desde el que ejecutas make up (Terminal, WebStorm…). Mejor: instala el agente (make agente), que tiene su propio permiso."
    fi
  else
    echo "No puedo leer la carpeta de WhatsApp ($MEDIA): ${READ_ERR:-error desconocido}"
  fi
}

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
ERRF="$STATE_DIR/whatsapp-find.err"
# Copia los audios nuevos. Un solo `find` por sondeo, con -cmin (solo lo cambiado en los últimos
# minutos): no se examinan los miles de ficheros viejos ni se crea ningún fichero marca.
# Devuelve cuántos copió en NEW_COPIED; si no puede leer la carpeta, deja el motivo en ERROR.
scan_copy() { # $1 = ahora, $2 = inicio (epoch): no copia nada anterior; $3 = ventana en minutos
  NEW_COPIED=0
  local dirs=() chat f ms m s out
  [[ -n "$CHATS" ]] || return 0
  if [[ "$CHATS" == all ]]; then dirs=("$MEDIA"); else
    while IFS= read -r chat; do [[ -d "$MEDIA/$chat" ]] && dirs+=("$MEDIA/$chat"); done <<<"$CHATS"
  fi
  if [[ ${#dirs[@]} -eq 0 ]]; then   # todavía no hay audios de esos chats... o no hay permiso
    can_read_media || ERROR="$(no_access_msg)"
    return 0
  fi
  if ! out="$(find "${dirs[@]}" -type f -name '*.opus' -cmin "-$3" 2>"$ERRF")"; then
    READ_ERR="$(cat "$ERRF" 2>/dev/null)"; ERROR="$(no_access_msg)"; return 0
  fi
  [[ -n "$out" ]] || return 0
  while IFS= read -r f; do
    [[ -n "$f" && "$SEEN_MEM" != *$'\n'"$f"$'\n'* ]] || continue
    ms="$(statms "$f")" || continue
    m="${ms% *}"; s="${ms#* }"
    [[ "$m" -ge "$2" ]] || continue                          # anterior al inicio (o a la ventana hacia atrás)
    [[ "${s:-0}" -gt 0 && $(($1 - m)) -ge 3 ]] || continue   # vacío o aún escribiéndose
    if deliver "$f" "$m"; then
      SEEN_MEM+="$f"$'\n'; echo "$f" >>"$SEENFILE"
      NEW_COPIED=$((NEW_COPIED + 1)); COPIED=$((COPIED + 1)); LAST_AT="$1"
      chat="${f#"$MEDIA"/}"; LAST_CHAT="${chat%%/*}"
    fi
  done <<<"$out"
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
    m="$(ctime "$f")" || continue
    [[ "$m" -gt "$best" ]] && { best="$m"; bestf="$f"; }
  done < <(find "$MEDIA" -type f -name '*.opus' -cmin -3 2>/dev/null)
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
# Espera sin lanzar `sleep`: `read -t` sobre una tubería propia que nunca recibe nada.
open_nap() {
  local fifo="$STATE_DIR/.nap-$$"
  rm -f "$fifo"; mkfifo "$fifo" && exec 9<>"$fifo"; rm -f "$fifo"
}
nap() { read -r -t "$1" -u 9 _ 2>/dev/null || true; }

run_loop() { # $1 = stack | agent
  HOST_KIND="$1"
  touch "$SEENFILE"
  SEEN_MEM+="$(cat "$SEENFILE")"$'\n'
  open_nap
  local t0 now start last_act last_scan sleep_s window polls=0
  t0="$(date +%s)"; SECONDS=0
  now="$t0"; last_act="$now"; start="$now"; last_scan="$now"
  log "vigilante ($HOST_KIND) en marcha → $INBOX"
  while :; do
    now=$((t0 + SECONDS)); polls=$((polls + 1))
    if [[ "$HOST_KIND" == stack ]] && alive "$AGENTPID"; then
      log "el agente en segundo plano ya vigila: este vigilante se retira"
      rm -f "$PIDFILE"; exit 0
    fi
    if reload_conf; then
      start=$((now - C_BACKLOG * 60))   # al cambiar la configuración, vuelve a mirar hacia atrás
      last_scan="$start"
      log "configuración ($(conf_source)): modo=$C_MODE chats=$C_CHATS atrás=${C_BACKLOG}min segundo plano=$BG_ENABLED"
    fi
    local detect=0
    detect_active "$now" && detect=1
    ERROR=""; NEW_COPIED=0
    if [[ -n "$CHATS" ]]; then
      # Ventana de -cmin: lo que pasó desde el sondeo anterior, con margen (el Mac pudo dormir).
      window=$(((now - last_scan) / 60 + 2))
      mkdir -p "$INBOX"
      scan_copy "$now" "$start" "$window"
      [[ -z "$ERROR" ]] && last_scan="$now"
    fi
    if [[ $detect == 1 ]]; then
      if can_read_media; then detect_scan "$now"; else ERROR="$(no_access_msg)"; fi
    fi

    if [[ "$HOST_KIND" == agent ]]; then
      # Preguntar a la app si está encendida solo cuando importa (o cada ~2 min, para el estado).
      if [[ $NEW_COPIED -gt 0 || -f "$AGENT_STARTED" || $((polls % 4)) == 1 ]]; then
        if stack_on; then STACK=on; else STACK=off; fi
      fi
      if [[ "$BG_ENABLED" == 1 ]]; then
        if [[ $NEW_COPIED -gt 0 ]]; then
          last_act="$now"
          if [[ $STACK == off ]]; then start_stack; now=$((t0 + SECONDS)); last_act="$now"; stack_on && STACK=on; fi
        fi
        if [[ $STACK == on && -f "$AGENT_STARTED" ]]; then
          [[ "$(busy_sessions)" -gt 0 ]] && last_act="$now"
          if [[ $((now - last_act)) -ge $((IDLE_MIN * 60)) ]]; then stop_stack; STACK=off; fi
        fi
      fi
    fi

    write_status "$now"
    if [[ $detect == 1 ]]; then sleep_s=2
    elif [[ -z "$CHATS" ]]; then sleep_s="$POLL_IDLE"
    elif [[ "$HOST_KIND" == agent && $STACK == off ]]; then sleep_s="$POLL_IDLE"
    else sleep_s="$POLL"; fi
    nap "$sleep_s"
  done
}

agent() {
  alive "$AGENTPID" && { echo "El agente ya está en marcha (pid $(cat "$AGENTPID"))."; exit 0; }
  echo $$ >"$AGENTPID"
  alive "$PIDFILE" && kill "$(cat "$PIDFILE")" 2>/dev/null   # que no haya dos vigilantes escribiendo el estado
  rm -f "$PIDFILE"
  trap 'rm -f "$AGENTPID"; exit 0' INT TERM
  trap 'rm -f "$AGENTPID"' EXIT
  run_loop agent
}

start() {
  alive "$AGENTPID" && return 0   # el agente ya vigila (y copia) por su cuenta
  # Agente instalado pero parado (p. ej. tras quitarle el permiso y volver a darlo): se lo arranca.
  if [[ -f "$HOME/Library/LaunchAgents/com.transcriptor.agent.plist" ]] && command -v launchctl >/dev/null; then
    launchctl kickstart "gui/$(id -u)/com.transcriptor.agent" >/dev/null 2>&1 && return 0
  fi
  alive "$PIDFILE" && return 0
  nohup perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die "$!"' -- bash "$SELF" vigilar >>"$LOG" 2>&1 &
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
    *) echo "No vigila ningún chat (actívalo en la web: Configuración, o WHATSAPP_CHATS en el .env)." ;;
  esac
  echo "Configuración tomada de: $(conf_source)"
  echo "Al configurar, mira hacia atrás ${C_BACKLOG} min · segundo plano: $([[ "$BG_ENABLED" == 1 ]] && echo sí || echo no)"
  if alive "$AGENTPID"; then echo "Agente: en marcha (pid $(cat "$AGENTPID"))"
  elif alive "$PIDFILE"; then echo "Vigilante de make up: en marcha (pid $(cat "$PIDFILE"))"
  else echo "Vigilante: apagado"; fi
  can_read_media && echo "Carpeta de WhatsApp: legible" || echo "Carpeta de WhatsApp: SIN PERMISO. $(no_access_msg)"
}

# Para pegar en una conversación cuando algo no anda: no cambia nada, solo informa.
diagnostico() {
  local out rc
  echo "== sistema"; echo "macOS: $(sw_vers -productVersion 2>/dev/null || uname -sr) · $(uname -m)"
  echo "bash que ejecuta esto: ${BASH:-?} ${BASH_VERSION:-}"
  echo "== carpeta de WhatsApp"; echo "ruta: $MEDIA"
  out="$(ls "$MEDIA" 2>&1 >/dev/null)"; rc=$?
  echo "ls con este bash: código $rc ${out:+→ $out}"
  echo "== desde qué programa se ejecuta (el permiso de Acceso total al disco hay que dárselo a este)"
  local p="$$" i name
  for i in 1 2 3 4 5 6 7 8; do
    p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"; [[ -n "$p" && "$p" -gt 1 ]] || break
    name="$(ps -o comm= -p "$p" 2>/dev/null)"; echo "  ← $name"
  done
  echo "== procesos"
  alive "$AGENTPID" && echo "agente: en marcha (pid $(cat "$AGENTPID"))" || echo "agente: no está en marcha"
  alive "$PIDFILE" && echo "vigilante de make up: en marcha (pid $(cat "$PIDFILE"))" || echo "vigilante de make up: no está en marcha"
  launchctl print "gui/$(id -u)/com.transcriptor.agent" 2>&1 | grep -E "state =|last exit|pid =|runs =" | head -5 | sed 's/^[[:space:]]*/launchd: /'
  echo "== configuración ($CONF)"; cat "$CONF" 2>/dev/null || echo "(no existe: aún no se guardó nada en Configuración)"
  echo "== estado ($STATUS)"; cat "$STATUS" 2>/dev/null || echo "(no existe)"
  echo "== últimas líneas del registro ($LOG)"; tail -n 15 "$LOG" 2>/dev/null || echo "(sin registro)"
}

case "${1:-}" in
  diagnostico) diagnostico ;;
  start) start ;;
  stop) stop ;;
  agent) agent ;;
  estado) estado ;;
  vigilar) run_loop stack ;;
  *) echo "Uso: $0 {start|stop|agent|estado|diagnostico|vigilar}" >&2; exit 2 ;;
esac
