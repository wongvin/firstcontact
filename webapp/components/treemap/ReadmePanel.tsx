"use client";

import { useEffect, useState } from "react";
import Markdown from "react-markdown";
import remarkGfm from "remark-gfm";

interface ReadmePanelProps {
  fullName: string;
  // Which half of the screen the panel occupies.
  side: "left" | "right";
  onClose: () => void;
}

// Resolve README-relative URLs against the repo so images/links work; leave
// absolute, anchor, and mailto URLs alone. Anything else (e.g. javascript:) is
// treated as a relative path and thus neutralised.
function makeUrlTransform(fullName: string) {
  return (url: string, key: string) => {
    if (!url) return url;
    if (/^(https?:|mailto:|#)/i.test(url)) return url;
    const clean = url.replace(/^\.?\//, "");
    return key === "src"
      ? `https://raw.githubusercontent.com/${fullName}/HEAD/${clean}`
      : `https://github.com/${fullName}/blob/HEAD/${clean}`;
  };
}

const mdComponents = {
  a: (props: React.ComponentProps<"a">) => (
    <a {...props} target="_blank" rel="noreferrer" className="text-cyan-400 underline underline-offset-2 hover:text-cyan-300" />
  ),
  img: (props: React.ComponentProps<"img">) => (
    // eslint-disable-next-line @next/next/no-img-element, jsx-a11y/alt-text
    <img {...props} className="inline-block max-w-full rounded" loading="lazy" />
  ),
  h1: (props: React.ComponentProps<"h1">) => <h1 {...props} className="mt-6 mb-3 border-b border-white/10 pb-1 text-2xl font-bold text-white first:mt-0" />,
  h2: (props: React.ComponentProps<"h2">) => <h2 {...props} className="mt-6 mb-3 border-b border-white/10 pb-1 text-xl font-bold text-white" />,
  h3: (props: React.ComponentProps<"h3">) => <h3 {...props} className="mt-5 mb-2 text-lg font-semibold text-white" />,
  h4: (props: React.ComponentProps<"h4">) => <h4 {...props} className="mt-4 mb-2 text-base font-semibold text-white" />,
  p: (props: React.ComponentProps<"p">) => <p {...props} className="my-3 leading-relaxed text-neutral-300" />,
  ul: (props: React.ComponentProps<"ul">) => <ul {...props} className="my-3 list-disc space-y-1 pl-6 text-neutral-300" />,
  ol: (props: React.ComponentProps<"ol">) => <ol {...props} className="my-3 list-decimal space-y-1 pl-6 text-neutral-300" />,
  li: (props: React.ComponentProps<"li">) => <li {...props} className="leading-relaxed" />,
  blockquote: (props: React.ComponentProps<"blockquote">) => (
    <blockquote {...props} className="my-3 border-l-4 border-white/20 pl-4 text-neutral-400 italic" />
  ),
  code: (props: React.ComponentProps<"code">) => {
    const { className } = props;
    // Inline code has no language class; block code is wrapped in <pre>.
    const isBlock = /language-/.test(className || "");
    return isBlock ? (
      <code {...props} className="block text-[13px] leading-relaxed" />
    ) : (
      <code {...props} className="rounded bg-white/10 px-1.5 py-0.5 text-[13px] text-cyan-200" />
    );
  },
  pre: (props: React.ComponentProps<"pre">) => (
    <pre {...props} className="my-3 overflow-x-auto rounded-lg border border-white/10 bg-black/50 p-3 text-neutral-200" />
  ),
  table: (props: React.ComponentProps<"table">) => (
    <div className="my-3 overflow-x-auto">
      <table {...props} className="w-full border-collapse text-sm" />
    </div>
  ),
  th: (props: React.ComponentProps<"th">) => <th {...props} className="border border-white/15 bg-white/5 px-3 py-1.5 text-left font-semibold text-white" />,
  td: (props: React.ComponentProps<"td">) => <td {...props} className="border border-white/15 px-3 py-1.5 text-neutral-300" />,
  hr: (props: React.ComponentProps<"hr">) => <hr {...props} className="my-5 border-white/10" />,
};

export function ReadmePanel({ fullName, side, onClose }: ReadmePanelProps) {
  const [state, setState] = useState<{ status: "loading" | "ok" | "error"; text: string; message: string }>({
    status: "loading",
    text: "",
    message: "",
  });

  useEffect(() => {
    // The parent remounts this panel per repo (key={fullName}), so initial
    // state is already "loading" — the effect just runs the fetch.
    const controller = new AbortController();

    fetch(`https://api.github.com/repos/${fullName}/readme`, {
      headers: { Accept: "application/vnd.github.raw" },
      signal: controller.signal,
    })
      .then(async (res) => {
        if (res.status === 404) throw new Error("This repository has no README.");
        if (res.status === 403) throw new Error("GitHub rate limit reached — try again in a little while.");
        if (!res.ok) throw new Error(`Couldn't load the README (HTTP ${res.status}).`);
        const text = await res.text();
        setState({ status: "ok", text, message: "" });
      })
      .catch((err: unknown) => {
        if (err instanceof DOMException && err.name === "AbortError") return;
        setState({ status: "error", text: "", message: err instanceof Error ? err.message : "Couldn't load the README." });
      });

    return () => controller.abort();
  }, [fullName]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  return (
    <div
      className={`fixed top-0 bottom-0 z-[60] flex w-1/2 flex-col border-white/10 bg-[rgba(12,12,12,0.97)] shadow-2xl backdrop-blur-xl ${
        side === "right" ? "right-0 border-l" : "left-0 border-r"
      }`}
    >
      <div className="flex items-center gap-3 border-b border-white/10 px-4 py-3">
        <a
          href={`https://github.com/${fullName}`}
          target="_blank"
          rel="noreferrer"
          className="min-w-0 flex-1 truncate text-sm font-semibold text-white hover:text-cyan-300"
          title={fullName}
        >
          {fullName}
        </a>
        <button
          type="button"
          onClick={onClose}
          aria-label="Close README"
          className="flex h-8 w-8 shrink-0 items-center justify-center rounded-lg border border-white/10 text-neutral-300 hover:bg-white/10 hover:text-white"
        >
          <span className="text-lg leading-none">×</span>
        </button>
      </div>

      <div className="flex-1 overflow-y-auto px-5 py-4">
        {state.status === "loading" && <div className="text-sm text-neutral-400">Loading README…</div>}
        {state.status === "error" && <div className="text-sm text-neutral-400">{state.message}</div>}
        {state.status === "ok" && (
          <div className="text-sm break-words">
            <Markdown remarkPlugins={[remarkGfm]} urlTransform={makeUrlTransform(fullName)} components={mdComponents}>
              {state.text}
            </Markdown>
          </div>
        )}
      </div>
    </div>
  );
}
