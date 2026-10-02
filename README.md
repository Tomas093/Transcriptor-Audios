# Transcriptor de audios

Transcribe los audios de WhatsApp a texto, **todo en tu Mac y sin gastar nada**, para poder leerlos cuando no puedes escucharlos (en clase, por ejemplo). Soporta español y spanglish.

- **Texto de cada audio** + **resumen de cada audio** + **resumen general** de todos los audios de la sesión, como si fueran una sola conversación.
- Subes varios audios a la vez: se ordenan por nombre (WhatsApp los numera por fecha) y se procesan de uno en uno.
- Sesiones tipo chat, con barra lateral. Cada sesión es una carpeta en tu disco.
- Borrado manual (botón *Eliminar*) y **borrado automático a los 7 días** sin actividad.
- Nada sale de tu equipo: Whisper y el modelo de resumen corren en local.

## Arquitectura

```
Navegador ──► Docker: app (API en Go + web en React) ──► Whisper (whisper.cpp, Metal)   ← nativo
                              │                      └──► Ollama + qwen2.5:7b (Metal)    ← nativo
                              └──► ~/TranscriptorAudios  (sesiones: audios, textos, resúmenes)
```

- **¿Por qué Whisper y Ollama fuera de Docker?** Docker en macOS corre en una máquina virtual Linux que **no puede usar la GPU de Apple**. Nativos usan Metal: son varias veces más rápidos y calientan mucho menos que en CPU dentro de un contenedor.
- **¿Por qué Go y no Rust?** El trabajo pesado lo hacen `whisper.cpp` y Ollama (C/C++). La app solo orquesta: Go da un binario estático, unos pocos MB de RAM en reposo y una cola simple. Rust no daría una ventaja medible aquí.
- El contenedor corre con el sistema de ficheros en solo lectura, sin privilegios, límite de 512 MB y 1 CPU, y solo es accesible desde tu Mac (`127.0.0.1`).

## Requisitos

- Mac con Apple Silicon, [Homebrew](https://brew.sh) y [Docker Desktop](https://www.docker.com/products/docker-desktop).
- ~7 GB de disco (modelo de Whisper ~570 MB + `qwen2.5:7b` ~4,7 GB + imagen).

## Uso

```bash
make setup   # una sola vez: instala whisper-cpp y ollama, descarga los modelos
make up      # levanta todo y abre http://localhost:8080
make down    # lo baja todo y libera la memoria
```

1. En WhatsApp, guarda los audios (en la versión de escritorio: clic derecho sobre el audio → *Guardar como…*).
2. Arrástralos a la ventana (o pulsa el botón). Puedes añadir más audios a la misma sesión más tarde.
3. Lee el texto y el resumen. *Copiar todo* o *Descargar* (Markdown) para llevártelo.

Tus sesiones quedan en `~/TranscriptorAudios/sessions/<fecha>-<id>/`:
`audio/` (originales), `texto/` (un `.txt` por audio con su resumen) y `resumen-general.txt`.

### Otros comandos

| Comando | Qué hace |
|---|---|
| `make status` | Estado de Whisper, Ollama y la app |
| `make logs` | Logs de la app |
| `make bench FILE=audio.opus` | Mide **tiempo, pico de CPU y memoria** procesando un audio tuyo |
| `make purge` | Borra todas las sesiones (pide confirmación) |
| `make test` | Tests del backend y compilación de la web |
| `make dev` | Desarrollo sin Docker (API :8080, web con recarga :5173) |

## Que no se caliente el Mac

Lo que ya hace el proyecto por defecto:

- **Un solo modelo a la vez**: primero se transcriben todos los audios de la tanda y después se resumen, sin alternar entre Whisper y el LLM.
- **Cola secuencial**, nunca en paralelo.
- Whisper corre con **prioridad baja** (`nice`) y 4 hilos; Ollama descarga el modelo de la RAM **30 s después** de resumir.
- Audios muy cortos (< 20 palabras) no se resumen: no hace falta gastar el LLM.
- El resumen general se recalcula solo si cambió el contenido.

Si aun así notas calor o ruido de ventiladores, mide con `make bench` y ajusta:

```bash
make up WHISPER_THREADS=2            # menos hilos para Whisper
make up OLLAMA_MODEL=qwen2.5:3b      # resumen más ligero (peor calidad)
```

## Configuración

Variables que acepta `make` (y el `docker-compose.yml`): `PORT` (8080), `DATA_PATH` (`~/TranscriptorAudios`), `OLLAMA_MODEL` (`qwen2.5:7b`), `WHISPER_THREADS` (4), `RETENTION_DAYS` (7; `0` desactiva el borrado automático).

Variables del backend (avanzado): `WHISPER_LANG` (`es`), `WHISPER_PROMPT` (vocabulario inicial para el spanglish), `OLLAMA_KEEP_ALIVE` (`30s`), `OLLAMA_NUM_CTX` (12288), `MAX_UPLOAD_MB` (1024).

**Spanglish:** Whisper se fuerza a español con un prompt inicial que incluye términos en inglés frecuentes (*deadline, meeting, commit…*). Con detección automática de idioma, un audio con mezcla podría cambiar a inglés a mitad de frase. Si tus audios usan otros términos recurrentes, añádelos en `WHISPER_PROMPT`.

## Si algo falla

- **Aviso amarillo "Whisper/Ollama no responde"** → `make up`.
- **"falta el modelo qwen2.5:7b"** → `ollama pull qwen2.5:7b`.
- **Un audio falló** → botón *Reintentar* en ese audio (el texto ya transcrito no se pierde si solo falló el resumen).
- Logs de los servicios nativos: `~/.transcriptor/whisper.log` y `~/.transcriptor/ollama.log`.

## Estructura del proyecto

```
backend/   API en Go (solo biblioteca estándar): sesiones, cola, clientes de Whisper/Ollama, SSE, borrado automático
web/       React + Vite + TypeScript (CSS propio, sigue el tema claro/oscuro del sistema)
scripts/   services.sh (Whisper/Ollama nativos), bench.sh
Dockerfile, docker-compose.yml, Makefile
PRODUCT.md contexto de producto y diseño
```

## Estado de verificación

Probado de punta a punta con **Whisper y Ollama simulados** (misma API que los reales): tests del backend con detector de carreras, imagen Docker (solo lectura, usuario sin privilegios), y el flujo completo en navegador en claro, oscuro y móvil, con auditoría de accesibilidad (axe) sin violaciones.

**No verificado todavía en un Mac real**: el arranque de `whisper-server` y Ollama con Metal, los tiempos y el consumo reales. Para eso está `make bench`. Detalles que se asumen del `whisper-server` de whisper.cpp: endpoint `POST /inference` con los campos `file`, `language`, `prompt`, `response_format` y `temperature`, y la fórmula de Homebrew `whisper-cpp`.
