import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "GitHub Treemap",
  description:
    "Interactive treemap of top GitHub repositories by language, stars, growth, and curated lists. Embedded from xiaoxiunique/1k-github-stars.",
};

// The treemap renders full-viewport with its own dark theme via Tailwind classes
// on the page wrapper, so this layout only supplies the route's <title> and
// passes children through. It does NOT redefine <html>/<body> (that's the root
// layout's job) and does NOT import the upstream globals.css (the light-theme
// webapp globals stay untouched — the components use inline/Tailwind colors).
export default function GhStarsLayout({
  children,
}: Readonly<{ children: React.ReactNode }>) {
  return <>{children}</>;
}
