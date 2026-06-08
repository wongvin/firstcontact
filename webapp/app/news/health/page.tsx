import TTSButton from "../TTSButton";
import type { Article } from "../types";

async function getHealthNews() {
  const apiKey = process.env.GNEWS_API_KEY;

  const res = await fetch(
    `https://gnews.io/api/v4/top-headlines?category=health&lang=en&country=us&apikey=${apiKey}`,
    { cache: "no-store" }
  );

  return res.json();
}

export default async function HealthNewsPage() {
  const data = await getHealthNews();

  return (
    <div style={{ padding: 40, maxWidth: 800, margin: "0 auto" }}>
      <h1 style={{ marginBottom: 20 }}>Health News</h1>

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

            <TTSButton text={`${article.title}. ${article.description}`} />
          </div>
        ))
      ) : (
        <p>No health articles found.</p>
      )}
    </div>
  );
}

