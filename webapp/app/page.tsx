"use client";

import Link from "next/link";
import { useEffect, useLayoutEffect, useRef, useState } from "react";
import styles from "./page.module.css";

// --- Tap-to-cycle view state for the two home-screen panels (#79) ---
// View 1 is the existing content; views 2 and 3 are placeholder
// "Work in progress" lines. Tap cycles 0 -> 1 -> 2 -> 0; page reload
// resets to 0. Real angles for views 2/3 land in follow-up issues.
const VIEW_COUNT = 3;
const wipText = (view: number) => `View ${view + 1}: Work in progress`;

const SUMMARY_URL = "http://localhost:8001/summary/30days";
const STORAGE_KEY = "firstcontact:summary-30d:v1";
const TTL_HOURS = 24;
const RECENT_STORAGE_KEY = "firstcontact:recent-changes:v1";

type SummaryView1 = { prose: string; footnote: string | null };
type RecentTask = { id: number; title: string };
type RecentTasksState =
  | { kind: "loading" | "empty" | "error"; items: RecentTask[]; message: string }
  | { kind: "ready"; items: RecentTask[]; message: null };

type CachedSummary = { summary: string; ageMs: number; fresh: boolean };

// Subset of the GitHub issues REST payload we rely on (PRs carry `pull_request`).
type IssueApiItem = {
  id: number;
  title: string;
  closed_at: string | null;
  pull_request?: unknown;
};

function readCache(): CachedSummary | null {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return null;
    const obj = JSON.parse(raw);
    if (typeof obj?.summary !== "string" || typeof obj?.generated_at !== "string") return null;
    const ageMs = Date.now() - new Date(obj.generated_at).getTime();
    if (Number.isNaN(ageMs)) return null;
    const ttlMs = (Number(obj.ttl_hours) || TTL_HOURS) * 3600_000;
    return { summary: obj.summary, ageMs, fresh: ageMs < ttlMs };
  } catch {
    return null;
  }
}

function writeCache(summary: string) {
  try {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({ summary, generated_at: new Date().toISOString(), ttl_hours: TTL_HOURS })
    );
  } catch {
    // quota exceeded / private browsing — degrade silently
  }
}

// Last-known-good cache for the recent-changes list, so a transient GitHub API
// failure (anonymous 60/hr rate limit, a 5xx, an offline blip) keeps showing the
// last successful result instead of blanking the panel. Mirrors readCache above.
function readRecentCache(): RecentTask[] | null {
  try {
    const raw = localStorage.getItem(RECENT_STORAGE_KEY);
    if (!raw) return null;
    const obj = JSON.parse(raw);
    if (!Array.isArray(obj?.items)) return null;
    const items: RecentTask[] = obj.items.filter(
      (i: unknown): i is RecentTask =>
        typeof (i as RecentTask)?.id === "number" && typeof (i as RecentTask)?.title === "string"
    );
    return items.length ? items : null;
  } catch {
    return null;
  }
}

function writeRecentCache(items: RecentTask[]) {
  try {
    localStorage.setItem(
      RECENT_STORAGE_KEY,
      JSON.stringify({ items, generated_at: new Date().toISOString() })
    );
  } catch {
    // quota exceeded / private browsing — degrade silently
  }
}

export default function HomePage() {
  const [device, setDevice] = useState("Loading device info…");
  const [quote, setQuote] = useState<{ text: string; author: string }>({ text: "", author: "" });

  const [summaryView, setSummaryView] = useState(0);
  const [summaryView1, setSummaryView1] = useState<SummaryView1>({
    prose: "Loading summary…",
    footnote: null,
  });

  const [recentTasksView, setRecentTasksView] = useState(0);
  const [recentTasksState, setRecentTasksState] = useState<RecentTasksState>({
    kind: "loading",
    items: [],
    message: "Loading…",
  });

  // Device line + today's quote (client-only — navigator/fetch run after mount).
  useEffect(() => {
    (async () => {
      try {
        setDevice("You are on: " + navigator.userAgent.split("(")[1].split(")")[0]);
      } catch {
        setDevice("You are on: this device");
      }

      try {
        const res = await fetch("https://dummyjson.com/quotes/random");
        if (!res.ok) throw new Error("HTTP " + res.status);
        const data = await res.json();
        setQuote({ text: "“" + data.quote + "”", author: data.author });
      } catch {
        setQuote({ text: "Could not load today’s quote.", author: "" });
      }
    })();
  }, []);

  // 30-day summary: cache-first, then backend, with graceful fallback.
  useEffect(() => {
    const setView1 = (prose: string, footnote?: string) =>
      setSummaryView1({ prose, footnote: footnote || null });

    const cached = readCache();
    if (cached?.fresh) {
      setView1(cached.summary);
      return;
    }
    if (cached) setView1(cached.summary);

    (async () => {
      try {
        const res = await fetch(SUMMARY_URL);
        if (!res.ok) throw new Error("HTTP " + res.status);
        const data = await res.json();
        if (typeof data?.summary !== "string") throw new Error("malformed response");
        setView1(data.summary);
        writeCache(data.summary);
      } catch {
        if (cached) {
          setView1(cached.summary, "(showing cached summary; backend unreachable)");
        } else {
          setView1(
            "Backend unreachable at http://localhost:8001 — start the local server (see api/server/README.md)."
          );
        }
      }
    })();
  }, []);

  // Changes made this week, from closed GitHub issues (PRs filtered out).
  // Cache-first: show last-known-good immediately, then revalidate. The fetch is
  // unauthenticated and browser-side, so it can fail on the anonymous 60/hr rate
  // limit or a transient blip — fall back to the cached list rather than blanking.
  useEffect(() => {
    const showItems = (items: RecentTask[]) =>
      setRecentTasksState({ kind: "ready", items, message: null });

    const cached = readRecentCache();
    if (cached) showItems(cached);

    (async () => {
      try {
        const res = await fetch(
          "https://api.github.com/repos/wongvin/firstcontact/issues?state=closed&per_page=30&sort=updated&direction=desc"
        );
        if (!res.ok) throw new Error("HTTP " + res.status);
        const items: IssueApiItem[] = await res.json();
        const cutoff = Date.now() - 7 * 86400000;
        const recent: RecentTask[] = items
          .filter(
            (i) => !i.pull_request && i.closed_at && new Date(i.closed_at).getTime() >= cutoff
          )
          .sort(
            (a, b) =>
              new Date(b.closed_at as string).getTime() -
              new Date(a.closed_at as string).getTime()
          )
          .map((i) => ({ id: i.id, title: i.title }));
        if (recent.length === 0) {
          setRecentTasksState({ kind: "empty", items: [], message: "No changes this week." });
        } else {
          showItems(recent);
          writeRecentCache(recent);
        }
      } catch {
        // Keep the cached list shown above; only surface an error with no fallback.
        if (!cached) {
          setRecentTasksState({
            kind: "error",
            items: [],
            message: "Could not load recent changes.",
          });
        }
      }
    })();
  }, []);

  // --- Height lock: pin each panel to view 1's natural height so cycling to
  // the shorter view 2/3 placeholders doesn't shrink it. min-height is a floor —
  // view 1 can still grow past it (async data), and the next snapshot raises it.
  const summaryRef = useRef<HTMLElement>(null);
  const recentRef = useRef<HTMLElement>(null);

  useLayoutEffect(() => {
    if (summaryView !== 0) return;
    const el = summaryRef.current;
    if (!el) return;
    const h = el.getBoundingClientRect().height;
    if (h > 0) el.style.minHeight = h + "px";
  }, [summaryView, summaryView1]);

  useLayoutEffect(() => {
    if (recentTasksView !== 0) return;
    const el = recentRef.current;
    if (!el) return;
    const h = el.getBoundingClientRect().height;
    if (h > 0) el.style.minHeight = h + "px";
  }, [recentTasksView, recentTasksState]);

  // Tap / Enter / Space cycles the view, skipping clicks that end a text selection.
  function makeCycleHandlers(setView: React.Dispatch<React.SetStateAction<number>>) {
    const advance = () => {
      const sel = window.getSelection();
      if (sel && sel.toString().length > 0) return;
      setView((v) => (v + 1) % VIEW_COUNT);
    };
    return {
      onClick: advance,
      onKeyDown: (e: React.KeyboardEvent) => {
        if (e.key === "Enter" || e.key === " ") {
          e.preventDefault();
          advance();
        }
      },
    };
  }

  return (
    <div className={styles.page}>
      <div className={styles.hero}>
        <h1>Hello, World!</h1>
        <p>{device}</p>
        <blockquote className={styles.quote}>
          <span>{quote.text}</span>
          <footer>— <span>{quote.author}</span></footer>
        </blockquote>
      </div>

      <section
        ref={summaryRef}
        className={`${styles.panel} ${styles.summaryPanel}`}
        role="button"
        tabIndex={0}
        aria-live="polite"
        aria-label="Summary of the last 30 days. Tap to cycle view."
        {...makeCycleHandlers(setSummaryView)}
      >
        <span className={styles.cycleGlyph} aria-hidden="true">⟳</span>
        <h2>Last 30 days</h2>
        {summaryView !== 0 ? (
          <p>{wipText(summaryView)}</p>
        ) : (
          <>
            <p>{summaryView1.prose}</p>
            {summaryView1.footnote && (
              <span className={styles.footnote}>{summaryView1.footnote}</span>
            )}
          </>
        )}
      </section>

      <aside
        ref={recentRef}
        className={`${styles.panel} ${styles.recentPanel}`}
        role="button"
        tabIndex={0}
        aria-live="polite"
        aria-label="Changes made this week. Tap to cycle view."
        {...makeCycleHandlers(setRecentTasksView)}
      >
        <span className={styles.cycleGlyph} aria-hidden="true">⟳</span>
        <h2>Changes made this week</h2>
        <ol>
          {recentTasksView !== 0 ? (
            <li className={styles.empty}>{wipText(recentTasksView)}</li>
          ) : recentTasksState.kind === "ready" ? (
            recentTasksState.items.map((item) => <li key={item.id}>{item.title}</li>)
          ) : (
            <li className={styles.empty}>{recentTasksState.message}</li>
          )}
        </ol>
      </aside>

      <nav className={styles.toolLinks} aria-label="Tools">
        <Link className={styles.toolLink} href="/news">Latest News →</Link>
        <Link className={styles.toolLink} href="/ghstars">GitHub Treemap →</Link>
        <a className={styles.toolLink} href="/digikey-search.html">DigiKey search →</a>
        <a className={styles.toolLink} href="/mouser-search.html">Mouser search →</a>
        <a className={styles.toolLink} href="/octopart-search.html">Octopart search →</a>
        <a className={styles.toolLink} href="/transcripts-viewer.html">Transcripts viewer →</a>
      </nav>
    </div>
  );
}
