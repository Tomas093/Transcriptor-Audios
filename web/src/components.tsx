import { useEffect, useRef, useState, type ReactNode } from "react";
import { Icon, Logo } from "./icons";
import {
  expiryLabel, expiryWarning, fmtDuration, fmtWhen, groupLabel, paragraphs, richBlocks, sessionAsText,
} from "./format";
import { api } from "./api";
import type { GlobalSummary, Health, Item, Session, SessionInfo } from "./types";

/* ---------- utilidades pequeñas ---------- */

export function useCopy(): [boolean, (text: string) => void] {
  const [done, setDone] = useState(false);
  const timer = useRef(0);
  const copy = (text: string) => {
    const finish = () => {
      setDone(true);
      window.clearTimeout(timer.current);
      timer.current = window.setTimeout(() => setDone(false), 1600);
    };
    if (navigator.clipboard?.writeText) {
      navigator.clipboard.writeText(text).then(finish, () => legacyCopy(text) && finish());
    } else if (legacyCopy(text)) finish();
  };
  useEffect(() => () => window.clearTimeout(timer.current), []);
  return [done, copy];
}

function legacyCopy(text: string): boolean {
  const ta = document.createElement("textarea");
  ta.value = text;
  ta.style.position = "fixed";
  ta.style.opacity = "0";
  document.body.appendChild(ta);
  ta.select();
  let ok = false;
  try {
    ok = document.execCommand("copy");
  } finally {
    ta.remove();
  }
  return ok;
}

export function CopyButton({ text, label = "Copiar", className = "" }: { text: string; label?: string; className?: string }) {
  const [done, copy] = useCopy();
  return (
    <button type="button" className={`btn btn-ghost btn-sm ${className}`} onClick={() => copy(text)} aria-label={`${label}`}>
      <Icon name={done ? "check" : "copy"} size={14} />
      <span>{done ? "Copiado" : label}</span>
    </button>
  );
}

const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;

/* ---------- barra lateral ---------- */

export function Sidebar(props: {
  list: SessionInfo[];
  activeId: string | null;
  health: Health | null;
  connected: boolean;
  open: boolean;
  onSelect: (id: string) => void;
  onDelete: (id: string) => void;
  onNew: () => void;
  onClose: () => void;
}) {
  const { list, activeId, health, connected, open, onSelect, onDelete, onNew, onClose } = props;
  const retention = health?.retentionDays ?? 1;
  const [confirmId, setConfirmId] = useState<string | null>(null);

  // La confirmación se retira sola a los 5 s, o con Escape.
  useEffect(() => {
    if (!confirmId) return;
    const t = window.setTimeout(() => setConfirmId(null), 5000);
    const esc = (e: KeyboardEvent) => e.key === "Escape" && setConfirmId(null);
    window.addEventListener("keydown", esc);
    return () => {
      window.clearTimeout(t);
      window.removeEventListener("keydown", esc);
    };
  }, [confirmId]);
  const groups: { label: string; items: SessionInfo[] }[] = [];
  for (const s of list) {
    const label = groupLabel(s.updatedAt);
    const g = groups.find((x) => x.label === label);
    if (g) g.items.push(s);
    else groups.push({ label, items: [s] });
  }
  return (
    <>
      <div className={`scrim ${open ? "show" : ""}`} onClick={onClose} aria-hidden="true" />
      <aside className={`sidebar ${open ? "open" : ""}`} aria-label="Sesiones">
        <div className="brand">
          <Logo />
          <span>Transcriptor</span>
        </div>
        <div className="side-actions">
          <button type="button" className="btn btn-primary btn-block" onClick={onNew}>
            <Icon name="plus" size={16} /> Nueva sesión
          </button>
        </div>
        <nav className="session-list">
          {list.length === 0 && <p className="side-empty">Aún no hay sesiones. Suelta unos audios para empezar.</p>}
          {groups.map((g) => (
            <section key={g.label}>
              <h2 className="group-label">{g.label}</h2>
              <ul>
                {g.items.map((s) => {
                  const warn = !s.busy ? expiryWarning(s.updatedAt, retention) : null;
                  return (
                    <li key={s.id} className="row-wrap">
                      <button
                        type="button"
                        className={`session-row ${s.id === activeId ? "active" : ""}`}
                        aria-current={s.id === activeId ? "page" : undefined}
                        onClick={() => onSelect(s.id)}
                      >
                        <span className="row-title">{s.title}</span>
                        <span className="row-meta">
                          {s.busy ? <Equalizer /> : null}
                          {plural(s.itemCount, "audio", "audios")} · {fmtWhen(s.updatedAt)}
                          {warn ? <span className="row-expiry"> · {warn}</span> : null}
                        </span>
                      </button>
                      {confirmId === s.id ? (
                        <div className="row-confirm" role="alertdialog" aria-label={`Confirmar eliminar ${s.title}`}>
                          <span>¿Eliminar con sus audios?</span>
                          <button
                            type="button"
                            className="btn btn-danger btn-sm"
                            autoFocus
                            onClick={() => {
                              setConfirmId(null);
                              onDelete(s.id);
                            }}
                          >
                            Eliminar
                          </button>
                          <button type="button" className="btn btn-sm" onClick={() => setConfirmId(null)}>
                            Cancelar
                          </button>
                        </div>
                      ) : (
                        <button
                          type="button"
                          className="row-delete"
                          aria-label={`Eliminar sesión: ${s.title}`}
                          title="Eliminar sesión"
                          onClick={() => setConfirmId(s.id)}
                        >
                          <Icon name="trash" size={15} />
                        </button>
                      )}
                    </li>
                  );
                })}
              </ul>
            </section>
          ))}
        </nav>
        <footer className="side-foot">
          <Service name="Whisper" ok={health?.whisper.ok} unknown={!health} title={health?.whisper.error} />
          <Service
            name={`Ollama${health?.ollama.model ? ` · ${health.ollama.model}` : ""}`}
            ok={health ? health.ollama.ok && health.ollama.modelReady : undefined}
            unknown={!health}
            title={health?.ollama.error}
          />
          {!connected && <p className="foot-warn">Sin conexión con la app. Reintentando…</p>}
          {retention > 0 && (
            <p className="foot-note">Las sesiones se borran solas tras {plural(retention, "día", "días")} sin actividad.</p>
          )}
        </footer>
      </aside>
    </>
  );
}

function Service({ name, ok, unknown, title }: { name: string; ok?: boolean; unknown: boolean; title?: string }) {
  const state = unknown ? "unknown" : ok ? "ok" : "down";
  const text = unknown ? "comprobando" : ok ? "listo" : "no responde";
  return (
    <div className="service" title={title}>
      <span className={`dot dot-${state}`} aria-hidden="true" />
      <span className="service-name">{name}</span>
      <span className="service-state">{text}</span>
    </div>
  );
}

function Equalizer() {
  return (
    <span className="eq" role="img" aria-label="Procesando">
      <i /><i /><i />
    </span>
  );
}

/* ---------- forma de onda ---------- */

const WAVE_BARS = 48;

export function Waveform({ wave, active }: { wave?: number[]; active: boolean }) {
  const bars = wave && wave.length ? wave : Array.from({ length: WAVE_BARS }, () => 8);
  const h = 28;
  return (
    <svg className={`wave ${active ? "wave-active" : ""} ${wave?.length ? "" : "wave-empty"}`} viewBox={`0 0 ${bars.length * 4} ${h}`} width={bars.length * 3} height={h} aria-hidden="true" focusable="false">
      {bars.map((v, i) => {
        const bh = Math.max(2.5, (v / 100) * h);
        return <rect key={i} x={i * 4} y={(h - bh) / 2} width="2.6" height={bh} rx="1.3" style={{ ["--i" as string]: i }} />;
      })}
    </svg>
  );
}

/* ---------- bloques de contenido ---------- */

function Skeleton({ lines = 3 }: { lines?: number }) {
  return (
    <div className="skel-group" aria-hidden="true">
      {Array.from({ length: lines }, (_, i) => (
        <div key={i} className="skel" style={{ width: i === lines - 1 ? "62%" : "100%" }} />
      ))}
    </div>
  );
}

function Rich({ text }: { text: string }) {
  return (
    <>
      {richBlocks(text).map((b, i) =>
        b.kind === "p" ? (
          <p key={i}>{b.text}</p>
        ) : (
          <ul key={i}>
            {b.items.map((it, j) => (
              <li key={j}>{it}</li>
            ))}
          </ul>
        ),
      )}
    </>
  );
}

function SummaryBlock(props: {
  label: string;
  text?: string;
  pending?: string;
  error?: string;
  onRetry?: () => void;
}) {
  const { label, text, pending, error, onRetry } = props;
  return (
    <div className="summary">
      <header className="summary-head">
        <span className="summary-label">
          <Icon name="sparkle" size={14} /> {label}
        </span>
        {text ? <CopyButton text={text} label="Copiar resumen" /> : null}
      </header>
      {text ? <div className="summary-body"><Rich text={text} /></div> : null}
      {pending ? (
        <div role="status">
          <p className="pending-label">{pending}</p>
          <Skeleton lines={2} />
        </div>
      ) : null}
      {error ? (
        <div className="inline-error" role="alert">
          <Icon name="alert" size={15} />
          <span>{error}</span>
          {onRetry ? (
            <button type="button" className="btn btn-sm" onClick={onRetry}>
              <Icon name="retry" size={14} /> Reintentar
            </button>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}

const STAGE: Record<string, string> = {
  queued: "En cola",
  converting: "Preparando el audio…",
  transcribing: "Transcribiendo…",
};

export function GlobalBlock({ g, onRetry }: { g: GlobalSummary; onRetry: () => void }) {
  if (g.status === "idle") return null;
  return (
    <SummaryBlock
      label={`Resumen general · ${g.items} audios`}
      text={g.text || undefined}
      pending={g.status === "working" ? (g.text ? "Actualizando el resumen general…" : "Preparando el resumen general…") : undefined}
      error={g.status === "error" ? g.error || "No se pudo generar el resumen general." : undefined}
      onRetry={g.status === "error" ? onRetry : undefined}
    />
  );
}

export function ItemBlock({ item, index, onRetry }: { item: Item; index: number; onRetry: () => void }) {
  const working = item.status === "converting" || item.status === "transcribing";
  const hasText = item.text !== "";
  const paras = hasText ? paragraphs(item.text) : [];
  return (
    <article className="item" aria-labelledby={`item-${item.id}`}>
      <header className="item-head">
        <Waveform wave={item.wave} active={working} />
        <div className="item-id">
          <h2 id={`item-${item.id}`} className="item-name" title={item.name}>
            {item.name}
          </h2>
          <p className="item-sub">
            <span className="item-index">Audio {index}</span>
            {item.durationSec ? ` · ${fmtDuration(item.durationSec)}` : ""} · {fmtWhen(item.addedAt)}
          </p>
        </div>
        {hasText ? <CopyButton text={item.text} label="Copiar texto" /> : null}
      </header>

      {!hasText && item.status !== "error" ? (
        <div role="status" className="item-pending">
          <p className="pending-label">{STAGE[item.status] ?? "Procesando…"}</p>
          <Skeleton lines={4} />
        </div>
      ) : null}

      {item.status === "error" ? (
        <div className="inline-error" role="alert">
          <Icon name="alert" size={15} />
          <span>{item.error || "No se pudo transcribir este audio."}</span>
          <button type="button" className="btn btn-sm" onClick={onRetry}>
            <Icon name="retry" size={14} /> Reintentar
          </button>
        </div>
      ) : null}

      {hasText ? (
        <div className="transcript">
          {paras.map((p, i) => (
            <p key={i}>{p}</p>
          ))}
        </div>
      ) : null}

      {hasText && item.summarySkipped ? (
        <p className="short-note">Audio corto: se lee de un vistazo, no necesita resumen.</p>
      ) : null}

      {hasText && !item.summarySkipped ? (
        <SummaryBlock
          label="Resumen"
          text={item.summary || undefined}
          pending={
            !item.summary && !item.summaryError
              ? item.status === "summarizing"
                ? "Resumiendo…"
                : "Resumen en cola"
              : undefined
          }
          error={item.summaryError ? `No se pudo resumir: ${item.summaryError}` : undefined}
          onRetry={item.summaryError ? onRetry : undefined}
        />
      ) : null}
    </article>
  );
}

/* ---------- cabecera de sesión ---------- */

export function SessionHeader(props: {
  session: Session;
  retention: number;
  onMenu: () => void;
  onRename: (title: string) => void;
  onDelete: () => void;
}) {
  const { session, retention, onMenu, onRename, onDelete } = props;
  const [title, setTitle] = useState(session.title);
  const [confirming, setConfirming] = useState(false);
  const [copied, copy] = useCopy();
  const editing = useRef(false);

  // Si el título cambia desde fuera (título automático) y no lo estoy editando, sincronizar.
  useEffect(() => {
    if (!editing.current) setTitle(session.title);
  }, [session.title]);

  useEffect(() => {
    setConfirming(false);
  }, [session.id]);

  useEffect(() => {
    if (!confirming) return;
    const t = window.setTimeout(() => setConfirming(false), 6000);
    const esc = (e: KeyboardEvent) => e.key === "Escape" && setConfirming(false);
    window.addEventListener("keydown", esc);
    return () => {
      window.clearTimeout(t);
      window.removeEventListener("keydown", esc);
    };
  }, [confirming]);

  const commit = () => {
    editing.current = false;
    const t = title.trim();
    if (!t) setTitle(session.title);
    else if (t !== session.title) onRename(t);
  };

  const hasContent = session.items.some((i) => i.text);
  return (
    <header className="topbar">
      <button type="button" className="btn btn-ghost btn-icon menu-btn" onClick={onMenu} aria-label="Abrir sesiones">
        <Icon name="menu" size={18} />
      </button>
      <div className="title-wrap">
        <h1 className="sr-only">{session.title}</h1>
        <input
          className="title-input"
          value={title}
          maxLength={200}
          aria-label="Título de la sesión"
          onFocus={() => (editing.current = true)}
          onChange={(e) => setTitle(e.target.value)}
          onBlur={commit}
          onKeyDown={(e) => {
            if (e.key === "Enter") e.currentTarget.blur();
            if (e.key === "Escape") {
              setTitle(session.title);
              editing.current = false;
              e.currentTarget.blur();
            }
          }}
        />
        {retention > 0 && (
          <p className="title-sub">Se borra sola el {expiryLabel(session.updatedAt, retention)} si no hay actividad</p>
        )}
      </div>
      <div className="top-actions">
        {confirming ? (
          <div className="confirm" role="alertdialog" aria-label="Confirmar eliminación">
            <span>¿Eliminar la sesión y sus audios?</span>
            <button type="button" className="btn btn-danger btn-sm" onClick={onDelete} autoFocus>
              Eliminar
            </button>
            <button type="button" className="btn btn-sm" onClick={() => setConfirming(false)}>
              Cancelar
            </button>
          </div>
        ) : (
          <>
            {hasContent && (
              <>
                <button type="button" className="btn btn-ghost btn-sm" onClick={() => copy(sessionAsText(session))}>
                  <Icon name={copied ? "check" : "copy"} size={14} />
                  <span>{copied ? "Copiado" : "Copiar todo"}</span>
                </button>
                <a className="btn btn-ghost btn-sm" href={api.exportUrl(session.id)} download>
                  <Icon name="download" size={14} />
                  <span>Descargar</span>
                </a>
              </>
            )}
            <button type="button" className="btn btn-ghost btn-sm btn-quiet-danger" onClick={() => setConfirming(true)}>
              <Icon name="trash" size={14} />
              <span>Eliminar</span>
            </button>
          </>
        )}
      </div>
    </header>
  );
}

/* ---------- añadir audios ---------- */

const ACCEPT = "audio/*,video/mp4,.opus,.ogg,.oga,.m4a,.mp3,.wav,.aac,.amr,.flac,.webm,.mp4,.caf,.3gp";

export function Composer(props: {
  busy: boolean;
  uploadingCount: number;
  health: Health | null;
  onFiles: (files: File[]) => void;
  big?: boolean;
}) {
  const { busy, uploadingCount, health, onFiles, big } = props;
  const input = useRef<HTMLInputElement>(null);
  const down = health && (!health.whisper.ok || !health.ollama.ok || !health.ollama.modelReady);
  const uploading = uploadingCount > 0;
  return (
    <div className={`composer ${big ? "composer-big" : ""}`}>
      {down && (
        <div className="svc-warn" role="alert">
          <Icon name="alert" size={15} />
          <div>
            {!health.whisper.ok && <p>Whisper no responde: no se podrá transcribir.</p>}
            {!health.ollama.ok && <p>Ollama no responde: no se podrán generar resúmenes.</p>}
            {health.ollama.ok && !health.ollama.modelReady && <p>{health.ollama.error}</p>}
            <p>
              Ejecuta <code>make up</code> en la carpeta del proyecto y vuelve a intentarlo.
            </p>
          </div>
        </div>
      )}
      <input
        ref={input}
        type="file"
        multiple
        accept={ACCEPT}
        hidden
        onChange={(e) => {
          const files = Array.from(e.target.files ?? []);
          e.target.value = "";
          if (files.length) onFiles(files);
        }}
      />
      <button type="button" className="dropzone" onClick={() => input.current?.click()} disabled={uploading}>
        {big ? <Logo size={40} /> : <Icon name="plus" size={18} />}
        <span className="dz-text">
          <strong>
            {uploading
              ? `Subiendo ${plural(uploadingCount, "audio", "audios")}…`
              : big
                ? "Suelta aquí tus audios de WhatsApp"
                : busy
                  ? "Añadir más audios (se procesan en orden)"
                  : "Añadir audios"}
          </strong>
          <span className="dz-hint">
            {big ? "o haz clic para elegirlos · puedes subir varios a la vez" : "Arrastra o haz clic · .opus .ogg .m4a .mp3 .wav"}
          </span>
        </span>
      </button>
    </div>
  );
}

export function Welcome({ children }: { children: ReactNode }) {
  return (
    <div className="welcome">
      <div className="welcome-inner">
        <h1>Lee tus audios en vez de escucharlos</h1>
        <p className="welcome-lead">
          Guarda los audios desde WhatsApp y suéltalos aquí. Todo se transcribe en tu equipo, sin enviar nada a internet.
        </p>
        {children}
        <ul className="tips">
          <li>Los audios se ordenan por nombre, así que quedan en el orden en que los recibiste.</li>
          <li>Obtienes el texto y un resumen de cada audio, y un resumen general si subes varios.</li>
          <li>Funciona con español y con spanglish.</li>
        </ul>
      </div>
    </div>
  );
}
