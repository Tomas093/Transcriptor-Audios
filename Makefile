SHELL := /bin/bash
.DEFAULT_GOAL := help

# --- Configuración (se puede cambiar: make up OLLAMA_MODEL=qwen2.5:3b) ---
PORT            ?= 8080
DATA_PATH       ?= $(HOME)/TranscriptorAudios
OLLAMA_MODEL    ?= qwen2.5:7b
WHISPER_MODEL_FILE ?= ggml-large-v3-turbo-q5_0.bin
WHISPER_THREADS ?= 4
RETENTION_DAYS  ?= 7
STATE_DIR       ?= $(HOME)/.transcriptor
MODEL_URL       := https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$(WHISPER_MODEL_FILE)

TZ_DETECT := $(shell readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')
export TZ ?= $(if $(TZ_DETECT),$(TZ_DETECT),UTC)
export HOST_UID := $(shell id -u)
export HOST_GID := $(shell id -g)
export PORT DATA_PATH OLLAMA_MODEL WHISPER_MODEL_FILE WHISPER_THREADS RETENTION_DAYS

help: ## Muestra esta ayuda
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  \033[1mmake %-8s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

setup: ## Instala y descarga todo lo necesario (una sola vez)
	@command -v brew >/dev/null || { echo "Instala Homebrew primero: https://brew.sh"; exit 1; }
	@command -v docker >/dev/null || { echo "Instala Docker Desktop primero: https://www.docker.com/products/docker-desktop"; exit 1; }
	brew list whisper-cpp >/dev/null 2>&1 || brew install whisper-cpp
	brew list ollama >/dev/null 2>&1 || brew install ollama
	mkdir -p "$(STATE_DIR)/models" "$(DATA_PATH)"
	@if [ -f "$(STATE_DIR)/models/$(WHISPER_MODEL_FILE)" ]; then echo "Modelo de Whisper ya descargado"; \
	else echo "Descargando modelo de Whisper (~570 MB)…"; \
	curl -L --fail --progress-bar -C - -o "$(STATE_DIR)/models/$(WHISPER_MODEL_FILE)" "$(MODEL_URL)"; fi
	./scripts/services.sh start
	ollama pull $(OLLAMA_MODEL)
	./scripts/services.sh stop
	@echo; echo "Listo. Arranca con: make up"

up: ## Levanta todo (Whisper + Ollama nativos y la app en Docker)
	mkdir -p "$(DATA_PATH)"
	./scripts/services.sh start
	docker compose up -d --build
	@echo; echo "Transcriptor listo en http://localhost:$(PORT)   (tus sesiones: $(DATA_PATH))"
	@command -v open >/dev/null && open "http://localhost:$(PORT)" || true

down: ## Baja todo y libera la memoria
	docker compose down
	./scripts/services.sh stop

status: ## Estado de los servicios
	@./scripts/services.sh status
	@docker compose ps --format 'app: {{.State}} ({{.Status}})' 2>/dev/null || true

logs: ## Logs de la app (Ctrl+C para salir)
	docker compose logs -f --tail=100 app

bench: ## Mide tiempo y consumo con un audio tuyo: make bench FILE=audio.opus
	./scripts/bench.sh "$(FILE)"

purge: ## Borra TODAS las sesiones guardadas (pide confirmación)
	@read -p "¿Borrar todo el contenido de $(DATA_PATH)? [s/N] " a; \
	if [ "$$a" = "s" ]; then rm -rf "$(DATA_PATH)/sessions" && echo "Borrado."; else echo "Cancelado."; fi

test: ## Tests del backend y chequeo de tipos de la web
	cd backend && go vet ./... && go test -race ./...
	cd web && npm ci --no-audit --no-fund && npm run build

dev: ## Desarrollo local sin Docker (API en :8080, web con recarga en :5173)
	@trap 'kill 0' EXIT; \
	(cd web && npm install --no-audit --no-fund && npm run dev) & \
	(cd backend && DATA_DIR="$(DATA_PATH)" WEB_DIR=../web/dist TMP_DIR=/tmp/transcriptor \
	  WHISPER_URL=http://127.0.0.1:8178 OLLAMA_URL=http://127.0.0.1:11434 ADDR=127.0.0.1:8080 go run .) & \
	wait

.PHONY: help setup up down status logs bench purge test dev
