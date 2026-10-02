import { useEffect, useRef, useState } from "react";
import { Composer, GlobalBlock, ItemBlock, SessionHeader, Sidebar, Welcome } from "./components";
import { Icon } from "./icons";
import { navigate, useApp } from "./useApp";

export default function App() {
  const app = useApp();
  const { session, activeId, health } = app;
  const [menuOpen, setMenuOpen] = useState(false);
  const [dragging, setDragging] = useState(false);
  const [announce, setAnnounce] = useState("");
  const scroller = useRef<HTMLDivElement>(null);
  const retention = health?.retentionDays ?? 7;

  // Arrastrar archivos sobre toda la ventana
  useEffect(() => {
    let depth = 0;
    const hasFiles = (e: DragEvent) => Array.from(e.dataTransfer?.types ?? []).includes("Files");
    const enter = (e: DragEvent) => {
      if (!hasFiles(e)) return;
      e.preventDefault();
      depth++;
      setDragging(true);
    };
    const over = (e: DragEvent) => {
      if (hasFiles(e)) e.preventDefault();
    };
    const leave = (e: DragEvent) => {
      if (!hasFiles(e)) return;
      depth = Math.max(0, depth - 1);
      if (depth === 0) setDragging(false);
    };
    const drop = (e: DragEvent) => {
      if (!hasFiles(e)) return;
      e.preventDefault();
      depth = 0;
      setDragging(false);
      const files = Array.from(e.dataTransfer?.files ?? []);
      if (files.length) void app.addFiles(files, activeId);
    };
    window.addEventListener("dragenter", enter);
    window.addEventListener("dragover", over);
    window.addEventListener("dragleave", leave);
    window.addEventListener("drop", drop);
    return () => {
      window.removeEventListener("dragenter", enter);
      window.removeEventListener("dragover", over);
      window.removeEventListener("dragleave", leave);
      window.removeEventListener("drop", drop);
    };
  }, [app.addFiles, activeId]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    document.title = session ? `${session.title} · Transcriptor` : "Transcriptor de audios";
  }, [session?.title]); // eslint-disable-line react-hooks/exhaustive-deps

  // Ir al final cuando llegan audios nuevos
  const itemCount = session?.items.length ?? 0;
  const lastCount = useRef({ id: "", n: 0 });
  useEffect(() => {
    const el = scroller.current;
    if (!el || !session) return;
    const prev = lastCount.current;
    if (prev.id === session.id && itemCount > prev.n) {
      const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
      const first = el.querySelectorAll<HTMLElement>(".item")[prev.n];
      first?.scrollIntoView({ block: "start", behavior: reduce ? "auto" : "smooth" });
    } else if (prev.id !== session.id) {
      el.scrollTo({ top: 0 });
    }
    lastCount.current = { id: session.id, n: itemCount };
  }, [session?.id, itemCount]); // eslint-disable-line react-hooks/exhaustive-deps

  // Avisar a lectores de pantalla cuando un audio termina
  const seen = useRef<Record<string, string>>({});
  useEffect(() => {
    if (!session) return;
    for (const it of session.items) {
      const before = seen.current[it.id];
      if (before && before !== it.status) {
        if (it.status === "done") setAnnounce(`${it.name}: transcripción lista`);
        if (it.status === "error") setAnnounce(`${it.name}: error al transcribir`);
      }
      seen.current[it.id] = it.status;
    }
  }, [session]);

  const select = (id: string) => {
    navigate(id);
    setMenuOpen(false);
  };
  const newSession = () => {
    navigate(null);
    setMenuOpen(false);
  };
  const uploadingHere = app.uploading && app.uploading.id === activeId ? app.uploading.count : 0;
  const busy = session ? session.items.some((i) => i.status !== "done" && i.status !== "error") : false;

  return (
    <div className="app">
      <Sidebar
        list={app.list}
        activeId={activeId}
        health={health}
        connected={app.connected}
        open={menuOpen}
        onSelect={select}
        onNew={newSession}
        onClose={() => setMenuOpen(false)}
      />

      <main className="main">
        {session ? (
          <>
            <SessionHeader
              session={session}
              retention={retention}
              onMenu={() => setMenuOpen(true)}
              onRename={(t) => void app.rename(session.id, t)}
              onDelete={() => void app.remove(session.id)}
            />
            <div className="scroll" ref={scroller}>
              <div className="column">
                {session.items.length === 0 ? (
                  <p className="empty-note">Esta sesión aún no tiene audios.</p>
                ) : null}
                <GlobalBlock g={session.global} onRetry={() => void app.retryGlobal(session.id)} />
                {session.items.map((it, i) => (
                  <ItemBlock key={it.id} item={it} index={i + 1} onRetry={() => void app.retry(session.id, it.id)} />
                ))}
              </div>
            </div>
            <div className="composer-wrap">
              <Composer
                busy={busy}
                uploadingCount={uploadingHere}
                health={health}
                onFiles={(f) => void app.addFiles(f, session.id)}
              />
            </div>
          </>
        ) : activeId ? (
          <>
            <div className="mobile-bar">
              <button type="button" className="btn btn-ghost btn-icon" onClick={() => setMenuOpen(true)} aria-label="Abrir sesiones">
                <Icon name="menu" size={18} />
              </button>
            </div>
            <div className="scroll">
              <div className="column" aria-busy="true">
                <div className="skel-group">
                  <div className="skel" style={{ width: "40%", height: 20 }} />
                  <div className="skel" />
                  <div className="skel" />
                  <div className="skel" style={{ width: "70%" }} />
                </div>
              </div>
            </div>
          </>
        ) : (
          <>
            <div className="mobile-bar">
              <button type="button" className="btn btn-ghost btn-icon" onClick={() => setMenuOpen(true)} aria-label="Abrir sesiones">
                <Icon name="menu" size={18} />
              </button>
            </div>
            <div className="scroll">
              <Welcome>
                <Composer
                  big
                  busy={false}
                  uploadingCount={app.uploading && app.uploading.id === null ? app.uploading.count : 0}
                  health={health}
                  onFiles={(f) => void app.addFiles(f, null)}
                />
              </Welcome>
            </div>
          </>
        )}

        {app.notice ? (
          <div className={`toast toast-${app.notice.kind}`} role={app.notice.kind === "error" ? "alert" : "status"}>
            <Icon name={app.notice.kind === "error" ? "alert" : "check"} size={16} />
            <span>{app.notice.msg}</span>
            <button type="button" className="btn btn-ghost btn-icon btn-sm" onClick={app.dismissNotice} aria-label="Cerrar aviso">
              <Icon name="close" size={14} />
            </button>
          </div>
        ) : null}

        <div className={`drop-overlay ${dragging ? "show" : ""}`} aria-hidden="true">
          <div className="drop-card">
            <Icon name="plus" size={22} />
            <p>{session ? "Suelta para añadir a esta sesión" : "Suelta para crear una sesión nueva"}</p>
          </div>
        </div>
      </main>

      <div className="sr-only" aria-live="polite">
        {announce}
      </div>
    </div>
  );
}
