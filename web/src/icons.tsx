import type { SVGProps } from "react";

const paths = {
  plus: "M12 5v14M5 12h14",
  trash: "M4 7h16M10 11v6M14 11v6M6 7l1 12a2 2 0 0 0 2 2h6a2 2 0 0 0 2-2l1-12M9 7V4h6v3",
  copy: "M9 9h10v10H9zM5 15V5h10",
  check: "M5 12.5l4.5 4.5L19 7.5",
  download: "M12 4v11M7.5 10.5L12 15l4.5-4.5M5 20h14",
  menu: "M4 7h16M4 12h16M4 17h16",
  retry: "M20 12a8 8 0 1 1-2.6-5.9M20 4v5h-5",
  sparkle: "M12 3l1.9 5.6L19.5 10l-5.6 1.9L12 17.5l-1.9-5.6L4.5 10l5.6-1.4zM19 16l.8 2.2L22 19l-2.2.8L19 22l-.8-2.2L16 19l2.2-.8z",
  close: "M6 6l12 12M18 6L6 18",
  alert: "M12 8v5M12 16.5v.5M10.3 4.2L2.8 17.5A2 2 0 0 0 4.5 20.5h15a2 2 0 0 0 1.7-3L13.7 4.2a2 2 0 0 0-3.4 0z",
} as const;

export type IconName = keyof typeof paths;

export function Icon({ name, size = 16, ...rest }: { name: IconName; size?: number } & SVGProps<SVGSVGElement>) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
      {...rest}
    >
      <path d={paths[name]} />
    </svg>
  );
}

/** Marca de la app: cuatro barras de voz. */
export function Logo({ size = 22 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 32 32" aria-hidden="true" focusable="false">
      <rect width="32" height="32" rx="8" fill="var(--primary)" />
      <g fill="var(--on-primary)">
        <rect x="7" y="13" width="3.2" height="6" rx="1.6" />
        <rect x="12.4" y="9" width="3.2" height="14" rx="1.6" />
        <rect x="17.8" y="5.5" width="3.2" height="21" rx="1.6" />
        <rect x="23.2" y="11" width="3.2" height="10" rx="1.6" />
      </g>
    </svg>
  );
}
