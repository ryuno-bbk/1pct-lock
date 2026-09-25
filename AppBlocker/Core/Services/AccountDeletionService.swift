//
//  AccountDeletionService.swift
//  AppBlocker
//
//  アカウント削除 (Supabase RPC delete_my_account)
//

import Foundation
import Supabase

@MainActor
final class AccountDeletionService {

    static let shared = AccountDeletionService()

    private let client: SupabaseClient

    private init(client: SupabaseClient = SupabaseManager.shared.client) {
        self.client = client
    }

    /// delete-account Edge Function を実行 → 成功時にローカル状態クリア + サインアウト。
    /// 旧 delete_my_account RPC は storage の SQL 直削除がプラットフォーム禁止
    /// (storage.protect_delete) で必ず失敗していたため、Storage API + Auth Admin API を
    /// 使う Edge Function に移行 (2026-07-25 M8 実弾テストで発覚、051 SQL で RPC 撤去)
    /// 戻り値: 成功なら true
    func deleteMyAccount() async -> Bool {
        guard UserAuthService.shared.userId != nil else {
            print("⚠️ deleteMyAccount ignored: not signed in")
            return false
        }

        do {
            try await client.functions.invoke("delete-account")

            // 削除ユーザー宛の未送信セッション行を破棄 (H3)。サーバー側の行が消えた後は
            // 永久に insert できないため、保留しておく意味がない
            if let uid = UserAuthService.shared.userId {
                BlockSessionTracker.purgeQueue(for: uid)
            }

            // サインアウト (auth.users は既に消えてるが Keychain クリア用に呼ぶ)
            await UserAuthService.shared.signOut()
            print("✅ Account deleted")
            return true
        } catch {
            print("⚠️ deleteMyAccount failed: \(error)")
            return false
        }
    }
}
