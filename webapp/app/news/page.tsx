import Link from "next/link";
import type { Article } from "./types";

export default async function NewsPage() {
  const apiKey = process.env.GNEWS_API_KEY;

  const res = await fetch(
    `https://gnews.io/api/v4/top-headlines?category=general&lang=en&country=us&apikey=${apiKey}`,
    { cache: "no-store" }
  );

  const data = await res.json();

  return (
    <div style={{ padding: 40, maxWidth: 800, margin: "0 auto" }}>
      <h1 style={{ marginBottom: 20 }}>Latest News</h1>

      {/* Category Navigation */}
      <nav style={{ marginBottom: 30, display: "flex", gap: 20 }}>
        <Link href="/news/health" style={{ fontWeight: "bold" }}>
          Health
        </Link>
        <Link href="/news/economy" style={{ fontWeight: "bold" }}>
          Economy
        </Link>
      </nav>

      {/* News List */}
      {data.articles?.length > 0 ? (
        data.articles.map((article: Article, index: number) => (
          <div
            key={index}
            style={{
              marginBottom: 40,
              paddingBottom: 20,
              borderBottom: "1px solid #ddd",
            }}
          >
            {article.image && (
              <img
                src={article.image}
                alt={article.title}
                style={{
                  width: "100%",
                  borderRadius: 8,
                  marginBottom: 12,
                }}
              />
            )}

            <h2 style={{ marginBottom: 8 }}>{article.title}</h2>
            <p style={{ marginBottom: 12 }}>{article.description}</p>

            <a
              href={article.url}
              target="_blank"
              rel="noopener noreferrer"
              style={{ color: "#0070f3", fontWeight: "bold" }}
            >
              Read more →
            </a>
          </div>
        ))
      ) : (
        <p>No articles found.</p>
      )}
    </div>
  );
}

