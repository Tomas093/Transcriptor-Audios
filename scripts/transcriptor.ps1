# Transcriptor en Windows: hace lo mismo que el Makefile (que es para macOS).
# Whisper (whisper.cpp) y Ollama corren nativos en Windows (con la GPU si hay una NVIDIA) y la app en Docker Desktop.
# Uso: .\transcriptor.cmd <comando> [VARIABLE=valor ...]
#   .\transcriptor.cmd up WHISPER_THREADS=2      .\transcriptor.cmd bench FILE=audio.opus
param(
  [string]$Command = 'help',
  [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue' # la barra de progreso de PowerShell 5.1 hace lentas las descargas
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# VARIABLE=valor como en make; el resto son argumentos sueltos (p. ej. el audio de bench).
$Positional = @()
foreach ($a in $Rest) {
  if ($a -match '^([A-Za-z_][A-Za-z0-9_]*)=(.*)$') { Set-Item "env:$($Matches[1])" $Matches[2] } else { $Positional += $a }
}

function Cfg([string]$name, $def) {
  $v = [Environment]::GetEnvironmentVariable($name)
  if ($v) { return $v } else { return $def }
}

# --- Configuración (mismos nombres y valores por defecto que en macOS) ---
$Root         = Split-Path -Parent $PSScriptRoot
$Port         = Cfg 'PORT' '4747'
$DataPath     = Cfg 'DATA_PATH' (Join-Path $env:USERPROFILE 'TranscriptorAudios')
$InboxPath    = Cfg 'INBOX_PATH' (Join-Path $DataPath 'entrada')   # carpeta vigilada
$StateDir     = Cfg 'TRANSCRIPTOR_HOME' (Join-Path $env:USERPROFILE '.transcriptor')
$OllamaModel  = Cfg 'OLLAMA_MODEL' 'qwen2.5:7b'
$ModelFile    = Cfg 'WHISPER_MODEL_FILE' 'ggml-large-v3.bin'
$Threads      = Cfg 'WHISPER_THREADS' '4'
$Retention    = Cfg 'RETENTION_DAYS' '1'
$WhisperFlags = Cfg 'WHISPER_FLAGS' '-fa'   # -fa: flash attention (menos cómputo)
$WhisperGpu   = Cfg 'WHISPER_GPU' 'auto'    # auto | cuda | cpu: qué compilación de whisper.cpp descargar
$WhisperPort  = Cfg 'WHISPER_PORT' '8178'
$OllamaPort   = Cfg 'OLLAMA_PORT' '11434'
$Model        = Join-Path $StateDir "models\$ModelFile"
$WhisperDir   = Join-Path $StateDir 'whisper'
$ModelUrl     = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$ModelFile"
$WhisperUrl   = "http://127.0.0.1:$WhisperPort/"
$OllamaUrl    = "http://127.0.0.1:$OllamaPort/api/tags"
$Base         = "http://127.0.0.1:$Port"
New-Item -ItemType Directory -Force $StateDir | Out-Null

function Fail([string]$msg) { Write-Host $msg -ForegroundColor Red; exit 1 }
function Has([string]$cmd) { [bool](Get-Command $cmd -ErrorAction SilentlyContinue) }
# Ejecuta un comando nativo sin mostrar su salida (PowerShell 5.1 convierte el stderr redirigido en errores).
function Quiet([string]$cmdline) { cmd /c "$cmdline >nul 2>&1"; return ($LASTEXITCODE -eq 0) }
function Check([string]$what) { if ($LASTEXITCODE -ne 0) { Fail "$what falló (código $LASTEXITCODE)" } }

function Up([string]$url) {
  try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 $url | Out-Null; return $true } catch { return $false }
}
function WaitFor([string]$url, [int]$seconds, $proc) {
  for ($i = 0; $i -lt $seconds; $i++) {
    if (Up $url) { return $true }
    if ($proc -and $proc.HasExited) { return $false }
    Start-Sleep 1
  }
  return $false
}

function WhisperBin {
  if ($env:WHISPER_BIN) { return $env:WHISPER_BIN }
  $f = Get-ChildItem $WhisperDir -Recurse -Filter 'whisper-server.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($f) { return $f.FullName }
  $c = Get-Command 'whisper-server' -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  return $null
}
function WhisperFlavor {
  $f = Join-Path $WhisperDir 'flavor.txt'
  if (Test-Path $f) { return (Get-Content $f -TotalCount 1) } else { return '' }
}
function OllamaExe {
  $c = Get-Command 'ollama' -ErrorAction SilentlyContinue
  if ($c) { return $c.Source }
  $p = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe' # instalación por defecto, antes de reabrir la terminal
  if (Test-Path $p) { return $p }
  return $null
}
function HasNvidia { Has 'nvidia-smi' }

function DockerReady {
  if (-not (Has 'docker')) { Fail 'Instala Docker Desktop primero: https://www.docker.com/products/docker-desktop' }
  if (-not (Quiet 'docker info')) { Fail 'Docker Desktop no está en marcha: ábrelo, espera a que diga "Engine running" y vuelve a intentarlo.' }
}

# Zona horaria IANA para el contenedor (nombres de carpeta y horas de las sesiones).
function IanaTz {
  if ($env:TZ) { return $env:TZ }
  $tz = [TimeZoneInfo]::Local
  $iana = $null
  if ([TimeZoneInfo].GetMethod('TryConvertWindowsIdToIanaId', [type[]]@([string], [string].MakeByRefType()))) {
    if ([TimeZoneInfo]::TryConvertWindowsIdToIanaId($tz.Id, [ref]$iana)) { return $iana } # PowerShell 7
  }
  $map = @{
    'Argentina Standard Time' = 'America/Argentina/Buenos_Aires'; 'Montevideo Standard Time' = 'America/Montevideo'
    'Pacific SA Standard Time' = 'America/Santiago'; 'Paraguay Standard Time' = 'America/Asuncion'
    'E. South America Standard Time' = 'America/Sao_Paulo'; 'SA Western Standard Time' = 'America/La_Paz'
    'SA Pacific Standard Time' = 'America/Bogota'; 'Venezuela Standard Time' = 'America/Caracas'
    'Central Standard Time (Mexico)' = 'America/Mexico_City'; 'Central America Standard Time' = 'America/Guatemala'
    'Eastern Standard Time' = 'America/New_York'; 'Central Standard Time' = 'America/Chicago'
    'Mountain Standard Time' = 'America/Denver'; 'Pacific Standard Time' = 'America/Los_Angeles'
    'Romance Standard Time' = 'Europe/Madrid'; 'W. Europe Standard Time' = 'Europe/Berlin'
    'GMT Standard Time' = 'Europe/London'; 'UTC' = 'UTC'
  }
  if ($map.ContainsKey($tz.Id)) { return $map[$tz.Id] }
  $off = $tz.GetUtcOffset((Get-Date))
  if ($off.Minutes -eq 0) { # Etc/GMT tiene el signo invertido: UTC-3 es Etc/GMT+3 (sin horario de verano)
    if ($off.Hours -le 0) { return "Etc/GMT+$(-$off.Hours)" } else { return "Etc/GMT-$($off.Hours)" }
  }
  return 'UTC'
}

function ComposeEnv {
  $env:PORT = $Port; $env:DATA_PATH = $DataPath; $env:INBOX_PATH = $InboxPath; $env:OLLAMA_MODEL = $OllamaModel; $env:RETENTION_DAYS = $Retention
  $env:WHISPER_PORT = $WhisperPort; $env:OLLAMA_PORT = $OllamaPort; $env:TZ = IanaTz
}
function Compose {
  ComposeEnv
  Push-Location $Root
  try { & docker compose @args } finally { Pop-Location }
}

# --- Servicios nativos ---

function Install-Whisper([string]$gpu) {
  if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { $gpu = 'arm64'; $pattern = '^whisper-bin-win-cpu-arm64\.zip$' }
  elseif ($gpu -eq 'cuda') { $pattern = '^whisper-(bin-win-cuda-12[\d.]*-x64|cublas-12[\d.]*-bin-x64)\.zip$' }
  else { $pattern = '^whisper-blas-bin-x64\.zip$' }
  Write-Host "Buscando whisper.cpp para Windows ($gpu)…"
  $releases = Invoke-RestMethod -UseBasicParsing -Headers @{ 'User-Agent' = 'transcriptor' } 'https://api.github.com/repos/ggml-org/whisper.cpp/releases?per_page=15'
  $asset = $null; $tag = ''
  foreach ($r in $releases) {
    $asset = $r.assets | Where-Object { $_.name -match $pattern } | Select-Object -First 1
    if ($asset) { $tag = $r.tag_name; break }
  }
  if (-not $asset) { Fail "No encontré un binario de whisper.cpp para Windows ($pattern). Descárgalo de https://github.com/ggml-org/whisper.cpp/releases y usa WHISPER_BIN=ruta\whisper-server.exe" }
  $zip = Join-Path $StateDir 'whisper.zip'
  Write-Host "Descargando $($asset.name) ($tag, $([math]::Round($asset.size / 1MB)) MB)…"
  curl.exe -L --fail --progress-bar -o $zip $asset.browser_download_url; Check 'La descarga de whisper.cpp'
  if (Test-Path $WhisperDir) { Remove-Item -Recurse -Force $WhisperDir }
  Expand-Archive -Path $zip -DestinationPath $WhisperDir
  Remove-Item $zip
  Set-Content (Join-Path $WhisperDir 'flavor.txt') @($gpu, "$tag $($asset.name)")
  if (-not (WhisperBin)) { Fail "El zip $($asset.name) no trae whisper-server.exe. Compílalo (https://github.com/ggml-org/whisper.cpp) y usa WHISPER_BIN=ruta\whisper-server.exe" }
}

function Start-Whisper {
  if (Up $WhisperUrl) { Write-Host 'whisper-server ya está en marcha'; return $true }
  $bin = WhisperBin
  if (-not $bin) { Fail 'Falta whisper-server. Ejecuta: .\transcriptor.cmd setup' }
  if (-not (Test-Path $Model)) { Fail "Falta el modelo $Model. Ejecuta: .\transcriptor.cmd setup" }
  Write-Host "Arrancando whisper-server (modelo $ModelFile)…"
  $argline = "-m `"$Model`" --host 127.0.0.1 --port $WhisperPort -t $Threads $WhisperFlags"
  # Ventana oculta con su propia consola: sigue vivo aunque cierres esta terminal.
  $p = Start-Process -FilePath $bin -ArgumentList $argline -WorkingDirectory (Split-Path $bin) -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $StateDir 'whisper.log') -RedirectStandardError (Join-Path $StateDir 'whisper.err.log')
  try { $p.PriorityClass = 'BelowNormal' } catch {} # prioridad baja: el PC sigue fluido mientras transcribe
  Set-Content (Join-Path $StateDir 'whisper.pid') $p.Id
  if (WaitFor $WhisperUrl 90 $p) { return $true }
  Write-Host "whisper-server no arrancó; últimas líneas de $StateDir\whisper.err.log:" -ForegroundColor Red
  Get-Content (Join-Path $StateDir 'whisper.err.log') -Tail 8 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $_" }
  Stop-Pid 'whisper' | Out-Null
  return $false
}

function Start-Ollama {
  if (Up $OllamaUrl) { Write-Host 'Ollama ya está en marcha'; return }
  $exe = OllamaExe
  if (-not $exe) { Fail 'Falta Ollama. Ejecuta: .\transcriptor.cmd setup' }
  Write-Host 'Arrancando Ollama…'
  # Un solo modelo en memoria, sin paralelismo y descarga rápida cuando no se usa.
  $env:OLLAMA_KEEP_ALIVE = '30s'; $env:OLLAMA_MAX_LOADED_MODELS = '1'; $env:OLLAMA_NUM_PARALLEL = '1'
  $p = Start-Process -FilePath $exe -ArgumentList 'serve' -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $StateDir 'ollama.log') -RedirectStandardError (Join-Path $StateDir 'ollama.err.log')
  Set-Content (Join-Path $StateDir 'ollama.pid') $p.Id
  if (-not (WaitFor $OllamaUrl 30 $p)) { Fail "Ollama no arrancó; mira $StateDir\ollama.err.log" }
}

# Para el proceso que arrancamos (y sus hijos, p. ej. el runner de Ollama) si sigue siendo el nuestro.
function Stop-Pid([string]$name) {
  $f = Join-Path $StateDir "$name.pid"
  $stopped = $false
  if (Test-Path $f) {
    $id = [int](Get-Content $f -TotalCount 1)
    $p = Get-Process -Id $id -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -match $name) { $stopped = Quiet "taskkill /PID $id /T /F" }
    Remove-Item $f -Force
  }
  return $stopped
}

function Stop-Services {
  if (Stop-Pid 'whisper') { Write-Host 'whisper-server detenido' }
  if (Stop-Pid 'ollama') { Write-Host 'Ollama detenido' }
  elseif ((Up $OllamaUrl) -and (OllamaExe)) {
    # Ya estaba en marcha (la app de Ollama de la bandeja): solo sacamos el modelo de la memoria.
    Quiet "`"$(OllamaExe)`" stop $OllamaModel" | Out-Null
    Write-Host 'Modelo descargado de la memoria (Ollama sigue activo porque no lo arrancó este proyecto)'
  }
}

function Show-Status {
  if (Up $WhisperUrl) { Write-Host 'whisper-server: listo' } else { Write-Host 'whisper-server: parado' }
  if (Up $OllamaUrl) { Write-Host 'ollama:         listo' } else { Write-Host 'ollama:         parado' }
}

# --- Medición (doctor y bench): CPU (100% = un núcleo), memoria y GPU de whisper-server + ollama ---

$script:PrevCpu = @{}; $script:PrevT = $null
$script:Peak = @{ cpu = 0; rss = 0; gpu = 0; vram = 0 }
function Sample {
  $now = Get-Date; $delta = 0.0; $rss = 0; $seen = @{}
  foreach ($p in (Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(whisper-server|ollama)' })) {
    try { $c = $p.TotalProcessorTime.TotalSeconds } catch { continue }
    if ($script:PrevCpu.ContainsKey($p.Id)) { $delta += $c - $script:PrevCpu[$p.Id] }
    $seen[$p.Id] = $c; $rss += $p.WorkingSet64
  }
  if ($script:PrevT) {
    $cpu = [int]($delta / ($now - $script:PrevT).TotalSeconds * 100)
    if ($cpu -gt $script:Peak.cpu) { $script:Peak.cpu = $cpu }
  }
  $script:PrevCpu = $seen; $script:PrevT = $now
  $mb = [int]($rss / 1MB); if ($mb -gt $script:Peak.rss) { $script:Peak.rss = $mb }
  if (HasNvidia) {
    $g = (nvidia-smi --query-gpu=utilization.gpu,memory.used --format=csv,noheader,nounits | Select-Object -First 1) -split ',\s*'
    if ($g.Count -ge 2) {
      if ([int]$g[0] -gt $script:Peak.gpu) { $script:Peak.gpu = [int]$g[0] }
      if ([int]$g[1] -gt $script:Peak.vram) { $script:Peak.vram = [int]$g[1] }
    }
  }
}
function PeakText {
  $t = "pico de CPU: $($script:Peak.cpu)% · pico de memoria: $($script:Peak.rss) MB"
  if (HasNvidia) { $t += " · pico de GPU: $($script:Peak.gpu)% ($($script:Peak.vram) MB de VRAM en total)" }
  return $t
}

function Api([string]$method, [string]$path, $body) {
  if ($body) { return Invoke-RestMethod -UseBasicParsing -Method $method -ContentType 'application/json' -Body ($body | ConvertTo-Json) "$Base$path" }
  return Invoke-RestMethod -UseBasicParsing -Method $method "$Base$path"
}
function Upload([string]$id, [string[]]$files) {
  $form = @(); foreach ($f in $files) { $form += '-F'; $form += "files=@$f" }
  $out = curl.exe -fsS @form "$Base/api/sessions/$id/audios"
  if ($LASTEXITCODE -ne 0) { return $null }
  return ($out -join "`n" | ConvertFrom-Json)
}
function IsBusy([string]$id) {
  foreach ($s in (Api 'GET' '/api/sessions')) { if ($s.id -eq $id) { return [bool]$s.busy } }
  return $false
}
function WaitIdle([string]$id, [int]$seconds = 300) {
  for ($n = 0; $n -lt $seconds; $n++) {
    Sample
    if (-not (IsBusy $id)) { return $true }
    Start-Sleep 1
  }
  return $false
}

# --- Comandos ---

function Cmd-Help {
  Write-Host 'Uso: .\transcriptor.cmd <comando> [VARIABLE=valor ...]'
  Write-Host ''
  Write-Host '  setup    Instala y descarga todo lo necesario (una sola vez)'
  Write-Host '  up       Levanta todo (Whisper + Ollama nativos y la app en Docker)'
  Write-Host '  down     Baja todo y libera la memoria'
  Write-Host '  entrada  Abre la carpeta de entrada (los audios que sueltes ahí se procesan solos)'
  Write-Host '  status   Estado de los servicios'
  Write-Host '  logs     Logs de la app (Ctrl+C para salir)'
  Write-Host '  doctor   Diagnóstico + prueba real con voz generada (pega la salida si algo falla)'
  Write-Host '  bench    Mide tiempo y consumo con un audio tuyo: .\transcriptor.cmd bench FILE=audio.opus'
  Write-Host '  purge    Borra TODAS las sesiones guardadas (pide confirmación)'
  Write-Host '  test     Tests del backend y chequeo de tipos de la web'
  Write-Host '  dev      Desarrollo local sin Docker (API en :4747 o PORT, web con recarga en :5173)'
}

function Cmd-Setup {
  DockerReady
  if (-not (OllamaExe)) {
    # winget vive en WindowsApps, que algunas terminales no tienen en el PATH.
    $winget = (Get-Command 'winget' -ErrorAction SilentlyContinue).Source
    if (-not $winget -and (Test-Path "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe")) { $winget = "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe" }
    if (-not $winget) { Fail 'Instala Ollama desde https://ollama.com/download/windows y vuelve a ejecutar setup.' }
    Write-Host 'Instalando Ollama con winget…'
    & $winget install --id Ollama.Ollama -e --accept-source-agreements --accept-package-agreements; Check 'La instalación de Ollama'
    if (-not (OllamaExe)) { Fail 'Ollama se instaló pero no lo encuentro: cierra y abre la terminal y vuelve a ejecutar setup.' }
  }
  $gpu = $WhisperGpu
  if ($gpu -eq 'auto') { if (HasNvidia) { $gpu = 'cuda' } else { $gpu = 'cpu' } }
  if (-not $env:WHISPER_BIN) {
    $flavor = WhisperFlavor
    if (-not (WhisperBin) -or ($env:WHISPER_GPU -and $flavor -and $flavor -ne $gpu)) { Install-Whisper $gpu }
    else { Write-Host "whisper.cpp ya instalado ($flavor)" }
  }
  New-Item -ItemType Directory -Force (Join-Path $StateDir 'models'), $DataPath | Out-Null
  if (Test-Path $Model) { Write-Host 'Modelo de Whisper ya descargado' }
  else {
    Write-Host "Descargando modelo de Whisper ($ModelFile)…"
    curl.exe -L --fail --progress-bar -C - -o $Model $ModelUrl; Check 'La descarga del modelo'
  }
  if (-not (Start-Whisper)) {
    if ((WhisperFlavor) -ne 'cuda' -or $env:WHISPER_BIN) { exit 1 }
    Write-Host 'La versión con CUDA no arrancó (driver de NVIDIA antiguo o faltan DLL de CUDA). Pruebo la versión para CPU…' -ForegroundColor Yellow
    Install-Whisper 'cpu'
    if (-not (Start-Whisper)) { exit 1 }
  }
  Start-Ollama
  & (OllamaExe) pull $OllamaModel; Check "ollama pull $OllamaModel"
  Stop-Services
  Write-Host ''; Write-Host 'Listo. Arranca con: .\transcriptor.cmd up'
}

function Cmd-Up {
  DockerReady
  New-Item -ItemType Directory -Force $DataPath, $InboxPath | Out-Null
  # Otro programa en el puerto (p. ej. Apache de XAMPP): mejor avisar que dejar fallar a Docker.
  foreach ($c in (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)) {
    $owner = Get-Process -Id $c.OwningProcess -ErrorAction SilentlyContinue
    if ($owner -and $owner.ProcessName -notmatch 'docker|wslrelay|vpnkit') {
      Fail "El puerto $Port ya lo usa otro programa ($($owner.ProcessName), PID $($owner.Id)). Usa otro: .\transcriptor.cmd up PORT=8090"
    }
  }
  if (-not (Start-Whisper)) { exit 1 }
  Start-Ollama
  Compose up -d --build; Check 'docker compose up'
  Write-Host ''; Write-Host "Transcriptor listo en http://localhost:$Port   (tus sesiones: $DataPath)"
  Write-Host "Carpeta de entrada: $InboxPath   (todo audio que sueltes ahí se procesa solo; .\transcriptor.cmd entrada la abre)"
  Start-Process "http://localhost:$Port"
}

function Cmd-Entrada {
  New-Item -ItemType Directory -Force $InboxPath | Out-Null
  Start-Process explorer.exe $InboxPath
}

function Cmd-Down {
  if ((Has 'docker') -and (Quiet 'docker info')) { Compose down }
  Stop-Services
}

function Cmd-Doctor {
  $fail = $false
  function ok([string]$m) { Write-Host "  ✔ $m" }
  function bad([string]$m) { Write-Host "  ✘ $m" -ForegroundColor Red; Set-Variable fail $true -Scope 1 }
  function info([string]$m) { Write-Host "  · $m" }

  Write-Host '== Sistema'
  $os = Get-CimInstance Win32_OperatingSystem
  $cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim()
  $gpus = (Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name }) -join ', '
  info "$($os.Caption) $($os.Version) · $env:PROCESSOR_ARCHITECTURE · $cpu · $([math]::Round($os.TotalVisibleMemorySize / 1MB)) GB RAM"
  info "GPU: $gpus"

  Write-Host '== Instalación'
  if (Has 'docker') { ok 'docker' } else { bad 'falta docker (Docker Desktop)' }
  $bin = WhisperBin
  if ($bin) { ok "whisper-server ($bin; $((Get-Content (Join-Path $WhisperDir 'flavor.txt') -ErrorAction SilentlyContinue) -join ' · '))" } else { bad 'falta whisper-server (setup)' }
  if (Test-Path $Model) { ok "modelo Whisper $ModelFile" } else { bad 'falta el modelo Whisper (setup)' }
  if (OllamaExe) { ok 'ollama' } else { bad 'falta ollama (setup)' }

  Write-Host '== Servicios'
  try { $h = Api 'GET' '/api/health' } catch { bad "la app no responde en $Base (up)"; Write-Host ''; Write-Host 'RESULTADO: FALLÓ'; exit 1 }
  if ($h.whisper.ok) { ok 'Whisper responde' } else { bad "Whisper no responde: $($h.whisper.error)" }
  if ($h.ollama.modelReady) { ok 'Ollama listo con el modelo' } else { bad "Ollama o su modelo no están listos: $($h.ollama.error)" }
  $glines = Get-Content (Join-Path $StateDir 'whisper.log'), (Join-Path $StateDir 'whisper.err.log') -ErrorAction SilentlyContinue |
    Where-Object { $_ -match 'cuda|gpu|vulkan|blas' } | Select-Object -Last 3
  foreach ($l in $glines) { info "log: $l" }

  Write-Host '== Prueba real'
  Add-Type -AssemblyName System.Speech
  $synth = New-Object System.Speech.Synthesis.SpeechSynthesizer
  $voice = $synth.GetInstalledVoices() | Where-Object { $_.Enabled -and $_.VoiceInfo.Culture.Name -like 'es*' } | Select-Object -First 1
  if ($voice) { $synth.SelectVoice($voice.VoiceInfo.Name) }
  else { info 'no hay voz de Windows en español (Configuración → Hora e idioma → Voz): se usa otra y no se comprueba el texto' }
  $tmp = Join-Path ([IO.Path]::GetTempPath()) "transcriptor-doctor-$PID"
  New-Item -ItemType Directory -Force $tmp | Out-Null
  function Say([string]$file, [string]$text) { $synth.SetOutputToWaveFile((Join-Path $tmp $file)); $synth.Speak($text); $synth.SetOutputToNull() }
  Say 'PTT-prueba-WA0001.wav' 'Hola, te escribo por lo del trabajo práctico de redes. El deadline es el viernes a las diez de la mañana y hay que subir el paper al campus.'
  Say 'PTT-prueba-WA0002.wav' 'Quedamos el jueves a las cuatro en la biblioteca para repasar el quiz de la unidad tres.'
  Say 'par1.wav' 'Hola, te cuento que mañana a las ocho de la mañana tenemos que entregar el informe final de la materia de bases de datos, así que revisá bien las consultas y los diagramas antes de subirlo al campus virtual por favor.'
  Say 'par2.wav' 'Che, acordate de que el viernes hay parcial de sistemas operativos, el profesor dijo que entran los temas de procesos, hilos y planificación, y que hay que llevar la calculadora y el carnet para identificarse.'
  Say 'par3.wav' 'Mirá, la reunión del grupo la pasamos para el sábado a las cinco de la tarde en la casa de Lucía, llevá la compu con el código del proyecto y también las notas de la última clase de ingeniería de software.'
  $synth.Dispose()

  $ids = @()
  try {
    $id = (Api 'POST' '/api/sessions' @{ title = 'doctor' }).id; $ids += $id
    $start = Get-Date
    if (-not (Upload $id @((Join-Path $tmp 'PTT-prueba-WA0001.wav'), (Join-Path $tmp 'PTT-prueba-WA0002.wav')))) { bad 'no se pudo subir'; exit 1 }
    if (-not (WaitIdle $id)) { bad 'tardó más de 5 minutos' }
    $elapsed = [int]((Get-Date) - $start).TotalSeconds
    $sess = Api 'GET' "/api/sessions/$id"
    foreach ($it in $sess.items) { if ($it.status -eq 'error') { bad "falló $($it.name): $($it.error)" } }
    $texts = ($sess.items | ForEach-Object { $_.text }) -join ' '
    if ($voice) {
      if ($texts -match 'deadline|viernes|biblioteca') { ok 'transcripción coherente con lo dicho' } else { bad 'la transcripción no coincide con lo dicho' }
    }
    foreach ($it in $sess.items) { $t = "$($it.text)"; Write-Host "    $($t.Substring(0, [math]::Min(200, $t.Length)))" }
    if ($sess.global.status -eq 'done') { ok 'resumen general generado' } else { bad 'no se generó el resumen general' }
    $peak1 = PeakText

    Write-Host '== Subidas en paralelo y audios repetidos'
    $pid2 = (Api 'POST' '/api/sessions' @{ title = 'doctor paralelo' }).id; $ids += $pid2
    $start2 = Get-Date
    $procs = foreach ($k in 1..3) {
      Start-Process curl.exe -ArgumentList '-fsS', '-o', 'NUL', '-F', "`"files=@$(Join-Path $tmp "par$k.wav")`"", "$Base/api/sessions/$pid2/audios" -NoNewWindow -PassThru
    }
    $procs | Wait-Process
    if (-not (WaitIdle $pid2)) { bad 'tardó más de 5 minutos' }
    $par = Api 'GET' "/api/sessions/$pid2"
    $elapsed2 = [int]((Get-Date) - $start2).TotalSeconds
    $items = @($par.items)
    $unfinished = @($items | Where-Object { $_.status -ne 'done' }).Count
    if ($items.Count -eq 3 -and $unfinished -eq 0) { ok '3 subidas simultáneas: los 3 audios terminaron' } else { bad "audios: $($items.Count) (esperaba 3), sin terminar o con error: $unfinished" }
    $empty = @($items | Where-Object { -not $_.summary }).Count
    if ($empty -eq 0) { ok 'los 3 audios tienen su resumen' } else { bad "$empty audios sin resumen" }
    $sumErr = @($items | Where-Object { $_.summaryError } | ForEach-Object { $_.summaryError })
    if ($sumErr.Count) { bad "hay errores de resumen: $($sumErr[0..1] -join ' | ')" }
    if ($par.global.status -eq 'done' -and $par.global.items -eq 3) { ok 'resumen general de los 3 audios' } else { bad 'el resumen general no cubre los 3 audios' }
    $reup = Upload $pid2 @((Join-Path $tmp 'par1.wav'))
    if ($reup -and @($reup.skipped).Count -gt 0) { ok 'el mismo audio otra vez se detecta y se deja sin cambios' } else { bad 'el audio repetido no se detectó como duplicado' }
    $count = @((Api 'GET' "/api/sessions/$pid2").items).Count
    if ($count -eq 3) { ok 'no se duplicó: siguen 3 audios' } else { bad "tras reenviar hay $count audios" }
    info "3 audios largos en paralelo: ${elapsed2}s"

    Write-Host '== Rendimiento (2 audios de voz cortos)'
    info "tiempo total: ${elapsed}s · $peak1"
    info "regla práctica: si ${elapsed}s es mucho para estos 2 audios, prueba WHISPER_THREADS=2 o OLLAMA_MODEL=qwen2.5:3b"
  } finally {
    foreach ($x in $ids) { try { Api 'DELETE' "/api/sessions/$x" | Out-Null } catch {} }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
  }
  Write-Host ''
  if ($fail) { Write-Host 'RESULTADO: FALLÓ'; exit 1 } else { Write-Host 'RESULTADO: OK' }
}

function Cmd-Bench {
  $file = Cfg 'FILE' ($Positional | Select-Object -First 1)
  if (-not $file) { Fail 'Uso: .\transcriptor.cmd bench FILE=ruta\al\audio.opus' }
  if (-not (Test-Path $file)) { Fail "No existe $file" }
  $file = (Resolve-Path $file).Path
  try { Api 'GET' '/api/health' | Out-Null } catch { Fail "La app no responde en $Base. Ejecuta: .\transcriptor.cmd up" }
  $id = (Api 'POST' '/api/sessions' @{ title = 'bench' }).id
  try {
    Write-Host "Procesando $(Split-Path -Leaf $file)…  (se borra al terminar)"
    $start = Get-Date
    if (-not (Upload $id @($file))) { Fail 'No se pudo subir el audio' }
    WaitIdle $id 3600 | Out-Null
    Write-Host "Tiempo total:        $([int]((Get-Date) - $start).TotalSeconds) s"
    Write-Host "Pico de CPU:         $($script:Peak.cpu)% (suma de procesos; 100% = un núcleo)"
    Write-Host "Pico de memoria:     $($script:Peak.rss) MB (whisper-server + ollama)"
    if (HasNvidia) { Write-Host "Pico de GPU:         $($script:Peak.gpu)% · $($script:Peak.vram) MB de VRAM en uso (todo el sistema)" }
    Write-Host 'Si el PC se calienta: baja WHISPER_THREADS (p. ej. 2) o usa OLLAMA_MODEL=qwen2.5:3b.'
  } finally {
    try { Api 'DELETE' "/api/sessions/$id" | Out-Null } catch {}
  }
}

function Cmd-Purge {
  $a = Read-Host "¿Borrar todo el contenido de $DataPath? [s/N]"
  if ($a -eq 's') { Remove-Item -Recurse -Force (Join-Path $DataPath 'sessions') -ErrorAction SilentlyContinue; Write-Host 'Borrado.' } else { Write-Host 'Cancelado.' }
}

function Cmd-Test {
  if (-not (Has 'go')) { Fail 'Falta Go: https://go.dev/dl/' }
  Push-Location (Join-Path $Root 'backend')
  try {
    go vet ./...; Check 'go vet'
    # -race necesita cgo y un compilador de C (gcc) en Windows.
    if (Has 'gcc') { $env:CGO_ENABLED = '1'; go test -race ./... } else { go test ./... }
    Check 'go test'
  } finally { Pop-Location }
  Push-Location (Join-Path $Root 'web')
  try { npm.cmd ci --no-audit --no-fund; Check 'npm ci'; npm.cmd run build; Check 'npm run build' } finally { Pop-Location }
}

function Cmd-Dev {
  if (-not (Has 'go')) { Fail 'Falta Go: https://go.dev/dl/' }
  if (-not (Has 'ffmpeg')) { Write-Host 'Aviso: sin ffmpeg en el PATH no se pueden convertir audios (winget install Gyan.FFmpeg).' -ForegroundColor Yellow }
  # La web va en otra ventana; al cortar la API con Ctrl+C se cierra también.
  $web = Start-Process cmd.exe -ArgumentList '/c', 'npm install --no-audit --no-fund && npm run dev' -WorkingDirectory (Join-Path $Root 'web') -PassThru
  $env:DATA_DIR = $DataPath; $env:INBOX_DIR = $InboxPath; $env:WEB_DIR = '..\web\dist'; $env:TMP_DIR = Join-Path ([IO.Path]::GetTempPath()) 'transcriptor'
  $env:WHISPER_URL = "http://127.0.0.1:$WhisperPort"; $env:OLLAMA_URL = "http://127.0.0.1:$OllamaPort"; $env:ADDR = "127.0.0.1:$Port"
  Push-Location (Join-Path $Root 'backend')
  try { go run . } finally { Pop-Location; Quiet "taskkill /PID $($web.Id) /T /F" | Out-Null }
}

switch ($Command) {
  'setup'  { Cmd-Setup }
  'up'     { Cmd-Up }
  'down'   { Cmd-Down }
  'entrada' { Cmd-Entrada }
  'status' { Show-Status; if ((Has 'docker') -and (Quiet 'docker info')) { Compose ps --format 'app: {{.State}} ({{.Status}})' } }
  'logs'   { Compose logs -f --tail=100 app }
  'doctor' { Cmd-Doctor }
  'bench'  { Cmd-Bench }
  'purge'  { Cmd-Purge }
  'test'   { Cmd-Test }
  'dev'    { Cmd-Dev }
  default  { Cmd-Help }
}
