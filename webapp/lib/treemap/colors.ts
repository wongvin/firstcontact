export function lighten(hex: string, amount: number): string {
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  return `rgb(${Math.min(255, r + (255 - r) * amount) | 0},${Math.min(255, g + (255 - g) * amount) | 0},${Math.min(255, b + (255 - b) * amount) | 0})`;
}

export function darken(hex: string, amount: number): string {
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  return `rgb(${(r * amount) | 0},${(g * amount) | 0},${(b * amount) | 0})`;
}

export function contrastText(hex: string): string {
  const r = parseInt(hex.slice(1, 3), 16);
  const g = parseInt(hex.slice(3, 5), 16);
  const b = parseInt(hex.slice(5, 7), 16);
  const lum = (0.299 * r + 0.587 * g + 0.114 * b) / 255;
  return lum > 0.5 ? "rgba(0,0,0,0.85)" : "rgba(255,255,255,0.92)";
}

// Viridis sequential ramp (6 anchor stops, dark purple → bright yellow).
// Perceptually uniform and colorblind-safe. Used to color star-range tiers in
// the detail view — a webapp-side override of the per-language linguist color.
const VIRIDIS_STOPS = [
  "#440154",
  "#414487",
  "#2a788e",
  "#22a884",
  "#7ad151",
  "#fde725",
];

function lerpChannel(a: number, b: number, t: number): number {
  return Math.round(a + (b - a) * t);
}

// Sample the Viridis ramp at t ∈ [0,1] (0 = darkest, 1 = brightest). Returns hex.
export function viridis(t: number): string {
  const clamped = t <= 0 ? 0 : t >= 1 ? 1 : t;
  const span = VIRIDIS_STOPS.length - 1;
  const scaled = clamped * span;
  const i = Math.min(span - 1, Math.floor(scaled));
  const local = scaled - i;
  const from = VIRIDIS_STOPS[i];
  const to = VIRIDIS_STOPS[i + 1];
  const r = lerpChannel(parseInt(from.slice(1, 3), 16), parseInt(to.slice(1, 3), 16), local);
  const g = lerpChannel(parseInt(from.slice(3, 5), 16), parseInt(to.slice(3, 5), 16), local);
  const b = lerpChannel(parseInt(from.slice(5, 7), 16), parseInt(to.slice(5, 7), 16), local);
  return `#${[r, g, b].map((c) => c.toString(16).padStart(2, "0")).join("")}`;
}

// Color for a star-range tier. `rank` is the tier's index in the star-descending
// tier list (0 = highest-star tier), so the highest tier maps to the bright end.
export function tierColor(rank: number, count: number): string {
  const t = count <= 1 ? 1 : (count - 1 - rank) / (count - 1);
  return viridis(t);
}

export function fmtK(n: number): string {
  if (n >= 1e6) return (n / 1e6).toFixed(1) + "M";
  if (n >= 1e4) return (n / 1e3).toFixed(0) + "k";
  if (n >= 1e3) return (n / 1e3).toFixed(1) + "k";
  return String(n);
}
