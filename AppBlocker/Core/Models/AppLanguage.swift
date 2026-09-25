//
//  AppLanguage.swift
//  AppBlocker
//
//  アプリ表示言語の選択肢。新しい言語追加は case を追加するだけで完結する。
//

import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case japanese = "ja"
    // 将来追加例: case chinese = "zh", case spanish = "es"

    var id: String { rawValue }

    /// 設定画面の Picker で表示するネイティブ言語名
    var displayName: String {
        switch self {
        case .english:  return "English"
        case .japanese: return "日本語"
        }
    }

    /// 端末言語に追従する既定言語 (2026-07-25 実機FB: 端末を英語にしてもUIが日本語のままで、
    /// OS提供画面 (FamilyActivityPicker 等) だけ英語になるチグハグが発生。審査も英語端末で行われる)。
    /// 旧実装は日本市場ファーストの「日本語固定」だったが、日本語端末は引き続き日本語になるので
    /// 日本先行戦略とは矛盾しない。mainLanguage への書き込みは存在しないため、
    /// この値が毎起動評価され端末言語に追従する
    static var deviceDefault: AppLanguage {
        // Locale.current はアプリの宣言済みローカリゼーションに解決され得るため、
        // 端末のユーザー設定そのもの (AppleLanguages) を直接読む
        (Locale.preferredLanguages.first ?? "en").hasPrefix("ja") ? .japanese : .english
    }
}
