import { useEffect, useRef, useState } from "react";
import { Icon } from "./icons";
import { applyStyle, currentStyle, SKINS, type SkinId } from "./theme";

/** Botón flotante para probar estilos en vivo. Es temporal: se quita al elegir uno. */
export function StyleLab() {
  const [open, setOpen] = useState(false);
  const [style, setStyle] = useState<SkinId>(currentStyle);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => applyStyle(style), [style]);

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
                onClick={() => setStyle(s.id)}
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
          <p className="lab-hint">Se recuerda tu elección. Dime cuál te gusta y dejo solo esa.</p>
        </div>
      )}
      <button type="button" className="lab-btn" aria-expanded={open} onClick={() => setOpen((o) => !o)}>
        <Icon name="palette" size={16} /> Estilos
      </button>
    </div>
  );
}
