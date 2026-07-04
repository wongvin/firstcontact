//
//  SyncPayload.swift
//  FirstContact
//
//  The full keyword-sync state exchanged between the user's own devices over Multipeer
//  Connectivity. Sent in its entirety on connect and after any local change; the receiver
//  merges it into its own store (last-writer-wins by `updatedAt`, tombstones included).
//

import Foundation

struct SyncPayload: Codable {
    var schemaVersion: Int = 1
    var keywords: [Keyword]
}
