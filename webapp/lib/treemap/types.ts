export interface Repo {
  fullName: string;
  stars: number;
  forks: number;
  langIdx: number;
  description: string;
  growth: number;
  createdAt?: string;
  updatedAt?: string;
  // Repository size in KB. Only present for forks fetched live from the GitHub
  // API (the "Repo size" metric in the fork-stars treemap); absent for the
  // main dataset's repos.
  size?: number;
}

export interface RepoData {
  langs: string[];
  colors: string[];
  repos: [string, number, number, number, string, number, string?, string?][];
  total: number;
  exported: string;
}

export interface GroupData {
  lang: string;
  color: string;
  count: number;
  total: number;
  repos: Repo[];
}

export interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface RepoRect extends Rect {
  idx: number;
  isOthers?: boolean;
  othersCount?: number;
  groupIdx?: number;
}

export interface GroupRect extends Rect {
  lang: string;
  color: string;
  count: number;
  total: number;
  headerH: number;
  allRepos: Repo[];
}

export type Metric = "stars" | "forks" | "growth" | "size";
