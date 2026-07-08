//
//  SyncStore.swift
//  FirstContact
//
//  The single owner of the keyword filter list: its persistence (UserDefaults, same key the
//  view used before) and its merge algorithm. The keyword set is modelled as a CRDT-lite
//  LWW-Element-Set — each `Keyword` carries an `updatedAt` stamp and a soft-delete `deleted`
//  tombstone, so concurrent edits and deletes across devices converge without a server.
//
//  The compose thread (long-press message screen) is owned here too, as a second LWW-Element-Set
//  synced over the same transport. The 30-day summary cache is intentionally NOT owned here — it
//  stays device-local, managed inline by ContentView.
//

import Foundation
import Combine

@MainActor
final class SyncStore: ObservableObject {
    // Same keys ContentView used, so existing on-device keywords and messages load unchanged.
    private static let keywordCacheKey = "firstcontact.keywords.v1"
    private static let composeCacheKey = "firstcontact.compose.v1"

    /// Full keyword list, tombstones included. The view reads it (filtering out tombstones);
    /// mutations go through the methods below so every change is stamped.
    @Published private(set) var keywords: [Keyword]

    /// Full compose-message list, tombstones included. Same LWW-Element-Set treatment as keywords.
    @Published private(set) var messages: [ComposeMessage]

    /// Called after a *local* mutation (keyword or message) so the transport can re-broadcast. Not
    /// called on merge — the SyncManager decides whether an incoming merge warrants an echo.
    var onLocalChange: (() -> Void)?

    init() {
        keywords = Self.loadKeywords()
        messages = Self.loadMessages()
    }

    // MARK: - Local mutations (stamp updatedAt; delete = tombstone, never a hard removal)

    func addKeyword(_ text: String) {
        keywords.append(Keyword(id: UUID(), text: text, excluded: false,
                                updatedAt: Date(), deleted: false))
        persistKeywords(broadcast: true)
    }

    func deleteKeyword(_ keyword: Keyword) {
        guard let i = keywords.firstIndex(where: { $0.id == keyword.id }) else { return }
        keywords[i].deleted = true
        keywords[i].updatedAt = Date()
        persistKeywords(broadcast: true)
    }

    /// Toggles the excluded flag. Returns the new value so the caller can warn on over-long queries.
    @discardableResult
    func toggleExcluded(_ keyword: Keyword) -> Bool {
        guard let i = keywords.firstIndex(where: { $0.id == keyword.id }) else { return false }
        keywords[i].excluded.toggle()
        keywords[i].updatedAt = Date()
        persistKeywords(broadcast: true)
        return keywords[i].excluded
    }

    /// Appends a message and returns its id so the caller can update it later (e.g. to attach an
    /// async-generated link summary).
    @discardableResult
    func addMessage(_ text: String) -> UUID {
        let message = ComposeMessage(id: UUID(), text: text, updatedAt: Date(), deleted: false)
        messages.append(message)
        persistMessages(broadcast: true)
        return message.id
    }

    /// Sets only a message's display label, leaving its text/URL intact. Used by the automatic
    /// link summary. Stamps `updatedAt` so the label syncs.
    func setDisplayText(id: UUID, _ displayText: String?) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].displayText = displayText
        messages[i].updatedAt = Date()
        persistMessages(broadcast: true)
    }

    func deleteMessage(_ message: ComposeMessage) {
        guard let i = messages.firstIndex(where: { $0.id == message.id }) else { return }
        messages[i].deleted = true
        messages[i].updatedAt = Date()
        persistMessages(broadcast: true)
    }

    /// Edit a message: replace its text and/or custom display label. Callers preserve `text`
    /// (the URL) when editing only a link's label. Stamps `updatedAt` so the edit wins on merge.
    func updateMessage(id: UUID, text: String, displayText: String?) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[i].text = text
        messages[i].displayText = displayText
        messages[i].updatedAt = Date()
        persistMessages(broadcast: true)
    }

    // MARK: - Sync

    /// The outgoing snapshots for a payload — include tombstones (peers need them to converge).
    func snapshot() -> [Keyword] { keywords }
    func snapshotMessages() -> [ComposeMessage] { messages }

    /// Merge an incoming keyword set: per-id last-writer-wins by `updatedAt` (a newer tombstone
    /// beats a live edit, a newer edit beats an older tombstone). Returns true iff local state
    /// changed — the caller re-broadcasts only then, which bounds the connect-time echo.
    @discardableResult
    func merge(_ incoming: [Keyword]) -> Bool {
        var byID = Dictionary(uniqueKeysWithValues: keywords.map { ($0.id, $0) })
        var changed = false
        for k in incoming {
            if let existing = byID[k.id] {
                if k.updatedAt > existing.updatedAt {
                    byID[k.id] = k
                    changed = true
                }
            } else {
                byID[k.id] = k
                changed = true
            }
        }
        guard changed else { return false }
        // Preserve existing display order; append any newly-seen ids at the end.
        var order = keywords.map { $0.id }
        for k in incoming where !order.contains(k.id) { order.append(k.id) }
        keywords = order.compactMap { byID[$0] }
        persistKeywords(broadcast: false)   // merge writeback: don't re-trigger the local-change echo
        return true
    }

    /// Merge an incoming message set — identical LWW-by-`updatedAt` logic as `merge(_:)`. The view
    /// orders the thread by `updatedAt` for display, so the stored order here isn't user-visible.
    @discardableResult
    func mergeMessages(_ incoming: [ComposeMessage]) -> Bool {
        var byID = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })
        var changed = false
        for m in incoming {
            if let existing = byID[m.id] {
                if m.updatedAt > existing.updatedAt {
                    byID[m.id] = m
                    changed = true
                }
            } else {
                byID[m.id] = m
                changed = true
            }
        }
        guard changed else { return false }
        var order = messages.map { $0.id }
        for m in incoming where !order.contains(m.id) { order.append(m.id) }
        messages = order.compactMap { byID[$0] }
        persistMessages(broadcast: false)
        return true
    }

    // MARK: - Persistence

    private func persistKeywords(broadcast: Bool) {
        if let data = try? JSONEncoder().encode(keywords) {
            UserDefaults.standard.set(data, forKey: Self.keywordCacheKey)
        }
        if broadcast { onLocalChange?() }
    }

    private func persistMessages(broadcast: Bool) {
        if let data = try? JSONEncoder().encode(messages) {
            UserDefaults.standard.set(data, forKey: Self.composeCacheKey)
        }
        if broadcast { onLocalChange?() }
    }

    private static func loadKeywords() -> [Keyword] {
        guard let data = UserDefaults.standard.data(forKey: keywordCacheKey) else { return [] }
        return (try? JSONDecoder().decode([Keyword].self, from: data)) ?? []
    }

    private static func loadMessages() -> [ComposeMessage] {
        guard let data = UserDefaults.standard.data(forKey: composeCacheKey) else { return [] }
        return (try? JSONDecoder().decode([ComposeMessage].self, from: data)) ?? []
    }
}
