"use client";

import { useCallback, useEffect, useRef, useState } from "react";
import { squarify } from "@/lib/treemap/squarify";
import { lighten, darken, contrastText, fmtK, tierColor } from "@/lib/treemap/colors";
import { getRepoValue } from "@/lib/treemap/metrics";
import { Header, type HeaderBreadcrumbItem, type TreemapView } from "./Header";
import { Panel, type PanelHandle } from "./Panel";
import { Tooltip, type TooltipHandle } from "./Tooltip";
import type { Repo, GroupData, Metric, RepoRect, GroupRect, Rect } from "@/lib/treemap/types";

type SquarifyRect = {
  rect?: Rect;
};

type GroupLayoutItem = SquarifyRect & {
  val: number;
  group: GroupData;
};

type TierGroup = {
  label: string;
  repos: Repo[];
  total: number;
};

type TierLayoutItem = SquarifyRect & {
  val: number;
  group: TierGroup;
};

type RepoLayoutItem = SquarifyRect & {
  val: number;
  repo: Repo | null;
  origIdx: number;
};

type RepoMeta = Pick<Repo, "createdAt" | "updatedAt">;

type RepoMetaIndex = Record<string, [string | null, string | null]>;

function matchesRepoSearch(repo: Repo, query: string, langName: string) {
  if (!query) return true;

  const normalizedLang = langName.toLowerCase();
  const normalizedDescription = repo.description.toLowerCase();

  return (
    repo.fullName.toLowerCase().includes(query) ||
    normalizedDescription.includes(query) ||
    normalizedLang.includes(query)
  );
}

// Dynamic tier computation based on data range
function computeDynamicTiers(
  minVal: number,
  maxVal: number,
  repos: Repo[],
  getVal: (r: Repo) => number
): { label: string; min: number; max: number }[] {
  // Standard boundaries to try
  const BOUNDARIES = [500000, 200000, 100000, 50000, 20000, 10000, 5000, 2000, 1000, 500, 200, 100, 0];
  const relevant = BOUNDARIES.filter(b => b >= minVal && b <= maxVal + 1);

  // Ensure we include minVal and maxVal+1
  if (!relevant.includes(maxVal + 1) && maxVal + 1 > (relevant[0] || 0)) relevant.unshift(maxVal + 1);
  if (relevant[relevant.length - 1] > minVal) relevant.push(minVal);

  // Dedupe and sort descending
  const bounds = [...new Set(relevant)].sort((a, b) => b - a);

  if (bounds.length < 2) {
    // Can't split meaningfully, force equal-count split
    return forceEqualSplit(repos, getVal, 5);
  }

  const tiers: { label: string; min: number; max: number }[] = [];
  for (let i = 0; i < bounds.length - 1; i++) {
    const max = bounds[i];
    const min = bounds[i + 1];
    const count = repos.filter(r => { const v = getVal(r); return v >= min && v < max; }).length;
    if (count > 0) {
      tiers.push({ label: `★ ${fmtK(min)}–${fmtK(max)}`, min, max });
    }
  }

  return tiers.length >= 2 ? tiers : forceEqualSplit(repos, getVal, 5);
}

function forceEqualSplit(
  repos: Repo[],
  getVal: (r: Repo) => number,
  chunks: number
): { label: string; min: number; max: number }[] {
  const sorted = [...repos].sort((a, b) => getVal(b) - getVal(a));
  const chunkSize = Math.ceil(sorted.length / chunks);
  const tiers: { label: string; min: number; max: number }[] = [];
  for (let i = 0; i < sorted.length; i += chunkSize) {
    const chunk = sorted.slice(i, i + chunkSize);
    const hi = getVal(chunk[0]);
    const lo = getVal(chunk[chunk.length - 1]);
    tiers.push({ label: `★ ${fmtK(lo)}–${fmtK(hi)}`, min: lo, max: hi + 1 });
  }
  return tiers;
}

const METRIC_OPTIONS: Record<Metric, { key: Metric; label: string }> = {
  stars: { key: "stars", label: "Stars" },
  growth: { key: "growth", label: "30d Growth" },
  forks: { key: "forks", label: "Forks" },
};

interface TreemapProps {
  mode: "overview" | "detail";
  groups?: GroupData[];
  detailGroup?: GroupData;
  total: number;
  tierLabel?: string;
  initialMetric?: Metric;
  availableMetrics?: Metric[];
  breadcrumbOverride?: HeaderBreadcrumbItem[];
  infoOverride?: string;
  fallbackMetric?: Metric;
  fallbackNotice?: {
    title: string;
    detail: string;
  };
  // Navigation is client-state driven (single /ghstars route, no router). The
  // parent owns view + lang/tier drill state and recomputes the props below.
  activeView: TreemapView;
  onViewChange: (v: TreemapView) => void;
  onOpenLang?: (langName: string) => void;
  onOpenTier?: (tierSlug: string) => void;
  onBackToOverview?: () => void;
  onBackToLang?: () => void;
}

export function Treemap({
  mode,
  groups,
  detailGroup,
  total,
  tierLabel,
  initialMetric = "stars",
  availableMetrics = ["stars", "growth", "forks"],
  breadcrumbOverride,
  infoOverride,
  fallbackMetric,
  fallbackNotice,
  activeView,
  onViewChange,
  onOpenLang,
  onOpenTier,
  onBackToOverview,
  onBackToLang,
}: TreemapProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const wrapRef = useRef<HTMLDivElement>(null);
  const panelRef = useRef<PanelHandle>(null);
  const tooltipRef = useRef<TooltipHandle>(null);

  const [metric, setMetric] = useState<Metric>(initialMetric);
  const [search, setSearch] = useState("");
  const [hasVisibleData, setHasVisibleData] = useState(true);
  const [fallbackActive, setFallbackActive] = useState(false);
  // Most-recently-hovered repo (+ its language label/color), surfaced in the
  // persistent bottom detail bar. Hover-driven (clicking a cell still opens
  // GitHub); persists after the cursor leaves the treemap until another repo
  // is hovered.
  const [detailRepo, setDetailRepo] =
    useState<{ repo: Repo; langName: string; langColor: string } | null>(null);
  const detailRepoNameRef = useRef<string | null>(null);

  const rectsRef = useRef<RepoRect[]>([]);
  const groupRectsRef = useRef<GroupRect[]>([]);
  const hoveredIdxRef = useRef(-1);
  const hoveredGroupRef = useRef(-1);
  // Touch: swallow the click iOS synthesizes after a tap (we handle taps in the
  // pointer handlers), plus the pointerdown position for tap-vs-drag detection.
  const suppressClickRef = useRef(false);
  const pointerDownPosRef = useRef<{ x: number; y: number } | null>(null);
  // Last pointer kind seen, so the synthesized mouse events iOS fires after a
  // tap don't drive the hover-only code paths.
  const lastPointerTypeRef = useRef<string>("mouse");
  const allReposRef = useRef<Repo[]>([]); // for detail panel
  const activeMetricRef = useRef<Metric>(initialMetric);
  const tooltipMetaCacheRef = useRef<Map<string, RepoMeta>>(new Map());
  const tooltipMetaIndexRequestRef = useRef<Promise<void> | null>(null);
  const searchReadyRef = useRef(false);

  const metricOptions = availableMetrics.map((metricKey) => METRIC_OPTIONS[metricKey]);

  const getMetricValue = useCallback((repo: Repo, metricKey: Metric) => getRepoValue(repo, metricKey), []);
  const formatMetricValue = useCallback((metricKey: Metric, value: number) => {
    if (metricKey === "growth") return `+${fmtK(value)}`;
    if (metricKey === "forks") return `⑂ ${fmtK(value)}`;
    return `★ ${fmtK(value)}`;
  }, []);
  const hideTooltip = useCallback(() => {
    tooltipRef.current?.hide();
  }, []);
  const ensureTooltipMetaIndex = useCallback(() => {
    if (tooltipMetaCacheRef.current.size > 0) {
      return Promise.resolve();
    }

    if (tooltipMetaIndexRequestRef.current) {
      return tooltipMetaIndexRequestRef.current;
    }

    // Hover metadata index lives on the upstream host (it's served from public/
    // there). Fetched lazily on first hover; the .catch below degrades silently.
    const request = fetch("https://github-treemap.pages.dev/repo-meta.json")
      .then(async (response) => {
        if (!response.ok) {
          throw new Error(`Failed to load repo meta index: ${response.status}`);
        }

        const payload = (await response.json()) as RepoMetaIndex;
        for (const [fullName, value] of Object.entries(payload)) {
          tooltipMetaCacheRef.current.set(fullName, {
            createdAt: value[0] ?? undefined,
            updatedAt: value[1] ?? undefined,
          });
        }
      })
      .catch(() => undefined)
      .finally(() => {
        tooltipMetaIndexRequestRef.current = null;
      });

    tooltipMetaIndexRequestRef.current = request;
    return request;
  }, []);
  const showRepoTooltip = useCallback(
    (x: number, y: number, repo: Repo, langName: string, langColor: string, floating = true, interactive = false) => {
      const cachedMeta = tooltipMetaCacheRef.current.get(repo.fullName);
      const tooltipRepo = cachedMeta ? { ...repo, ...cachedMeta } : repo;

      // Mirror into the persistent bottom bar, but only when the hovered repo
      // changes (this runs on every mousemove over the same cell).
      if (detailRepoNameRef.current !== repo.fullName) {
        detailRepoNameRef.current = repo.fullName;
        setDetailRepo({ repo: tooltipRepo, langName, langColor });
      }

      // On touch the floating hint is interactive (tap to open, drag to move it
      // off the tiles it covers); on hover it's a plain click-through tooltip.
      if (floating) tooltipRef.current?.show(x, y, tooltipRepo, interactive);

      if (cachedMeta) {
        return;
      }

      ensureTooltipMetaIndex().then(() => {
        const meta = tooltipMetaCacheRef.current.get(repo.fullName);
        if (!meta) return;

        // The tooltip only shows name + description (no meta), so nothing to
        // re-render there — just backfill the bottom bar's Created/Updated once
        // the meta index resolves, if it's still showing this repo.
        if (detailRepoNameRef.current === repo.fullName) {
          setDetailRepo({ repo: { ...repo, ...meta }, langName, langColor });
        }
      });
    },
    [ensureTooltipMetaIndex]
  );

  useEffect(() => {
    if (typeof window === "undefined") return;

    const syncSearchFromUrl = () => {
      const url = new URL(window.location.href);
      const query = url.searchParams.get("q") ?? "";
      setSearch(query);
      searchReadyRef.current = true;
    };

    syncSearchFromUrl();
    window.addEventListener("popstate", syncSearchFromUrl);

    return () => {
      window.removeEventListener("popstate", syncSearchFromUrl);
    };
  }, []);

  useEffect(() => {
    if (typeof window === "undefined" || !searchReadyRef.current) return;

    const url = new URL(window.location.href);
    const query = search.trim();

    if (query) {
      url.searchParams.set("q", query);
    } else {
      url.searchParams.delete("q");
    }

    const nextUrl = `${url.pathname}${url.search}${url.hash}`;
    const currentUrl = `${window.location.pathname}${window.location.search}${window.location.hash}`;

    if (nextUrl !== currentUrl) {
      window.history.replaceState(window.history.state, "", nextUrl);
    }
  }, [search]);

  // ── Compute layout ──
  const computeLayout = useCallback(() => {
    const canvas = canvasRef.current;
    const wrap = wrapRef.current;
    if (!canvas || !wrap) return;
    const dpr = devicePixelRatio || 1;
    const W = canvas.width / dpr;
    const H = canvas.height / dpr;
    const query = search.trim().toLowerCase();

    if (mode === "overview" && groups) {
      const searchedGroups = groups.map((g) => ({
        ...g,
        repos: query
          ? g.repos.filter((r) => matchesRepoSearch(r, query, g.lang))
          : g.repos,
      }));
      const hasSearchMatches = searchedGroups.some((g) => g.repos.length > 0);

      const buildGroupsForMetric = (metricKey: Metric) =>
        searchedGroups
          .map((g) => {
            const repos = [...g.repos]
              .filter((repo) => getMetricValue(repo, metricKey) > 0)
              .sort((a, b) => getMetricValue(b, metricKey) - getMetricValue(a, metricKey));
            const filteredTotal = repos.reduce((sum, repo) => sum + getMetricValue(repo, metricKey), 0);
            return { ...g, repos, total: filteredTotal, count: repos.length };
          })
          .filter((g) => g.total > 0)
          .sort((a, b) => b.total - a.total);

      let activeMetric = metric;
      let filtered = buildGroupsForMetric(metric);
      let shouldUseFallback = false;

      if (hasSearchMatches && filtered.length === 0 && fallbackMetric) {
        const fallbackGroups = buildGroupsForMetric(fallbackMetric);
        if (fallbackGroups.length > 0) {
          filtered = fallbackGroups;
          activeMetric = fallbackMetric;
          shouldUseFallback = true;
        }
      }

      activeMetricRef.current = activeMetric;
      setFallbackActive(shouldUseFallback);
      setHasVisibleData(hasSearchMatches && filtered.length > 0);

      if (!hasSearchMatches || filtered.length === 0) {
        groupRectsRef.current = [];
        rectsRef.current = [];
        return;
      }

      const gItems: GroupLayoutItem[] = filtered.map((g) => ({
        val: g.total,
        group: g,
      }));
      squarify(gItems, 0, 0, W, H);

      const newGroupRects: GroupRect[] = [];
      const newRects: RepoRect[] = [];

      for (const gi of gItems) {
        if (!gi.rect) continue;
        const g = gi.group;
        const GAP = 1.5;
        const HEADER_H = Math.min(22, Math.max(14, gi.rect.h * 0.06));

        newGroupRects.push({
          ...gi.rect,
          lang: g.lang,
          color: g.color,
          count: g.count,
          total: g.total,
          headerH: HEADER_H,
          allRepos: g.repos,
        });

        const ix = gi.rect.x + GAP;
        const iy = gi.rect.y + HEADER_H + GAP;
        const iw = gi.rect.w - GAP * 2;
        const ih = gi.rect.h - HEADER_H - GAP * 2;

        if (iw > 5 && ih > 5) {
          const TOP_N = Math.min(6, g.repos.length);
          const SMALL_MAX = 30;
          const totalShow = Math.min(g.repos.length, TOP_N + SMALL_MAX);
          const shown: RepoLayoutItem[] = g.repos.slice(0, totalShow).map((r, idx) => ({
            val: getMetricValue(r, activeMetric),
            repo: r,
            origIdx: idx,
          }));

          if (g.repos.length > totalShow) {
            const shownTotal = shown.reduce((s, it) => s + it.val, 0);
            shown.push({
              val: shownTotal * 0.15,
              repo: null,
              origIdx: -1,
            });
          }

          squarify(shown, ix, iy, iw, ih);
          for (let si = 0; si < shown.length; si++) {
            const it = shown[si];
            if (!it.rect) continue;
            const isOthers = it.origIdx === -1;
            newRects.push({
              ...it.rect,
              idx: isOthers ? -1 : it.origIdx,
              groupIdx: newGroupRects.length - 1,
              isOthers,
              othersCount: isOthers ? g.repos.length - totalShow : 0,
            });
          }
        }
      }
      groupRectsRef.current = newGroupRects;
      rectsRef.current = newRects;
    } else if (mode === "detail" && detailGroup) {
      const searchedRepos = query
        ? detailGroup.repos.filter((r) =>
            matchesRepoSearch(r, query, detailGroup.lang)
          )
        : detailGroup.repos;
      const buildReposForMetric = (metricKey: Metric) =>
        [...searchedRepos]
          .filter((repo) => getMetricValue(repo, metricKey) > 0)
          .sort((a, b) => getMetricValue(b, metricKey) - getMetricValue(a, metricKey));

      let activeMetric = metric;
      let sorted = buildReposForMetric(metric);
      let shouldUseFallback = false;

      if (searchedRepos.length > 0 && sorted.length === 0 && fallbackMetric) {
        const fallbackRepos = buildReposForMetric(fallbackMetric);
        if (fallbackRepos.length > 0) {
          sorted = fallbackRepos;
          activeMetric = fallbackMetric;
          shouldUseFallback = true;
        }
      }

      activeMetricRef.current = activeMetric;
      setFallbackActive(shouldUseFallback);
      allReposRef.current = sorted;
      setHasVisibleData(searchedRepos.length > 0 && sorted.length > 0);

      if (searchedRepos.length === 0 || sorted.length === 0) {
        rectsRef.current = [];
        groupRectsRef.current = [];
        return;
      }

      // If few enough repos, show flat (no grouping needed)
      const MAX_FLAT = 36;
      if (sorted.length <= MAX_FLAT) {
        // Flat layout — all repos as individual cells
        const shown: RepoLayoutItem[] = sorted.map((r, idx) => ({
          val: getMetricValue(r, activeMetric),
          repo: r,
          origIdx: idx,
        }));
        squarify(shown, 0, 0, W, H);
        const newRects: RepoRect[] = [];
        for (const it of shown) {
          if (it.rect) newRects.push({ ...it.rect, idx: it.origIdx });
        }
        rectsRef.current = newRects;
        groupRectsRef.current = [];
      } else {
        // Dynamic tier grouping based on actual data range
        const metricGetter = (repo: Repo) => getMetricValue(repo, activeMetric);
        const maxVal = metricGetter(sorted[0]);
        const minVal = metricGetter(sorted[sorted.length - 1]);
        const tiers = computeDynamicTiers(minVal, maxVal, sorted, metricGetter);

        const tierGroups: TierGroup[] = [];
        for (const tier of tiers) {
          const tierRepos = sorted.filter((r) => {
            const v = metricGetter(r);
            return v >= tier.min && v < tier.max;
          });
          if (tierRepos.length > 0) {
            tierGroups.push({
              label: tier.label,
              repos: tierRepos,
              total: tierRepos.reduce((sum, repo) => sum + metricGetter(repo), 0),
            });
          }
        }

        // If only 1 tier resulted (all repos in same range), bump up granularity
        if (tierGroups.length <= 1 && sorted.length > MAX_FLAT) {
          // Force split into ~5 equal-count groups
          const chunkSize = Math.ceil(sorted.length / 5);
          tierGroups.length = 0;
          for (let i = 0; i < sorted.length; i += chunkSize) {
            const chunk = sorted.slice(i, i + chunkSize);
            const hi = metricGetter(chunk[0]);
            const lo = metricGetter(chunk[chunk.length - 1]);
            tierGroups.push({
              label: `★ ${fmtK(lo)}–${fmtK(hi)}`,
              repos: chunk,
              total: chunk.reduce((sum, repo) => sum + metricGetter(repo), 0),
            });
          }
        }

      // Layout tier groups like overview groups
      const gItems: TierLayoutItem[] = tierGroups.map((g) => ({ val: g.total, group: g }));
      squarify(gItems, 0, 0, W, H);

      const newGroupRects: GroupRect[] = [];
      const newRects: RepoRect[] = [];

      for (let tierRank = 0; tierRank < gItems.length; tierRank++) {
        const gi = gItems[tierRank];
        if (!gi.rect) continue;
        const g = gi.group;
        // Webapp-side override: color each star-range tier by its rank along a
        // Viridis ramp (gItems is star-descending, so rank 0 = highest = bright).
        const color = tierColor(tierRank, gItems.length);
        const GAP = 1.5;
        const HEADER_H = Math.min(22, Math.max(14, gi.rect.h * 0.06));

        newGroupRects.push({
          ...gi.rect,
          lang: g.label,
          color,
          count: g.repos.length,
          total: g.total,
          headerH: HEADER_H,
          allRepos: g.repos,
        });

        const ix = gi.rect.x + GAP;
        const iy = gi.rect.y + HEADER_H + GAP;
        const iw = gi.rect.w - GAP * 2;
        const ih = gi.rect.h - HEADER_H - GAP * 2;

        if (iw > 5 && ih > 5) {
          const TOP_N = Math.min(6, g.repos.length);
          const SMALL_MAX = 30;
          const totalShow = Math.min(g.repos.length, TOP_N + SMALL_MAX);
          const shown: RepoLayoutItem[] = g.repos.slice(0, totalShow).map((r, idx) => ({
            val: metricGetter(r),
            repo: r,
            origIdx: idx,
          }));

          if (g.repos.length > totalShow) {
            const shownTotal = shown.reduce((s, it) => s + it.val, 0);
            shown.push({
              val: shownTotal * 0.15,
              repo: null,
              origIdx: -1,
            });
          }

          squarify(shown, ix, iy, iw, ih);
          for (let si = 0; si < shown.length; si++) {
            const it = shown[si];
            if (!it.rect) continue;
            const isOthers = it.origIdx === -1;
            newRects.push({
              ...it.rect,
              idx: isOthers ? -1 : it.origIdx,
              groupIdx: newGroupRects.length - 1,
              isOthers,
              othersCount: isOthers ? g.repos.length - totalShow : 0,
            });
          }
        }
      }

      rectsRef.current = newRects;
      groupRectsRef.current = newGroupRects;
      } // end else (grouped layout)
      allReposRef.current = sorted;
    }
  }, [mode, groups, detailGroup, metric, search, getMetricValue, fallbackMetric]);

  // ── Render ──
  const render = useCallback(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d")!;
    const dpr = devicePixelRatio || 1;
    const W = canvas.width / dpr;
    const H = canvas.height / dpr;
    const rects = rectsRef.current;
    const gRects = groupRectsRef.current;
    const hovIdx = hoveredIdxRef.current;
    const hovG = hoveredGroupRef.current;
    const activeMetric = activeMetricRef.current;

    ctx.save();
    ctx.scale(dpr, dpr);
    ctx.fillStyle = "#0c0c0c";
    ctx.fillRect(0, 0, W, H);

    if (mode === "overview") {
      // Group backgrounds
      for (let gi = 0; gi < gRects.length; gi++) {
        const g = gRects[gi];
        const isHov = gi === hovG;
        const GAP = 1.5;
        ctx.fillStyle = darken(g.color, 0.25);
        ctx.fillRect(g.x + GAP, g.y + GAP, g.w - GAP * 2, g.h - GAP * 2);
        ctx.strokeStyle = isHov ? g.color : "rgba(255,255,255,0.05)";
        ctx.lineWidth = isHov ? 2.5 : 1;
        ctx.strokeRect(g.x + GAP, g.y + GAP, g.w - GAP * 2, g.h - GAP * 2);
      }

      // Repo cells
      for (const r of rects) {
        if (r.isOthers || r.idx < 0) {
          const gi = gRects[r.groupIdx!];
          const color = gi?.color || "#888";
          ctx.fillStyle = darken(color, 0.4);
          ctx.fillRect(r.x + 0.5, r.y + 0.5, r.w - 1, r.h - 1);
          ctx.strokeStyle = "rgba(0,0,0,0.3)";
          ctx.lineWidth = 0.5;
          ctx.strokeRect(r.x + 0.5, r.y + 0.5, r.w - 1, r.h - 1);
          if (r.w > 40 && r.h > 14) {
            ctx.fillStyle = "rgba(255,255,255,0.3)";
            ctx.font = `400 ${Math.min(11, Math.max(8, r.h * 0.35))}px system-ui`;
            ctx.textBaseline = "middle";
            ctx.fillText(`+${(r.othersCount || 0).toLocaleString()} more`, r.x + 4, r.y + r.h / 2);
          }
          continue;
        }

        const gi = gRects[r.groupIdx!];
        const group = gi;
        const repo = group?.allRepos[r.idx];
        if (!repo) continue;
        const color = group?.color || "#888";
        const isHov = r.idx === hovIdx && r.groupIdx === hovG;

        ctx.fillStyle = isHov ? lighten(color, 0.35) : color;
        ctx.fillRect(r.x + 0.5, r.y + 0.5, r.w - 1, r.h - 1);
        ctx.strokeStyle = "rgba(0,0,0,0.35)";
        ctx.lineWidth = 0.5;
        ctx.strokeRect(r.x + 0.5, r.y + 0.5, r.w - 1, r.h - 1);
        if (isHov) {
          ctx.strokeStyle = "#fff";
          ctx.lineWidth = 2;
          ctx.strokeRect(r.x + 1, r.y + 1, r.w - 2, r.h - 2);
        }

        if (r.w > 32 && r.h > 14) {
          const name = repo.fullName.split("/")[1] || repo.fullName;
          const fs = Math.min(20, Math.max(7, Math.min(r.w / (name.length * 0.52), r.h * 0.42)));
          ctx.fillStyle = contrastText(color);
          ctx.font = `700 ${fs}px system-ui`;
          ctx.textBaseline = "middle";
          ctx.save();
          ctx.beginPath();
          ctx.rect(r.x + 2, r.y + 1, r.w - 4, r.h - 2);
          ctx.clip();
          if (r.h > 28 && fs >= 9) {
            ctx.fillText(name, r.x + 4, r.y + r.h * 0.36);
            ctx.font = `400 ${Math.max(7, fs * 0.6)}px system-ui`;
            ctx.globalAlpha = 0.55;
            ctx.fillText(formatMetricValue(activeMetric, getMetricValue(repo, activeMetric)), r.x + 4, r.y + r.h * 0.64);
            ctx.globalAlpha = 1;
          } else {
            ctx.fillText(name, r.x + 3, r.y + r.h / 2);
          }
          ctx.restore();
        }
      }

      // Group headers
      for (let gi = 0; gi < gRects.length; gi++) {
        const g = gRects[gi];
        if (g.w < 50 || g.h < 20) continue;
        const GAP = 1.5;
        const isHov = gi === hovG;
        ctx.fillStyle = darken(g.color, 0.5);
        ctx.fillRect(g.x + GAP, g.y + GAP, g.w - GAP * 2, g.headerH);
        const fs = Math.min(12, Math.max(8, g.headerH * 0.7));
        ctx.font = `700 ${fs}px system-ui`;
        ctx.fillStyle = isHov ? lighten(g.color, 0.3) : g.color;
        ctx.textBaseline = "middle";
        ctx.save();
        ctx.beginPath();
        ctx.rect(g.x + GAP, g.y + GAP, g.w - GAP * 2, g.headerH);
        ctx.clip();
        ctx.fillText(
          `${g.lang}  ${formatMetricValue(activeMetric, g.total)}  ${g.count.toLocaleString()}`,
          g.x + 6,
          g.y + GAP + g.headerH / 2
        );
        ctx.restore();
      }
    } else {
      // Detail view — same rendering as overview (tier groups + repo cells)
      // Group backgrounds
      for (let gi = 0; gi < gRects.length; gi++) {
        const g = gRects[gi];
        const isHov = gi === hovG;
        const GAP = 1.5;
        // Vary brightness per tier for visual depth
        const tierDarken = 0.2 + gi * 0.03;
        ctx.fillStyle = darken(g.color, tierDarken);
        ctx.fillRect(g.x + GAP, g.y + GAP, g.w - GAP * 2, g.h - GAP * 2);
        ctx.strokeStyle = isHov ? g.color : "rgba(255,255,255,0.05)";
        ctx.lineWidth = isHov ? 2.5 : 1;
        ctx.strokeRect(g.x + GAP, g.y + GAP, g.w - GAP * 2, g.h - GAP * 2);
      }

      // Repo cells
      for (const r of rects) {
        if (r.isOthers || r.idx < 0) {
          const gi = gRects[r.groupIdx!];
          const color = gi?.color || "#888";
          ctx.fillStyle = darken(color, 0.4);
          ctx.fillRect(r.x + 0.5, r.y + 0.5, r.w - 1, r.h - 1);
          ctx.strokeStyle = "rgba(0,0,0,0.3)";
          ctx.lineWidth = 0.5;
          ctx.strokeRect(r.x + 0.5, r.y + 0.5, r.w - 1, r.h - 1);
          if (r.w > 40 && r.h > 14) {
            ctx.fillStyle = "rgba(255,255,255,0.3)";
            ctx.font = `400 ${Math.min(11, Math.max(8, r.h * 0.35))}px system-ui`;
            ctx.textBaseline = "middle";
            ctx.fillText(`+${(r.othersCount || 0).toLocaleString()} more`, r.x + 4, r.y + r.h / 2);
          }
          continue;
        }

        const gi = gRects[r.groupIdx!];
        const repo = gi?.allRepos[r.idx];
        if (!repo) continue;
        const color = gi?.color || "#888";
        const isHov = r.idx === hovIdx && r.groupIdx === hovG;

        ctx.fillStyle = isHov ? lighten(color, 0.35) : color;
        ctx.fillRect(r.x + 0.5, r.y + 0.5, r.w - 1, r.h - 1);
        ctx.strokeStyle = "rgba(0,0,0,0.35)";
        ctx.lineWidth = 0.5;
        ctx.strokeRect(r.x + 0.5, r.y + 0.5, r.w - 1, r.h - 1);
        if (isHov) {
          ctx.strokeStyle = "#fff";
          ctx.lineWidth = 2;
          ctx.strokeRect(r.x + 1, r.y + 1, r.w - 2, r.h - 2);
        }

        if (r.w > 32 && r.h > 14) {
          const name = repo.fullName.split("/")[1] || repo.fullName;
          const fs = Math.min(20, Math.max(7, Math.min(r.w / (name.length * 0.52), r.h * 0.42)));
          ctx.fillStyle = contrastText(color);
          ctx.font = `700 ${fs}px system-ui`;
          ctx.textBaseline = "middle";
          ctx.save();
          ctx.beginPath();
          ctx.rect(r.x + 2, r.y + 1, r.w - 4, r.h - 2);
          ctx.clip();
          if (r.h > 28 && fs >= 9) {
            ctx.fillText(name, r.x + 4, r.y + r.h * 0.36);
            ctx.font = `400 ${Math.max(7, fs * 0.6)}px system-ui`;
            ctx.globalAlpha = 0.55;
            ctx.fillText(formatMetricValue(activeMetric, getMetricValue(repo, activeMetric)), r.x + 4, r.y + r.h * 0.64);
            ctx.globalAlpha = 1;
          } else {
            ctx.fillText(name, r.x + 3, r.y + r.h / 2);
          }
          ctx.restore();
        }
      }

      // Group headers (tier labels)
      for (let gi = 0; gi < gRects.length; gi++) {
        const g = gRects[gi];
        if (g.w < 50 || g.h < 20) continue;
        const GAP = 1.5;
        const isHov = gi === hovG;
        ctx.fillStyle = darken(g.color, 0.5);
        ctx.fillRect(g.x + GAP, g.y + GAP, g.w - GAP * 2, g.headerH);
        const fs = Math.min(12, Math.max(8, g.headerH * 0.7));
        ctx.font = `700 ${fs}px system-ui`;
        ctx.fillStyle = isHov ? lighten(g.color, 0.3) : g.color;
        ctx.textBaseline = "middle";
        ctx.save();
        ctx.beginPath();
        ctx.rect(g.x + GAP, g.y + GAP, g.w - GAP * 2, g.headerH);
        ctx.clip();
        ctx.fillText(
          `${g.lang}  ${formatMetricValue(activeMetric, g.total)}  ${g.count.toLocaleString()} repos`,
          g.x + 6,
          g.y + GAP + g.headerH / 2
        );
        ctx.restore();
      }
    }

    ctx.restore();
  }, [mode, formatMetricValue, getMetricValue]);

  // ── Resize ──
  const resize = useCallback(() => {
    const canvas = canvasRef.current;
    const wrap = wrapRef.current;
    if (!canvas || !wrap) return;
    const dpr = devicePixelRatio || 1;
    canvas.width = wrap.clientWidth * dpr;
    canvas.height = wrap.clientHeight * dpr;
    canvas.style.width = wrap.clientWidth + "px";
    canvas.style.height = wrap.clientHeight + "px";
    computeLayout();
    render();
  }, [computeLayout, render]);

  useEffect(() => {
    resize();
    const handler = () => resize();
    window.addEventListener("resize", handler);
    return () => window.removeEventListener("resize", handler);
  }, [resize]);

  useEffect(() => {
    // Recompute the canvas treemap layout when data/metric/search change. This
    // measures the live canvas (an external system) and derives visibility flags
    // from the result, so the setState inside computeLayout is intentional here.
    // eslint-disable-next-line react-hooks/set-state-in-effect
    computeLayout();
    render();
  }, [computeLayout, render]);

  // ── Hit tests ──
  const hitRepo = (mx: number, my: number) => {
    const rects = rectsRef.current;
    for (let i = rects.length - 1; i >= 0; i--) {
      const r = rects[i];
      if (r.isOthers) continue;
      if (mx >= r.x && mx < r.x + r.w && my >= r.y && my < r.y + r.h) return i;
    }
    return -1;
  };
  const hitOthers = (mx: number, my: number) => {
    const rects = rectsRef.current;
    for (let i = rects.length - 1; i >= 0; i--) {
      const r = rects[i];
      if (!r.isOthers) continue;
      if (mx >= r.x && mx < r.x + r.w && my >= r.y && my < r.y + r.h) return i;
    }
    return -1;
  };
  const hitGroup = (mx: number, my: number) => {
    const g = groupRectsRef.current;
    for (let i = g.length - 1; i >= 0; i--) {
      if (mx >= g[i].x && mx < g[i].x + g[i].w && my >= g[i].y && my < g[i].y + g[i].h) return i;
    }
    return -1;
  };
  const hitHeader = (mx: number, my: number) => {
    const g = groupRectsRef.current;
    for (let i = 0; i < g.length; i++) {
      if (mx >= g[i].x && mx < g[i].x + g[i].w && my >= g[i].y && my < g[i].y + g[i].headerH + 2) return i;
    }
    return -1;
  };

  // ── Mouse events ──
  const onMouseMove = useCallback(
    (e: React.MouseEvent) => {
      // Ignore the one-shot mousemove iOS synthesizes on tap — touch is driven
      // by the pointer handlers, which show an interactive hint instead.
      if (lastPointerTypeRef.current === "touch") return;
      const canvas = canvasRef.current;
      if (!canvas) return;
      const rect = canvas.getBoundingClientRect();
      const mx = e.clientX - rect.left;
      const my = e.clientY - rect.top;
      const gRects = groupRectsRef.current;

      let needRender = false;

      if (mode === "detail") {
        // Detail view uses same group-based layout now
        const repoHit = hitRepo(mx, my);
        if (repoHit >= 0) {
          const r = rectsRef.current[repoHit];
          const gi = gRects[r.groupIdx!];
          const repo = gi?.allRepos[r.idx];
          if (hoveredIdxRef.current !== r.idx || hoveredGroupRef.current !== r.groupIdx!) {
            hoveredIdxRef.current = r.idx;
            hoveredGroupRef.current = r.groupIdx!;
            needRender = true;
          }
          if (repo) showRepoTooltip(e.clientX, e.clientY, repo, detailGroup!.lang, detailGroup!.color);
          panelRef.current?.hide();
          canvas.style.cursor = "pointer";
        } else {
          if (hoveredIdxRef.current !== -1) { hoveredIdxRef.current = -1; needRender = true; }
          hideTooltip();
          const oHit = hitOthers(mx, my);
          if (oHit >= 0) {
            const r = rectsRef.current[oHit];
            const gi = gRects[r.groupIdx!];
            if (hoveredGroupRef.current !== r.groupIdx!) { hoveredGroupRef.current = r.groupIdx!; needRender = true; }
            const TOP_N = 6, SMALL_MAX = 30;
            const skipCount = Math.min(gi.allRepos.length, TOP_N + SMALL_MAX);
            const hidden = gi.allRepos.slice(skipCount);
            panelRef.current?.show(e.clientX, e.clientY, {
              title: `${gi.lang} — more repos`,
              subtitle: `${hidden.length.toLocaleString()} repos not shown`,
              color: gi.color,
              repos: hidden,
              startRank: skipCount + 1,
            });
            canvas.style.cursor = "pointer";
          } else {
            if (hoveredGroupRef.current !== -1) { hoveredGroupRef.current = -1; needRender = true; }
            panelRef.current?.hide();
            canvas.style.cursor = "default";
          }
        }
      } else {
        const hdrHit = hitHeader(mx, my);
        const repoHit = hdrHit < 0 ? hitRepo(mx, my) : -1;

        if (repoHit >= 0) {
          const r = rectsRef.current[repoHit];
          const gi = gRects[r.groupIdx!];
          const repo = gi?.allRepos[r.idx];
          if (hoveredIdxRef.current !== r.idx || hoveredGroupRef.current !== r.groupIdx!) {
            hoveredIdxRef.current = r.idx;
            hoveredGroupRef.current = r.groupIdx!;
            needRender = true;
          }
          if (repo) showRepoTooltip(e.clientX, e.clientY, repo, gi.lang, gi.color);
          panelRef.current?.hide();
          canvas.style.cursor = "pointer";
        } else if (hdrHit >= 0) {
          if (hoveredIdxRef.current !== -1) { hoveredIdxRef.current = -1; needRender = true; }
          if (hoveredGroupRef.current !== hdrHit) { hoveredGroupRef.current = hdrHit; needRender = true; }
          hideTooltip();
          panelRef.current?.hide();
          canvas.style.cursor = "pointer";
        } else {
          if (hoveredIdxRef.current !== -1) { hoveredIdxRef.current = -1; needRender = true; }
          hideTooltip();
          const oHit = hitOthers(mx, my);
          if (oHit >= 0) {
            const r = rectsRef.current[oHit];
            const gi = gRects[r.groupIdx!];
            if (hoveredGroupRef.current !== r.groupIdx!) { hoveredGroupRef.current = r.groupIdx!; needRender = true; }
            const TOP_N = 6, SMALL_MAX = 30;
            const skipCount = Math.min(gi.allRepos.length, TOP_N + SMALL_MAX);
            const hidden = gi.allRepos.slice(skipCount);
            panelRef.current?.show(e.clientX, e.clientY, {
              title: `${gi.lang} — more repos`,
              subtitle: `${hidden.length.toLocaleString()} repos not shown`,
              color: gi.color,
              repos: hidden,
              startRank: skipCount + 1,
            });
            canvas.style.cursor = "pointer";
          } else {
            if (hoveredGroupRef.current !== -1) { hoveredGroupRef.current = -1; needRender = true; }
            panelRef.current?.hide();
            canvas.style.cursor = "default";
          }
        }
      }

      if (needRender) render();
    },
    [detailGroup, hideTooltip, mode, render, showRepoTooltip]
  );

  const onMouseLeave = useCallback(() => {
    // Don't let a synthesized mouseleave tear down a touch reveal.
    if (lastPointerTypeRef.current === "touch") return;
    hoveredIdxRef.current = -1;
    hoveredGroupRef.current = -1;
    hideTooltip();
    panelRef.current?.hide();
    if (canvasRef.current) canvasRef.current.style.cursor = "default";
    render();
  }, [hideTooltip, render]);

  // Open the hit repo on GitHub, or drill into a tapped header/group/"more"
  // cell. Shared by mouse clicks and the second tap of a touch interaction.
  const openOrNavigate = useCallback(
    (mx: number, my: number) => {
      if (mode === "detail") {
        // Header click → navigate to sub-tier
        const hdrHit = hitHeader(mx, my);
        if (hdrHit >= 0) {
          const g = groupRectsRef.current[hdrHit];
          // g.lang is the tier label like "★ 5k–10k", extract slug from allRepos range
          if (g.allRepos.length > 36) {
            const maxVal = Math.max(...g.allRepos.map(r => r.stars));
            const minVal = Math.min(...g.allRepos.map(r => r.stars));
            const slug = `${minVal}-${maxVal + 1}`;
            onOpenTier?.(slug);
          }
          return;
        }
        // Repo click → open GitHub
        const hit = hitRepo(mx, my);
        if (hit >= 0) {
          const r = rectsRef.current[hit];
          const gi = groupRectsRef.current[r.groupIdx!];
          const repo = gi?.allRepos[r.idx];
          if (repo) window.open(`https://github.com/${repo.fullName}`, "_blank");
          return;
        }
        // "More" click → navigate to sub-tier
        const oHit = hitOthers(mx, my);
        if (oHit >= 0) {
          const r = rectsRef.current[oHit];
          const gi = groupRectsRef.current[r.groupIdx!];
          if (gi.allRepos.length > 36) {
            const maxVal = Math.max(...gi.allRepos.map(r => r.stars));
            const minVal = Math.min(...gi.allRepos.map(r => r.stars));
            const slug = `${minVal}-${maxVal + 1}`;
            onOpenTier?.(slug);
          }
        }
      } else {
        const hdrHit = hitHeader(mx, my);
        if (hdrHit >= 0) {
          const g = groupRectsRef.current[hdrHit];
          onOpenLang?.(g.lang);
          return;
        }
        const repoHit = hitRepo(mx, my);
        if (repoHit >= 0) {
          const r = rectsRef.current[repoHit];
          const gi = groupRectsRef.current[r.groupIdx!];
          const repo = gi?.allRepos[r.idx];
          if (repo) window.open(`https://github.com/${repo.fullName}`, "_blank");
          return;
        }
        const gh = hitGroup(mx, my);
        if (gh >= 0) {
          const g = groupRectsRef.current[gh];
          onOpenLang?.(g.lang);
        }
      }
    },
    [mode, onOpenLang, onOpenTier]
  );

  const onClick = useCallback(
    (e: React.MouseEvent) => {
      // iOS fires a synthetic click after a tap; the pointer handlers already
      // dealt with it, so swallow this one.
      if (suppressClickRef.current) {
        suppressClickRef.current = false;
        return;
      }
      const canvas = canvasRef.current;
      if (!canvas) return;
      const rect = canvas.getBoundingClientRect();
      openOrNavigate(e.clientX - rect.left, e.clientY - rect.top);
    },
    [openOrNavigate]
  );

  // ── Touch events ──
  // No hover on touch, so a tap reveals the tile's hint in the bottom detail
  // bar (two-stage: tap to reveal, tap the same tile again to open on GitHub).
  // Gated on pointerType so mouse behaviour above is untouched.
  const onPointerDown = useCallback((e: React.PointerEvent) => {
    lastPointerTypeRef.current = e.pointerType;
    if (e.pointerType === "mouse") return;
    suppressClickRef.current = false;
    pointerDownPosRef.current = { x: e.clientX, y: e.clientY };
  }, []);

  const onPointerUp = useCallback(
    (e: React.PointerEvent) => {
      lastPointerTypeRef.current = e.pointerType;
      if (e.pointerType === "mouse") return;
      const canvas = canvasRef.current;
      if (!canvas) return;

      // Treat a moved finger as a scroll/drag, not a tap.
      const down = pointerDownPosRef.current;
      pointerDownPosRef.current = null;
      if (down && Math.hypot(e.clientX - down.x, e.clientY - down.y) > 10) return;

      // We handle the tap here; suppress the click iOS synthesizes next.
      suppressClickRef.current = true;

      const rect = canvas.getBoundingClientRect();
      const mx = e.clientX - rect.left;
      const my = e.clientY - rect.top;
      const gRects = groupRectsRef.current;

      const hdrHit = hitHeader(mx, my);
      const repoHit = hdrHit < 0 ? hitRepo(mx, my) : -1;

      if (repoHit >= 0) {
        const r = rectsRef.current[repoHit];
        const gi = gRects[r.groupIdx!];
        const repo = gi?.allRepos[r.idx];
        if (!repo) return;
        if (detailRepoNameRef.current === repo.fullName) {
          // Second tap on the already-revealed tile → open it.
          window.open(`https://github.com/${repo.fullName}`, "_blank");
          return;
        }
        // First tap → reveal hint (interactive floating hint + detail bar) and
        // highlight the tile.
        hoveredIdxRef.current = r.idx;
        hoveredGroupRef.current = r.groupIdx!;
        panelRef.current?.hide();
        showRepoTooltip(e.clientX, e.clientY, repo, gi.lang, gi.color, true, true);
        render();
        return;
      }

      // Tapping a header / group / "more" cell navigates, same as a click.
      if (hdrHit >= 0 || hitOthers(mx, my) >= 0 || hitGroup(mx, my) >= 0) {
        openOrNavigate(mx, my);
        return;
      }

      // Tap on empty space → dismiss the current selection.
      if (detailRepoNameRef.current !== null) {
        detailRepoNameRef.current = null;
        hoveredIdxRef.current = -1;
        hoveredGroupRef.current = -1;
        setDetailRepo(null);
        hideTooltip();
        render();
      }
    },
    [hideTooltip, openOrNavigate, render, showRepoTooltip]
  );

  const breadcrumb: HeaderBreadcrumbItem[] =
    breadcrumbOverride ??
    (mode === "overview"
      ? [{ label: "All Languages" }]
      : tierLabel
        ? [
            { label: "All Languages", onClick: onBackToOverview },
            { label: detailGroup!.lang, onClick: onBackToLang, color: detailGroup!.color },
            { label: tierLabel },
          ]
        : [
            { label: "All Languages", onClick: onBackToOverview },
            { label: detailGroup!.lang, color: detailGroup!.color },
          ]);

  const info =
    infoOverride ??
    (mode === "overview"
      ? `${total.toLocaleString()} repos · ${groups?.length || 0} languages`
      : `${detailGroup!.repos.length.toLocaleString()} ${detailGroup!.lang} repos`);

  const emptyMessage = search
    ? `No repositories match "${search}"`
    : metric === "growth"
      ? "No positive 30d growth data in the current dataset"
      : "No repositories available for this view";

  return (
    <>
      <Header
        breadcrumb={breadcrumb}
        metric={metric}
        onMetricChange={setMetric}
        search={search}
        onSearchChange={setSearch}
        info={info}
        metrics={metricOptions}
        activeView={activeView}
        onViewChange={onViewChange}
      />
      <div ref={wrapRef} className="flex-1 relative overflow-hidden">
        <canvas
          ref={canvasRef}
          onMouseMove={onMouseMove}
          onMouseLeave={onMouseLeave}
          onClick={onClick}
          onPointerDown={onPointerDown}
          onPointerUp={onPointerUp}
          className="block w-full h-full"
          style={{ touchAction: "manipulation" }}
        />
        {fallbackActive && fallbackNotice && (
          <div className="absolute left-4 top-4 z-10 max-w-md rounded-2xl border border-[#2b3e45] bg-[rgba(12,12,12,0.88)] px-4 py-3 shadow-2xl backdrop-blur-xl">
            <div className="text-xs uppercase tracking-[0.22em] text-cyan-300/80">Fallback View</div>
            <div className="mt-1 text-sm font-semibold text-white">{fallbackNotice.title}</div>
            <div className="mt-1 text-xs leading-5 text-neutral-400">{fallbackNotice.detail}</div>
          </div>
        )}
        {!hasVisibleData && (
          <div className="absolute inset-0 flex items-center justify-center px-6 text-center pointer-events-none">
            <div className="max-w-md rounded-2xl border border-white/10 bg-black/40 px-5 py-4 backdrop-blur-md">
              <div className="text-base font-semibold text-white">{emptyMessage}</div>
              <div className="mt-1 text-sm text-neutral-400">
                {metric === "growth"
                  ? "Try Stars or Forks, or refresh the dataset with real 30d growth values."
                  : "Try a different metric or search keyword."}
              </div>
            </div>
          </div>
        )}
      </div>
      <RepoDetailBar detail={detailRepo} />
      <Panel ref={panelRef} />
      <Tooltip
        ref={tooltipRef}
        onActivate={(fullName) => window.open(`https://github.com/${fullName}`, "_blank")}
      />
    </>
  );
}

function formatBarDate(value?: string) {
  if (!value) return "—";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "—";
  return date.toISOString().slice(0, 10);
}

// Persistent detail bar pinned to the bottom of the treemap. Hover-driven: it
// mirrors the hover tooltip's fields (name / owner / description plus language,
// stars, forks, growth, created, updated) and keeps the last repo visible after
// the cursor leaves the canvas. Fixed height so the canvas layout above stays
// stable; the stats sit in fixed-width slots so they hold the same position on
// the first line as you move between repos.
function RepoDetailBar({
  detail,
}: {
  detail: { repo: Repo; langName: string; langColor: string } | null;
}) {
  if (!detail) {
    return (
      <div className="h-20 shrink-0 border-t border-white/10 bg-[#0c0c0c] px-4 py-2.5">
        <div className="flex h-full items-center text-xs text-neutral-500">
          Hover a repo to see its details
        </div>
      </div>
    );
  }

  const { repo, langName, langColor } = detail;
  const [owner, name] = repo.fullName.split("/");

  return (
    <div className="h-20 shrink-0 border-t border-white/10 bg-[#0c0c0c] px-4 py-2.5">
      <div className="flex h-full flex-col">
        <div className="flex items-baseline gap-4">
          {/* Name + owner: flexible, truncates so the stats stay put. */}
          <div className="flex min-w-0 flex-1 items-baseline gap-2">
            <span className="truncate text-sm font-bold text-white">{name || repo.fullName}</span>
            {owner && name && (
              <span className="shrink-0 text-xs text-neutral-500">{owner}</span>
            )}
          </div>
          {/* Fixed-width stat slots — same x-position across repos. */}
          <div className="flex shrink-0 items-baseline gap-4 text-xs text-neutral-400">
            <span className="flex w-32 items-center gap-1">
              <span
                className="inline-block h-2 w-2 shrink-0 rounded-full"
                style={{ background: langColor }}
              />
              <span className="truncate">{langName}</span>
            </span>
            <span className="w-16 shrink-0">★ {fmtK(repo.stars)}</span>
            <span className="w-16 shrink-0">⑂ {fmtK(repo.forks)}</span>
            <span className="w-24 shrink-0">
              <span className="text-neutral-500">Growth </span>
              {repo.growth > 0 ? (
                <span className="text-green-400">+{fmtK(repo.growth)}</span>
              ) : (
                "—"
              )}
            </span>
            <span className="w-36 shrink-0">
              <span className="text-neutral-500">Created </span>
              {formatBarDate(repo.createdAt)}
            </span>
            <span className="w-36 shrink-0">
              <span className="text-neutral-500">Updated </span>
              {formatBarDate(repo.updatedAt)}
            </span>
          </div>
        </div>
        {repo.description && (
          <div className="mt-1 line-clamp-2 text-xs leading-relaxed text-neutral-400">
            {repo.description}
          </div>
        )}
      </div>
    </div>
  );
}
