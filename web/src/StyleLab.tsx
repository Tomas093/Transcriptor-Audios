import { useEffect, useRef, useState } from "react";
import { Icon } from "./icons";
import { applyTheme, currentTheme, LAYOUTS, SKINS, type LayoutId, type SkinId } from "./theme";

/** Botón flotante para probar estilos y estructuras en vivo. Es temporal: se quita al elegir. */
export function StyleLab() {
  const [open, setOpen] = useState(false);
  const [{ style, layout }, setTheme] = useState(currentTheme);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => applyTheme(style, layout), [style, layout]);

  useEffect(() => {
    if (!open) return;
    const away = (e: MouseEvent) => ref.current && !ref.current.contains(e.target as Node) && setOpen(false);
    const esc = (e: KeyboardEvent) => e.key === "Escape" && setOpen(false);
    window.addEventListener("mousedown", away);
    window.addEventListener("keydown", esc);
    return () => {
      window.removeEventListener("mousedown", away);
      window.removeEventListener("keydown", esc);
    };
  }, [open]);

  return (
    <div className="lab" ref={ref}>
      {open && (
        <div className="lab-panel" role="dialog" aria-label="Laboratorio de estilos">
          <p className="lab-title">Estilo</p>
          <div className="lab-skins">
            {SKINS.map((s) => (
              <button
                key={s.id}
                type="button"
                className={`lab-skin ${s.id === style ? "on" : ""}`}
                aria-pressed={s.id === style}
                onClick={() => setTheme((t) => ({ ...t, style: s.id as SkinId }))}
              >
                <span className="lab-sw" aria-hidden="true">
                  {s.sw.map((c) => (
                    <i key={c} style={{ background: c }} />
                  ))}
                </span>
                <span className="lab-name">{s.name}</span>
                <span className="lab-note">{s.note}</span>
              </button>
            ))}
          </div>
          <p className="lab-title">Estructura</p>
          <div className="lab-layouts">
            {LAYOUTS.map((l) => (
              <button
                key={l.id}
                type="button"
                className={`lab-layout ${l.id === layout ? "on" : ""}`}
                aria-pressed={l.id === layout}
                title={l.note}
                onClick={() => setTheme((t) => ({ ...t, layout: l.id as LayoutId }))}
              >
                {l.name}
              </button>
            ))}
          </div>
          <p className="lab-hint">Se recuerda tu elección. Dime cuál te gusta y dejo solo esa.</p>
        </div>
      )}
      <button type="button" className="lab-btn" aria-expanded={open} onClick={() => setOpen((o) => !o)}>
        <Icon name="palette" size={16} /> Estilos
      </button>
    </div>
  );
}
