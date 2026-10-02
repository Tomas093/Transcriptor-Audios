// Laboratorio de estilos: dos ejes independientes que se combinan en vivo.
//  · estilo (piel visual)  → data-style en <html>
//  · estructura (layout)   → data-layout en <html>
// Se recuerdan en localStorage y se pueden fijar por URL: ?style=neo&layout=arriba

export const SKINS = [
  { id: "calma", name: "Calma", note: "El actual", sw: ["#ffffff", "#a3195b"] },
  { id: "bento", name: "Bento", note: "Teselas modulares", sw: ["#eef0f6", "#fff3a8", "#a3195b"] },
  { id: "neo", name: "Neo-brutal", note: "Bordes gruesos, sombras duras", sw: ["#ffe94d", "#ff7ac6", "#3b5bff"] },
  { id: "terminal", name: "Terminal", note: "Fósforo verde, monoespaciada", sw: ["#06100a", "#4dff9a"] },
  { id: "clay", name: "Clay", note: "Blando, inflado, pastel", sw: ["#fbe3e4", "#ff8a9b", "#bfe9d6"] },
  { id: "aurora", name: "Aurora", note: "Oscuro con luz y vidrio", sw: ["#0b1020", "#2ee6c5", "#ff4fa3"] },
  { id: "editorial", name: "Editorial", note: "Revista: serif y filetes", sw: ["#ffffff", "#141414", "#d6361f"] },
  { id: "cuaderno", name: "Cuaderno", note: "Hoja rayada y post-its", sw: ["#fbfdff", "#ffe36e", "#ff9fc4"] },
  { id: "grabadora", name: "Grabadora", note: "Aparato con pantalla LCD", sw: ["#2b2926", "#c9c6bd", "#ff7a1a"] },
] as const;

export const LAYOUTS = [
  { id: "lateral", name: "Lateral", note: "Barra a la izquierda" },
  { id: "flotante", name: "Flotante", note: "Paneles sueltos" },
  { id: "arriba", name: "Pestañas", note: "Sesiones arriba" },
] as const;

export type SkinId = (typeof SKINS)[number]["id"];
export type LayoutId = (typeof LAYOUTS)[number]["id"];

const KEY_STYLE = "ts-style";
const KEY_LAYOUT = "ts-layout";

function read(key: string, param: string, valid: readonly string[], fallback: string): string {
  try {
    const q = new URLSearchParams(location.search).get(param);
    if (q && valid.includes(q)) return q;
    const v = localStorage.getItem(key);
    if (v && valid.includes(v)) return v;
  } catch {
    /* sin almacenamiento: se usa el valor por defecto */
  }
  return fallback;
}

export function currentTheme(): { style: SkinId; layout: LayoutId } {
  return {
    style: read(KEY_STYLE, "style", SKINS.map((s) => s.id), "calma") as SkinId,
    layout: read(KEY_LAYOUT, "layout", LAYOUTS.map((l) => l.id), "lateral") as LayoutId,
  };
}

export function applyTheme(style: SkinId, layout: LayoutId) {
  const root = document.documentElement;
  root.dataset.style = style;
  root.dataset.layout = layout;
  try {
    localStorage.setItem(KEY_STYLE, style);
    localStorage.setItem(KEY_LAYOUT, layout);
  } catch {
    /* ignorar */
  }
}
