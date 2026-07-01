"use client";

import { useRef, forwardRef, useImperativeHandle } from "react";
import type { Repo } from "@/lib/treemap/types";

// Half of the screen to keep the hint out of (the half the README panel
// occupies), or null when no panel is open.
type AvoidSide = "left" | "right" | null;

export interface TooltipHandle {
  show: (x: number, y: number, repo: Repo, metricLabel: string, interactive?: boolean, avoid?: AvoidSide) => void;
  hide: () => void;
  // Slide the currently-shown hint horizontally out of `avoid`'s half.
  nudgeIntoHalf: (avoid: AvoidSide) => void;
}

interface TooltipProps {
  // Called when an interactive (touch) hint is tapped rather than dragged;
  // `x` is the hint's center, used to pick which side the panel opens on.
  onActivate?: (fullName: string, x: number) => void;
}

// Clamp a left coordinate so a `width`-wide box stays in the half NOT covered
// by `avoid`.
function clampLeft(left: number, width: number, avoid: AvoidSide) {
  const half = window.innerWidth / 2;
  if (avoid === "right") return Math.max(8, Math.min(left, half - width - 12));
  if (avoid === "left") return Math.min(window.innerWidth - width - 8, Math.max(left, half + 12));
  return left;
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
    show(x, y, repo, metricLabel, interactive = false, avoid = null) {
      const el = elRef.current;
      if (!el) return;
      repoRef.current = repo;
      const name = repo.fullName.split("/")[1] || repo.fullName;
      const safeName = escapeHtml(name);
      const safeMetric = metricLabel ? escapeHtml(metricLabel) : "";
      const safeDescription = repo.description ? escapeHtml(repo.description) : "";

      el.innerHTML = `
        <div class="font-bold text-[15px]">${safeName}${safeMetric ? ` <span class="font-normal text-neutral-400">${safeMetric}</span>` : ""}</div>
        ${safeDescription ? `<div class="mt-0.5 text-xs text-neutral-400 leading-relaxed">${safeDescription}</div>` : ""}
        ${interactive ? `<div class="mt-1.5 text-[11px] text-neutral-500">Drag to move</div>` : ""}`;

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
      tx = clampLeft(tx, el.offsetWidth || 380, avoid);
      el.style.left = tx + "px";
      el.style.top = ty + "px";
    },
    hide() {
      if (elRef.current) elRef.current.style.display = "none";
      repoRef.current = null;
    },
    nudgeIntoHalf(avoid) {
      const el = elRef.current;
      if (!el || el.style.display === "none") return;
      const left = parseFloat(el.style.left) || 0;
      el.style.left = clampLeft(left, el.offsetWidth || 380, avoid) + "px";
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
    // A press that didn't move is a tap → open the repo. Pass the hint's center
    // x so the panel can open on the opposite half.
    if (!d.moved && repoRef.current) {
      const rect = el.getBoundingClientRect();
      onActivate?.(repoRef.current.fullName, rect.left + rect.width / 2);
    }
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
