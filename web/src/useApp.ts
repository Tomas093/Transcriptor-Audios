import { useCallback, useEffect, useRef, useState } from "react";
import { api, ApiError } from "./api";
import { looksLikeAudio } from "./format";
import { infoOf, type Health, type Session, type SessionInfo } from "./types";

function readRoute(): string | null {
  const m = location.hash.match(/^#\/s\/([\w-]+)$/);
  return m ? m[1] : null;
}

export function navigate(id: string | null) {
  location.hash = id ? `#/s/${id}` : "#/";
}

const byRecent = (a: SessionInfo, b: SessionInfo) => b.updatedAt.localeCompare(a.updatedAt);

export function useApp() {
  const [list, setList] = useState<SessionInfo[]>([]);
  const [sessions, setSessions] = useState<Record<string, Session>>({});
  const [health, setHealth] = useState<Health | null>(null);
  const [connected, setConnected] = useState(true);
  const [loaded, setLoaded] = useState(false);
  const [activeId, setActiveId] = useState<string | null>(readRoute());
  const [uploading, setUploading] = useState<{ id: string | null; count: number } | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const noticeTimer = useRef<number>(0);
  const gone = useRef(new Set<string>()); // sesiones borradas: no volver a pedirlas

  const say = useCallback((msg: string) => {
    setNotice(msg);
    window.clearTimeout(noticeTimer.current);
    noticeTimer.current = window.setTimeout(() => setNotice(null), 6000);
  }, []);

  const upsert = useCallback((s: Session) => {
    setSessions((prev) => ({ ...prev, [s.id]: s }));
    setList((prev) => [infoOf(s), ...prev.filter((x) => x.id !== s.id)].sort(byRecent));
  }, []);

  const drop = useCallback((id: string) => {
    gone.current.add(id);
    if (readRoute() === id) navigate(null);
    setSessions((prev) => {
      const next = { ...prev };
      delete next[id];
      return next;
    });
    setList((prev) => prev.filter((x) => x.id !== id));
  }, []);

  const refresh = useCallback(async () => {
    try {
      setList((await api.list()).sort(byRecent));
      setLoaded(true);
    } catch {
      setLoaded(true);
    }
  }, []);

  // Ruta (hash)
  useEffect(() => {
    const on = () => setActiveId(readRoute());
    window.addEventListener("hashchange", on);
    return () => window.removeEventListener("hashchange", on);
  }, []);

  // Eventos en vivo
  useEffect(() => {
    void refresh();
    const es = new EventSource("/api/events");
    es.addEventListener("session", (e) => upsert(JSON.parse((e as MessageEvent).data)));
    es.addEventListener("deleted", (e) => drop(JSON.parse((e as MessageEvent).data).id));
    es.onopen = () => {
      setConnected(true);
      void refresh(); // por si se perdió algo mientras estaba desconectado
    };
    es.onerror = () => setConnected(false);
    return () => es.close();
  }, [refresh, upsert, drop]);

  // Estado de Whisper y Ollama
  useEffect(() => {
    let alive = true;
    const poll = async () => {
      if (document.hidden) return;
      try {
        const h = await api.health();
        if (alive) setHealth(h);
      } catch {
        if (alive) setHealth(null);
      }
    };
    void poll();
    const t = window.setInterval(poll, 15_000);
    document.addEventListener("visibilitychange", poll);
    return () => {
      alive = false;
      window.clearInterval(t);
      document.removeEventListener("visibilitychange", poll);
    };
  }, []);

  // Cargar la sesión abierta si todavía no la tenemos
  const hasActive = activeId ? activeId in sessions : true;
  useEffect(() => {
    if (!activeId || hasActive || gone.current.has(activeId)) return;
    let alive = true;
    api
      .get(activeId)
      .then((s) => alive && upsert(s))
      .catch(() => {
        if (alive) {
          say("Esa sesión ya no existe (quizá se borró sola).");
          navigate(null);
        }
      });
    return () => {
      alive = false;
    };
  }, [activeId, hasActive, upsert, say]);

  // Si se borra la sesión abierta (p. ej. por caducidad), volver al inicio
  useEffect(() => {
    if (loaded && activeId && hasActive && !list.some((x) => x.id === activeId)) navigate(null);
  }, [loaded, activeId, hasActive, list]);

  const addFiles = useCallback(
    async (files: File[], targetId: string | null) => {
      const audio = files.filter(looksLikeAudio);
      const skipped = files.length - audio.length;
      if (skipped > 0) {
        say(`${skipped} ${skipped === 1 ? "archivo ignorado" : "archivos ignorados"}: no parecen audio.`);
      }
      if (audio.length === 0) return;
      setUploading({ id: targetId, count: audio.length });
      try {
        let id = targetId;
        if (!id) {
          const created = await api.create();
          upsert(created);
          id = created.id;
          navigate(id);
        }
        upsert(await api.upload(id, audio));
      } catch (e) {
        say(e instanceof ApiError ? e.message : "No se pudieron subir los audios.");
      } finally {
        setUploading(null);
      }
    },
    [say, upsert],
  );

  const rename = useCallback(
    async (id: string, title: string) => {
      try {
        await api.rename(id, title);
      } catch (e) {
        say(e instanceof ApiError ? e.message : "No se pudo renombrar.");
      }
    },
    [say],
  );

  const remove = useCallback(
    async (id: string) => {
      try {
        await api.remove(id);
        drop(id);
      } catch (e) {
        say(e instanceof ApiError ? e.message : "No se pudo eliminar la sesión.");
      }
    },
    [say, drop],
  );

  const retry = useCallback(
    async (id: string, itemId: string) => {
      try {
        await api.retryItem(id, itemId);
      } catch (e) {
        say(e instanceof ApiError ? e.message : "No se pudo reintentar.");
      }
    },
    [say],
  );

  const retryGlobal = useCallback(
    async (id: string) => {
      try {
        await api.retryGlobal(id);
      } catch (e) {
        say(e instanceof ApiError ? e.message : "No se pudo reintentar.");
      }
    },
    [say],
  );

  return {
    list, sessions, health, connected, loaded, activeId, uploading, notice, dismissNotice: () => setNotice(null),
    session: activeId ? sessions[activeId] : undefined,
    addFiles, rename, remove, retry, retryGlobal,
  };
}
