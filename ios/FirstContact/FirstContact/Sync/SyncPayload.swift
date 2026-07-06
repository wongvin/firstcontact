//
//  SyncPayload.swift
//  FirstContact
//
//  The full sync state exchanged between the user's own devices over Multipeer Connectivity —
//  the keyword filter list and the compose-message thread. Sent in its entirety on connect and
//  after any local change; the receiver merges each set into its own store (last-writer-wins by
//  `updatedAt`, tombstones included).
//
//  `messages` is decoded defensively (schemaVersion 1 payloads from an older peer omit it): a
//  missing field decodes to an empty array rather than failing the whole payload, so keyword sync
//  keeps working while devices are on mixed builds.
//

import Foundation

struct SyncPayload: Codable {
    var schemaVersion: Int = 2
    var keywords: [Keyword]
    var messages: [ComposeMessage] = []

    enum CodingKeys: String, CodingKey { case schemaVersion, keywords, messages }

    init(keywords: [Keyword], messages: [ComposeMessage] = []) {
        self.keywords = keywords
        self.messages = messages
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        keywords = try c.decodeIfPresent([Keyword].self, forKey: .keywords) ?? []
        messages = try c.decodeIfPresent([ComposeMessage].self, forKey: .messages) ?? []
    }
}
