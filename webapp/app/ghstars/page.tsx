"use client";

import { useEffect, useMemo, useState } from "react";
import { Treemap } from "@/components/treemap/Treemap";
import { ForksTreemap } from "./ForksTreemap";
import type { TreemapView } from "@/components/treemap/Header";
import {
  DAILY_TRENDING_MIN_BASELINE_STARS,
  DAILY_TRENDING_MIN_REPO_AGE_DAYS,
  getCuratedGroups,
  getCuratedTotal,
  getDailyTrendingData,
  getExportedAt,
  getGroups,
  getTotal,
} from "@/lib/treemap/data";
import { filterReposByTier, parseTierSlug } from "@/lib/treemap/tiers";
import type { GroupData, Metric, RepoData } from "@/lib/treemap/types";

// Dataset is fetched at runtime from public/treemap-data/ (gitignored — present
// in `npm run dev`, absent on Vercel where this 404s into the empty state).
const DATA_URL = "/treemap-data/repos.json";

type LoadState =
  | { status: "loading" }
  | { status: "error" }
  | { status: "ready"; data: RepoData };

function formatExportedAt(value: string) {
  return new Intl.DateTimeFormat("en-US", {
    month: "short",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
    timeZone: "UTC",
  }).format(new Date(value));
}

function formatBaseThreshold(value: number) {
  if (value >= 1000) {
    const compact = value / 1000;
    return Number.isInteger(compact) ? `${compact}k` : `${compact.toFixed(1)}k`;
  }
  return String(value);
}

function tierLabelFor(min: number, max: number) {
  const fmt = (v: number) =>
    v === Infinity ? "∞" : v >= 1000 ? `${v / 1000}k` : `${v}`;
  return `★ ${fmt(min)}–${fmt(max)}`;
}

export default function GhStarsPage() {
  const [load, setLoad] = useState<LoadState>({ status: "loading" });

  // View + drill navigation are client state (single route, no router).
  const [view, setView] = useState<TreemapView>("projects");
  const [langName, setLangName] = useState<string | null>(null);
  const [tierSlug, setTierSlug] = useState<string | null>(null);
  // Forks view drill: the parent repo whose forks fill the fork-stars treemap.
  // Set by re-activating a README-open tile while the Forks metric is active;
  // cleared by the back chevron.
  const [forksTarget, setForksTarget] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    const apply = (next: LoadState) => {
      if (!cancelled) setLoad(next);
    };
    (async () => {
      try {
        const res = await fetch(DATA_URL);
        if (!res.ok) throw new Error("HTTP " + res.status);
        const data = (await res.json()) as RepoData;
        if (!Array.isArray(data?.repos) || !Array.isArray(data?.langs)) {
          throw new Error("malformed dataset");
        }
        apply({ status: "ready", data });
      } catch {
        apply({ status: "error" });
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  const data = load.status === "ready" ? load.data : null;

  // Base groups + headline numbers for the active view.
  const viewModel = useMemo(() => {
    if (!data) return null;
    if (view === "awesome") {
      return {
        groups: getCuratedGroups(data),
        total: getCuratedTotal(data),
        exportedAt: getExportedAt(data),
        daily: null as ReturnType<typeof getDailyTrendingData> | null,
      };
    }
    if (view === "daily") {
      const daily = getDailyTrendingData(data);
      return { groups: daily.groups, total: daily.positiveGrowthRepoCount, exportedAt: getExportedAt(data), daily };
    }
    return { groups: getGroups(data), total: getTotal(data), exportedAt: getExportedAt(data), daily: null };
  }, [data, view]);

  const navHandlers = {
    onViewChange: (v: TreemapView) => {
      setView(v);
      setLangName(null);
      setTierSlug(null);
      setForksTarget(null);
    },
    onOpenLang: (name: string) => {
      setLangName(name);
      setTierSlug(null);
    },
    onOpenTier: (slug: string) => setTierSlug(slug),
    onBackToOverview: () => {
      setLangName(null);
      setTierSlug(null);
    },
    onBackToLang: () => setTierSlug(null),
    onDrillForks: (fullName: string) => setForksTarget(fullName),
  };

  let body: React.ReactNode;

  if (load.status === "loading") {
    body = <StatusScreen title="Loading treemap…" />;
  } else if (load.status === "error" || !viewModel) {
    body = (
      <StatusScreen
        title="Treemap dataset unavailable"
        detail="The repo dataset isn't bundled in this deployment. Run the app locally (npm run dev) with public/treemap-data/repos.json present to explore the treemap."
      />
    );
  } else if (forksTarget) {
    // Fork-stars drill: live-fetch the parent repo's forks and render them as a
    // detail treemap with the back-chevron header. Sits above the normal
    // view/drill branches; the back chevron clears forksTarget to return.
    body = (
      <ForksTreemap
        key={forksTarget}
        fullName={forksTarget}
        langs={load.data.langs}
        colors={load.data.colors}
        onBack={() => setForksTarget(null)}
      />
    );
  } else {
    const selectedGroup: GroupData | undefined = langName
      ? viewModel.groups.find((g) => g.lang === langName)
      : undefined;

    // Shared metric config — daily ranks by growth with no metric switcher.
    const metricProps =
      view === "daily"
        ? {
            initialMetric: "growth" as Metric,
            availableMetrics: [] as Metric[],
            fallbackMetric: "stars" as Metric,
            fallbackNotice: {
              title: "No eligible growth rows in the current dataset",
              detail: `This view only includes repos at least ${DAILY_TRENDING_MIN_REPO_AGE_DAYS} days old with at least ${formatBaseThreshold(DAILY_TRENDING_MIN_BASELINE_STARS)} stars before the current growth window. It falls back to stars for the same eligible pool.`,
            },
          }
        : {};

    if (selectedGroup && tierSlug) {
      // Tier drill within a language.
      const range = parseTierSlug(tierSlug);
      const tierRepos = range
        ? filterReposByTier(selectedGroup.repos, range.min, range.max)
        : [];
      const tierGroup: GroupData = {
        lang: selectedGroup.lang,
        color: selectedGroup.color,
        count: tierRepos.length,
        total: tierRepos.reduce((s, r) => s + r.stars, 0),
        repos: tierRepos,
      };
      body = (
        <Treemap
          key={`${view}|${langName}|${tierSlug}`}
          mode="detail"
          detailGroup={tierGroup}
          total={viewModel.total}
          tierLabel={range ? tierLabelFor(range.min, range.max) : undefined}
          activeView={view}
          {...navHandlers}
          {...metricProps}
        />
      );
    } else if (selectedGroup) {
      // Language detail.
      body = (
        <Treemap
          key={`${view}|${langName}`}
          mode="detail"
          detailGroup={selectedGroup}
          total={viewModel.total}
          activeView={view}
          {...navHandlers}
          {...metricProps}
        />
      );
    } else {
      // Overview for the active view.
      const overrides =
        view === "awesome"
          ? {
              breadcrumbOverride: [
                { label: "All Languages", onClick: () => navHandlers.onViewChange("projects") },
                { label: "Awesome / Guides", color: "#8eea54" },
              ],
              infoOverride: `${formatExportedAt(viewModel.exportedAt)} UTC · ${viewModel.total.toLocaleString()} curated repos`,
            }
          : view === "daily" && viewModel.daily
            ? {
                breadcrumbOverride: [
                  { label: "All Languages", onClick: () => navHandlers.onViewChange("projects") },
                  { label: "Daily Trending", color: "#61dafb" },
                ],
                infoOverride: `${formatExportedAt(viewModel.exportedAt)} UTC · ${viewModel.daily.positiveGrowthRepoCount.toLocaleString()} growing repos · ${viewModel.daily.eligibleRepoCount.toLocaleString()} eligible · ${DAILY_TRENDING_MIN_REPO_AGE_DAYS}d+ old · ${formatBaseThreshold(DAILY_TRENDING_MIN_BASELINE_STARS)}+ base`,
              }
            : {};
      body = (
        <Treemap
          key={view}
          mode="overview"
          groups={viewModel.groups}
          total={viewModel.total}
          activeView={view}
          {...navHandlers}
          {...metricProps}
          {...overrides}
        />
      );
    }
  }

  return (
    <main className="flex flex-col h-screen bg-[#0c0c0c] text-white overflow-hidden">
      {body}
    </main>
  );
}

function StatusScreen({ title, detail }: { title: string; detail?: string }) {
  return (
    <div className="flex-1 flex items-center justify-center px-6 text-center">
      <div className="max-w-md rounded-2xl border border-white/10 bg-black/40 px-5 py-4 backdrop-blur-md">
        <div className="text-base font-semibold text-white">{title}</div>
        {detail && <div className="mt-1 text-sm text-neutral-400">{detail}</div>}
      </div>
    </div>
  );
}
