// Estilo visual: piel elegida con data-style en <html>. Se recuerda en localStorage y se puede
// fijar por URL (?style=bauhaus-color). El CSS de cada uno está en styles/win95.css y styles/skins.css.

export const SKINS = [
  { id: "win95", name: "Windows 95", note: "Escritorio turquesa, ventanas con bisel", sw: ["#008080", "#c0c0c0", "#000080"] },
  { id: "neo-crema", name: "Neo-brutalismo crema", note: "Papel crema, amarillo, lila y sombras duras", sw: ["#fff3dc", "#ffd60a", "#b8a4ff", "#111111"] },
  { id: "neo-azul", name: "Neo-brutalismo azul", note: "Azul eléctrico, naranja y lima, sombras duras", sw: ["#2a47ff", "#ff7a1a", "#c9f31d", "#111111"] },
  { id: "albiceleste", name: "Albiceleste", note: "Camiseta y bandera: celeste, blanco y Sol de Mayo", sw: ["#7fb0e0", "#ffffff", "#f6b40e", "#16304f"] },
  { id: "el10", name: "El 10 (Qatar)", note: "Noche de gala: negro, dorado, celeste y dorsal enorme", sw: ["#0d0d10", "#d9b45a", "#7fb0e0"] },
  { id: "taxi", name: "Taxi porteño", note: "Negro y amarillo, cinta a cuadros, taxímetro", sw: ["#ffd60a", "#141414", "#ffb000"] },
  { id: "cuaderno", name: "Cuaderno", note: "Hoja rayada, margen rojo, resaltador y post-it", sw: ["#fbf8ee", "#e8403a", "#ffe94d", "#2c3a8c"] },
  { id: "ticket", name: "Ticket", note: "Ticket de caja térmico, monoespaciada", sw: ["#d5d4cf", "#fbfbf8", "#23252b"] },
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
