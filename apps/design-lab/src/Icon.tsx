import type { SVGProps } from "react";

export type IconName =
  | "add" | "back" | "collapse" | "discover" | "download" | "forward"
  | "library" | "more" | "next" | "pause" | "play" | "previous"
  | "queue" | "repeat" | "search" | "shuffle" | "volume";

const paths: Record<Exclude<IconName, "pause" | "play">, string> = {
  add: "M12 5v14M5 12h14",
  back: "m15 18-6-6 6-6",
  collapse: "m6 9 6 6 6-6",
  discover: "M3 11.5 12 4l9 7.5V20H7v-8h10v8M10 20v-5h4v5",
  download: "M12 3v12m-5-5 5 5 5-5M5 21h14",
  forward: "m9 18 6-6-6-6",
  library: "M4 5v14M9 5v14M14 7v12m5-14v14",
  more: "M5 12h.01M12 12h.01M19 12h.01",
  next: "m9 18 6-6-6-6M18 6v12",
  previous: "m15 18-6-6 6-6M6 6v12",
  queue: "M9 6h11M9 12h11M9 18h11M4 6h.01M4 12h.01M4 18h.01",
  repeat: "m17 2 4 4-4 4M3 11V9a3 3 0 0 1 3-3h15M7 22l-4-4 4-4m14-1v2a3 3 0 0 1-3 3H3",
  search: "m21 21-4.4-4.4M19 11a8 8 0 1 1-16 0 8 8 0 0 1 16 0Z",
  shuffle: "M16 3h5v5M4 20 21 3M21 16v5h-5M15 15l6 6M4 4l5 5",
  volume: "M11 5 6 9H3v6h3l5 4V5Zm4.5 4a4 4 0 0 1 0 6M18 6a8 8 0 0 1 0 12",
};

export function Icon({ name, ...props }: { name: IconName } & SVGProps<SVGSVGElement>) {
  return (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="square" strokeLinejoin="miter" aria-hidden="true" {...props}>
      {name === "play" ? <path d="m8 5 11 7-11 7V5Z" fill="currentColor" stroke="none" />
        : name === "pause" ? <><path d="M8 5v14M16 5v14" strokeWidth="3" /></>
        : <path d={paths[name]} />}
    </svg>
  );
}
