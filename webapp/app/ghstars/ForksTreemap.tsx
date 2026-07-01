"use client";

import { useEffect, useState } from "react";
import { Treemap } from "@/components/treemap/Treemap";
import type { GroupData, Repo } from "@/lib/treemap/types";

interface ForksTreemapProps {
  // The parent repo whose forks we drill into (e.g. "facebook/react").
  fullName: string;
  // Language names + Linguist colors from the loaded dataset, so a fork's
  // language string can be mapped back to a colour.
  langs: string[];
  colors: string[];
  // Return to the Forks view the drill came from.
  onBack: () => void;
}

// The subset of GitHub's "list forks" response we use. Forks are repository
// objects; sort=stargazers returns the most-starred first.
interface ForkRow {
  full_name: string;
  stargazers_count: number;
  forks_count: number;
  size: number;
  language: string | null;
  description: string | null;
}

type LoadState =
  | { status: "loading" }
  | { status: "error"; message: string }
  | { status: "ready"; repos: Repo[] };

// Top 100 forks in one request — the per_page=100 ceiling packs the most forks
// into a single call, and the api.github.com rate limit counts requests, not
// items (see issue #174 for the raw-CDN follow-up that would cut README cost).
const FORKS_URL = (fullName: string) =>
  `https://api.github.com/repos/${fullName}/forks?sort=stargazers&per_page=100`;

export function ForksTreemap({ fullName, langs, colors, onBack }: ForksTreemapProps) {
  const [load, setLoad] = useState<LoadState>({ status: "loading" });

  useEffect(() => {
    // Remounted per parent repo (key={fullName} in the page), so state already
    // starts at "loading" — the effect just runs the fetch.
    const controller = new AbortController();

    fetch(FORKS_URL(fullName), {
      headers: { Accept: "application/vnd.github+json" },
      signal: controller.signal,
    })
      .then(async (res) => {
        if (res.status === 404) throw new Error("This repository couldn't be found.");
        if (res.status === 403) throw new Error("GitHub rate limit reached — try again in a little while.");
        if (!res.ok) throw new Error(`Couldn't load forks (HTTP ${res.status}).`);
        const rows = (await res.json()) as ForkRow[];
        const repos: Repo[] = (Array.isArray(rows) ? rows : []).map((f) => ({
          fullName: f.full_name,
          stars: f.stargazers_count ?? 0,
          forks: f.forks_count ?? 0,
          langIdx: f.language ? langs.indexOf(f.language) : -1,
          description: f.description ?? "",
          growth: 0,
          size: f.size ?? 0,
        }));
        setLoad({ status: "ready", repos });
      })
      .catch((err: unknown) => {
        if (err instanceof DOMException && err.name === "AbortError") return;
        setLoad({ status: "error", message: err instanceof Error ? err.message : "Couldn't load forks." });
      });

    return () => controller.abort();
  }, [fullName, langs]);

  if (load.status === "loading") {
    return <ForksStatus title={`Loading forks of ${fullName}…`} onBack={onBack} />;
  }
  if (load.status === "error") {
    return <ForksStatus title="Couldn't load forks" detail={load.message} onBack={onBack} />;
  }

  // Group colour: the most-starred fork's language colour (forks mostly share
  // the parent's language); neutral grey when unknown.
  const langIdx = load.repos.find((r) => r.langIdx >= 0)?.langIdx ?? -1;
  const group: GroupData = {
    lang: fullName,
    color: langIdx >= 0 ? colors[langIdx] : "#888",
    count: load.repos.length,
    total: load.repos.reduce((s, r) => s + r.stars, 0),
    repos: load.repos,
  };

  return (
    <Treemap
      mode="detail"
      detailGroup={group}
      total={load.repos.length}
      initialMetric="stars"
      availableMetrics={["stars", "size"]}
      infoOverride={`${load.repos.length.toLocaleString()} forks · by stars`}
      onBack={onBack}
      backTitle={fullName}
      // Required by the Treemap props but unused while the back-chevron header
      // (onBack) is active — the global tabs/breadcrumb aren't rendered here.
      activeView="projects"
      onViewChange={() => {}}
    />
  );
}

function ForksStatus({ title, detail, onBack }: { title: string; detail?: string; onBack: () => void }) {
  return (
    <>
      <header className="flex items-center gap-3 px-5 py-2.5 bg-[#151515] border-b border-[#252525] shrink-0 z-10">
        <button
          type="button"
          onClick={onBack}
          aria-label="Back to forks view"
          className="flex h-7 w-7 shrink-0 items-center justify-center rounded border border-[#252525] text-neutral-300 hover:border-neutral-600 hover:text-white transition-all cursor-pointer"
        >
          <span className="text-lg leading-none">‹</span>
        </button>
      </header>
      <div className="flex-1 flex items-center justify-center px-6 text-center">
        <div className="max-w-md rounded-2xl border border-white/10 bg-black/40 px-5 py-4 backdrop-blur-md">
          <div className="text-base font-semibold text-white">{title}</div>
          {detail && <div className="mt-1 text-sm text-neutral-400">{detail}</div>}
        </div>
      </div>
    </>
  );
}
