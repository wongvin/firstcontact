"use client";

import { useRef, forwardRef, useImperativeHandle } from "react";
import type { Repo } from "@/lib/treemap/types";

export interface TooltipHandle {
  show: (x: number, y: number, repo: Repo) => void;
  hide: () => void;
}

function escapeHtml(value: string) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

export const Tooltip = forwardRef<TooltipHandle>(function Tooltip(_, ref) {
  const elRef = useRef<HTMLDivElement>(null);

  useImperativeHandle(ref, () => ({
    show(x, y, repo) {
      const el = elRef.current;
      if (!el) return;
      const name = repo.fullName.split("/")[1] || repo.fullName;
      const safeName = escapeHtml(name);
      const safeDescription = repo.description ? escapeHtml(repo.description) : "";

      el.innerHTML = `
        <div class="font-bold text-[15px]">${safeName}</div>
        ${safeDescription ? `<div class="mt-0.5 text-xs text-neutral-400 leading-relaxed">${safeDescription}</div>` : ""}`;

      el.style.display = "block";
      let tx = x + 16,
        ty = y + 16;
      if (tx + 380 > window.innerWidth) tx = x - 390;
      const height = el.offsetHeight || 80;
      if (ty + height > window.innerHeight) ty = y - height - 16;
      el.style.left = tx + "px";
      el.style.top = ty + "px";
    },
    hide() {
      if (elRef.current) elRef.current.style.display = "none";
    },
  }));

  return (
    <div
      ref={elRef}
      className="fixed z-50 hidden pointer-events-none max-w-[380px] bg-[rgba(10,10,10,0.92)] border border-white/10 rounded-xl px-4 py-3 backdrop-blur-2xl shadow-2xl"
    />
  );
});
