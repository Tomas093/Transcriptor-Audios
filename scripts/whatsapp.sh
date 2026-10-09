#!/usr/bin/env bash
# Copia a la carpeta de entrada los audios que WhatsApp de escritorio (macOS) guarda en el disco,
# SOLO de los chats que elijas. No se conecta a WhatsApp ni a tu cuenta: solo lee los ficheros .opus
# que la propia app ya dejó en su carpeta (nunca abre sus bases de datos).
#
# Uso: scripts/whatsapp.sh {elegir|quitar|estado|vigilar|start|stop}
#   elegir   te deja marcar un chat reproduciendo un audio suyo
#   quitar   deja de vigilar todos los chats
#   estado   muestra qué chats vigila y si está en marcha
#   start/stop   en segundo plano (lo usan `make up` y `make down`)
#   vigilar  en primer plano (para ver qué hace; Ctrl+C para salir)
#
# Qué vigila (en el fichero .env de la raíz del proyecto, ver .env.example):
#   WHATSAPP_CHATS=all                  todos los chats
#   WHATSAPP_CHATS=<id>,<id>            solo esos chats (el id lo da `make whatsapp`)
#   (sin definir)                       los chats elegidos con `make whatsapp`
#   WHATSAPP_BACKLOG_MIN=60             al encender, también los audios de los últimos 60 min (0 = solo nuevos)
#
# Necesita que el programa que lo ejecuta (Terminal, o la app Transcriptor) tenga "Acceso total
# al disco" en Ajustes del Sistema → Privacidad y seguridad. Solo toma audios que lleguen
# DESPUÉS de encenderlo, más los de los últimos WHATSAPP_BACKLOG_MIN minutos (60 por defecto).
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
ROOT="$(dirname "$(dirname "$SELF")")"

# .env (CLAVE=valor, sin comillas; comentarios en su propia línea). Lo ya definido en el entorno
# o en la línea de comandos manda sobre el fichero.
if [[ -f "$ROOT/.env" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*([A-Z][A-Z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
    val="${val%"${val##*[![:space:]]}"}"; val="${val#\"}"; val="${val%\"}"
    [[ -z "${!key+x}" ]] && export "$key=$val"
  done <"$ROOT/.env"
fi

STATE_DIR="${TRANSCRIPTOR_HOME:-$HOME/.transcriptor}"
MEDIA="${WHATSAPP_MEDIA:-$HOME/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media}"
INBOX="${INBOX_PATH:-${DATA_PATH:-$HOME/TranscriptorAudios}/entrada}"
CHATS="$STATE_DIR/whatsapp-chats"
SEEN="$STATE_DIR/whatsapp-seen"
PIDFILE="$STATE_DIR/whatsapp.pid"
LOG="$STATE_DIR/whatsapp.log"
POLL="${WHATSAPP_POLL:-3}"
mkdir -p "$STATE_DIR"

# Lista de chats a vigilar: WHATSAPP_CHATS del .env (all o ids separados por coma) o, si no está, el fichero de `make whatsapp`.
chat_list() {
  if [[ -n "${WHATSAPP_CHATS:-}" ]]; then
    printf '%s\n' "$WHATSAPP_CHATS" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -v '^$'
  elif [[ -s "$CHATS" ]]; then
    cat "$CHATS"
  fi
}
configured() { [[ -n "$(chat_list)" ]]; }
all_chats() { chat_list | grep -qxi 'all'; }

# stat/date: BSD (macOS) y GNU; se prueba primero la forma GNU porque `stat -f` en GNU no falla, solo da otra cosa.
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
size() { stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null; }
stamp() { date -r "$1" '+%Y-%m-%d %H.%M.%S' 2>/dev/null || date -d "@$1" '+%Y-%m-%d %H.%M.%S'; }
alive() { [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; }

need_access() {
  if ! ls "$MEDIA" >/dev/null 2>&1; then
    echo "No puedo leer la carpeta de WhatsApp: $MEDIA" >&2
    echo "Si dice 'Operation not permitted': Ajustes del Sistema → Privacidad y seguridad → Acceso total al disco," >&2
    echo "activa Terminal (o la app Transcriptor, si lo enciendes con el ícono) y vuelve a abrirla." >&2
    return 1
  fi
}

elegir() {
  need_access || exit 1
  echo "1) En WhatsApp de escritorio, reproduce (o descarga) un audio del chat que quieres vigilar."
  read -r -p "2) Cuando lo hayas hecho, pulsa Enter… " _
  local f chat
  f="$(find "$MEDIA" -type f -name '*.opus' -mmin -3 2>/dev/null | while IFS= read -r p; do echo "$(mtime "$p") $p"; done | sort -rn | head -1 | cut -d' ' -f2-)"
  if [[ -z "$f" ]]; then
    echo "No vi ningún audio nuevo en los últimos 3 minutos. Reproduce uno y vuelve a intentarlo." >&2
    exit 1
  fi
  chat="${f#"$MEDIA"/}"; chat="${chat%%/*}"
  if grep -qxF -- "$chat" "$CHATS" 2>/dev/null; then echo "Ese chat ya estaba en la lista ($chat)."; return; fi
  echo "$chat" >>"$CHATS"
  echo "Listo: voy a vigilar ese chat ($chat). Se aplica la próxima vez que enciendas (make up / ícono)."
  echo "Para otro chat, repite el comando. Para dejar de vigilar: make whatsapp-off"
  echo "Para fijarlo en el fichero .env (y poder cambiarlo ahí): WHATSAPP_CHATS=$chat"
  [[ -n "${WHATSAPP_CHATS:-}" ]] && echo "Ojo: WHATSAPP_CHATS ya está definido en .env y manda sobre esta lista."
}

quitar() { rm -f "$CHATS" && echo "Dejé de vigilar WhatsApp."; }

estado() {
  if all_chats; then echo "Vigila: TODOS los chats"
  elif configured; then echo "Chats vigilados:"; chat_list | sed 's/^/  /'
  else echo "No hay chats elegidos (WHATSAPP_CHATS en .env, o make whatsapp)."; fi
  echo "Al encender incluye los audios de los últimos ${WHATSAPP_BACKLOG_MIN:-60} min"
  if alive; then echo "Estado: en marcha (pid $(cat "$PIDFILE"))"; else echo "Estado: apagado"; fi
}

# Copia un audio a la entrada con un nombre legible (fecha y hora), en dos pasos para que la app
# no lo tome a medias (los ficheros que empiezan por punto se ignoran).
deliver() { # origen mtime
  local name dst n=1
  name="WhatsApp $(stamp "$2")"
  dst="$INBOX/$name.opus"
  while [[ -e "$dst" || -e "$INBOX/procesados/$name.opus" ]]; do n=$((n + 1)); dst="$INBOX/$name ($n).opus"; done
  cp -p "$1" "$INBOX/.$name.part" && mv "$INBOX/.$name.part" "$dst" && echo "$(date '+%F %T') copiado: $dst"
}

vigilar() {
  need_access || exit 1
  configured || { echo "No hay chats elegidos. Pon WHATSAPP_CHATS en .env o usa: make whatsapp" >&2; exit 1; }
  mkdir -p "$INBOX"
  touch "$SEEN"
  local start=$(( $(date +%s) - ${WHATSAPP_BACKLOG_MIN:-60} * 60 )) dirs=() chat
  if all_chats; then
    echo "$(date '+%F %T') vigilando TODOS los chats → $INBOX"
  else
    echo "$(date '+%F %T') vigilando $(chat_list | wc -l | tr -d ' ') chat(s) → $INBOX"
  fi
  while :; do
    dirs=()
    if all_chats; then dirs=("$MEDIA"); else
      while IFS= read -r chat; do [[ -d "$MEDIA/$chat" ]] && dirs+=("$MEDIA/$chat"); done < <(chat_list)
    fi
    for dir in ${dirs[@]+"${dirs[@]}"}; do
      while IFS= read -r f; do
        local m s now; m="$(mtime "$f")"; s="$(size "$f")"; now="$(date +%s)"
        [[ -n "$m" && "${s:-0}" -gt 0 && "$m" -ge "$start" && $((now - m)) -ge 3 ]] || continue
        grep -qxF -- "$f" "$SEEN" && continue
        deliver "$f" "$m" && echo "$f" >>"$SEEN"
      done < <(find "$dir" -type f -name '*.opus' 2>/dev/null)
    done
    sleep "$POLL"
  done
}

start() {
  configured || return 0 # sin chats elegidos no hace nada
  alive && return 0
  need_access || { echo "WhatsApp: se omite la copia automática (falta permiso)." >&2; return 0; }
  nohup perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die "$!"' -- "$SELF" vigilar >>"$LOG" 2>&1 &
  echo $! >"$PIDFILE"
  echo "Copia automática de audios de WhatsApp activada (make whatsapp-off la desactiva)."
}

stop() {
  alive && kill "$(cat "$PIDFILE")" && echo "Copia de audios de WhatsApp detenida"
  rm -f "$PIDFILE"
}

case "${1:-}" in
  elegir) elegir ;;
  quitar) quitar ;;
  estado) estado ;;
  vigilar) vigilar ;;
  start) start ;;
  stop) stop ;;
  *) echo "Uso: $0 {elegir|quitar|estado|vigilar|start|stop}" >&2; exit 2 ;;
esac
