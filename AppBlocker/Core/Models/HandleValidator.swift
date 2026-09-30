//
//  HandleValidator.swift
//  AppBlocker
//
//  Format validation + reserved word check for the user handle (@handle).
//  Keep the same rules as the CHECK constraints (users_handle_format /
//  users_handle_not_reserved) in 022_sns_minimum.sql on the Supabase side. This is for instant
//  client-side validation; the final decision is made by the is_handle_available RPC (server side).
//

import Foundation

enum HandleValidator {

    /// Reserved words (keep in sync with the reserved list on the SQL side)
    static let reserved: Set<String> = [
        "onepercent", "one_percent", "1percent",
        "official", "admin", "arete", "support", "moderator", "system"
    ]

    /// Trim leading/trailing whitespace + lowercase
    static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// ^[a-z0-9._]{3,20}$ format check
    static func isValidFormat(_ handle: String) -> Bool {
        handle.range(of: "^[a-z0-9._]{3,20}$", options: .regularExpression) != nil
    }

    /// Reserved word check (pass a normalized string)
    static func isReserved(_ handle: String) -> Bool {
        reserved.contains(handle)
    }
}
