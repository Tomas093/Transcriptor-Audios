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
# Necesita que el programa que lo ejecuta (Terminal, o la app Transcriptor) tenga "Acceso total
# al disco" en Ajustes del Sistema → Privacidad y seguridad. Solo toma audios que lleguen
# DESPUÉS de encenderlo (WHATSAPP_BACKLOG_MIN=30 para incluir los de los últimos 30 min).
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
STATE_DIR="${TRANSCRIPTOR_HOME:-$HOME/.transcriptor}"
MEDIA="${WHATSAPP_MEDIA:-$HOME/Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media}"
INBOX="${INBOX_PATH:-${DATA_PATH:-$HOME/TranscriptorAudios}/entrada}"
CHATS="$STATE_DIR/whatsapp-chats"
SEEN="$STATE_DIR/whatsapp-seen"
PIDFILE="$STATE_DIR/whatsapp.pid"
LOG="$STATE_DIR/whatsapp.log"
POLL="${WHATSAPP_POLL:-3}"
mkdir -p "$STATE_DIR"

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
}

quitar() { rm -f "$CHATS" && echo "Dejé de vigilar WhatsApp."; }

estado() {
  if [[ -s "$CHATS" ]]; then echo "Chats vigilados:"; sed 's/^/  /' "$CHATS"; else echo "No hay chats elegidos (make whatsapp)."; fi
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
  [[ -s "$CHATS" ]] || { echo "No hay chats elegidos. Usa: make whatsapp" >&2; exit 1; }
  mkdir -p "$INBOX"
  touch "$SEEN"
  local start=$(( $(date +%s) - ${WHATSAPP_BACKLOG_MIN:-0} * 60 ))
  echo "$(date '+%F %T') vigilando $(wc -l <"$CHATS" | tr -d ' ') chat(s) → $INBOX"
  while :; do
    while IFS= read -r chat; do
      [[ -n "$chat" && -d "$MEDIA/$chat" ]] || continue
      while IFS= read -r f; do
        local m s now; m="$(mtime "$f")"; s="$(size "$f")"; now="$(date +%s)"
        [[ -n "$m" && "${s:-0}" -gt 0 && "$m" -ge "$start" && $((now - m)) -ge 3 ]] || continue
        grep -qxF -- "$f" "$SEEN" && continue
        deliver "$f" "$m" && echo "$f" >>"$SEEN"
      done < <(find "$MEDIA/$chat" -type f -name '*.opus' 2>/dev/null)
    done <"$CHATS"
    sleep "$POLL"
  done
}

start() {
  [[ -s "$CHATS" ]] || return 0 # sin chats elegidos no hace nada
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
