//
//  ContentView.swift
//  FirstContact
//
//  Created by Vincent Wong on 4/26/26.
//

import SwiftUI
import UIKit
import WebKit
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

// A single message typed in the long-press compose screen. Persisted to UserDefaults
// so the thread survives app relaunches (same approach as CachedSummary).
struct ComposeMessage: Codable, Identifiable {
    let id: UUID
    let text: String
}

// A saved keyword from the key-term panel — its own persisted list, separate from the
// compose messages above. `excluded` keywords render as a red bubble.
struct Keyword: Codable, Identifiable {
    let id: UUID
    let text: String
    var excluded: Bool = false

    enum CodingKeys: String, CodingKey { case id, text, excluded }

    init(id: UUID, text: String, excluded: Bool = false) {
        self.id = id
        self.text = text
        self.excluded = excluded
    }

    // Decode `excluded` defensively so keywords saved before the field existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        excluded = try c.decodeIfPresent(Bool.self, forKey: .excluded) ?? false
    }
}

// Wrapping flow layout: places subviews left-to-right, wrapping to the next line when the
// available width runs out, top-to-bottom, starting at the top-left. Used for keyword chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                totalWidth = max(totalWidth, rowWidth)
                totalHeight += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalWidth = max(totalWidth, rowWidth)
        totalHeight += rowHeight
        return CGSize(width: min(totalWidth, maxWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - WebKit page fetch (Cloudflare / bot-wall fallback)

// Loads a URL in a hidden WKWebView and returns the rendered HTML. Used as a fallback when
// a plain URLSession GET is blocked (e.g. Cloudflare 403s URLSession on its client
// fingerprint but serves a real WebKit engine). The web view runs the page's JS — including
// any Cloudflare challenge — so we read the DOM only after navigation settles.
@MainActor
final class WebPageFetcher: NSObject, WKNavigationDelegate {

    // Convenience entry point: one fetch per call, self-retained for its lifetime.
    static func html(from url: URL, timeout: TimeInterval = 25) async -> String? {
        await WebPageFetcher().load(url, timeout: timeout)
    }

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<String?, Never>?
    private var pollTask: Task<Void, Never>?
    private var finished = false

    private func load(_ url: URL, timeout: TimeInterval) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            continuation = cont

            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
            webView.navigationDelegate = self
            webView.customUserAgent =
                "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
            // Attach off-screen to the key window so the page's JS timers actually run
            // (WebKit throttles script in a web view that isn't in a window) — needed for
            // Cloudflare's challenge to complete.
            if let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap({ $0.windows })
                .first(where: { $0.isKeyWindow }) {
                webView.isHidden = true
                window.addSubview(webView)
            }
            self.webView = webView
            webView.load(URLRequest(url: url, timeoutInterval: timeout))
        }
    }

    // Start polling once the first navigation finishes. A Cloudflare interstitial loads first
    // and then auto-navigates to the real page once its JS challenge passes, so we can't just
    // read the DOM on the first didFinish — we poll until the content is no longer a challenge
    // page (or the timeout elapses).
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in await self?.pollUntilSettled() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(nil)
    }

    private func pollUntilSettled() async {
        // Give the page a few seconds to either render real content or clear a quick
        // interstitial. An interactive Cloudflare challenge won't auto-clear in a hidden
        // web view, so we bail rather than block — the caller then offers "Open in Safari".
        for _ in 0..<6 {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if finished { return }
            guard let webView else { return }
            let html = try? await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String
            if let html, !Self.looksLikeChallenge(html) {
                finish(html)
                return
            }
        }
        finish(nil)   // still challenged / no real content — fall through to the Safari fallback
    }

    // Cloudflare / generic interstitial markers. Used to keep waiting rather than scraping
    // "checking your connection…" as if it were the article body.
    private static func looksLikeChallenge(_ html: String) -> Bool {
        let needles = ["challenge-platform", "cf-chl", "_cf_chl", "cf-browser-verification",
                       "Just a moment", "Checking your connection", "checking your connection",
                       "Enable JavaScript and cookies to continue"]
        return needles.contains { html.contains($0) }
    }

    private func finish(_ html: String?) {
        guard !finished else { return }
        finished = true
        pollTask?.cancel()
        webView?.navigationDelegate = nil
        webView?.removeFromSuperview()
        webView = nil
        continuation?.resume(returning: html)
        continuation = nil
    }
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

// A drilled-in feed of related news, spawned by cross-swiping a headline: GNews `search`
// results for that headline's Gemini key term. Articles-only (no home); one level deep.
struct NewsFeed: Identifiable {
    let id = UUID()
    let source: Article        // the headline that spawned this feed
    var state: NewsState       // .loading → .ready([Article]) / .empty / .failed / .missingKey
    var index = 0              // current article within this feed
    var articles: [Article] { if case .ready(let a) = state { return a } else { return [] } }
}

// Full article body fetched from the article's linked URL. GNews only returns a
// ~160-char truncated `content` field, so the detail screen scrapes the source page.
enum ArticleTextState {
    case loading
    case loaded(String)
    case failed
}

// Gemini-extracted key word/term for an article (from headline + description only).
enum KeywordState {
    case loading
    case loaded(String)
    case failed
    case missingKey
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
    @State private var spawnedFeed: NewsFeed?                 // nil = base pager; one level only
    @State private var spawnCache: [String: NewsState] = [:] // related-news by source article.url (session memory)
    @State private var keywordTermCache: [String: String] = [:] // key-term panel's Gemini term by article.url (session memory)
    @State private var detailArticle: Article?
    @State private var articleTextState: ArticleTextState = .loading
    @State private var keywordArticle: Article?      // article whose term to suggest; nil when opened without an article
    @State private var showKeywordPanel = false      // drives panel presentation (article optional)
    @State private var keywordState: KeywordState = .loading
    @State private var keywordDragOffset: CGFloat = 0
    @State private var keywords: [Keyword] = []
    @State private var keywordDraft = ""
    @State private var showKeywordTooLong = false
    @FocusState private var keywordFieldFocused: Bool
    @State private var showCompose = false
    @State private var messages: [ComposeMessage] = []
    @State private var draft = ""
    @FocusState private var composeFieldFocused: Bool
    // On iPhone a compact vertical size class means landscape orientation.
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    private var isLandscape: Bool { verticalSizeClass == .compact }

    private static let summaryCacheKey = "firstcontact.summary30d.v1"
    private static let composeCacheKey = "firstcontact.compose.v1"
    private static let keywordCacheKey = "firstcontact.keywords.v1"
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
    private static let keywordSystemPrompt = """
        You extract the single most important key word or short term (1-4 words) from a \
        news headline, description, and content. Respond with ONLY that word or term — no punctuation \
        wrapping, no quotes, no explanation, no preamble. Use only the provided headline, description, and content.
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

            if showCompose {
                composeScreen
                    .transition(.move(edge: .trailing))
            } else if let article = detailArticle {
                articleDetailScreen(article)
                    .transition(.move(edge: .trailing))
            } else {
                ZStack(alignment: isLandscape ? .trailing : .bottom) {
                    Group {
                        if let feed = spawnedFeed {
                            spawnedFeedPager(feed)
                                .transition(.move(edge: .trailing))
                        } else {
                            pager
                        }
                    }
                    .allowsHitTesting(!showKeywordPanel)
                    if showKeywordPanel {
                        // Dim the screen behind; tapping it dismisses the sheet.
                        Color.black.opacity(0.35)
                            .ignoresSafeArea()
                            .transition(.opacity)
                            .onTapGesture { withAnimation { showKeywordPanel = false } }
                        keywordPanel()
                            .transition(.move(edge: isLandscape ? .trailing : .bottom))
                    }
                }
            }
        }
        .task { await loadQuote() }
        .task { await loadIssues() }
        .task { await loadSummary() }
        .task { await loadNews() }
        .task { messages = loadComposeMessages() }
        .task { keywords = loadKeywords() }
        .alert("Search filter too long", isPresented: $showKeywordTooLong) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The keyword search expression is over GNews's 200-character limit, so some keywords may not be applied to the news filter.")
        }
    }

    // Vertical swipe pager: home at index 0, news articles after it, wrapping in a
    // circular ring (swipe up past the last article -> home; swipe down on home -> last).
    private var pager: some View {
        currentScreen
            .id(screenIndex)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    // The base pager's currently-shown article, or nil on the home/status screen.
    private var currentArticle: Article? {
        guard screenIndex >= 1, case .ready(let articles) = newsState,
              screenIndex - 1 < articles.count else { return nil }
        return articles[screenIndex - 1]
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
        // Long-press on the welcome screen opens the compose screen. simultaneousGesture
        // coexists with the panels' button taps (tap-to-cycle still works); scoping it to
        // homeScreen means other pager screens and the article/key-term overlays don't trigger it.
        .contentShape(Rectangle())
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in withAnimation { showCompose = true } }
        )
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
                let horizontal = abs(dx) > abs(dy)
                // Navigation runs on the horizontal axis in landscape, vertical in portrait.
                if horizontal == isLandscape {
                    let primary = isLandscape ? dx : dy
                    guard abs(primary) > 50 else { return }
                    let total = totalScreens
                    guard total > 1 else { return }
                    // No animation: pages swap instantly (no slide or fade).
                    if primary < 0 {
                        screenIndex = (screenIndex + 1) % total
                    } else {
                        screenIndex = (screenIndex - 1 + total) % total
                    }
                } else {
                    // Cross-axis swipe on a headline drills into a related-news feed.
                    let cross = isLandscape ? dy : dx
                    guard abs(cross) > 50, let article = currentArticle else { return }
                    withAnimation { spawn(from: article) }
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
        // Long-press an article (any non-home screen) opens the keyword panel, pre-filled
        // with that article's Gemini key term. simultaneousGesture so it coexists with the
        // tap-to-open-detail and the pager swipe.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in withAnimation { keywordArticle = article; showKeywordPanel = true } }
        )
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
        // A horizontal swipe (either direction) dismisses, like the back chevron.
        // simultaneousGesture so the body's vertical scrolling still works; we only
        // act on horizontal-dominant swipes.
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if abs(value.translation.width) > abs(value.translation.height),
                       abs(value.translation.width) > 50 {
                        withAnimation { detailArticle = nil }
                    }
                }
        )
        .task(id: article.url) { await loadFullText(article) }
    }

    // Reached by a long-press on an article: a half-size compose sheet for keywords,
    // peeking over the (dimmed) article. A thread of saved keyword bubbles (own store,
    // separate from the compose messages) sits above an input box pre-filled with the
    // Gemini-extracted term. Portrait = bottom half (slides up); landscape = right half
    // (slides in). Dismiss by dragging it down/right or tapping the dimmed area outside.
    // A grabber handle hints the drag; long-press a bubble to delete it.
    private func keywordPanel() -> some View {
        // Round only the inner corners so the outer edges sit flush to the screen.
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: 20,
            bottomLeadingRadius: isLandscape ? 20 : 0,
            bottomTrailingRadius: 0,
            topTrailingRadius: isLandscape ? 0 : 20,
            style: .continuous
        )
        // Compose content: a static (non-scrolling) keyword thread + status + input.
        // No ScrollView, so the panel-wide drag-to-dismiss has nothing to conflict with.
        return VStack(spacing: 0) {
            // Bubbles flow left-to-right and wrap top-to-bottom, starting at the top-left.
            FlowLayout(spacing: 8) {
                ForEach(sortedKeywords) { keyword in
                    Text(keyword.text)
                        .font(.system(size: 16))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(keyword.excluded ? Color.red : Color.blue,
                                    in: RoundedRectangle(cornerRadius: 18))
                        .contextMenu {
                            Button {
                                withAnimation { toggleExcluded(keyword) }
                            } label: {
                                if keyword.excluded {
                                    Label("Include", systemImage: "plus.circle")
                                } else {
                                    Label("Exclude", systemImage: "minus.circle")
                                }
                            }
                            Button(role: .destructive) {
                                withAnimation { deleteKeyword(keyword) }
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            keywordContent

            HStack(spacing: 8) {
                TextField("Keyword", text: $keywordDraft)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
                    .focused($keywordFieldFocused)
                    .submitLabel(.send)
                    .onSubmit(sendKeyword)

                if !keywordDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: sendKeyword) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel("Send keyword")
                }
            }
            .padding()
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerRelativeFrame(isLandscape ? .horizontal : .vertical) { dim, _ in dim / 2 }
        .background(.ultraThinMaterial)
        .overlay(alignment: isLandscape ? .leading : .top) {
            Capsule()
                .fill(.white.opacity(0.5))
                .frame(width: isLandscape ? 5 : 40, height: isLandscape ? 40 : 5)
                .padding(isLandscape ? .leading : .top, 8)
        }
        .clipShape(shape)
        .overlay(shape.stroke(.white.opacity(0.2), lineWidth: 1))
        .offset(x: isLandscape ? keywordDragOffset : 0, y: isLandscape ? 0 : keywordDragOffset)
        .gesture(keywordDismissDrag)
        .task(id: keywordArticle?.title) {
            if let article = keywordArticle {
                await loadKeyword(article)        // pre-fill the input with the article's term
            } else {
                keywordState = .loaded("")        // opened without an article → no term, no spinner
            }
        }
    }

    // Drag the sheet in its entry direction (down in portrait, right in landscape) to dismiss.
    private var keywordDismissDrag: some Gesture {
        DragGesture()
            .onChanged { value in
                let t = isLandscape ? value.translation.width : value.translation.height
                keywordDragOffset = max(0, t)
            }
            .onEnded { value in
                let t = isLandscape ? value.translation.width : value.translation.height
                if t > 120 { withAnimation { showKeywordPanel = false } }
                withAnimation { keywordDragOffset = 0 }
            }
    }

    // Compact status shown just above the keyword input: a spinner while the Gemini term
    // loads, an error / missing-key hint otherwise. Empty once loaded — the term is then
    // pre-filled into the input box (keywordDraft).
    @ViewBuilder
    private var keywordContent: some View {
        switch keywordState {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().tint(.white)
                Text("Finding the key term\u{2026}")
                    .font(.system(size: 13))
                    .opacity(0.7)
            }
            .padding(.bottom, 4)
        case .failed:
            Text("Couldn't extract a key term.")
                .font(.system(size: 13))
                .opacity(0.8)
                .padding(.bottom, 4)
        case .missingKey:
            Text("Set GEMINI_API_KEY in Secrets.xcconfig — see ios/CLAUDE.md.")
                .font(.system(size: 12))
                .opacity(0.85)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.bottom, 4)
        case .loaded:
            EmptyView()
        }
    }

    // MARK: - Compose screen (long-press)

    // iMessage-style screen reached by long-pressing any other screen: a scrollable
    // thread of sent bubbles above a bottom input bar. Dismissed via the top-left chevron.
    private var composeScreen: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    withAnimation { showCompose = false }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .bold))
                        .padding(8)
                }
                .accessibilityLabel("Back")
                Spacer()
            }
            .padding(.horizontal, 12)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(messages) { message in
                            HStack {
                                Spacer(minLength: 40)
                                Text(message.text)
                                    .font(.system(size: 16))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(Color.blue, in: RoundedRectangle(cornerRadius: 18))
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            withAnimation { delete(message) }
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                            }
                            .id(message.id)
                        }
                    }
                    .padding()
                }
                .onChange(of: messages.count) {
                    guard let last = messages.last else { return }
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }

            HStack(spacing: 8) {
                TextField("Message", text: $draft)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
                    .focused($composeFieldFocused)
                    .submitLabel(.send)
                    .onSubmit(send)

                if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel("Send")
                }
            }
            .padding()
        }
        .foregroundStyle(.white)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messages.append(ComposeMessage(id: UUID(), text: text))
        draft = ""
        saveComposeMessages()
    }

    private func delete(_ message: ComposeMessage) {
        messages.removeAll { $0.id == message.id }
        saveComposeMessages()
    }

    private func loadComposeMessages() -> [ComposeMessage] {
        guard let data = UserDefaults.standard.data(forKey: Self.composeCacheKey) else { return [] }
        return (try? JSONDecoder().decode([ComposeMessage].self, from: data)) ?? []
    }

    private func saveComposeMessages() {
        guard let data = try? JSONEncoder().encode(messages) else { return }
        UserDefaults.standard.set(data, forKey: Self.composeCacheKey)
    }

    // MARK: - Keyword thread (key-term panel; own store, separate from compose messages)

    private func sendKeyword() {
        let text = keywordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        keywords.append(Keyword(id: UUID(), text: text))
        keywordDraft = ""
        saveKeywords()
        warnIfQueryTooLong()
    }

    private func deleteKeyword(_ keyword: Keyword) {
        keywords.removeAll { $0.id == keyword.id }
        saveKeywords()
    }

    private func toggleExcluded(_ keyword: Keyword) {
        guard let i = keywords.firstIndex(where: { $0.id == keyword.id }) else { return }
        keywords[i].excluded.toggle()
        saveKeywords()
        // Excluding adds a `NOT ` prefix, lengthening the expression; warn only then.
        if keywords[i].excluded { warnIfQueryTooLong() }
    }

    // Display order: non-excluded (blue) bubbles first, excluded (red) last. Stable within
    // each group (insertion order preserved). Storage order is unchanged — this is display-only.
    private var sortedKeywords: [Keyword] {
        keywords.filter { !$0.excluded } + keywords.filter { $0.excluded }
    }

    // Boolean GNews `q` from saved keywords: the blue (included) terms are OR-ed inside one
    // parenthesized group, then AND-ed with each NOT-prefixed red (excluded) term —
    //   ("blue1" OR "blue2") AND NOT "red1" AND NOT "red2"
    // Empty string when there are no keywords. Reads the persisted list directly (not @State
    // `keywords`) so it's correct at launch, where loadNews() races the keyword-load `.task`.
    private func keywordQuery() -> String {
        let saved = loadKeywords()
        let blue = saved.filter { !$0.excluded }.map { "\"\($0.text)\"" }
        let red  = saved.filter {  $0.excluded }.map { "NOT \"\($0.text)\"" }
        var parts: [String] = []
        if !blue.isEmpty { parts.append("(" + blue.joined(separator: " OR ") + ")") }
        parts += red
        return parts.joined(separator: " AND ")
    }

    // GNews caps `q` at 200 characters; warn (informational) if the expression exceeds it.
    private func warnIfQueryTooLong() {
        if keywordQuery().count > 200 { showKeywordTooLong = true }
    }

    private func loadKeywords() -> [Keyword] {
        guard let data = UserDefaults.standard.data(forKey: Self.keywordCacheKey) else { return [] }
        return (try? JSONDecoder().decode([Keyword].self, from: data)) ?? []
    }

    private func saveKeywords() {
        guard let data = try? JSONEncoder().encode(keywords) else { return }
        UserDefaults.standard.set(data, forKey: Self.keywordCacheKey)
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
            openInSafariLink(article)
        }
    }

    // Shown when the full body can't be scraped (e.g. a publisher behind a Cloudflare /
    // bot-wall that blocks URLSession and serves an interactive challenge our hidden
    // WKWebView can't clear). Opens the source in Safari, which passes the challenge natively.
    @ViewBuilder
    private func openInSafariLink(_ article: Article) -> some View {
        if let urlString = article.url, let url = URL(string: urlString) {
            Link(destination: url) {
                HStack(spacing: 6) {
                    Text("Open full article in Safari")
                    Image(systemName: "arrow.up.right.square")
                }
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.vertical, 10)
                .padding(.horizontal, 16)
                .background(.white.opacity(0.18), in: Capsule())
            }
            .padding(.top, 4)
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

    // Loading / empty / failed / missing-key status view for any NewsState — shared by the
    // base pager and spawned feeds.
    private func statusScreen(for state: NewsState) -> some View {
        VStack(spacing: 12) {
            switch state {
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

    private var newsStatusScreen: some View {
        statusScreen(for: newsState)
            .contentShape(Rectangle())
            // Long-press the status screen (e.g. "No news right now." when the keyword filter is
            // too narrow) opens the keyword panel — no article, so no term is pre-filled.
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5)
                    .onEnded { _ in withAnimation { keywordArticle = nil; showKeywordPanel = true } }
            )
    }

    // MARK: - Spawned related-news feed (cross-swipe drill-down)

    // Articles-only pager for a spawned feed: a top-left back chevron above the feed's current
    // article (or its loading/empty/failed status). Inherits tap→detail and long-press→keyword
    // via articleScreen. Nav-axis swipe pages within the feed; cross-swipe is ignored (one level).
    private func spawnedFeedPager(_ feed: NewsFeed) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    withAnimation { spawnedFeed = nil }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 20, weight: .bold))
                        .padding(8)
                }
                .accessibilityLabel("Back to headline")
                Spacer()
            }
            .padding(.horizontal, 12)
            .foregroundStyle(.white)

            Group {
                if !feed.articles.isEmpty, feed.index < feed.articles.count {
                    articleScreen(feed.articles[feed.index])
                } else {
                    statusScreen(for: feed.state)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(spawnedFeedSwipe(count: feed.articles.count))
        }
    }

    // Nav-axis paging within the spawned feed (wraps among its articles). Cross-axis ignored.
    private func spawnedFeedSwipe(count: Int) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                let horizontal = abs(value.translation.width) > abs(value.translation.height)
                guard horizontal == isLandscape else { return }   // cross-axis: no drill-down (one level)
                let primary = isLandscape ? value.translation.width : value.translation.height
                guard abs(primary) > 50, count > 1,
                      let i = spawnedFeed?.index else { return }
                spawnedFeed?.index = primary < 0 ? (i + 1) % count : (i - 1 + count) % count
            }
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
        // `q` filters each category by the keyword expression ("" when no keywords).
        let q = keywordQuery()
        async let general = fetchNews(category: Self.newsCategories[0], key: key, query: q)
        async let technology = fetchNews(category: Self.newsCategories[1], key: key, query: q)
        async let science = fetchNews(category: Self.newsCategories[2], key: key, query: q)
        let groups = await [general, technology, science]
        let succeeded = groups.compactMap { $0 }
        if succeeded.isEmpty {
            newsState = .failed
            return
        }
        let combined = succeeded.flatMap { $0 }
        newsState = combined.isEmpty ? .empty : .ready(combined)
    }

    private func fetchNews(category: String, key: String, query: String) async -> [Article]? {
        // URLComponents percent-encodes the q expression (quotes/spaces/AND/NOT) correctly.
        // The q item is always present — its value may be the empty string.
        var components = URLComponents(string: "https://gnews.io/api/v4/top-headlines")
        components?.queryItems = [
            URLQueryItem(name: "category", value: category),
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "in", value: "title,description,content"),
            URLQueryItem(name: "lang", value: "en"),
            URLQueryItem(name: "country", value: "us"),
            URLQueryItem(name: "max", value: "10"),
            URLQueryItem(name: "apikey", value: key)
        ]
        guard let url = components?.url else { return nil }
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

    // GNews /search for related-news drill-down (q = a single key term).
    private func searchNews(query: String, key: String) async -> [Article]? {
        var components = URLComponents(string: "https://gnews.io/api/v4/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "in", value: "title,description,content"),
            URLQueryItem(name: "lang", value: "en"),
            URLQueryItem(name: "country", value: "us"),
            URLQueryItem(name: "max", value: "10"),
            URLQueryItem(name: "apikey", value: key)
        ]
        guard let url = components?.url else { return nil }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            return try JSONDecoder().decode(NewsResponse.self, from: data).articles
        } catch {
            return nil
        }
    }

    // MARK: - Related-news drill-down (cross-swipe a headline)

    // Cross-swipe handler: show a feed of related news for `article`. Reuses the session cache
    // (keyed by article.url) so the same headline never re-runs Gemini or the GNews search.
    private func spawn(from article: Article) {
        let cacheKey = article.url   // nil → spawn without caching
        if let cacheKey, let cached = spawnCache[cacheKey] {
            spawnedFeed = NewsFeed(source: article, state: cached)
            return
        }
        let feed = NewsFeed(source: article, state: .loading)
        spawnedFeed = feed
        Task {
            let state = await fetchSpawnState(for: article)
            if let cacheKey { spawnCache[cacheKey] = state }
            if spawnedFeed?.id == feed.id { spawnedFeed?.state = state }   // still showing this feed
        }
    }

    // Gemini key term for the headline, then a GNews search on it → a NewsState.
    private func fetchSpawnState(for article: Article) async -> NewsState {
        guard let geminiKey = geminiAPIKey() else { return .missingKey }
        guard let gnewsKey = gnewsAPIKey() else { return .missingKey }
        let input = "Headline: \(article.title)\nDescription: \(article.description ?? "")\nContent: \(article.content ?? "")"
        let term: String
        do {
            term = try await generateKeyword(apiKey: geminiKey, input: input)
        } catch {
            return .failed
        }
        guard !term.isEmpty else { return .failed }
        guard let articles = await searchNews(query: term, key: gnewsKey) else { return .failed }
        return articles.isEmpty ? .empty : .ready(articles)
    }

    // MARK: - Full article text (client-side scrape of article.url)

    private func loadFullText(_ article: Article) async {
        guard let urlString = article.url, let url = URL(string: urlString) else {
            articleTextState = .failed
            return
        }
        articleTextState = .loading
        // Fast path: a plain URLSession GET. Works for most publishers.
        if let html = await fetchHTMLDirect(url) {
            let text = Self.extractReadableText(from: html)
            if !text.isEmpty {
                articleTextState = .loaded(text)
                return
            }
        }
        // Fallback: some publishers (e.g. phys.org, NYT) sit behind Cloudflare/bot walls
        // that 403 URLSession on its client fingerprint regardless of User-Agent, but
        // serve normally to a real WebKit engine. Retry through a hidden WKWebView, which
        // presents a genuine Safari fingerprint and runs any JS challenge, then extract
        // from the rendered DOM.
        if let html = await WebPageFetcher.html(from: url),
           case let text = Self.extractReadableText(from: html), !text.isEmpty {
            articleTextState = .loaded(text)
            return
        }
        articleTextState = .failed
    }

    // Direct URLSession fetch. Returns the page HTML on a 200, nil on any failure/non-200
    // (the caller then tries the WebKit fallback).
    private func fetchHTMLDirect(_ url: URL) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        // Some sites serve a stripped page (or block) the default URLSession UA.
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }

    // Heuristic readability extraction: strip non-content blocks, then collect block-level text
    // from the best scope. Good across most news sites, not perfect.
    static func extractReadableText(from html: String) -> String {
        let stripped = removeBlocks(
            html,
            tags: ["script", "style", "head", "noscript", "svg",
                   "header", "footer", "nav", "aside", "form", "figure", "button"])
        // Pick the scope to harvest paragraphs from. Pages vary: some wrap the body in one
        // <article> (related-link lists / sidebars sit outside it, so scoping helps), others
        // scatter many small <article> promo cards with the real body outside all of them
        // (e.g. Business Insider). So compare the richest <article> region against the whole
        // doc — only scope to the article when it holds most of the page's readable text;
        // otherwise the body isn't inside one and the whole doc is the better source.
        let docParagraphs = readableParagraphs(in: stripped)
        let articleParagraphs = captures(stripped, pattern: "<article\\b[^>]*>(.*?)</article>", group: 1)
            .map { readableParagraphs(in: $0) }
            .max { paragraphCharCount($0) < paragraphCharCount($1) } ?? []
        let docCount = paragraphCharCount(docParagraphs)
        let useArticle = docCount > 0 && paragraphCharCount(articleParagraphs) >= docCount / 2
        let paragraphs = useArticle ? articleParagraphs : docParagraphs
        if !paragraphs.isEmpty {
            return paragraphs.joined(separator: "\n\n")
        }
        // Fallback: strip every tag and return whatever text remains.
        return collapseWhitespace(decodeEntities(stripTags(stripped)))
    }

    // Block-level text in a scope, cleaned and filtered down to body-prose candidates.
    private static func readableParagraphs(in scope: String) -> [String] {
        captures(scope, pattern: "<(p|h1|h2|h3|li)\\b[^>]*>(.*?)</\\1>", group: 2)
            .map { collapseWhitespace(decodeEntities(stripTags($0))) }
            .filter { $0.count >= 40 }          // drop nav/ad/byline scraps
            .filter { !looksLikeMarkup($0) }    // drop escaped-HTML/JSON blobs that survived stripping
    }

    private static func paragraphCharCount(_ paragraphs: [String]) -> Int {
        paragraphs.reduce(0) { $0 + $1.count }
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

    // MARK: - Key term (Gemini, from headline + description)

    private func loadKeyword(_ article: Article) async {
        keywordState = .loading
        guard let apiKey = geminiAPIKey() else {
            keywordState = .missingKey
            return
        }
        // Reuse the session cache (keyed by article.url) so the same headline never re-runs Gemini.
        if let cacheKey = article.url, let cached = keywordTermCache[cacheKey] {
            keywordState = .loaded(cached)
            keywordDraft = cached
            return
        }
        let description = article.description ?? ""
        let content = article.content ?? ""
        let input = "Headline: \(article.title)\nDescription: \(description)\nContent: \(content)"
        do {
            let term = try await generateKeyword(apiKey: apiKey, input: input)
            if term.isEmpty {
                keywordState = .failed
            } else {
                if let cacheKey = article.url { keywordTermCache[cacheKey] = term }
                keywordState = .loaded(term)
                keywordDraft = term   // pre-fill the input so the term is ready to edit/send
            }
        } catch {
            keywordState = .failed
        }
    }

    private func generateKeyword(apiKey: String, input: String) async throws -> String {
        let config = GenerationConfig(temperature: 0.2)
        let model = GenerativeModel(
            name: Self.geminiModel,
            apiKey: apiKey,
            generationConfig: config,
            systemInstruction: ModelContent(parts: [.text(Self.keywordSystemPrompt)])
        )
        let response = try await model.generateContent(input)
        return (response.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
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
