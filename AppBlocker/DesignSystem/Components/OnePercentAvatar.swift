//
//  OnePercentAvatar.swift
//  AppBlocker
//
//  Shared avatar display for the 1% official account.
//  With the removal of accounts that used real names of historical figures, the poster of all
//  quotes became the single "1%" official account.
//  The icon is the same image as the app icon (OnePercentIcon asset, user decision 2026-07-06).
//  Follows full monochrome (AppColors). Gold is not used.
//

import SwiftUI

/// Constants for the 1% official account
enum OnePercentAccount {
    /// id of the sentinel row in the authors table (inserted in Supabase/migrations/020_official_account.sql)
    static let authorId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let name = "1%"
}

/// Avatar of the 1% official account (app icon image, no ring)
/// A simple type with only a size parameter, so that both AvatarImage / OnePercentAvatar can be used
/// in the same places.
struct OnePercentAvatar: View {
    let size: CGFloat

    var body: some View {
        // No ring: a white ring on top looks like a planet's ring and is lame (rejected by the user 2026-07-06)
        Image("OnePercentIcon")
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(Circle())
    }
}

#Preview {
    ZStack {
        AppColors.background.ignoresSafeArea()

        VStack(spacing: 24) {
            OnePercentAvatar(size: 80)
            OnePercentAvatar(size: 46)
            OnePercentAvatar(size: 36)
            OnePercentAvatar(size: 24)
        }
    }
}
