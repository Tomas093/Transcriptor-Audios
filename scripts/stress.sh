#!/usr/bin/env bash
# Prueba de carga y temperatura: genera ~4 min de voz con `say`, la procesa de punta a punta
# y mide si macOS limita la CPU por calor (pmset -g therm, sin sudo), además de CPU y memoria.
# Uso: make stress   (con `make up` ya ejecutado)
set -uo pipefail

BASE="http://127.0.0.1:${PORT:-8080}"
PARRAFOS="${STRESS_PARRAFOS:-14}"   # ~4 min de voz con 14 párrafos
curl -fsS -m 5 "$BASE/api/health" >/dev/null 2>&1 || { echo "La app no responde en $BASE. Ejecuta: make up" >&2; exit 1; }
command -v say >/dev/null || { echo "Hace falta 'say' (solo macOS)." >&2; exit 1; }

TMP=$(mktemp -d); ID=""
trap 'rm -rf "$TMP"; [[ -n "$ID" ]] && curl -fsS -X DELETE "$BASE/api/sessions/$ID" >/dev/null 2>&1' EXIT

P="Mirá, te resumo cómo viene el proyecto de la facultad. El lunes entregamos el avance de la base de datos, el martes hay una reunión con el profesor para revisar el deadline y el feedback del último commit, y el jueves tenemos el parcial de redes con los temas de TCP, UDP y enrutamiento. Además hay que preparar la presentación con slides y subir el paper al campus antes del viernes a las diez de la mañana."
TEXT=""; for ((i = 0; i < PARRAFOS; i++)); do TEXT="$TEXT $P"; done

echo "== Generando ~$((PARRAFOS * 17 / 60 + 1)) min de voz con 'say'…"
say -v Monica -o "$TMP/largo.aiff" "$TEXT" 2>/dev/null || say -o "$TMP/largo.aiff" "$TEXT"

therm_limit() { pmset -g therm 2>/dev/null | awk '/CPU_Speed_Limit/ {print $NF}' | head -1; }
HAS_PMSET=0; command -v pmset >/dev/null && HAS_PMSET=1
MIN_LIMIT=100; MAX_CPU=0; SUM_CPU=0; N=0; PEAK_RSS=0

ID=$(curl -fsS -X POST "$BASE/api/sessions" -H 'Content-Type: application/json' -d '{"title":"stress"}' | sed -E 's/.*"id":"([^"]+)".*/\1/')
START=$(date +%s)
curl -fsS -F "files=@$TMP/largo.aiff" "$BASE/api/sessions/$ID/audios" >/dev/null || { echo "No se pudo subir." >&2; exit 1; }
echo "== Procesando… (muestreo cada 2 s)"

while [[ $N -lt 900 ]]; do
  read -r CPU RSS < <(ps -axo pcpu,rss,comm | awk '/whisper-server|ollama/ {c+=$1; r+=$2} END {printf "%.0f %.0f\n", c, r/1024}')
  [[ ${CPU:-0} -gt $MAX_CPU ]] && MAX_CPU=$CPU
  [[ ${RSS:-0} -gt $PEAK_RSS ]] && PEAK_RSS=$RSS
  SUM_CPU=$((SUM_CPU + ${CPU:-0})); N=$((N + 1))
  if [[ $HAS_PMSET == 1 ]]; then
    L=$(therm_limit); [[ -n "$L" && "$L" -lt "$MIN_LIMIT" ]] && MIN_LIMIT=$L
  fi
  curl -fsS "$BASE/api/sessions" | grep -o "\"id\":\"$ID\"[^}]*\"busy\":[a-z]*" | grep -q '"busy":false' && break
  sleep 2
done
ELAPSED=$(( $(date +%s) - START ))
SESSION=$(curl -fsS "$BASE/api/sessions/$ID")
DUR=$(echo "$SESSION" | grep -o '"durationSec":[0-9.]*' | head -1 | cut -d: -f2)
OKTXT=$(echo "$SESSION" | grep -c '"status":"done"')
echo "$SESSION" | grep -q '"status":"error"' && echo "  ✘ el audio falló: $(echo "$SESSION" | grep -o '"error":"[^"]*"' | head -1)"
[[ "$OKTXT" -ge 1 ]] && echo "  ✔ transcripción y resumen completados"

echo; echo "== Resultado"
echo "  · audio: ${DUR:-?} s de voz · procesado en ${ELAPSED}s"
[[ -n "${DUR:-}" ]] && awk -v d="$DUR" -v e="$ELAPSED" 'BEGIN { if (e > 0) printf "  · velocidad: %.1fx tiempo real (más de 1x = más rápido que escuchar)\n", d / e }'
echo "  · CPU: pico ${MAX_CPU}% · media $((SUM_CPU / (N > 0 ? N : 1)))% (suma de procesos; 100% = un núcleo)"
echo "  · memoria pico: ${PEAK_RSS} MB"
if [[ $HAS_PMSET == 1 ]]; then
  if [[ $MIN_LIMIT -lt 100 ]]; then
    echo "  ⚠ macOS LIMITÓ la CPU por calor (mínimo ${MIN_LIMIT}% de velocidad). Prueba: make up WHISPER_THREADS=2"
  else
    echo "  ✔ sin limitación térmica: macOS no redujo la velocidad de la CPU en ningún momento"
  fi
else
  echo "  · (no hay pmset: no se pudo medir la limitación térmica)"
fi
echo "  · ventiladores: no se pueden medir sin sudo; ¿los oíste? Si sí, avísame y ajustamos."
