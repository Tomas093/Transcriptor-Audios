import { useCallback, useEffect, useRef, useState } from "react";
import { api, ApiError } from "./api";
import { Icon } from "./icons";
import { SKINS, applyStyle, currentStyle, type SkinId } from "./theme";
import type { Settings, WhatsAppMode, WhatsAppStatus } from "./types";

const EMPTY: WhatsAppStatus = {
  running: false, host: "", stack: "", updatedAt: 0, error: "", lastChat: "", lastAt: 0, detected: "", detectedAt: 0, copied: 0,
};

function shortId(id: string) {
  return id.length > 22 ? `${id.slice(0, 10)}…${id.slice(-8)}` : id;
}

function ago(unix: number) {
  if (!unix) return "";
  const s = Math.max(0, Math.round(Date.now() / 1000 - unix));
  if (s < 90) return "hace un momento";
  if (s < 3600) return `hace ${Math.round(s / 60)} min`;
  return `hace ${Math.round(s / 3600)} h`;
}

/** Ventana de configuración (audios de WhatsApp de escritorio y segundo plano). */
export function SettingsDialog({ open, onClose, onSaved }: { open: boolean; onClose: () => void; onSaved: (msg: string) => void }) {
  const ref = useRef<HTMLDialogElement>(null);
  const [form, setForm] = useState<Settings | null>(null);
  const [status, setStatus] = useState<WhatsAppStatus>(EMPTY);
  const [error, setError] = useState("");
  const [saving, setSaving] = useState(false);
  const [skin, setSkin] = useState<SkinId>(currentStyle);
  const [detectSince, setDetectSince] = useState(0); // unix de cuando se pulsó «Detectar»; 0 = no activo
  const loaded = useRef(false);

  const refresh = useCallback(async () => {
    try {
      const r = await api.settings();
      setStatus(r.whatsapp);
      if (!loaded.current) {
        loaded.current = true;
        setForm(r.settings);
      }
    } catch (e) {
      setError(e instanceof ApiError ? e.message : "No se pudo leer la configuración.");
    }
  }, []);

  // Abrir/cerrar el <dialog> nativo (da foco, Escape y capa modal gratis).
  useEffect(() => {
    const d = ref.current;
    if (!d) return;
    if (open && !d.open) {
      loaded.current = false;
      setError("");
      setDetectSince(0);
      d.showModal();
      void refresh();
    } else if (!open && d.open) {
      d.close();
    }
  }, [open, refresh]);

  // Estado al día mientras está abierta (el script lo actualiza solo; más rápido al detectar).
  useEffect(() => {
    if (!open) return;
    const t = window.setInterval(() => void refresh(), detectSince ? 2000 : 5000);
    return () => window.clearInterval(t);
  }, [open, detectSince, refresh]);

  const detected = detectSince && status.detected && status.detectedAt >= detectSince ? status.detected : "";

  const set = (fn: (s: Settings) => Settings) => setForm((f) => (f ? fn(f) : f));
  const setMode = (mode: WhatsAppMode) => set((f) => ({ ...f, whatsapp: { ...f.whatsapp, mode } }));
  const addChat = (id: string) =>
    set((f) => ({ ...f, whatsapp: { ...f.whatsapp, mode: "chats", chats: f.whatsapp.chats.includes(id) ? f.whatsapp.chats : [...f.whatsapp.chats, id] } }));
  const removeChat = (id: string) => set((f) => ({ ...f, whatsapp: { ...f.whatsapp, chats: f.whatsapp.chats.filter((c) => c !== id) } }));

  async function startDetect() {
    setError("");
    try {
      await api.detectChat();
      setDetectSince(Math.floor(Date.now() / 1000) - 1);
    } catch (e) {
      setError(e instanceof ApiError ? e.message : "No se pudo iniciar la detección.");
    }
  }

  async function save() {
    if (!form) return;
    setSaving(true);
    setError("");
    try {
      const r = await api.saveSettings(form);
      setStatus(r.whatsapp);
      onSaved("Configuración guardada.");
      onClose();
    } catch (e) {
      setError(e instanceof ApiError ? e.message : "No se pudo guardar.");
    } finally {
      setSaving(false);
    }
  }

  const wa = form?.whatsapp;
  const bg = form?.background;
  const agentMissing = bg?.enabled && status.host !== "agent";

  return (
    <dialog ref={ref} className="dlg" aria-labelledby="dlg-title" onClose={onClose} onCancel={onClose}>
      <div className="dlg-bar">
        <h2 id="dlg-title">Configuración</h2>
        <button type="button" className="btn btn-icon btn-sm" onClick={onClose} aria-label="Cerrar">
          <Icon name="close" size={14} />
        </button>
      </div>
      {!form ? (
        <div className="dlg-body">
          <p className="dlg-note">{error || "Cargando…"}</p>
        </div>
      ) : (
        <form
          className="dlg-body"
          onSubmit={(e) => {
            e.preventDefault();
            void save();
          }}
        >
          <fieldset className="dlg-group">
            <legend>Estilo de la app</legend>
            <div className="skin-grid" role="radiogroup" aria-label="Estilo visual">
              {SKINS.map((k) => (
                <label key={k.id} className={`skin ${skin === k.id ? "on" : ""}`} title={k.note}>
                  <input
                    type="radio"
                    name="skin"
                    checked={skin === k.id}
                    onChange={() => {
                      setSkin(k.id);
                      applyStyle(k.id);
                    }}
                  />
                  <span className="skin-sw" aria-hidden="true">
                    {k.sw.map((c) => (
                      <i key={c} style={{ background: c }} />
                    ))}
                  </span>
                  <span className="skin-name">{k.name}</span>
                </label>
              ))}
            </div>
            <p className="dlg-note">Se aplica al instante y se recuerda en este navegador.</p>
          </fieldset>

          <fieldset className="dlg-group">
            <legend>Audios de WhatsApp de escritorio</legend>
            <p className="dlg-note">
              Copia solos a la carpeta de entrada los audios que WhatsApp ya guardó en tu disco. No se conecta a tu cuenta.
              Lo que guardes aquí manda sobre el fichero <code>.env</code>.
            </p>
            <div className="dlg-choices" role="radiogroup" aria-label="Qué chats copiar">
              <label><input type="radio" name="mode" checked={wa!.mode === "off"} onChange={() => setMode("off")} /> No copiar nada</label>
              <label><input type="radio" name="mode" checked={wa!.mode === "all"} onChange={() => setMode("all")} /> Todos los chats</label>
              <label><input type="radio" name="mode" checked={wa!.mode === "chats"} onChange={() => setMode("chats")} /> Solo estos chats</label>
            </div>

            {wa!.mode === "chats" && (
              <div className="dlg-chats">
                {wa!.chats.length === 0 && <p className="dlg-note">Aún no hay chats. Pulsa «Detectar chat» y reproduce un audio de ese chat en WhatsApp.</p>}
                <ul>
                  {wa!.chats.map((c) => (
                    <li key={c}>
                      <code title={c}>{shortId(c)}</code>
                      <button type="button" className="btn btn-sm" onClick={() => removeChat(c)} aria-label={`Quitar el chat ${shortId(c)}`}>
                        Quitar
                      </button>
                    </li>
                  ))}
                </ul>
                <div className="dlg-detect">
                  <button type="button" className="btn btn-sm" onClick={() => void startDetect()} disabled={!!detectSince && !detected}>
                    {detectSince && !detected ? "Esperando un audio…" : "Detectar chat"}
                  </button>
                  {detectSince && !detected ? (
                    <span className="dlg-note" role="status">Reproduce un audio de ese chat en WhatsApp de escritorio.</span>
                  ) : null}
                  {detectSince && !detected && !status.running ? (
                    <span className="dlg-warn" role="alert">
                      El vigilante no está en marcha, así que no puede detectar nada. Instálalo una vez: <code>make agente</code> (Mac) o <code>.\transcriptor.cmd agente</code> (Windows). En Mac, <code>./scripts/whatsapp.sh diagnostico</code> dice qué falla.
                    </span>
                  ) : null}
                  {detected ? (
                    <span className="dlg-found" role="status">
                      Detectado: <code title={detected}>{shortId(detected)}</code>
                      <button type="button" className="btn btn-sm btn-primary" onClick={() => { addChat(detected); setDetectSince(0); }}>
                        Añadir
                      </button>
                    </span>
                  ) : null}
                </div>
              </div>
            )}

            {wa!.mode !== "off" && (
              <label className="dlg-row">
                Al encender, incluir audios de los últimos
                <input
                  type="number"
                  min={0}
                  max={1440}
                  value={wa!.backlogMin}
                  onChange={(e) => set((f) => ({ ...f, whatsapp: { ...f.whatsapp, backlogMin: Math.max(0, Math.min(1440, Number(e.target.value) || 0)) } }))}
                />
                min <span className="dlg-hint">(0 = solo los nuevos)</span>
              </label>
            )}
          </fieldset>

          <fieldset className="dlg-group">
            <legend>Agrupar audios en una sesión</legend>
            <label className="dlg-row">
              Los audios que lleguen con menos de
              <input
                type="number"
                min={0}
                max={1440}
                value={form.inbox.groupMin}
                onChange={(e) => set((f) => ({ ...f, inbox: { groupMin: Math.max(0, Math.min(1440, Number(e.target.value) || 0)) } }))}
              />
              min entre uno y otro van a la misma sesión
            </label>
            <p className="dlg-note">
              Vale para los que llegan a la carpeta de entrada (también los de WhatsApp). Cuenta desde el último audio de la sesión, así que mientras sigan llegando se van sumando; cuando pasa ese tiempo sin audios nuevos, el siguiente empieza una sesión nueva. 0 = una sesión por cada tanda.
            </p>
          </fieldset>

          <fieldset className="dlg-group">
            <legend>Segundo plano</legend>
            <label className="dlg-check">
              <input type="checkbox" checked={bg!.enabled} onChange={(e) => set((f) => ({ ...f, background: { ...f.background, enabled: e.target.checked } }))} />
              Escuchar en segundo plano y encender todo cuando llegue un audio
            </label>
            <p className="dlg-note">
              Un vigilante casi sin consumo (sin GPU, unos pocos MB). La app y los modelos solo se encienden cuando llega un audio y se apagan solos.
            </p>
            {bg!.enabled && (
              <>
                <label className="dlg-row">
                  Apagar tras
                  <input
                    type="number"
                    min={1}
                    max={240}
                    value={bg!.idleMin}
                    onChange={(e) => set((f) => ({ ...f, background: { ...f.background, idleMin: Math.max(1, Math.min(240, Number(e.target.value) || 1)) } }))}
                  />
                  min sin actividad
                </label>
                <label className="dlg-check">
                  <input type="checkbox" checked={bg!.quitDocker} onChange={(e) => set((f) => ({ ...f, background: { ...f.background, quitDocker: e.target.checked } }))} />
                  Cerrar también Docker Desktop al apagar (solo si no hay otros contenedores en marcha)
                </label>
              </>
            )}
            {agentMissing && (
              <p className="dlg-warn" role="status">
                Falta instalar el vigilante, una sola vez: <code>make agente</code> (Mac) o <code>.\transcriptor.cmd agente</code> (Windows).
              </p>
            )}
          </fieldset>

          <div className="dlg-status" aria-live="polite">
            <span className={`dot dot-${status.running ? "ok" : "unknown"}`} aria-hidden="true" />
            {status.running
              ? `Vigilante ${status.host === "agent" ? "en segundo plano" : "activo"} · app ${status.stack === "on" ? "encendida" : "apagada"}${status.copied ? ` · ${status.copied} copiados` : ""}${status.lastAt ? ` · último ${ago(status.lastAt)}` : ""}`
              : "Vigilante apagado (se instala con «make agente» en Mac o «transcriptor.cmd agente» en Windows)."}
          </div>
          {status.error && <p className="dlg-warn" role="alert">{status.error}</p>}
          {error && <p className="dlg-warn" role="alert">{error}</p>}

          <div className="dlg-actions">
            <button type="submit" className="btn btn-primary" disabled={saving}>
              {saving ? "Guardando…" : "Guardar"}
            </button>
            <button type="button" className="btn" onClick={onClose}>
              Cancelar
            </button>
          </div>
        </form>
      )}
    </dialog>
  );
}
