"use client";

import { useRef, forwardRef, useImperativeHandle } from "react";
import type { Repo } from "@/lib/treemap/types";

export interface TooltipHandle {
  show: (x: number, y: number, repo: Repo, interactive?: boolean) => void;
  hide: () => void;
}

interface TooltipProps {
  // Called when an interactive (touch) hint is tapped rather than dragged.
  onActivate?: (fullName: string) => void;
}

function escapeHtml(value: string) {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

export const Tooltip = forwardRef<TooltipHandle, TooltipProps>(function Tooltip({ onActivate }, ref) {
  const elRef = useRef<HTMLDivElement>(null);
  const repoRef = useRef<Repo | null>(null);
  // Active drag of the (touch) hint: corner offset from the finger, the start
  // point (to tell a tap from a drag), and the captured pointer id.
  const dragRef = useRef<{ offX: number; offY: number; startX: number; startY: number; moved: boolean; id: number } | null>(null);

  useImperativeHandle(ref, () => ({
    show(x, y, repo, interactive = false) {
      const el = elRef.current;
      if (!el) return;
      repoRef.current = repo;
      const name = repo.fullName.split("/")[1] || repo.fullName;
      const safeName = escapeHtml(name);
      const safeDescription = repo.description ? escapeHtml(repo.description) : "";

      el.innerHTML = `
        <div class="font-bold text-[15px]">${safeName}</div>
        ${safeDescription ? `<div class="mt-0.5 text-xs text-neutral-400 leading-relaxed">${safeDescription}</div>` : ""}
        ${interactive ? `<div class="mt-1.5 text-[11px] text-neutral-500">Tap to open · drag to move</div>` : ""}`;

      // Interactive (touch) hints receive pointer events so they can be tapped
      // or dragged; hover (mouse) hints stay click-through.
      el.style.pointerEvents = interactive ? "auto" : "none";
      el.style.touchAction = interactive ? "none" : "";
      el.style.cursor = interactive ? "grab" : "";

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
      repoRef.current = null;
    },
  }));

  const onPointerDown = (e: React.PointerEvent<HTMLDivElement>) => {
    const el = elRef.current;
    if (!el || el.style.pointerEvents !== "auto") return; // only when interactive
    e.stopPropagation();
    const rect = el.getBoundingClientRect();
    dragRef.current = {
      offX: e.clientX - rect.left,
      offY: e.clientY - rect.top,
      startX: e.clientX,
      startY: e.clientY,
      moved: false,
      id: e.pointerId,
    };
    el.setPointerCapture(e.pointerId);
  };

  const onPointerMove = (e: React.PointerEvent<HTMLDivElement>) => {
    const d = dragRef.current;
    const el = elRef.current;
    if (!d || !el) return;
    if (Math.hypot(e.clientX - d.startX, e.clientY - d.startY) > 6) d.moved = true;
    el.style.left = e.clientX - d.offX + "px";
    el.style.top = e.clientY - d.offY + "px";
  };

  const onPointerUp = () => {
    const d = dragRef.current;
    const el = elRef.current;
    if (!d || !el) return;
    el.releasePointerCapture(d.id);
    dragRef.current = null;
    // A press that didn't move is a tap → open the repo.
    if (!d.moved && repoRef.current) onActivate?.(repoRef.current.fullName);
  };

  return (
    <div
      ref={elRef}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={onPointerUp}
      className="fixed z-50 hidden max-w-[380px] bg-[rgba(10,10,10,0.92)] border border-white/10 rounded-xl px-4 py-3 backdrop-blur-2xl shadow-2xl"
    />
  );
});
