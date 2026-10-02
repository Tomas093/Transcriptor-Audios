export type ItemStatus =
  | "queued"
  | "converting"
  | "transcribing"
  | "transcribed"
  | "summarizing"
  | "done"
  | "error";

export interface Item {
  id: string;
  name: string;
  file: string;
  size: number;
  status: ItemStatus;
  text: string;
  summary: string;
  summarySkipped?: boolean;
  error?: string;
  summaryError?: string;
  durationSec?: number;
  wave?: number[];
  addedAt: string;
}

export interface GlobalSummary {
  status: "idle" | "working" | "done" | "error";
  text: string;
  error?: string;
  items: number;
}

export interface Session {
  id: string;
  title: string;
  titleAuto: boolean;
  createdAt: string;
  updatedAt: string;
  rev?: number;
  items: Item[];
  global: GlobalSummary;
}

export interface SessionInfo {
  id: string;
  title: string;
  createdAt: string;
  updatedAt: string;
  itemCount: number;
  busy: boolean;
  rev?: number;
}

export interface Health {
  whisper: { ok: boolean; error?: string };
  ollama: { ok: boolean; model: string; modelReady: boolean; error?: string };
  retentionDays: number;
}

export const BUSY: ItemStatus[] = ["queued", "converting", "transcribing", "transcribed", "summarizing"];

export function isBusy(s: Session): boolean {
  return s.global.status === "working" || s.items.some((i) => BUSY.includes(i.status));
}

export function infoOf(s: Session): SessionInfo {
  return {
    id: s.id,
    title: s.title,
    createdAt: s.createdAt,
    updatedAt: s.updatedAt,
    itemCount: s.items.length,
    busy: isBusy(s),
    rev: s.rev,
  };
}
