import type { Health, Session, SessionInfo } from "./types";

export class ApiError extends Error {}

async function req<T>(path: string, init?: RequestInit): Promise<T> {
  let res: Response;
  try {
    res = await fetch(path, init);
  } catch {
    throw new ApiError("No se pudo conectar con el servidor.");
  }
  if (!res.ok) {
    let msg = `Error ${res.status}`;
    try {
      const body = await res.json();
      if (body?.error) msg = body.error;
    } catch {
      /* sin cuerpo JSON */
    }
    throw new ApiError(msg);
  }
  const text = await res.text();
  return (text ? JSON.parse(text) : undefined) as T;
}

const json = (method: string, body?: unknown): RequestInit => ({
  method,
  headers: { "Content-Type": "application/json" },
  body: body === undefined ? undefined : JSON.stringify(body),
});

export const api = {
  health: () => req<Health>("/api/health"),
  list: () => req<SessionInfo[]>("/api/sessions"),
  get: (id: string) => req<Session>(`/api/sessions/${id}`),
  create: () => req<Session>("/api/sessions", json("POST", {})),
  rename: (id: string, title: string) => req<void>(`/api/sessions/${id}`, json("PATCH", { title })),
  remove: (id: string) => req<void>(`/api/sessions/${id}`, { method: "DELETE" }),
  retryItem: (id: string, item: string) => req<void>(`/api/sessions/${id}/items/${item}/retry`, { method: "POST" }),
  retryGlobal: (id: string) => req<void>(`/api/sessions/${id}/global/retry`, { method: "POST" }),
  upload: (id: string, files: File[]) => {
    const form = new FormData();
    for (const f of files) form.append("files", f, f.name);
    return req<Session>(`/api/sessions/${id}/audios`, { method: "POST", body: form });
  },
  exportUrl: (id: string) => `/api/sessions/${id}/export`,
};
