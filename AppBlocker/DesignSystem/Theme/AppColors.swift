//
//  AppColors.swift
//  AppBlocker
//
//  アプリ全体のカラーパレット
//

import SwiftUI

/// アプリのカラーテーマ
enum AppColors {

    // MARK: - Primary Colors

    /// メインブランドカラー
    static let primary = Color("Primary", bundle: nil)
    static let primaryFallback = Color(hex: "F2EFE7") // 反転CTA用のオフホワイト（旧: インディゴ）

    /// アクセントカラー（モノクロ化。金 (gold) にはしない）
    static let accent = Color(hex: "F2EFE7") // 旧: パープル

    // MARK: - Background Colors

    /// メイン背景（真っ黒。BeReal 準拠でアプリ全体を純黒に統一。2026-07-10 ユーザー指定）
    static let background = Color(hex: "000000")

    /// カード背景
    static let cardBackground = Color(hex: "17171B")

    /// セカンダリ背景
    static let secondaryBackground = Color(hex: "2A2A30")

    // MARK: - Text Colors

    /// プライマリテキスト
    static let textPrimary = Color(hex: "F2EFE7")

    /// セカンダリテキスト
    static let textSecondary = Color(hex: "97928A")

    /// 弱調テキスト
    static let textTertiary = Color(hex: "6E6A63")

    // MARK: - Semantic Colors

    /// 成功
    static let success = Color(hex: "22C55E")

    /// 警告
    static let warning = Color(hex: "F59E0B")

    /// エラー
    static let error = Color(hex: "EF4444")

    // MARK: - Mode Colors
    //
    // モノクロブランドのため 3 モードとも同一のダークニュートラル。
    // モードの区別は SF Symbol とラベル文言が担う（色では区別しない）。

    /// タイマーブロックモード
    static let modeTimer = Color(hex: "2E2E33")

    /// スケジュールモード
    static let modeSchedule = Color(hex: "2E2E33")

    /// 位置情報ロックモード
    static let modeLocation = Color(hex: "2E2E33")

    // MARK: - Shield Colors

    /// Shield背景（純黒）
    static let shieldBlack = Color.black

    /// Shield背景（ダーク）
    static let shieldDark = Color(hex: "111111")

    // MARK: - Gold (専用・限定使用)

    /// 上位%バッジ / 1%(Pro)バッジ / ペイウォール強調 / セッション完了画面の達成数字 専用の金色。
    /// ブランドは完全モノクロが基本のため、この4箇所以外での使用は禁止。
    static let gold = Color(hex: "C6A14B")
}

// MARK: - Gradients

enum AppGradients {

    /// プライマリグラデーション（モノクロ化のためオフホワイト単色。呼び出し側は事実上ベタ塗り）
    static let primary = LinearGradient(
        colors: [
            Color(hex: "F2EFE7"),
            Color(hex: "F2EFE7")
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Shield背景グラデーション
    static let shieldBackground = LinearGradient(
        colors: [
            Color(hex: "0F0F0F"),
            Color(hex: "1A1A1A"),
            Color(hex: "0F0F0F")
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// カード背景グラデーション
    static let cardGlow = RadialGradient(
        colors: [
            Color.white.opacity(0.05),
            Color.clear
        ],
        center: .center,
        startRadius: 0,
        endRadius: 200
    )

    /// タイマーモードグラデーション（モノクロ化：3モード共通のダークニュートラル）
    static let timerMode = LinearGradient(
        colors: [
            Color(hex: "17171B"),
            Color(hex: "0F0F10")
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// スケジュールモードグラデーション（モノクロ化：3モード共通のダークニュートラル）
    static let scheduleMode = LinearGradient(
        colors: [
            Color(hex: "17171B"),
            Color(hex: "0F0F10")
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// 位置情報モードグラデーション（モノクロ化：3モード共通のダークニュートラル）
    static let locationMode = LinearGradient(
        colors: [
            Color(hex: "17171B"),
            Color(hex: "0F0F10")
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Color Extension

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
