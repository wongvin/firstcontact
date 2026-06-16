import type { RepoData, Repo, GroupData, Metric } from "./types";
import { getRepoValue } from "./metrics";
import { shouldExcludeRepo } from "./repo-classifier";

// NOTE: ported from xiaoxiunique/1k-github-stars. The upstream module imported
// `@/data/repos.json` at load time and closed over it. For the webapp embed the
// dataset is fetched at runtime (client-side), so every helper now takes the
// already-fetched `RepoData` as an argument and stays pure. `getLangSlug` is the
// one exception — it's a pure string transform with no data dependency, so the
// Treemap component can import it directly.

export const DAILY_TRENDING_MIN_REPO_AGE_DAYS = 7;
export const DAILY_TRENDING_MIN_BASELINE_STARS = 2500;

function filteredRows(data: RepoData): RepoData["repos"] {
  return data.repos.filter((row) => {
    const langName = data.langs[row[3]] || "Other";
    return !shouldExcludeRepo(row[0], row[4] ?? "", langName);
  });
}

function curatedRows(data: RepoData): RepoData["repos"] {
  return data.repos.filter((row) => {
    const langName = data.langs[row[3]] || "Other";
    return shouldExcludeRepo(row[0], row[4] ?? "", langName);
  });
}

function mapRowsToRepos(rows: RepoData["repos"]): Repo[] {
  return rows.map((r) => ({
    fullName: r[0],
    stars: r[1],
    forks: r[2],
    langIdx: r[3],
    description: r[4],
    growth: r[5],
  }));
}

function normalizeLangSlug(value: string) {
  return value
    .toLowerCase()
    .replaceAll("c++", "c-plus-plus")
    .replaceAll("c#", "c-sharp")
    .replaceAll("f#", "f-sharp")
    .replaceAll("objective-c++", "objective-c-plus-plus")
    .replaceAll("+", "-plus-")
    .replaceAll("#", "-sharp")
    .replaceAll(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

export function getAllRepos(data: RepoData): Repo[] {
  return mapRowsToRepos(filteredRows(data));
}

export function getCuratedRepos(data: RepoData): Repo[] {
  return mapRowsToRepos(curatedRows(data));
}

export function getLangs(data: RepoData): string[] {
  return data.langs;
}

export function getColors(data: RepoData): string[] {
  return data.colors;
}

export function getTotal(data: RepoData): number {
  return filteredRows(data).length;
}

export function getCuratedTotal(data: RepoData): number {
  return curatedRows(data).length;
}

export function getExportedAt(data: RepoData): string {
  return data.exported;
}

function groupRepos(data: RepoData, repos: Repo[], metric: Metric = "stars"): GroupData[] {
  const langs = getLangs(data);
  const colors = getColors(data);
  const groups = new Map<string, { repos: Repo[]; total: number }>();

  for (const repo of repos) {
    const v = getRepoValue(repo, metric);
    if (v <= 0) continue;
    const lang = langs[repo.langIdx] || "Other";
    if (!groups.has(lang)) groups.set(lang, { repos: [], total: 0 });
    const g = groups.get(lang)!;
    g.repos.push(repo);
    g.total += v;
  }

  return [...groups.entries()]
    .map(([lang, g]) => {
      const langIdx = langs.indexOf(lang);
      return {
        lang,
        color: langIdx >= 0 ? colors[langIdx] : "#888",
        count: g.repos.length,
        total: g.total,
        repos: g.repos.sort(
          (a, b) => getRepoValue(b, metric) - getRepoValue(a, metric)
        ),
      };
    })
    .sort((a, b) => b.total - a.total);
}

export function getGroups(data: RepoData, metric: Metric = "stars"): GroupData[] {
  return groupRepos(data, getAllRepos(data), metric);
}

export function getCuratedGroups(data: RepoData, metric: Metric = "stars"): GroupData[] {
  return groupRepos(data, getCuratedRepos(data), metric);
}

export function getDailyTrendingData(data: RepoData) {
  const exportedAtMs = new Date(data.exported).getTime();
  const eligibleRepos: Repo[] = [];
  let positiveGrowthRepoCount = 0;

  for (const row of filteredRows(data)) {
    const growth = row[5] ?? 0;
    const baselineStars = row[1] - growth;
    const createdAt = row[6];
    const createdAtMs = createdAt ? new Date(createdAt).getTime() : Number.NaN;

    if (baselineStars < DAILY_TRENDING_MIN_BASELINE_STARS) continue;
    if (!Number.isFinite(createdAtMs)) continue;
    if (exportedAtMs - createdAtMs < DAILY_TRENDING_MIN_REPO_AGE_DAYS * 24 * 60 * 60 * 1000) continue;

    if (growth > 0) {
      positiveGrowthRepoCount += 1;
    }

    eligibleRepos.push({
      fullName: row[0],
      stars: row[1],
      forks: row[2],
      langIdx: row[3],
      description: row[4],
      growth,
    });
  }

  return {
    groups: groupRepos(data, eligibleRepos),
    eligibleRepoCount: eligibleRepos.length,
    positiveGrowthRepoCount,
  };
}

export function getGroupByLang(data: RepoData, lang: string): GroupData | null {
  const groups = getGroups(data);
  const normalized = normalizeLangSlug(lang);
  return groups.find((g) => getLangSlug(g.lang) === normalized) ?? null;
}

export function getAllLangSlugs(data: RepoData): string[] {
  const groups = getGroups(data);
  return groups.map((g) => getLangSlug(g.lang));
}

export function getLangSlug(lang: string): string {
  return normalizeLangSlug(lang);
}
