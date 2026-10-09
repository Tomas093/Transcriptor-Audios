# Transcriptor de audios

Transcribe los audios de WhatsApp a texto, **todo en tu Mac o PC con Windows y sin gastar nada**, para poder leerlos cuando no puedes escucharlos (en clase, por ejemplo). Soporta español y spanglish.

- **Texto de cada audio** + **resumen de cada audio** + **resumen general** de todos los audios de la sesión, como si fueran una sola conversación.
- Subes varios audios a la vez: se ordenan por nombre (WhatsApp los numera por fecha) y se procesan de uno en uno.
- Sesiones tipo chat, con barra lateral. Cada sesión es una carpeta en tu disco.
- Borrado manual (botón *Eliminar*) y **borrado automático a los 7 días** sin actividad.
- Nada sale de tu equipo: Whisper y el modelo de resumen corren en local.

## Arquitectura

```
Navegador ──► Docker: app (API en Go + web en React) ──► Whisper (whisper.cpp)   ← nativo (Metal / CUDA)
                              │                      └──► Ollama + qwen2.5:7b     ← nativo (Metal / CUDA)
                              └──► ~/TranscriptorAudios  (sesiones: audios, textos, resúmenes)
```

- **¿Por qué Whisper y Ollama fuera de Docker?** Docker en macOS corre en una máquina virtual Linux que **no puede usar la GPU de Apple**. Nativos usan Metal: son varias veces más rápidos y calientan mucho menos que en CPU dentro de un contenedor. En Windows, nativos usan la GPU NVIDIA (CUDA) sin configurar nada en Docker ni en WSL; sin NVIDIA, la CPU (con BLAS).
- **¿Por qué Go y no Rust?** El trabajo pesado lo hacen `whisper.cpp` y Ollama (C/C++). La app solo orquesta: Go da un binario estático, unos pocos MB de RAM en reposo y una cola simple. Rust no daría una ventaja medible aquí.
- El contenedor corre con el sistema de ficheros en solo lectura, sin privilegios, límite de 512 MB y 1 CPU, y solo es accesible desde tu equipo (`127.0.0.1`).

## Requisitos

- **macOS:** Mac con Apple Silicon, [Homebrew](https://brew.sh) y [Docker Desktop](https://www.docker.com/products/docker-desktop).
- **Windows:** Windows 10/11 de 64 bits con [Docker Desktop](https://www.docker.com/products/docker-desktop) (WSL 2) y `winget` (viene con Windows 11). Con GPU NVIDIA va mucho más rápido; sin ella funciona en CPU.
- ~7 GB de disco (modelo de Whisper ~570 MB + `qwen2.5:7b` ~4,7 GB + imagen). En Windows con NVIDIA, +650 MB de whisper.cpp con CUDA.

## Uso

**macOS:**

```bash
make setup   # una sola vez: instala whisper-cpp y ollama, descarga los modelos
make up      # levanta todo y abre http://localhost:8080
make down    # lo baja todo y libera la memoria
```

**Windows** (PowerShell o CMD, en la carpeta del proyecto, con Docker Desktop abierto):

```powershell
.\transcriptor.cmd setup   # una sola vez: instala Ollama (winget), descarga whisper.cpp y los modelos
.\transcriptor.cmd up      # levanta todo y abre http://localhost:8080
.\transcriptor.cmd down    # lo baja todo y libera la memoria
```

`transcriptor.cmd` acepta los mismos comandos y variables que `make` (`.\transcriptor.cmd up WHISPER_THREADS=2`). Por debajo ejecuta `scripts\transcriptor.ps1` con Windows PowerShell, sin cambiar tu política de ejecución.

1. En WhatsApp, guarda los audios (en la versión de escritorio: clic derecho sobre el audio → *Guardar como…*).
2. Arrástralos a la ventana (o pulsa el botón). Puedes añadir más audios a la misma sesión más tarde. Si subes un audio que ya estaba (mismo contenido), se deja el ya procesado sin tocar; si subes uno con el mismo nombre pero contenido distinto, reemplaza al anterior en su sitio y se vuelve a procesar.
3. Lee el texto y el resumen. *Copiar todo* o *Descargar* (Markdown) para llevártelo.

Tus sesiones quedan en `~/TranscriptorAudios/sessions/<fecha>-<id>/` (en Windows, `%USERPROFILE%\TranscriptorAudios\sessions\…`):
`audio/` (originales), `texto/` (un `.txt` por audio con su resumen) y `resumen-general.txt`.

### Otros comandos

En Windows, cambia `make` por `.\transcriptor.cmd`.

| Comando | Qué hace |
|---|---|
| `make status` | Estado de Whisper, Ollama y la app |
| `make logs` | Logs de la app |
| `make doctor` | Diagnóstico completo y **prueba real** (genera voz con `say` en macOS o con la voz de Windows, la transcribe y resume, y mide tiempo/CPU/memoria, y GPU si es NVIDIA) |
| `make bench FILE=audio.opus` | Mide **tiempo, pico de CPU y memoria** procesando un audio tuyo |
| `make purge` | Borra todas las sesiones (pide confirmación) |
| `make test` | Tests del backend y compilación de la web |
| `make dev` | Desarrollo sin Docker (API :8080, web con recarga :5173; necesita Go, Node y `ffmpeg`) |

## Que no se caliente el equipo

Lo que ya hace el proyecto por defecto:

- **Un solo trabajo de IA a la vez**: cada audio se transcribe y se resume enseguida, uno tras otro, así el texto y el resumen van apareciendo en orden.
- **Cola secuencial**, nunca en paralelo.
- Whisper corre con **prioridad baja** (`nice` en macOS, *por debajo de lo normal* en Windows) y 4 hilos; Ollama descarga el modelo de la RAM **60 s después** de resumir.
- Audios muy cortos (< 20 palabras) no se resumen: no hace falta gastar el LLM.
- El resumen general se recalcula solo si cambió el contenido.

Si aun así notas calor o ruido de ventiladores, mide con `make bench` y ajusta:

```bash
make up WHISPER_THREADS=2            # menos hilos para Whisper
make up OLLAMA_MODEL=qwen2.5:3b      # resumen más ligero (peor calidad)
```

En Windows igual: `.\transcriptor.cmd up WHISPER_THREADS=2`.

## Configuración

Variables que aceptan `make` y `transcriptor.cmd` (y el `docker-compose.yml`): `PORT` (8080), `DATA_PATH` (`~/TranscriptorAudios`), `OLLAMA_MODEL` (`qwen2.5:7b`), `WHISPER_THREADS` (4), `RETENTION_DAYS` (7; `0` desactiva el borrado automático), `WHISPER_BIN` (ruta a tu propio `whisper-server`).

Solo en Windows: `WHISPER_GPU` (`auto`; `cuda` o `cpu` fuerzan qué compilación de whisper.cpp descarga `setup`, p. ej. `.\transcriptor.cmd setup WHISPER_GPU=cpu` la reemplaza). La zona horaria del contenedor se toma de Windows; si sale mal, pásala con `TZ=America/Argentina/Buenos_Aires`.

Variables del backend (avanzado): `WHISPER_LANG` (`es`), `WHISPER_PROMPT` (vocabulario inicial para el spanglish), `OLLAMA_KEEP_ALIVE` (`60s`), `OLLAMA_NUM_CTX` (12288), `MAX_UPLOAD_MB` (1024), `ALLOWED_HOSTS` (`localhost,127.0.0.1,::1`; rechaza otras cabeceras `Host` para evitar ataques de DNS rebinding).

**Spanglish:** Whisper se fuerza a español con un prompt inicial que incluye términos en inglés frecuentes (*deadline, meeting, commit…*). Con detección automática de idioma, un audio con mezcla podría cambiar a inglés a mitad de frase. Si tus audios usan otros términos recurrentes, añádelos en `WHISPER_PROMPT`.

## Si algo falla

- **Aviso amarillo "Whisper/Ollama no responde"** → `make up` (o `.\transcriptor.cmd up`).
- **"falta el modelo qwen2.5:7b"** → `ollama pull qwen2.5:7b`.
- **Un audio falló** → botón *Reintentar* en ese audio (el texto ya transcrito no se pierde si solo falló el resumen).
- Logs de los servicios nativos: `~/.transcriptor/whisper.log` y `~/.transcriptor/ollama.log` (en Windows, en `%USERPROFILE%\.transcriptor`, también `whisper.err.log` y `ollama.err.log`).
- **"El puerto 8080 ya lo usa otro programa"** (p. ej. Apache de XAMPP) → usa otro: `.\transcriptor.cmd up PORT=8090` (y lo mismo en `doctor`/`bench`).
- **Windows: "Docker Desktop no está en marcha"** → ábrelo y espera a *Engine running*.
- **Windows: whisper-server con CUDA no arranca** (driver de NVIDIA antiguo) → `setup` pasa solo a la versión para CPU; también puedes actualizar el driver o forzarla con `.\transcriptor.cmd setup WHISPER_GPU=cpu`.
- **Windows: `doctor` no comprueba el texto** → no tienes una voz de Windows en español (Configuración → Hora e idioma → Voz → Agregar voces).

## Estructura del proyecto

```
backend/   API en Go (solo biblioteca estándar): sesiones, cola, clientes de Whisper/Ollama, SSE, borrado automático
web/       React + Vite + TypeScript (CSS propio, sigue el tema claro/oscuro del sistema)
scripts/   services.sh (Whisper/Ollama nativos), bench.sh, doctor.sh · transcriptor.ps1 (lo mismo en Windows)
transcriptor.cmd  entrada para Windows (equivale al Makefile)
Dockerfile, docker-compose.yml, Makefile
PRODUCT.md contexto de producto y diseño
```

## Estado de verificación

Probado de punta a punta:

- **Backend** (Go): 14 tests con detector de carreras, repetidos sin fallos.
- **Contra el `whisper-server` real** (whisper.cpp 1.9.4, compilado desde el código fuente, en CPU y con un modelo de pruebas): el cliente, el formato de la petición (`/inference`, `language`, `prompt`, `carry_initial_prompt`, `response_format`) y los flags del script (`-m --host --port -t -fa`) funcionan; `scripts/services.sh` y `scripts/bench.sh` también.
- **Docker**: la imagen corre con sistema de ficheros de solo lectura y usuario sin privilegios; el flujo completo en navegador (claro, oscuro, móvil, errores y reintentos) sin errores y con auditoría de accesibilidad (axe) sin violaciones.

- **Windows, de punta a punta** (Windows 11, Ryzen 7 6800HS, 16 GB, RTX 3050 Laptop 4 GB, Docker Desktop 28, PowerShell 5.1): `setup` (Ollama por winget, whisper.cpp con CUDA, modelos), `up` y `doctor` con **RESULTADO: OK**. Whisper usa la GPU por CUDA; transcripción exacta de los audios de prueba, resúmenes por audio y general, 3 subidas simultáneas y detección de duplicados. Tiempos: 76 s para los 2 audios cortos con los modelos en frío (incluye cargar `qwen2.5:7b`) y 42 s para 3 audios largos en paralelo; picos de 71 % de CPU, 1,2 GB de RAM y la GPU al 99 % (3,8 GB de VRAM de 4).

**No se pudo verificar fuera de un Mac real:**

- La aceleración con Metal, los **tiempos y el consumo reales** (`make doctor` lo comprueba de una vez; `make bench FILE=audio.opus` mide con un audio tuyo) y la calidad de transcripción con `large-v3-turbo`.
- El resumen con Ollama + `qwen2.5:7b` (se probó contra un servidor que imita su API `/api/chat`).
- Que Homebrew instale el binario `whisper-server`. `make setup` lo comprueba y, si falta, te da los comandos para compilarlo (`WHISPER_BIN=…`).
