//
//  HandleValidator.swift
//  AppBlocker
//
//  ユーザーハンドル (@handle) のフォーマット検証 + 予約語チェック。
//  Supabase 側 022_sns_minimum.sql の CHECK 制約 (users_handle_format /
//  users_handle_not_reserved) と同じルールを維持すること。ここはクライアント側の
//  即時バリデーション用で、最終判定は is_handle_available RPC (サーバー側) が持つ。
//

import Foundation

enum HandleValidator {

    /// 予約語 (SQL 側の reserved list と同期させること)
    static let reserved: Set<String> = [
        "onepercent", "one_percent", "1percent",
        "official", "admin", "arete", "support", "moderator", "system"
    ]

    /// 前後の空白除去 + 小文字化
    static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// ^[a-z0-9._]{3,20}$ 形式チェック
    static func isValidFormat(_ handle: String) -> Bool {
        handle.range(of: "^[a-z0-9._]{3,20}$", options: .regularExpression) != nil
    }

    /// 予約語チェック (normalized 済みの文字列を渡すこと)
    static func isReserved(_ handle: String) -> Bool {
        reserved.contains(handle)
    }
}
