import type { Session } from "./types";

const timeFmt = new Intl.DateTimeFormat("es", { hour: "2-digit", minute: "2-digit" });
const dayFmt = new Intl.DateTimeFormat("es", { day: "numeric", month: "short" });

export const fmtTime = (iso: string) => timeFmt.format(new Date(iso));

export function fmtDuration(sec?: number): string {
  if (!sec || sec < 0) return "";
  const s = Math.round(sec);
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, "0")}`;
}

const startOfDay = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();

export function dayDiff(iso: string, now = new Date()): number {
  return Math.round((startOfDay(now) - startOfDay(new Date(iso))) / 86_400_000);
}

export function fmtWhen(iso: string, now = new Date()): string {
  const d = dayDiff(iso, now);
  if (d === 0) return fmtTime(iso);
  if (d === 1) return `ayer ${fmtTime(iso)}`;
  return `${dayFmt.format(new Date(iso))} ${fmtTime(iso)}`;
}

export function groupLabel(iso: string, now = new Date()): string {
  const d = dayDiff(iso, now);
  if (d <= 0) return "Hoy";
  if (d === 1) return "Ayer";
  return "Anteriores";
}

const HOUR = 3_600_000;
const DAY = 24 * HOUR;

/** Milisegundos que faltan para el borrado automático (0 si ya toca). */
export function msLeft(updatedAt: string, retentionDays: number, now = Date.now()): number {
  return Math.max(0, new Date(updatedAt).getTime() + retentionDays * DAY - now);
}

/**
 * Aviso para la barra lateral cuando se acerca el borrado: solo aparece al final del plazo
 * (el último 25 %, máximo 2 días), para no mostrar el aviso en todas las sesiones.
 */
export function expiryWarning(updatedAt: string, retentionDays: number, now = Date.now()): string | null {
  if (retentionDays <= 0) return null;
  const left = msLeft(updatedAt, retentionDays, now);
  if (left > Math.min(2 * DAY, retentionDays * DAY * 0.25)) return null;
  if (left < HOUR) return "se borra en menos de 1 h";
  if (left < DAY) return `se borra en ${Math.floor(left / HOUR)} h`;
  const d = Math.ceil(left / DAY);
  return `se borra en ${d} ${d === 1 ? "día" : "días"}`;
}

const expiryFmt = new Intl.DateTimeFormat("es", { weekday: "long", day: "numeric", month: "long", hour: "2-digit", minute: "2-digit" });

/** Fecha y hora exactas del borrado automático, para la cabecera de la sesión. */
export function expiryLabel(updatedAt: string, retentionDays: number): string {
  return expiryFmt.format(new Date(new Date(updatedAt).getTime() + retentionDays * DAY));
}

/** Parte un texto corrido en párrafos de ~3 frases para poder leerlo cómodo. */
export function paragraphs(text: string, target = 360): string[] {
  const sentences = text.match(/[^.!?…]+[.!?…]+["')\]]*\s*|[^.!?…]+$/g) ?? [text];
  const out: string[] = [];
  let cur = "";
  for (const s of sentences) {
    cur += s;
    if (cur.length >= target) {
      out.push(cur.trim());
      cur = "";
    }
  }
  if (cur.trim()) out.push(cur.trim());
  return out;
}

export type Block = { kind: "p"; text: string } | { kind: "ul"; items: string[] };

/** Convierte el resumen del modelo (párrafos + listas con "- ") en bloques renderizables. */
export function richBlocks(text: string): Block[] {
  const blocks: Block[] = [];
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line) continue;
    const m = line.match(/^[-•*]\s+(.*)$/);
    if (m) {
      const last = blocks[blocks.length - 1];
      if (last?.kind === "ul") last.items.push(m[1]);
      else blocks.push({ kind: "ul", items: [m[1]] });
    } else {
      blocks.push({ kind: "p", text: line.replace(/\*\*(.*?)\*\*/g, "$1") });
    }
  }
  return blocks;
}

export function sessionAsText(s: Session): string {
  const parts = [s.title];
  if (s.global.status === "done" && s.global.text) parts.push(`Resumen general\n${s.global.text}`);
  s.items.forEach((it, i) => {
    const sum = it.summary && !it.summarySkipped ? `Resumen: ${it.summary}\n` : "";
    parts.push(`${i + 1}. ${it.name}\n${sum}${it.text}`);
  });
  return parts.join("\n\n");
}

export const AUDIO_EXT = /\.(opus|ogg|oga|m4a|mp3|wav|aac|amr|flac|webm|mp4|mpeg|mpga|caf|3gp)$/i;

export function looksLikeAudio(f: File): boolean {
  return f.type.startsWith("audio/") || f.type.startsWith("video/") || AUDIO_EXT.test(f.name);
}
