//
//  ContentView.swift
//  FirstContact
//
//  Created by Vincent Wong on 4/26/26.
//

import SwiftUI
import UIKit
import GoogleGenerativeAI

struct Quote: Codable {
    let id: Int
    let quote: String
    let author: String
}

struct Issue: Codable, Identifiable {
    let id: Int
    let title: String
    let closedAt: Date?
    let pullRequest: PRMarker?

    enum CodingKeys: String, CodingKey {
        case id, title
        case closedAt = "closed_at"
        case pullRequest = "pull_request"
    }
    struct PRMarker: Codable {}
}

struct CachedSummary: Codable {
    let summary: String
    let generatedAt: Date
    let ttlHours: Int
}

enum SummaryState {
    case loading
    case missingKey
    case ready(String, stale: Bool)
    case failedNoCache
}

// MARK: - News (gnews.io)

struct Article: Codable, Identifiable {
    let id = UUID()
    let title: String
    let description: String?
    let content: String?
    let url: String?
    let image: String?

    enum CodingKeys: String, CodingKey {
        case title, description, content, url, image
    }
}

struct NewsResponse: Codable {
    let articles: [Article]
}

enum NewsState {
    case loading
    case missingKey
    case failed
    case empty
    case ready([Article])
}

// Full article body fetched from the article's linked URL. GNews only returns a
// ~160-char truncated `content` field, so the detail screen scrapes the source page.
enum ArticleTextState {
    case loading
    case loaded(String)
    case failed
}

struct ContentView: View {
    @State private var quote: Quote?
    @State private var quoteError = false
    @State private var issues: [Issue] = []
    @State private var issuesLoaded = false
    @State private var issuesError = false
    @State private var summaryState: SummaryState = .loading
    @State private var recentChangesView = 0
    @State private var summary30dView = 0
    @State private var newsState: NewsState = .loading
    @State private var screenIndex = 0          // 0 = home; i>=1 = news article i-1
    @State private var goingForward = true      // drives swipe transition direction
    @State private var detailArticle: Article?
    @State private var articleTextState: ArticleTextState = .loading
    // On iPhone a compact vertical size class means landscape orientation.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }

    private static let summaryCacheKey = "firstcontact.summary30d.v1"
    private static let summaryTTLHours = 24
    private static let geminiModel = "gemini-2.5-flash-lite"
    private static let issueWindowDays = 30
    private static let issueFetchLimit = 50
    private static let wordLimit = 50
    private static let viewCount = 3
    private static let newsCategories = ["general", "technology", "science"]
    private static func wipText(_ view: Int) -> String { "View \(view + 1): Work in progress" }
    private static let geminiSystemPrompt = """
        You write concise editorial summaries of software engineering work. \
        Given a chronological list of recently-closed issue titles, write a single \
        plain-prose paragraph under 50 words that describes the overall themes of the work. \
        No bullet points, no emojis, no markdown, no headings. \
        Plain prose only. Do not include preamble like 'Here is the summary:'.
        """

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.40, green: 0.494, blue: 0.918), // #667eea
                    Color(red: 0.463, green: 0.294, blue: 0.635) // #764ba2
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if let article = detailArticle {
                articleDetailScreen(article)
                    .transition(.move(edge: .trailing))
            } else {
                pager
            }
        }
        .task { await loadQuote() }
        .task { await loadIssues() }
        .task { await loadSummary() }
        .task { await loadNews() }
    }

    // Vertical swipe pager: home at index 0, news articles after it, wrapping in a
    // circular ring (swipe up past the last article -> home; swipe down on home -> last).
    private var pager: some View {
        currentScreen
            .id(screenIndex)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(
                insertion: .move(edge: isLandscape
                    ? (goingForward ? .trailing : .leading)
                    : (goingForward ? .bottom : .top)),
                removal: .move(edge: isLandscape
                    ? (goingForward ? .leading : .trailing)
                    : (goingForward ? .top : .bottom))
            ))
            .contentShape(Rectangle())
            .gesture(swipeGesture)
    }

    @ViewBuilder
    private var currentScreen: some View {
        if screenIndex == 0 {
            homeScreen
        } else if case .ready(let articles) = newsState, screenIndex - 1 < articles.count {
            articleScreen(articles[screenIndex - 1])
        } else {
            newsStatusScreen
        }
    }

    private var homeScreen: some View {
        ZStack {
            VStack(spacing: 8) {
                Text("Hello, World!")
                    .font(.system(size: 48, weight: .bold))
                Text("You are on: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
                    .font(.system(size: 20))
                    .opacity(0.9)

                quoteSection
            }
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding()

            recentChangesPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding()

            summary30dPanel
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding()
        }
    }

    // Total swipe screens = home + one per article (or a single status screen
    // while news is loading / empty / failed).
    private var totalScreens: Int {
        let newsCount: Int
        if case .ready(let articles) = newsState { newsCount = articles.count } else { newsCount = 1 }
        return newsCount + 1
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                let dx = value.translation.width
                let dy = value.translation.height
                let total = totalScreens
                guard total > 1 else { return }
                // Landscape navigates on the horizontal axis (swipe-left = forward,
                // mirroring portrait's swipe-up); portrait stays on the vertical axis.
                let forward: Bool
                if isLandscape {
                    guard abs(dx) > abs(dy), abs(dx) > 50 else { return }
                    forward = dx < 0
                } else {
                    guard abs(dy) > abs(dx), abs(dy) > 50 else { return }
                    forward = dy < 0
                }
                withAnimation(.easeInOut(duration: 0.3)) {
                    if forward {
                        goingForward = true
                        screenIndex = (screenIndex + 1) % total
                    } else {
                        goingForward = false
                        screenIndex = (screenIndex - 1 + total) % total
                    }
                }
            }
    }

    @ViewBuilder
    private var quoteSection: some View {
        if let q = quote {
            VStack(spacing: 8) {
                Rectangle()
                    .fill(.white.opacity(0.4))
                    .frame(height: 1)
                Text("\u{201C}\(q.quote)\u{201D}")
                    .italic()
                    .font(.system(size: 16))
                    .padding(.top, 4)
                Text("— \(q.author)")
                    .font(.system(size: 14))
                    .opacity(0.8)
            }
            .frame(maxWidth: 320)
            .padding(.horizontal, 20)
            .padding(.top, 32)
            .opacity(0.95)
        } else if quoteError {
            Text("Could not load today’s quote.")
                .font(.system(size: 14))
                .opacity(0.6)
                .padding(.top, 32)
        }
    }

    @ViewBuilder
    private var summary30dPanel: some View {
        Button {
            summary30dView = (summary30dView + 1) % Self.viewCount
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Text("LAST 30 DAYS")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.0)
                    .padding(.bottom, 4)
                    .overlay(
                        Rectangle()
                            .fill(.white.opacity(0.3))
                            .frame(height: 1),
                        alignment: .bottom
                    )

                if summary30dView == 0 {
                    switch summaryState {
                    case .loading:
                        Text("Loading\u{2026}")
                            .font(.system(size: 12))
                            .opacity(0.7)
                    case .missingKey:
                        Text("Set GEMINI_API_KEY in Secrets.xcconfig — see ios/CLAUDE.md.")
                            .font(.system(size: 12))
                            .opacity(0.85)
                    case .ready(let prose, let stale):
                        VStack(alignment: .leading, spacing: 6) {
                            Text(prose)
                                .font(.system(size: 13))
                                .multilineTextAlignment(.leading)
                            if stale {
                                Text("(showing cached summary; refresh failed)")
                                    .font(.system(size: 11))
                                    .opacity(0.65)
                            }
                        }
                    case .failedNoCache:
                        Text("Could not load summary.")
                            .font(.system(size: 12))
                            .opacity(0.7)
                    }
                } else {
                    Text(Self.wipText(summary30dView))
                        .font(.system(size: 13))
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .frame(maxWidth: 320, minHeight: 120, alignment: .topLeading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.white.opacity(0.25), lineWidth: 1)
            )
            .overlay(
                Text("⟳")
                    .font(.system(size: 11))
                    .opacity(0.5)
                    .padding(.top, 6)
                    .padding(.trailing, 8)
                    .accessibilityHidden(true),
                alignment: .topTrailing
            )
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .padding(.top, 16)
        .accessibilityLabel("Summary of the last 30 days. Tap to cycle view.")
        .accessibilityHint("Cycles through alternate views of the panel's data.")
    }

    private var recentChangesPanel: some View {
        Button {
            recentChangesView = (recentChangesView + 1) % Self.viewCount
        } label: {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("CHANGES MADE THIS WEEK")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(1.0)
                        .padding(.bottom, 4)
                        .overlay(
                            Rectangle()
                                .fill(.white.opacity(0.3))
                                .frame(height: 1),
                            alignment: .bottom
                        )

                    if recentChangesView == 0 {
                        if !issues.isEmpty {
                            ForEach(Array(issues.enumerated()), id: \.element.id) { idx, issue in
                                HStack(alignment: .top, spacing: 6) {
                                    Text("\(idx + 1).").bold()
                                    Text(issue.title)
                                }
                                .font(.system(size: 12))
                            }
                        } else if issuesError {
                            Text("Could not load recent changes.")
                                .font(.system(size: 12))
                                .opacity(0.7)
                        } else if issuesLoaded {
                            Text("No changes this week.")
                                .font(.system(size: 12))
                                .opacity(0.7)
                        } else {
                            Text("Loading\u{2026}")
                                .font(.system(size: 12))
                                .opacity(0.7)
                        }
                    } else {
                        Text(Self.wipText(recentChangesView))
                            .font(.system(size: 12))
                            .opacity(0.85)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }
            .frame(maxWidth: 320, maxHeight: 200, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.white.opacity(0.25), lineWidth: 1)
            )
            .overlay(
                Text("⟳")
                    .font(.system(size: 11))
                    .opacity(0.5)
                    .padding(.top, 6)
                    .padding(.trailing, 8)
                    .accessibilityHidden(true),
                alignment: .topTrailing
            )
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Changes made this week. Tap to cycle view.")
        .accessibilityHint("Cycles through alternate views of the panel's data.")
    }

    // MARK: - News screens

    private func articleScreen(_ article: Article) -> some View {
        GeometryReader { geo in
            if isLandscape {
                // Landscape: image fills the left half, text the right half.
                HStack(spacing: 0) {
                    articleImage(article)
                        .frame(width: geo.size.width * 0.5, height: geo.size.height)
                        .clipped()

                    articleText(article)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(20)
                }
            } else {
                // Portrait: image across the top 35%, text below.
                VStack(spacing: 0) {
                    articleImage(article)
                        .frame(width: geo.size.width, height: geo.size.height * 0.35)
                        .clipped()

                    articleText(article)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(20)
                }
            }
        }
        .ignoresSafeArea(edges: .top)
        .foregroundStyle(.white)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation { detailArticle = article } }
    }

    // Headline + description block shared by the portrait and landscape article layouts.
    private func articleText(_ article: Article) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(article.title)
                .font(.system(size: 24, weight: .bold))
                .multilineTextAlignment(.leading)
            if let description = article.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 16))
                    .opacity(0.9)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 0)
        }
    }

    private func articleDetailScreen(_ article: Article) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    withAnimation { detailArticle = nil }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .bold))
                        .padding(8)
                }
                .accessibilityLabel("Back to article")
                Spacer()
            }
            .padding(.horizontal, 12)

            // GeometryReader pins the content column to the screen width so a long
            // unbreakable token in the body (e.g. a bare URL) can't widen the column
            // past the screen — which previously clipped the left margin and pushed the
            // image full-bleed on narrower devices. The hard `.frame(width:)` forces the
            // body text to wrap within the column instead of overflowing it.
            GeometryReader { geo in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(article.title)
                            .font(.system(size: 26, weight: .bold))
                            .fixedSize(horizontal: false, vertical: true)

                        // Color.clear anchors the layout to exactly the column width; the
                        // scaledToFill image rides in a clipped overlay so it can't overflow
                        // the right margin the way `.frame(maxWidth: .infinity)` applied
                        // directly to the overflowing image did.
                        Color.clear
                            .frame(maxWidth: .infinity)
                            .frame(height: 200)
                            .overlay { articleImage(article) }
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 10))

                        articleBody(article)
                    }
                    .padding(20)
                    .frame(width: geo.size.width, alignment: .leading)
                }
            }
        }
        .foregroundStyle(.white)
        .task(id: article.url) { await loadFullText(article) }
    }

    // The article body: the full text scraped from article.url once it loads, with the
    // truncated GNews `content` shown immediately as a placeholder and on failure.
    @ViewBuilder
    private func articleBody(_ article: Article) -> some View {
        switch articleTextState {
        case .loaded(let text):
            Text(text)
                .font(.system(size: 16))
                .opacity(0.9)
                .fixedSize(horizontal: false, vertical: true)
        case .loading:
            truncatedContent(article)
            HStack(spacing: 8) {
                ProgressView().tint(.white)
                Text("Loading full article\u{2026}")
                    .font(.system(size: 14))
                    .opacity(0.7)
            }
            .padding(.top, 4)
        case .failed:
            truncatedContent(article)
        }
    }

    @ViewBuilder
    private func truncatedContent(_ article: Article) -> some View {
        if let content = article.content, !content.isEmpty {
            Text(content)
                .font(.system(size: 16))
                .opacity(0.9)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("No further text available for this article.")
                .font(.system(size: 15))
                .opacity(0.7)
        }
    }

    private var newsStatusScreen: some View {
        VStack(spacing: 12) {
            switch newsState {
            case .loading:
                ProgressView().tint(.white)
                Text("Loading latest news\u{2026}")
            case .missingKey:
                Text("Set GNEWS_API_KEY in Secrets.xcconfig — see ios/CLAUDE.md.")
                    .multilineTextAlignment(.center)
            case .failed:
                Text("Could not load news.")
            case .empty:
                Text("No news right now.")
            case .ready:
                EmptyView()
            }
        }
        .font(.system(size: 15))
        .foregroundStyle(.white)
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func articleImage(_ article: Article) -> some View {
        if let urlString = article.image, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFill()
                case .empty:
                    ZStack { imagePlaceholder; ProgressView().tint(.white) }
                case .failure:
                    imagePlaceholder
                @unknown default:
                    imagePlaceholder
                }
            }
        } else {
            imagePlaceholder
        }
    }

    private var imagePlaceholder: some View {
        Rectangle()
            .fill(.white.opacity(0.1))
            .overlay(
                Image(systemName: "newspaper")
                    .font(.system(size: 40))
                    .foregroundStyle(.white.opacity(0.5))
            )
    }

    // MARK: - News data

    private func loadNews() async {
        guard let key = gnewsAPIKey() else {
            newsState = .missingKey
            return
        }
        // Fetch the three categories concurrently, then concatenate in order
        // (general -> technology -> science) so articles stay grouped by category.
        async let general = fetchNews(category: Self.newsCategories[0], key: key)
        async let technology = fetchNews(category: Self.newsCategories[1], key: key)
        async let science = fetchNews(category: Self.newsCategories[2], key: key)
        let groups = await [general, technology, science]
        let succeeded = groups.compactMap { $0 }
        if succeeded.isEmpty {
            newsState = .failed
            return
        }
        let combined = succeeded.flatMap { $0 }
        newsState = combined.isEmpty ? .empty : .ready(combined)
    }

    private func fetchNews(category: String, key: String) async -> [Article]? {
        let urlString = "https://gnews.io/api/v4/top-headlines?category=\(category)&lang=en&country=us&apikey=\(key)"
        guard let url = URL(string: urlString) else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            return try JSONDecoder().decode(NewsResponse.self, from: data).articles
        } catch {
            return nil
        }
    }

    private func gnewsAPIKey() -> String? {
        let key = GeneratedSecrets.gnewsAPIKey
        return key.isEmpty ? nil : key
    }

    // MARK: - Full article text (client-side scrape of article.url)

    private func loadFullText(_ article: Article) async {
        guard let urlString = article.url, let url = URL(string: urlString) else {
            articleTextState = .failed
            return
        }
        articleTextState = .loading
        do {
            var request = URLRequest(url: url, timeoutInterval: 15)
            // Some sites serve a stripped page (or block) the default URLSession UA.
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
                forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let html = String(decoding: data, as: UTF8.self)
            let text = Self.extractReadableText(from: html)
            guard !text.isEmpty else { throw URLError(.cannotParseResponse) }
            articleTextState = .loaded(text)
        } catch {
            articleTextState = .failed
        }
    }

    // Heuristic readability extraction: strip non-content blocks, prefer the <article>
    // region, then collect block-level text. Good across most news sites, not perfect.
    static func extractReadableText(from html: String) -> String {
        let stripped = removeBlocks(
            html,
            tags: ["script", "style", "head", "noscript", "svg",
                   "header", "footer", "nav", "aside", "form", "figure", "button"])
        // Prefer the first <article>…</article> region when the page has one.
        let scope = captures(stripped, pattern: "<article\\b[^>]*>(.*?)</article>", group: 1).first ?? stripped
        let paragraphs = captures(scope, pattern: "<(p|h1|h2|h3|li)\\b[^>]*>(.*?)</\\1>", group: 2)
            .map { collapseWhitespace(decodeEntities(stripTags($0))) }
            .filter { $0.count >= 40 }          // drop nav/ad/byline scraps
            .filter { !looksLikeMarkup($0) }    // drop escaped-HTML/JSON blobs that survived stripping
        if !paragraphs.isEmpty {
            return paragraphs.joined(separator: "\n\n")
        }
        // Fallback: strip every tag from the scope and return whatever text remains.
        return collapseWhitespace(decodeEntities(stripTags(scope)))
    }

    private static func removeBlocks(_ html: String, tags: [String]) -> String {
        var s = html
        for tag in tags {
            s = replacingRegex(s, pattern: "<\(tag)\\b[^>]*>.*?</\(tag)>", with: " ")
        }
        return s
    }

    private static func stripTags(_ s: String) -> String {
        replacingRegex(s, pattern: "<[^>]+>", with: " ")
    }

    // True when a candidate paragraph still carries markup/JSON signatures (some pages
    // embed escaped HTML inside attributes that survives tag stripping). Clean prose never does.
    private static func looksLikeMarkup(_ s: String) -> Bool {
        s.contains("href=") || s.contains("src=") || s.contains("</") || s.contains("/>")
    }

    private static func collapseWhitespace(_ s: String) -> String {
        replacingRegex(s, pattern: "\\s+", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ s: String) -> String {
        var t = s
        let named: [String: String] = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&nbsp;": " ",
            "&mdash;": "\u{2014}", "&ndash;": "\u{2013}", "&hellip;": "\u{2026}",
            "&rsquo;": "\u{2019}", "&lsquo;": "\u{2018}",
            "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}"
        ]
        for (k, v) in named { t = t.replacingOccurrences(of: k, with: v) }
        return decodeNumericEntities(t)
    }

    // &#160; (decimal) and &#xA0; (hex) numeric character references.
    private static func decodeNumericEntities(_ s: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "&#(x?)([0-9A-Fa-f]+);") else { return s }
        let ns = s as NSString
        var result = ""
        var last = 0
        re.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match = match else { return }
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            let isHex = ns.substring(with: match.range(at: 1)) == "x"
            let digits = ns.substring(with: match.range(at: 2))
            if let code = UInt32(digits, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                result += String(scalar)
            }
            last = match.range.location + match.range.length
        }
        result += ns.substring(with: NSRange(location: last, length: ns.length - last))
        return result
    }

    private static func captures(_ s: String, pattern: String, group: Int) -> [String] {
        guard let re = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(s.startIndex..., in: s)
        return re.matches(in: s, range: range).compactMap { match in
            guard match.numberOfRanges > group, let r = Range(match.range(at: group), in: s) else { return nil }
            return String(s[r])
        }
    }

    private static func replacingRegex(_ s: String, pattern: String, with replacement: String) -> String {
        guard let re = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, range: range, withTemplate: replacement)
    }

    private func loadQuote() async {
        do {
            let url = URL(string: "https://dummyjson.com/quotes/random")!
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            quote = try JSONDecoder().decode(Quote.self, from: data)
        } catch {
            quoteError = true
        }
    }

    private func loadIssues() async {
        do {
            let url = URL(string: "https://api.github.com/repos/wongvin/firstcontact/issues?state=closed&per_page=30&sort=updated&direction=desc")!
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let all = try decoder.decode([Issue].self, from: data)
            let cutoff = Date().addingTimeInterval(-7 * 86_400)
            issues = all
                .filter { $0.pullRequest == nil && ($0.closedAt ?? .distantPast) >= cutoff }
                .sorted { ($0.closedAt ?? .distantPast) > ($1.closedAt ?? .distantPast) }
        } catch {
            issuesError = true
        }
        issuesLoaded = true
    }

    private func loadSummary() async {
        let cached = readCachedSummary()
        if let cached, isFresh(cached) {
            summaryState = .ready(cached.summary, stale: false)
            return
        }
        if let cached {
            summaryState = .ready(cached.summary, stale: false)
        } else {
            summaryState = .loading
        }

        guard let apiKey = geminiAPIKey(), !apiKey.isEmpty else {
            if cached == nil { summaryState = .missingKey }
            return
        }

        do {
            let titles = try await fetchClosedIssues30d()
            if titles.isEmpty {
                let prose = "No issues were closed in the last 30 days."
                writeCachedSummary(prose)
                summaryState = .ready(prose, stale: false)
                return
            }
            let prompt = buildSummaryPrompt(titles: titles)
            var prose = try await callGemini(apiKey: apiKey, prompt: prompt)
            if wordCount(prose) > Self.wordLimit {
                let retryPrompt = prompt + "\n\nYour previous response exceeded \(Self.wordLimit) words. Rewrite it more concisely. Hard limit: strictly under \(Self.wordLimit) words."
                prose = try await callGemini(apiKey: apiKey, prompt: retryPrompt)
            }
            if wordCount(prose) > Self.wordLimit {
                prose = truncateToWordLimit(prose, limit: Self.wordLimit)
            }
            writeCachedSummary(prose)
            summaryState = .ready(prose, stale: false)
        } catch {
            if let cached {
                summaryState = .ready(cached.summary, stale: true)
            } else {
                summaryState = .failedNoCache
            }
        }
    }

    private func geminiAPIKey() -> String? {
        // Value comes from Secrets.xcconfig (gitignored) via the
        // "Generate Secrets" build phase that writes GeneratedSecrets.swift.
        // See ios/CLAUDE.md "API keys and Secrets.xcconfig".
        let key = GeneratedSecrets.geminiAPIKey
        return key.isEmpty ? nil : key
    }

    private func readCachedSummary() -> CachedSummary? {
        guard let data = UserDefaults.standard.data(forKey: Self.summaryCacheKey) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(CachedSummary.self, from: data)
    }

    private func writeCachedSummary(_ prose: String) {
        let payload = CachedSummary(summary: prose, generatedAt: Date(), ttlHours: Self.summaryTTLHours)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: Self.summaryCacheKey)
    }

    private func isFresh(_ cached: CachedSummary) -> Bool {
        let age = Date().timeIntervalSince(cached.generatedAt)
        let ttlSeconds = TimeInterval(cached.ttlHours * 3600)
        return age < ttlSeconds
    }

    private func fetchClosedIssues30d() async throws -> [Issue] {
        let cutoff = Date().addingTimeInterval(-Double(Self.issueWindowDays) * 86_400)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let since = formatter.string(from: cutoff)
        let urlString = "https://api.github.com/repos/wongvin/firstcontact/issues?state=closed&per_page=100&since=\(since)&sort=updated&direction=desc"
        guard let url = URL(string: urlString) else { return [] }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let all = try decoder.decode([Issue].self, from: data)
        let filtered = all
            .filter { $0.pullRequest == nil && ($0.closedAt ?? .distantPast) >= cutoff }
            .sorted { ($0.closedAt ?? .distantPast) > ($1.closedAt ?? .distantPast) }
        return Array(filtered.prefix(Self.issueFetchLimit))
    }

    private func extractPrefix(_ title: String) -> String {
        let pattern = #"^(feat|fix|chore|docs|refactor|test|build|ci|perf)(\(.+?\))?:"#
        let lowered = title.lowercased()
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return "other" }
        let range = NSRange(lowered.startIndex..., in: lowered)
        guard let match = regex.firstMatch(in: lowered, options: [], range: range),
              match.numberOfRanges > 1,
              let r = Range(match.range(at: 1), in: lowered) else {
            return "other"
        }
        return String(lowered[r])
    }

    private func buildSummaryPrompt(titles: [Issue]) -> String {
        let lines = titles.map { issue -> String in
            let title = issue.title.trimmingCharacters(in: .whitespaces)
            let prefix = extractPrefix(title)
            return "- [\(prefix)] \(title)"
        }
        return """
            Recently-closed issues from the last \(Self.issueWindowDays) days \
            (most recent first, \(titles.count) total):

            \(lines.joined(separator: "\n"))

            Write a single plain-prose paragraph strictly under \(Self.wordLimit) words \
            summarizing the overall themes. No bullet points, no markdown, no emojis.
            """
    }

    private func callGemini(apiKey: String, prompt: String) async throws -> String {
        let config = GenerationConfig(temperature: 0.4)
        let model = GenerativeModel(
            name: Self.geminiModel,
            apiKey: apiKey,
            generationConfig: config,
            systemInstruction: ModelContent(parts: [.text(Self.geminiSystemPrompt)])
        )
        let response = try await model.generateContent(prompt)
        let text = (response.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            throw URLError(.cannotParseResponse)
        }
        return text
    }

    private func wordCount(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        return trimmed.split(whereSeparator: { $0.isWhitespace }).count
    }

    private func truncateToWordLimit(_ text: String, limit: Int) -> String {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
        if words.count <= limit { return text }
        let kept = words.prefix(limit).joined(separator: " ")
        let trailingPunctuation = CharacterSet(charactersIn: ",.;:")
        return kept.trimmingCharacters(in: trailingPunctuation) + "\u{2026}"
    }
}

#Preview {
    ContentView()
}
