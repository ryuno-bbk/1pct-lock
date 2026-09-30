//
//  SupabaseManager.swift
//  AppBlocker
//
//  Supabase client initialization
//

import Foundation
import Supabase

/// Singleton management of the Supabase client
final class SupabaseManager {

    static let shared = SupabaseManager()

    let client: SupabaseClient

    private init() {
        // Tokyo region migration (2026-07-04): migrated from the old meogoetpvjcqlmpttiod (Singapore)
        client = SupabaseClient(
            supabaseURL: URL(string: "https://uzhoghjgsjujergdzadt.supabase.co")!,
            supabaseKey: "sb_publishable_So5_S34-eJX4IlP8UXtoNw_eO0LdD9W"
        )
    }
}
