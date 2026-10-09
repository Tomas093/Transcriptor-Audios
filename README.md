# Transcriptor de audios

Convierte los audios de WhatsApp en **texto y resúmenes**, para poder leerlos cuando no puedes escucharlos (por ejemplo, en clase).
Funciona **100 % en tu Mac o PC con Windows, sin internet y sin gastar nada**: ningún audio sale de tu equipo.

Qué obtienes al soltar uno o varios audios:

- El **texto** de cada audio (español y *spanglish*).
- Un **resumen de cada audio**.
- Un **resumen general** de todos los audios de la sesión, como si fueran una sola conversación.

---

## 1. Instalación (una sola vez)

**Necesitas:** un Mac con chip Apple Silicon (M1 o posterior), unos 7 GB libres en disco y estas dos aplicaciones instaladas:

- [Homebrew](https://brew.sh)
- [Docker Desktop](https://www.docker.com/products/docker-desktop), **abierto** (ícono de la ballena en la barra superior).

Abre la **Terminal** y ejecuta:

```bash
git clone https://github.com/Tomas093/Transcriptor-Audios.git
cd Transcriptor-Audios
git checkout claude/exciting-knuth-1qnu23    # la rama con la versión final
make setup
```

`make setup` instala Whisper y Ollama, y descarga los modelos (~5 GB). Tarda un rato la primera vez. Si Homebrew no instala `whisper-server`, el propio comando te dice cómo compilarlo.

### En Windows

**Necesitas:** Windows 10/11 de 64 bits, [Docker Desktop](https://www.docker.com/products/docker-desktop) **abierto** y `winget` (viene con Windows 11). Con una GPU NVIDIA va mucho más rápido; sin ella funciona en CPU.

En PowerShell o CMD, dentro de la carpeta del proyecto:

```powershell
.\transcriptor.cmd setup
```

Instala Ollama con winget y descarga whisper.cpp (la versión con CUDA si tienes NVIDIA, ~650 MB; si no, la de CPU) y los modelos. Todos los comandos de esta guía funcionan igual cambiando `make` por `.\transcriptor.cmd`, también con variables: `.\transcriptor.cmd up WHISPER_THREADS=2`. Por debajo ejecuta `scripts\transcriptor.ps1` con Windows PowerShell, sin tocar tu política de ejecución.

> Con una GPU de 4 GB o menos (p. ej. una RTX 3050 de portátil), Whisper `large-v3` y `qwen2.5:7b` no caben juntos en la VRAM. Va más fluido con el modelo turbo: `.\transcriptor.cmd setup WHISPER_MODEL_FILE=ggml-large-v3-turbo-q5_0.bin` y luego `up` con la misma variable.

## 2. Uso diario

Desde la carpeta del proyecto, en la Terminal:

```bash
make up      # levanta todo y abre http://localhost:4747
make down    # lo apaga todo y libera la memoria
```

En Windows: `.\transcriptor.cmd up` y `.\transcriptor.cmd down`.

> La primera vez que arranca, Metal (la GPU del Mac) tarda unos 15 s en preparar sus kernels. Es normal.
>
> La web queda en el puerto **4747** (poco usado, para no chocar con 8080 y similares). Si por algún motivo estuviera ocupado, `make up` te avisa y puedes elegir otro: `make up PORT=4748`.

### Sin Terminal: ícono con doble clic (macOS)

Si no quieres abrir la Terminal ni escribir comandos, crea el ícono una sola vez:

```bash
make app
```

Aparece **Transcriptor** en el Escritorio y en Launchpad. Desde ahí:

- **Doble clic** (apagado): abre Docker Desktop si hace falta, enciende todo y abre la web.
- **Doble clic** (encendido): pregunta **Abrir** o **Apagar** (apagar libera toda la memoria).

No queda nada consumiendo mientras no lo uses: solo está encendido cuando tú lo enciendes. `make app-off` borra el ícono. Para usar otra imagen: `make app ICON=/ruta/a/mi-imagen.png` (PNG cuadrado, mejor de 1024×1024). Si el ícono no cambia al instante, reinicia el Dock: `killall Dock`. Registro: `~/.transcriptor/launcher.log`.

### Arranque automático (opcional, macOS)

`make up` levanta todo junto: Whisper, Ollama y el contenedor. Si no quieres ni siquiera ejecutarlo, activa el arranque automático:

```bash
make autostart       # desde ahora, todo se levanta solo al iniciar sesión en el Mac
make autostart-off   # lo desactiva
```

Al iniciar sesión abre Docker Desktop si hace falta, espera a que esté listo y ejecuta `make up` sin abrir el navegador; entra a `http://localhost:4747` cuando quieras. Registro: `~/.transcriptor/autostart.log`. Ten en cuenta que Whisper queda cargado en memoria (~1,5 GB) mientras el Mac esté encendido; Ollama descarga su modelo solo a los 60 s. Si cambias el puerto o el modelo, vuelve a ejecutar `make autostart PORT=…` para que lo recuerde.

**Paso a paso:**

1. **Guarda los audios desde WhatsApp.** En WhatsApp de escritorio: clic derecho sobre el audio → *Guardar como…* (te queda un `.opus`).
2. **Arrástralos a la ventana** (o pulsa el botón de subida). Puedes soltar varios a la vez; se ordenan por nombre, que en WhatsApp sigue la fecha.
3. **Lee.** Cada audio aparece como una ventana, con su texto y su resumen, en orden. Si subiste varios, arriba aparece el **resumen general**.
4. Usa **Copiar texto / Copiar resumen / Copiar todo** o **Descargar** (Markdown) para llevarte lo que necesites.

### Carpeta de entrada (sin abrir la web)

Al encender, se crea la carpeta `~/TranscriptorAudios/entrada` (la abres con `make entrada`; en Windows, `%USERPROFILE%\TranscriptorAudios\entrada` y `.\transcriptor.cmd entrada`). **Todo audio que dejes ahí se procesa solo**, sin tener que abrir la web ni arrastrar nada:

- Guarda los audios de WhatsApp directamente ahí (clic derecho → *Guardar como…* → carpeta `entrada`), o cámbiale al navegador la carpeta de descargas.
- Los audios que llegan con menos de 10 minutos de diferencia se agrupan en **una sola sesión** ("Entrada 05/10 19:30"), con su resumen general. Pasados 10 minutos se crea una sesión nueva.
- Cuando termina de copiarlos, mueve los originales a `entrada/procesados/`. Si quieres, bórralos de ahí cuando quieras: ya están dentro de la sesión.
- Si algo cae mientras la app está apagada, se procesa en cuanto la enciendas.
- Un audio idéntico a uno ya procesado en esa sesión no se repite. Los archivos que no son audio se ignoran, y un archivo que aún se está descargando espera a terminar.

#### Sin guardar nada a mano: audios de WhatsApp de escritorio (macOS, opcional)

WhatsApp de escritorio ya deja en tu disco los audios que recibes o reproduces. El Transcriptor puede **copiarlos solo a `entrada`** (y de ahí se procesan solos). No se conecta a WhatsApp ni a tu cuenta: solo copia los ficheros `.opus` de esa carpeta (no abre sus bases de datos), así que no hay riesgo para tu número.

Todo se configura **desde la web**: botón **Configuración** (abajo a la izquierda).

1. **Permiso (una vez):** Ajustes del Sistema → Privacidad y seguridad → **Acceso total al disco** → activa **Terminal** (y **Transcriptor**, si enciendes con el ícono). macOS protege los datos de WhatsApp y sin esto la web mostrará un aviso con el permiso que falta.
2. **Qué copiar:** *Todos los chats*, o *Solo estos chats* (por ejemplo, el chat contigo mismo al que reenvías los audios que quieras procesar; WhatsApp permite reenviar varios a la vez). Para añadir un chat: **Detectar chat**, reproduce un audio de ese chat en WhatsApp y pulsa **Añadir**.
3. **Hacia atrás:** al encender, también procesa los audios de los últimos N minutos (60 por defecto; 0 = solo los nuevos). Los más viejos se ignoran.

Los audios se copian con nombre por fecha y hora. Solo se copian los que WhatsApp **ya guardó en el disco** (los descargados solos o al reproducirlos). Es una carpeta interna de WhatsApp: si una actualización cambia dónde guarda los audios, dejará de copiarlos y el resto sigue funcionando.

##### Que escuche en segundo plano y se encienda solo

Con `make up` el vigilante funciona mientras todo está encendido. Si quieres que **escuche siempre** y encienda todo **solo cuando llegue un audio**:

```bash
make agente        # una sola vez
```

y en **Configuración → Segundo plano** activa *Escuchar en segundo plano*. Entonces:

- Un vigilante muy liviano arranca al iniciar sesión y mira la carpeta cada 15 s (prioridad mínima, sin GPU, unos pocos MB). **Con todo apagado, eso es lo único que consume**; compruébalo en el Monitor de Actividad (proceso `bash`, `whatsapp.sh agent`).
- Cuando llega un audio nuevo: copia el audio, enciende Docker, Whisper y Ollama, se procesa y aparece la sesión. Tarda entre 30 s y 1-2 min en estar listo (arrancar Docker y cargar el modelo).
- Tras **N minutos sin actividad** (10 por defecto, configurable) apaga todo y libera la memoria. Opcional: cerrar también Docker Desktop (solo si lo abrió él y no hay otros contenedores en marcha).
- Si enciendes tú (`make up` o el ícono), el agente no lo apaga: solo apaga lo que él encendió.
- El agente necesita *Acceso total al disco* para `/bin/bash` (`make agente` te dice cómo). Es un permiso amplio, porque lo usa bash: si no lo quieres, no instales el agente; `make up`, el ícono y la carpeta `entrada` funcionan sin él.
- `make whatsapp-estado` muestra qué vigila; `make agente-off` lo quita. Registro: `~/.transcriptor/whatsapp.log`.

### Sesiones

La barra lateral lista tus sesiones, como un chat. Cada vez que sueltas audios en "Nueva sesión" se crea una; puedes **seguir añadiendo audios** a una sesión existente.

- **Renombrar:** haz clic en el título de arriba.
- **Eliminar:** el **tacho** al lado de cada sesión en la barra lateral (aparece al pasar el cursor; te pide confirmar). También está el botón *Eliminar* arriba, dentro de la sesión. Borra la sesión y sus audios del disco.
- **Borrado automático:** las sesiones se borran solas a **1 día (24 h) sin actividad**. La barra lateral avisa cuando a una le quedan menos de 6 horas.

**¿Cómo sabe cuándo pasó el día?** Cada sesión guarda en su `session.json` la fecha y hora de su **última actividad** (cuando se procesó o modificó algo; abrirla para leerla no la renueva). El borrado no usa un contador: compara esa fecha con la hora actual. Lo hace **al arrancar** (`make up`) y **cada 10 minutos** mientras está encendida. Por eso, si apagas todo y vuelves días después, al hacer `make up` se borra de inmediato todo lo que ya pasó el plazo; mientras está apagado no se borra nada.

### Audios repetidos

- Si subes **el mismo audio** (mismo contenido, aunque cambie el nombre), se deja el que ya estaba procesado: no se duplica ni se vuelve a procesar.
- Si subes uno con **el mismo nombre pero otro contenido**, reemplaza al anterior en su sitio y se procesa de nuevo.
- Un audio que había fallado y subes otra vez, se reintenta.

### Dónde quedan tus archivos

En `~/TranscriptorAudios/sessions/<fecha>-<id>/` (puedes verlo desde el Finder; en Windows, `%USERPROFILE%\TranscriptorAudios\sessions\…`):

```
audio/                 los audios originales
texto/                 un .txt por audio: transcripción + resumen
resumen-general.txt    el resumen de toda la sesión
```

---

## 3. Si algo falla

| Qué ves | Qué hacer |
|---|---|
| Aviso amarillo "Whisper no responde" u "Ollama no responde" | Ejecuta `make up` |
| "falta el modelo qwen2.5:7b" | `ollama pull qwen2.5:7b` |
| Un audio quedó en error | Botón **Reintentar** en ese audio. Si solo falló el resumen, el texto no se pierde |
| Un audio no muestra resumen | Si tiene menos de ~20 palabras se omite a propósito (se lee de un vistazo) |
| La app no abre | Comprueba que Docker Desktop esté abierto y ejecuta `make status` |
| No sabes qué pasa | `make doctor` hace un diagnóstico completo y una prueba real; pega su salida si necesitas ayuda |
| Windows: "El puerto … ya lo usa otro programa" (p. ej. Apache de XAMPP) | Usa otro: `.\transcriptor.cmd up PORT=4748` (y el mismo `PORT=` en `doctor`/`bench`) |
| Windows: "Docker Desktop no está en marcha" | Ábrelo y espera a *Engine running* |
| Windows: whisper-server con CUDA no arranca (driver de NVIDIA antiguo) | `setup` pasa solo a la versión para CPU; o actualiza el driver, o fuérzala con `.\transcriptor.cmd setup WHISPER_GPU=cpu` |
| Windows: `doctor` no comprueba el texto | Falta una voz de Windows en español: Configuración → Hora e idioma → Voz → Agregar voces |

Registros: `make logs` (la app) y `~/.transcriptor/whisper.log`, `~/.transcriptor/ollama.log` (Whisper y Ollama). En Windows, en `%USERPROFILE%\.transcriptor`, también `whisper.err.log` y `ollama.err.log`.

## 4. Comandos

En Windows, cambia `make` por `.\transcriptor.cmd` (salvo `app`, `autostart` y `stress`, que son solo de macOS).

| Comando | Qué hace |
|---|---|
| `make setup` | Instala y descarga todo lo necesario (una vez) |
| `make up` / `make down` | Levanta / apaga todo |
| `make entrada` | Abre la carpeta de entrada |
| `make agente` / `make agente-off` | Instala / quita el vigilante en segundo plano que enciende todo cuando llega un audio de WhatsApp (macOS; se configura en la web) |
| `make whatsapp-estado` | Muestra qué audios de WhatsApp vigila y si tiene permiso |
| `make app` / `make app-off` | Crea / borra el ícono «Transcriptor» (doble clic para encender o apagar, sin Terminal) |
| `make autostart` / `make autostart-off` | Activa / desactiva el arranque automático al iniciar sesión |
| `make status` | Estado de Whisper, Ollama y la app |
| `make logs` | Registros de la app (Ctrl+C para salir) |
| `make doctor` | Diagnóstico + prueba real con voz generada (`say` en macOS, la voz de Windows en Windows): transcripción, resúmenes, **3 subidas simultáneas**, detección de audios repetidos y rendimiento (y GPU si es NVIDIA) |
| `make stress` | Procesa ~4 min de voz y mide CPU, memoria y **si macOS limita la CPU por calor** (`pmset`, sin sudo) |
| `make bench FILE=audio.opus` | Mide tiempo, CPU y memoria con un audio tuyo |
| `make purge` | Borra todas las sesiones (pide confirmación) |
| `make test` | Tests del backend y compilación de la web |
| `make dev` | Desarrollo sin Docker (API en :4747, web con recarga en :5173) |

## 5. Que el equipo no se caliente

Por defecto ya hace esto:

- **Un solo trabajo de IA a la vez**: cada audio se transcribe y se resume enseguida, uno tras otro. Nunca hay dos en paralelo, aunque subas muchos.
- Whisper corre con **prioridad baja** (`nice` en macOS, *por debajo de lo normal* en Windows) y 4 hilos, y usa la GPU.
- Ollama descarga el modelo de la memoria **60 s después** de resumir.
- Los audios muy cortos no se resumen, y el resumen general solo se recalcula si cambió el contenido.

Si notas calor o ventiladores, mídelo con `make stress` y ajusta:

```bash
make up WHISPER_THREADS=2          # menos hilos para Whisper
make up OLLAMA_MODEL=qwen2.5:3b    # resumen más ligero (algo peor)
make setup up WHISPER_MODEL_FILE=ggml-large-v3-turbo-q5_0.bin   # Whisper más rápido y liviano (algo menos preciso)
```

## 6. Configuración

Variables que aceptan `make` y `transcriptor.cmd` (y el `docker-compose.yml`). Para dejarlas fijas, ponlas en un fichero `.env` (`cp .env.example .env`); lo que escribas en la línea de comandos manda sobre él:

| Variable | Por defecto | Qué es |
|---|---|---|
| `PORT` | `4747` | Puerto de la web |
| `DATA_PATH` | `~/TranscriptorAudios` | Dónde se guardan las sesiones |
| `INBOX_PATH` | `~/TranscriptorAudios/entrada` | Carpeta de entrada vigilada |
| `OLLAMA_MODEL` | `qwen2.5:7b` | Modelo de resumen |
| `WHISPER_MODEL_FILE` | `ggml-large-v3.bin` | Modelo de Whisper (el más preciso, ~3 GB). Más rápido y liviano: `ggml-large-v3-turbo-q5_0.bin` |
| `WHISPER_THREADS` | `4` | Hilos de Whisper |
| `WHISPER_FLAGS` | `-fa` | Flags extra de `whisper-server` (`-fa` = flash attention) |
| `RETENTION_DAYS` | `1` | Días sin actividad hasta el borrado automático (`0` = nunca) |
| `WHISPER_BIN` | — | Ruta a tu propio `whisper-server` |
| `WHISPER_GPU` | `auto` | Solo Windows: `cuda` o `cpu` fuerzan qué compilación de whisper.cpp descarga `setup` (la reemplaza si ya había otra) |
| `TZ` | la del sistema | Zona horaria del contenedor (en Windows se convierte sola; si sale mal: `TZ=America/Argentina/Buenos_Aires`) |

Avanzado (variables de la app): `WHISPER_LANG` (`es`), `WHISPER_PROMPT` (vocabulario inicial para el spanglish), `OLLAMA_KEEP_ALIVE` (`60s`), `OLLAMA_NUM_CTX` (`12288`), `MAX_UPLOAD_MB` (`1024`), `ALLOWED_HOSTS` (`localhost,127.0.0.1,::1`; protege contra ataques de *DNS rebinding*).

**Spanglish:** Whisper se fuerza a español con un prompt que incluye términos en inglés frecuentes (*deadline, meeting, commit…*), porque con detección automática un audio mezclado podría saltar a inglés a mitad de frase. Si tus audios usan otros términos, añádelos a `WHISPER_PROMPT`.

---

## Cómo funciona

```
Navegador ──► Docker: app (API en Go + web en React) ──► Whisper (whisper.cpp)   ← nativo (Metal / CUDA)
                              │                      └──► Ollama + qwen2.5:7b     ← nativo (Metal / CUDA)
                              └──► ~/TranscriptorAudios  (audios, textos, resúmenes)
```

- **Whisper y Ollama van fuera de Docker** porque Docker en macOS corre en una máquina virtual Linux que **no puede usar la GPU de Apple**. Nativos usan Metal: son mucho más rápidos y calientan menos. En Windows, nativos usan la GPU NVIDIA (CUDA) sin configurar nada en Docker ni en WSL; sin NVIDIA, la CPU.
- **Go en el backend:** el trabajo pesado lo hacen `whisper.cpp` y Ollama (C/C++); la app solo coordina, y Go da un binario estático que en reposo usa unos pocos MB.
- El contenedor corre con el sistema de ficheros en **solo lectura**, sin privilegios, con límite de 512 MB y 1 CPU, y **solo es accesible desde tu equipo** (`127.0.0.1`).

```
backend/   API en Go (solo biblioteca estándar): sesiones, cola, clientes de Whisper/Ollama, SSE, borrado automático
web/       React + Vite + TypeScript (CSS propio; diseño estilo Windows 95, en web/src/styles/win95.css)
scripts/   whatsapp.sh + agent.sh (copia de audios de WhatsApp y agente en segundo plano), launcher.sh + make-app.sh (ícono de doble clic), services.sh (Whisper y Ollama nativos), doctor.sh, stress.sh, bench.sh
           transcriptor.ps1: lo mismo en Windows (setup, up/down, doctor, bench…); se usa con transcriptor.cmd
Dockerfile, docker-compose.yml, Makefile
PRODUCT.md contexto de producto y diseño
```

## Estado de verificación

- **Probado en un Mac real** (Apple M4 Max, 36 GB): `make doctor` completo con Whisper en GPU (Metal) y Ollama reales; 3 subidas simultáneas con resumen por audio y resumen general (9 s para 3 audios largos); detección de audios repetidos; 2 audios cortos en ~4 s con un pico de ~6 GB de memoria; y uso real con 8 audios.
- **Probado en Windows** (Windows 11, Ryzen 7 6800HS, 16 GB, RTX 3050 Laptop 4 GB, Docker Desktop 28): `setup`, `up` y `doctor` completos con **RESULTADO: OK**, con Whisper en GPU (CUDA) y Ollama reales: transcripción exacta, resúmenes por audio y general, 3 subidas simultáneas (42 s) y detección de repetidos; 2 audios cortos en 76 s en frío (incluye cargar `qwen2.5:7b`), GPU al 99 % y 3,8 GB de VRAM. Se midió con el modelo turbo, antes de que `large-v3` pasara a ser el modelo por defecto.
- **Tests automáticos:** backend con detector de carreras (subidas simultáneas, reemplazo y duplicados, reintentos, apagado a mitad de un audio, borrado automático); interfaz verificada en navegador (escritorio, móvil, errores) con auditoría de accesibilidad sin violaciones.
- **Sin medir objetivamente:** la temperatura sostenida con audios muy largos. Para eso está `make stress`.
