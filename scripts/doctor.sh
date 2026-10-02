#!/usr/bin/env bash
# Diagnóstico y prueba real en tu Mac: comprueba la instalación y transcribe un audio de voz
# generado con `say` (voz de macOS). Imprime un informe que puedes pegar tal cual.
# Uso: make doctor   (con `make up` ya ejecutado)
set -uo pipefail

BASE="http://127.0.0.1:${PORT:-8080}"
STATE_DIR="${TRANSCRIPTOR_HOME:-$HOME/.transcriptor}"
MODEL_FILE="${WHISPER_MODEL_FILE:-ggml-large-v3-turbo-q5_0.bin}"
FAIL=0
ok()   { echo "  ✔ $*"; }
bad()  { echo "  ✘ $*"; FAIL=1; }
info() { echo "  · $*"; }

echo "== Sistema"
info "$(sw_vers -productName 2>/dev/null) $(sw_vers -productVersion 2>/dev/null) · $(uname -m) · $(sysctl -n machdep.cpu.brand_string 2>/dev/null) · $(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 )) GB RAM"

echo "== Instalación"
command -v docker >/dev/null && ok "docker" || bad "falta docker (Docker Desktop)"
command -v "${WHISPER_BIN:-whisper-server}" >/dev/null && ok "whisper-server ($(command -v "${WHISPER_BIN:-whisper-server}"))" || bad "falta whisper-server (make setup)"
[[ -f "$STATE_DIR/models/$MODEL_FILE" ]] && ok "modelo Whisper $MODEL_FILE" || bad "falta el modelo Whisper (make setup)"
command -v ollama >/dev/null && ok "ollama" || bad "falta ollama (make setup)"

echo "== Servicios"
HEALTH=$(curl -fsS -m 5 "$BASE/api/health" 2>/dev/null) || { bad "la app no responde en $BASE (make up)"; echo; echo "RESULTADO: FALLÓ"; exit 1; }
echo "$HEALTH" | grep -q '"whisper":{"ok":true' && ok "Whisper responde" || bad "Whisper no responde"
echo "$HEALTH" | grep -q '"modelReady":true' && ok "Ollama listo con el modelo" || bad "Ollama o su modelo no están listos"
if grep -qi "metal\|gpu" "$STATE_DIR/whisper.log" 2>/dev/null; then
  grep -i "metal\|gpu" "$STATE_DIR/whisper.log" | head -3 | sed 's/^/  · log: /'
fi

echo "== Prueba real"
if ! command -v say >/dev/null; then info "no hay 'say' (solo macOS): salta la prueba de voz. Usa: make bench FILE=tu-audio.opus"; echo; [[ $FAIL == 0 ]] && echo "RESULTADO: OK (sin prueba de voz)" || echo "RESULTADO: FALLÓ"; exit $FAIL; fi

TMP=$(mktemp -d); trap 'rm -rf "$TMP"; [[ -n "${ID:-}" ]] && curl -fsS -X DELETE "$BASE/api/sessions/$ID" >/dev/null 2>&1' EXIT
say -v Monica -o "$TMP/PTT-prueba-WA0001.aiff" "Hola, te escribo por lo del trabajo práctico de redes. El deadline es el viernes a las diez de la mañana y hay que subir el paper al campus." 2>/dev/null \
  || say -o "$TMP/PTT-prueba-WA0001.aiff" "Hola, te escribo por lo del trabajo práctico de redes. El deadline es el viernes a las diez de la mañana y hay que subir el paper al campus."
say -v Monica -o "$TMP/PTT-prueba-WA0002.aiff" "Quedamos el jueves a las cuatro en la biblioteca para repasar el quiz de la unidad tres." 2>/dev/null \
  || say -o "$TMP/PTT-prueba-WA0002.aiff" "Quedamos el jueves a las cuatro en la biblioteca para repasar el quiz de la unidad tres."

ID=$(curl -fsS -X POST "$BASE/api/sessions" -H 'Content-Type: application/json' -d '{"title":"doctor"}' | sed -E 's/.*"id":"([^"]+)".*/\1/')
START=$(date +%s)
curl -fsS -F "files=@$TMP/PTT-prueba-WA0001.aiff" -F "files=@$TMP/PTT-prueba-WA0002.aiff" "$BASE/api/sessions/$ID/audios" >/dev/null || { bad "no se pudo subir"; exit 1; }

PEAK_CPU=0; PEAK_RSS=0; N=0
while [[ $N -lt 300 ]]; do
  read -r CPU RSS < <(ps -axo pcpu,rss,comm | awk '/whisper-server|ollama/ {c+=$1; r+=$2} END {printf "%.0f %.0f\n", c, r/1024}')
  [[ ${CPU:-0} -gt $PEAK_CPU ]] && PEAK_CPU=$CPU
  [[ ${RSS:-0} -gt $PEAK_RSS ]] && PEAK_RSS=$RSS
  curl -fsS "$BASE/api/sessions" | grep -o "\"id\":\"$ID\"[^}]*\"busy\":[a-z]*" | grep -q '"busy":false' && break
  sleep 1; N=$((N + 1))
done
ELAPSED=$(( $(date +%s) - START ))
SESSION=$(curl -fsS "$BASE/api/sessions/$ID")

echo "$SESSION" | grep -q '"status":"error"' && bad "algún audio falló:" && echo "$SESSION" | grep -o '"error":"[^"]*"' | sed 's/^/    /'
TEXTS=$(echo "$SESSION" | grep -o '"text":"[^"]*"' | head -3)
echo "$TEXTS" | grep -qi "deadline\|viernes\|biblioteca" && ok "transcripción coherente con lo dicho" || bad "la transcripción no coincide con lo dicho"
echo "$TEXTS" | sed 's/^/    /' | cut -c1-200
echo "$SESSION" | grep -q '"global":{"status":"done"' && ok "resumen general generado" || bad "no se generó el resumen general"

echo "== Rendimiento (2 audios de voz cortos)"
info "tiempo total: ${ELAPSED}s · pico de CPU: ${PEAK_CPU}% · pico de memoria: ${PEAK_RSS} MB"
info "regla práctica: si ${ELAPSED}s es mucho para estos 2 audios, prueba WHISPER_THREADS=2 o OLLAMA_MODEL=qwen2.5:3b"

echo; [[ $FAIL == 0 ]] && echo "RESULTADO: OK" || echo "RESULTADO: FALLÓ"
exit $FAIL
