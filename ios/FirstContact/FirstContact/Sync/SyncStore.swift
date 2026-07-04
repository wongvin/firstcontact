//
//  SyncStore.swift
//  FirstContact
//
//  The single owner of the keyword filter list: its persistence (UserDefaults, same key the
//  view used before) and its merge algorithm. The keyword set is modelled as a CRDT-lite
//  LWW-Element-Set — each `Keyword` carries an `updatedAt` stamp and a soft-delete `deleted`
//  tombstone, so concurrent edits and deletes across devices converge without a server.
//
//  The compose thread and 30-day summary cache are intentionally NOT owned here — they stay
//  device-local, managed inline by ContentView as before.
//

import Foundation
import Combine

@MainActor
final class SyncStore: ObservableObject {
    // Same key ContentView used, so existing on-device keywords load unchanged.
    private static let keywordCacheKey = "firstcontact.keywords.v1"

    /// Full keyword list, tombstones included. The view reads it (filtering out tombstones);
    /// mutations go through the methods below so every change is stamped.
    @Published private(set) var keywords: [Keyword]

    /// Called after a *local* mutation so the transport can re-broadcast. Not called on merge —
    /// the SyncManager decides whether an incoming merge warrants an echo (see `merge`).
    var onLocalChange: (() -> Void)?

    init() {
        keywords = Self.load()
    }

    // MARK: - Local mutations (stamp updatedAt; delete = tombstone, never a hard removal)

    func addKeyword(_ text: String) {
        keywords.append(Keyword(id: UUID(), text: text, excluded: false,
                                updatedAt: Date(), deleted: false))
        persist(broadcast: true)
    }

    func deleteKeyword(_ keyword: Keyword) {
        guard let i = keywords.firstIndex(where: { $0.id == keyword.id }) else { return }
        keywords[i].deleted = true
        keywords[i].updatedAt = Date()
        persist(broadcast: true)
    }

    /// Toggles the excluded flag. Returns the new value so the caller can warn on over-long queries.
    @discardableResult
    func toggleExcluded(_ keyword: Keyword) -> Bool {
        guard let i = keywords.firstIndex(where: { $0.id == keyword.id }) else { return false }
        keywords[i].excluded.toggle()
        keywords[i].updatedAt = Date()
        persist(broadcast: true)
        return keywords[i].excluded
    }

    // MARK: - Sync

    /// The outgoing snapshot for a payload — includes tombstones (peers need them to converge).
    func snapshot() -> [Keyword] { keywords }

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
        persist(broadcast: false)   // merge writeback: don't re-trigger the local-change echo
        return true
    }

    // MARK: - Persistence

    private func persist(broadcast: Bool) {
        if let data = try? JSONEncoder().encode(keywords) {
            UserDefaults.standard.set(data, forKey: Self.keywordCacheKey)
        }
        if broadcast { onLocalChange?() }
    }

    private static func load() -> [Keyword] {
        guard let data = UserDefaults.standard.data(forKey: keywordCacheKey) else { return [] }
        return (try? JSONDecoder().decode([Keyword].self, from: data)) ?? []
    }
}
