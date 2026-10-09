ifeq ($(OS),Windows_NT)
$(error En Windows usa transcriptor.cmd en lugar de make (por ejemplo: .\transcriptor.cmd up))
endif
SHELL := /bin/bash
.DEFAULT_GOAL := help

# --- Configuración (se puede cambiar: make up OLLAMA_MODEL=qwen2.5:3b) ---
PORT            ?= 4747
DATA_PATH       ?= $(HOME)/TranscriptorAudios
INBOX_PATH      ?= $(DATA_PATH)/entrada
OLLAMA_MODEL    ?= qwen2.5:7b
WHISPER_MODEL_FILE ?= ggml-large-v3.bin
WHISPER_THREADS ?= 4
RETENTION_DAYS  ?= 1
STATE_DIR       ?= $(HOME)/.transcriptor
MODEL_URL       := https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$(WHISPER_MODEL_FILE)

TZ_DETECT := $(shell readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')
export TZ ?= $(if $(TZ_DETECT),$(TZ_DETECT),UTC)
export HOST_UID := $(shell id -u)
export HOST_GID := $(shell id -g)
export PORT DATA_PATH INBOX_PATH OLLAMA_MODEL WHISPER_MODEL_FILE WHISPER_THREADS RETENTION_DAYS WHISPER_BIN WHISPER_FLAGS

help: ## Muestra esta ayuda
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  \033[1mmake %-8s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

setup: ## Instala y descarga todo lo necesario (una sola vez)
	@command -v brew >/dev/null || { echo "Instala Homebrew primero: https://brew.sh"; exit 1; }
	@command -v docker >/dev/null || { echo "Instala Docker Desktop primero: https://www.docker.com/products/docker-desktop"; exit 1; }
	brew list whisper-cpp >/dev/null 2>&1 || brew install whisper-cpp
	@command -v "$${WHISPER_BIN:-whisper-server}" >/dev/null || { \
	  echo; echo "Homebrew no instaló el binario 'whisper-server'. Compílalo (Metal viene activado en Mac):"; \
	  echo "  git clone https://github.com/ggml-org/whisper.cpp && cd whisper.cpp"; \
	  echo "  cmake -B build && cmake --build build -j --config Release --target whisper-server"; \
	  echo "y vuelve a ejecutar: make setup WHISPER_BIN=\$$PWD/build/bin/whisper-server"; exit 1; }
	brew list ollama >/dev/null 2>&1 || brew install ollama
	mkdir -p "$(STATE_DIR)/models" "$(DATA_PATH)"
	@if [ -f "$(STATE_DIR)/models/$(WHISPER_MODEL_FILE)" ]; then echo "Modelo de Whisper ya descargado"; \
	else echo "Descargando modelo de Whisper (~570 MB)…"; \
	curl -L --fail --progress-bar -C - -o "$(STATE_DIR)/models/$(WHISPER_MODEL_FILE)" "$(MODEL_URL)"; fi
	./scripts/services.sh start
	ollama pull $(OLLAMA_MODEL)
	./scripts/services.sh stop
	@echo; echo "Listo. Arranca con: make up"

up: check-port ## Levanta todo (Whisper + Ollama nativos y la app en Docker)
	mkdir -p "$(DATA_PATH)" "$(INBOX_PATH)"
	./scripts/services.sh start
	docker compose up -d --build
	@echo; echo "Transcriptor listo en http://localhost:$(PORT)   (tus sesiones: $(DATA_PATH))"; echo "Carpeta de entrada: $(INBOX_PATH)   (todo audio que sueltes ahí se procesa solo; make entrada la abre)"
	@if [ -z "$(NO_OPEN)" ] && command -v open >/dev/null; then open "http://localhost:$(PORT)"; fi

check-port:
	@if lsof -nP -iTCP:$(PORT) -sTCP:LISTEN >/dev/null 2>&1 && ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx transcriptor; then \
	  echo "El puerto $(PORT) ya está en uso por otra aplicación. Elige otro, por ejemplo: make up PORT=4748"; exit 1; fi

entrada: ## Abre la carpeta de entrada (los audios que sueltes ahí se procesan solos)
	mkdir -p "$(INBOX_PATH)" && open "$(INBOX_PATH)"

whatsapp: ## Elige un chat de WhatsApp de escritorio para copiar sus audios a la entrada (macOS)
	./scripts/whatsapp.sh elegir

whatsapp-off: ## Deja de copiar audios de WhatsApp
	./scripts/whatsapp.sh quitar

app: ## Crea el ícono «Transcriptor» (Escritorio y Launchpad): doble clic para encender/apagar, sin Terminal
	PORT=$(PORT) ICON=$(ICON) ./scripts/make-app.sh install

app-off: ## Borra el ícono «Transcriptor»
	./scripts/make-app.sh uninstall

autostart: ## Arranca todo solo al iniciar sesión en el Mac (make autostart-off lo desactiva)
	PORT=$(PORT) DATA_PATH="$(DATA_PATH)" OLLAMA_MODEL=$(OLLAMA_MODEL) WHISPER_THREADS=$(WHISPER_THREADS) RETENTION_DAYS=$(RETENTION_DAYS) ./scripts/autostart.sh install

autostart-off: ## Desactiva el arranque automático
	./scripts/autostart.sh uninstall

down: ## Baja todo y libera la memoria
	docker compose down
	./scripts/services.sh stop

status: ## Estado de los servicios
	@./scripts/services.sh status
	@docker compose ps --format 'app: {{.State}} ({{.Status}})' 2>/dev/null || true

logs: ## Logs de la app (Ctrl+C para salir)
	docker compose logs -f --tail=100 app

doctor: ## Diagnóstico + prueba real con voz generada (pega la salida si algo falla)
	./scripts/doctor.sh

stress: ## Prueba de carga y temperatura con ~4 min de voz (¿limita macOS la CPU por calor?)
	./scripts/stress.sh

bench: ## Mide tiempo y consumo con un audio tuyo: make bench FILE=audio.opus
	./scripts/bench.sh "$(FILE)"

purge: ## Borra TODAS las sesiones guardadas (pide confirmación)
	@read -p "¿Borrar todo el contenido de $(DATA_PATH)? [s/N] " a; \
	if [ "$$a" = "s" ]; then rm -rf "$(DATA_PATH)/sessions" && echo "Borrado."; else echo "Cancelado."; fi

test: ## Tests del backend y chequeo de tipos de la web
	cd backend && go vet ./... && go test -race ./...
	cd web && npm ci --no-audit --no-fund && npm run build

dev: ## Desarrollo local sin Docker (API en :$(PORT), web con recarga en :5173)
	@trap 'kill 0' EXIT; \
	(cd web && npm install --no-audit --no-fund && npm run dev) & \
	(cd backend && DATA_DIR="$(DATA_PATH)" INBOX_DIR="$(INBOX_PATH)" WEB_DIR=../web/dist TMP_DIR=/tmp/transcriptor \
	  WHISPER_URL=http://127.0.0.1:8178 OLLAMA_URL=http://127.0.0.1:11434 ADDR=127.0.0.1:$(PORT) go run .) & \
	wait

.PHONY: help setup up check-port entrada whatsapp whatsapp-off app app-off autostart autostart-off down status logs doctor stress bench purge test dev
