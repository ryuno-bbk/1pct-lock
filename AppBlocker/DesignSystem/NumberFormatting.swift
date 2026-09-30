//
//  NumberFormatting.swift
//  AppBlocker
//
//  Shared formatter to unify the various counts shown on cards (likes / comments / taps, etc.).
//  Before, FeedListCard.formatCount / ProfileCards.formatViewCount existed as
//  byte-identical copies, so they are merged here.
//  The notation is unified to lowercase 'k' (e.g. 1200 → "1.2k") (style from the UI spec finalized
//  2026-07-10).
//
//  formatNumber in UserProfileView / MyProfileView / AuthorProfileView / OfficialProfileView
//  (uppercase 'K', 4 separate copies) has also been merged here (2026-07 cleanup).
//  The follower count in each View now uses per-language notation through abbreviatedCount(lang)
//  ("1.2万" (12,000) / '1.2k') (before, it was always the fixed uppercase 'K' notation).
//

import Foundation

extension Int {
    /// Below 1000 as is; from there 'k' notation with 1 decimal place (a trailing ".0k" is shortened to "k")
    var abbreviated: String {
        guard self >= 1000 else { return "\(self)" }
        return String(format: "%.1fk", Double(self) / 1000)
            .replacingOccurrences(of: ".0k", with: "k")
    }

    /// Per-language count notation (for numbers on feed cards such as likes/comments).
    /// - Japanese: below 10000 as is; from there "万" (10,000) notation with 1 decimal place (a trailing
    ///   ".0万" is shortened to "万") e.g. 342 → "342" / 12345 → "1.2万" / 10000 → "1万" / 99000 → "9.9万" /
    ///   1000000 → "100万"
    /// - English: reuses the existing `abbreviated` ('k' notation), switching to 'M' notation at 1 million
    ///   and above e.g. 342 → "342" / 8210 → "8.2k" / 1200000 → "1.2M"
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
    /// Express seconds as "Xh Ym" / "Ym" (for the weekly report).
    /// The format matches BlockSessionTracker.formattedTotal(). It uses h/m even in Japanese because
    /// the total lock time on the profile uses h/m in all languages (do not change the notation on just 1
    /// screen).
    /// ⚠️ Copies of the same format already exist in BlockSessionTracker / UserProfileView /
    ///    SessionCompleteView. To avoid the risk of touching displays that have already shipped, they are
    ///    not merged this time.
    var lockDurationText: String {
        let hours = self / 3600
        let minutes = (self % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }
}
