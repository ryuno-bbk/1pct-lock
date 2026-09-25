//
//  NumberFormatting.swift
//  AppBlocker
//
//  カード上の各種カウント表示 (いいね数 / コメント数 / タップ数など) を統一するための
//  共有フォーマッタ。以前は FeedListCard.formatCount / ProfileCards.formatViewCount が
//  byte-identical なコピーとして存在していたため、ここに一本化する。
//  表記は小文字 'k' 方式 (例: 1200 → "1.2k") に統一 (2026-07-10 UI 確定仕様のスタイル)。
//
//  UserProfileView / MyProfileView / AuthorProfileView / OfficialProfileView の
//  formatNumber (大文字 'K' 方式、独自コピー4本) もここへ統一済み (2026-07 クリーンアップ)。
//  各 View のフォロワー数表示は abbreviatedCount(lang) 経由の言語別表記 ('1.2万'/'1.2k') に
//  変わった (以前は常に大文字 'K' 固定表記だった)。
//

import Foundation

extension Int {
    /// 1000 未満はそのまま、以降は小数第1位までの 'k' 表記 (末尾 ".0k" は "k" に短縮)
    var abbreviated: String {
        guard self >= 1000 else { return "\(self)" }
        return String(format: "%.1fk", Double(self) / 1000)
            .replacingOccurrences(of: ".0k", with: "k")
    }

    /// 言語別のカウント表記 (いいね数/コメント数などフィードカード上の数字用)。
    /// - 日本語: 10000 未満はそのまま、以降は小数第1位までの '万' 表記 (末尾 ".0万" は "万" に短縮)
    ///   例: 342 → "342" / 12345 → "1.2万" / 10000 → "1万" / 99000 → "9.9万" / 1000000 → "100万"
    /// - 英語: 既存の `abbreviated` ('k' 表記) を流用しつつ、100万以上は 'M' 表記に切り替える
    ///   例: 342 → "342" / 8210 → "8.2k" / 1200000 → "1.2M"
    func abbreviatedCount(_ lang: AppLanguage) -> String {
        switch lang {
        case .japanese:
            guard self >= 10000 else { return "\(self)" }
            return String(format: "%.1f万", Double(self) / 10000)
                .replacingOccurrences(of: ".0万", with: "万")
        case .english:
            guard self >= 1_000_000 else { return abbreviated }
            return String(format: "%.1fM", Double(self) / 1_000_000)
                .replacingOccurrences(of: ".0M", with: "M")
        }
    }
}

extension Int {
    /// 秒数を "Xh Ym" / "Ym" で表す (週次レポート用)。
    /// 書式は BlockSessionTracker.formattedTotal() に合わせてある。日本語でも h/m 表記なのは
    /// プロフィールの累計ロック時間が全言語で h/m のため (1画面だけ表記を変えない)。
    /// ⚠️ 同じ書式のコピーが BlockSessionTracker / UserProfileView / SessionCompleteView に
    ///    既にある。出荷済みの表示を触るリスクを取らないため、今回は統合していない。
    var lockDurationText: String {
        let hours = self / 3600
        let minutes = (self % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}
