// Laboratorio de estilos (temporal): piel visual en vivo con data-style en <html>.
// Se recuerda en localStorage y se puede fijar por URL: ?style=poster

export const SKINS = [
  { id: "calma", name: "Calma", note: "El actual (referencia)", sw: ["#ffffff", "#a3195b"] },
  { id: "poster", name: "Póster suizo", note: "Tipografía gigante, naranja señal", sw: ["#ffffff", "#1a1a1a", "#ff5a1f"] },
  { id: "win95", name: "Windows 95", note: "Escritorio turquesa, ventanas", sw: ["#008080", "#c0c0c0", "#000080"] },
  { id: "riso", name: "Risografía", note: "Zine a dos tintas, tramas", sw: ["#fff7ec", "#ff3fa4", "#2a3cc4"] },
  { id: "hud", name: "HUD ciberpunk", note: "Esquinas cortadas, neón", sw: ["#0b0c14", "#f3ee2f", "#31e0f0"] },
  { id: "pixel", name: "Pixel 8-bit", note: "Game Boy, bloques", sw: ["#0f380f", "#306230", "#9bbc0f"] },
  { id: "aero", name: "Frutiger Aero", note: "Cielo, vidrio brillante, 2008", sw: ["#7ec8ff", "#e9fbff", "#8be36b"] },
  { id: "constructivismo", name: "Constructivismo", note: "Rojo, negro, diagonales", sw: ["#e8e6e1", "#141414", "#e0301e"] },
] as const;

export type SkinId = (typeof SKINS)[number]["id"];

const KEY = "ts-style-v2";

export function currentStyle(): SkinId {
  const valid: readonly string[] = SKINS.map((s) => s.id);
  try {
    const q = new URLSearchParams(location.search).get("style");
    if (q && valid.includes(q)) return q as SkinId;
    const v = localStorage.getItem(KEY);
    if (v && valid.includes(v)) return v as SkinId;
  } catch {
    /* sin almacenamiento: valor por defecto */
  }
  return "calma";
}

export function applyStyle(style: SkinId) {
  document.documentElement.dataset.style = style;
  try {
    localStorage.setItem(KEY, style);
  } catch {
    /* ignorar */
  }
}
