# Transcriptor de audios

Convierte los audios de WhatsApp en **texto y resúmenes**, para poder leerlos cuando no puedes escucharlos (por ejemplo, en clase).
Funciona **100 % en tu Mac, sin internet y sin gastar nada**: ningún audio sale de tu equipo.

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

## 2. Uso diario

Desde la carpeta del proyecto, en la Terminal:

```bash
make up      # levanta todo y abre http://localhost:4747
make down    # lo apaga todo y libera la memoria
```

> La primera vez que arranca, Metal (la GPU del Mac) tarda unos 15 s en preparar sus kernels. Es normal.
>
> La web queda en el puerto **4747** (poco usado, para no chocar con 8080 y similares). Si por algún motivo estuviera ocupado, `make up` te avisa y puedes elegir otro: `make up PORT=4748`.

### Sin Terminal: ícono con doble clic

Si no quieres abrir la Terminal ni escribir comandos, crea el ícono una sola vez:

```bash
make app
```

Aparece **Transcriptor** en el Escritorio y en Launchpad. Desde ahí:

- **Doble clic** (apagado): abre Docker Desktop si hace falta, enciende todo y abre la web.
- **Doble clic** (encendido): pregunta **Abrir** o **Apagar** (apagar libera toda la memoria).

No queda nada consumiendo mientras no lo uses: solo está encendido cuando tú lo enciendes. `make app-off` borra el ícono. Registro: `~/.transcriptor/launcher.log`.

### Arranque automático (opcional)

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

En `~/TranscriptorAudios/sessions/<fecha>-<id>/` (puedes verlo desde el Finder):

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

Registros: `make logs` (la app) y `~/.transcriptor/whisper.log`, `~/.transcriptor/ollama.log` (Whisper y Ollama).

## 4. Comandos

| Comando | Qué hace |
|---|---|
| `make setup` | Instala y descarga todo lo necesario (una vez) |
| `make up` / `make down` | Levanta / apaga todo |
| `make app` / `make app-off` | Crea / borra el ícono «Transcriptor» (doble clic para encender o apagar, sin Terminal) |
| `make autostart` / `make autostart-off` | Activa / desactiva el arranque automático al iniciar sesión |
| `make status` | Estado de Whisper, Ollama y la app |
| `make logs` | Registros de la app (Ctrl+C para salir) |
| `make doctor` | Diagnóstico + prueba real con voz generada: transcripción, resúmenes, **3 subidas simultáneas**, detección de audios repetidos y rendimiento |
| `make stress` | Procesa ~4 min de voz y mide CPU, memoria y **si macOS limita la CPU por calor** (`pmset`, sin sudo) |
| `make bench FILE=audio.opus` | Mide tiempo, CPU y memoria con un audio tuyo |
| `make purge` | Borra todas las sesiones (pide confirmación) |
| `make test` | Tests del backend y compilación de la web |
| `make dev` | Desarrollo sin Docker (API en :4747, web con recarga en :5173) |

## 5. Que el Mac no se caliente

Por defecto ya hace esto:

- **Un solo trabajo de IA a la vez**: cada audio se transcribe y se resume enseguida, uno tras otro. Nunca hay dos en paralelo, aunque subas muchos.
- Whisper corre con **prioridad baja** (`nice`) y 4 hilos, y usa la GPU.
- Ollama descarga el modelo de la memoria **60 s después** de resumir.
- Los audios muy cortos no se resumen, y el resumen general solo se recalcula si cambió el contenido.

Si notas calor o ventiladores, mídelo con `make stress` y ajusta:

```bash
make up WHISPER_THREADS=2          # menos hilos para Whisper
make up OLLAMA_MODEL=qwen2.5:3b    # resumen más ligero (algo peor)
```

## 6. Configuración

Variables que acepta `make` (y el `docker-compose.yml`):

| Variable | Por defecto | Qué es |
|---|---|---|
| `PORT` | `4747` | Puerto de la web |
| `DATA_PATH` | `~/TranscriptorAudios` | Dónde se guardan las sesiones |
| `OLLAMA_MODEL` | `qwen2.5:7b` | Modelo de resumen |
| `WHISPER_THREADS` | `4` | Hilos de Whisper |
| `WHISPER_FLAGS` | `-fa` | Flags extra de `whisper-server` (`-fa` = flash attention) |
| `RETENTION_DAYS` | `1` | Días sin actividad hasta el borrado automático (`0` = nunca) |

Avanzado (variables de la app): `WHISPER_LANG` (`es`), `WHISPER_PROMPT` (vocabulario inicial para el spanglish), `OLLAMA_KEEP_ALIVE` (`60s`), `OLLAMA_NUM_CTX` (`12288`), `MAX_UPLOAD_MB` (`1024`), `ALLOWED_HOSTS` (`localhost,127.0.0.1,::1`; protege contra ataques de *DNS rebinding*).

**Spanglish:** Whisper se fuerza a español con un prompt que incluye términos en inglés frecuentes (*deadline, meeting, commit…*), porque con detección automática un audio mezclado podría saltar a inglés a mitad de frase. Si tus audios usan otros términos, añádelos a `WHISPER_PROMPT`.

---

## Cómo funciona

```
Navegador ──► Docker: app (API en Go + web en React) ──► Whisper (whisper.cpp, Metal)  ← nativo
                              │                      └──► Ollama + qwen2.5:7b (Metal)   ← nativo
                              └──► ~/TranscriptorAudios  (audios, textos, resúmenes)
```

- **Whisper y Ollama van fuera de Docker** porque Docker en macOS corre en una máquina virtual Linux que **no puede usar la GPU de Apple**. Nativos usan Metal: son mucho más rápidos y calientan menos.
- **Go en el backend:** el trabajo pesado lo hacen `whisper.cpp` y Ollama (C/C++); la app solo coordina, y Go da un binario estático que en reposo usa unos pocos MB.
- El contenedor corre con el sistema de ficheros en **solo lectura**, sin privilegios, con límite de 512 MB y 1 CPU, y **solo es accesible desde tu Mac** (`127.0.0.1`).

```
backend/   API en Go (solo biblioteca estándar): sesiones, cola, clientes de Whisper/Ollama, SSE, borrado automático
web/       React + Vite + TypeScript (CSS propio; diseño estilo Windows 95, en web/src/styles/win95.css)
scripts/   launcher.sh + make-app.sh (ícono de doble clic), services.sh (Whisper y Ollama nativos), doctor.sh, stress.sh, bench.sh
Dockerfile, docker-compose.yml, Makefile
PRODUCT.md contexto de producto y diseño
```

## Estado de verificación

- **Probado en un Mac real** (Apple M4 Max, 36 GB): `make doctor` completo con Whisper en GPU (Metal) y Ollama reales; 3 subidas simultáneas con resumen por audio y resumen general (9 s para 3 audios largos); detección de audios repetidos; 2 audios cortos en ~4 s con un pico de ~6 GB de memoria; y uso real con 8 audios.
- **Tests automáticos:** backend con detector de carreras (subidas simultáneas, reemplazo y duplicados, reintentos, apagado a mitad de un audio, borrado automático); interfaz verificada en navegador (escritorio, móvil, errores) con auditoría de accesibilidad sin violaciones.
- **Sin medir objetivamente:** la temperatura sostenida con audios muy largos. Para eso está `make stress`.
