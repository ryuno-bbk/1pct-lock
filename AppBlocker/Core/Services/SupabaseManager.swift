//
//  SupabaseManager.swift
//  AppBlocker
//
//  Supabaseクライアント初期化
//

import Foundation
import Supabase

/// Supabaseクライアントのシングルトン管理
final class SupabaseManager {

    static let shared = SupabaseManager()

    let client: SupabaseClient

    private init() {
        // 東京リージョン移行 (2026-07-04): 旧 meogoetpvjcqlmpttiod (シンガポール) から移行
        client = SupabaseClient(
            supabaseURL: URL(string: "https://uzhoghjgsjujergdzadt.supabase.co")!,
            supabaseKey: "sb_publishable_So5_S34-eJX4IlP8UXtoNw_eO0LdD9W"
        )
    }
}
