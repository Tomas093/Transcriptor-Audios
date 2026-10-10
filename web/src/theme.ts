// Estilo visual: piel elegida con data-style en <html>. Se recuerda en localStorage y se puede
// fijar por URL (?style=bauhaus-color). El CSS de cada uno está en styles/win95.css y styles/skins.css.

export const SKINS = [
  { id: "win95", name: "Windows 95", note: "Escritorio turquesa, ventanas con bisel", sw: ["#008080", "#c0c0c0", "#000080"] },
  { id: "neo-pop", name: "Neo-brutalismo pop", note: "Colores planos, sombras duras", sw: ["#b8f2e6", "#ff6fb5", "#ffd84d"] },
  { id: "neo-oscuro", name: "Neo-brutalismo oscuro", note: "Negro con sombras lima", sw: ["#14141b", "#c6ff3d", "#ff5fa2"] },
  { id: "bauhaus-color", name: "Bauhaus", note: "Círculo, cuadrado, triángulo", sw: ["#f2efe6", "#d62718", "#1d3fa8", "#f6c500"] },
  { id: "bauhaus-negro", name: "Bauhaus negro", note: "Geometría sobre negro", sw: ["#0e0e0e", "#d62718", "#f6c500", "#ffffff"] },
  { id: "swiss", name: "Swiss", note: "Tipografía grande, rejilla, un rojo", sw: ["#ffffff", "#111111", "#d62718"] },
  { id: "memphis", name: "Memphis", note: "Años 80: confeti, zigzags, sombras", sw: ["#f7d6e6", "#5b2bb5", "#37cfc4", "#ffe14d"] },
  { id: "periodico", name: "Periódico", note: "Papel de diario, serif, capitular", sw: ["#f3efe2", "#2b2620", "#8a3a2d"] },
  { id: "brutal-crudo", name: "Brutalismo crudo", note: "HTML pelado, serif, enlaces azules", sw: ["#ffffff", "#000000", "#0000ee"] },
  { id: "brutal-hormigon", name: "Brutalismo hormigón", note: "Cemento, negro, franjas de obra", sw: ["#b8b8b4", "#111111", "#ffd400"] },
] as const;

export type SkinId = (typeof SKINS)[number]["id"];

const KEY = "ts-style-v4";
const DEFAULT: SkinId = "win95";

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
  return DEFAULT;
}

export function applyStyle(style: SkinId, remember = true) {
  document.documentElement.dataset.style = style;
  if (!remember) return;
  try {
    localStorage.setItem(KEY, style);
  } catch {
    /* ignorar */
  }
}
