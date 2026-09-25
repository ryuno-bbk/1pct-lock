//
//  OnePercentAvatar.swift
//  AppBlocker
//
//  1% 公式アカウントの共通アバター表示。
//  偉人実名アカウント廃止に伴い、名言の投稿主体は「1%」公式アカウント1本になった。
//  アイコンはアプリアイコンと同じ画像 (OnePercentIcon アセット、ユーザー決定 2026-07-06)。
//  完全モノクロ (AppColors) 準拠。金色は使用しない。
//

import SwiftUI

/// 1% 公式アカウントの定数
enum OnePercentAccount {
    /// authors テーブルの sentinel 行 id (Supabase/migrations/020_official_account.sql で挿入)
    static let authorId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let name = "1%"
}

/// 1% 公式アカウントのアバター (アプリアイコン画像、リング無し)
/// AvatarImage / OnePercentAvatar のどちらも同じ場所で使えるよう size 指定のみのシンプルな型。
struct OnePercentAvatar: View {
    let size: CGFloat

    var body: some View {
        // リング無し: 白リングを重ねると惑星の輪みたいでダサい (ユーザー却下 2026-07-06)
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
