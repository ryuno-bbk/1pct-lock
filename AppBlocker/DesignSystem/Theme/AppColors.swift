//
//  AppColors.swift
//  AppBlocker
//
//  Color palette for the whole app
//

import SwiftUI

/// App color theme
enum AppColors {

    // MARK: - Primary Colors

    /// Main brand color
    static let primary = Color("Primary", bundle: nil)
    static let primaryFallback = Color(hex: "F2EFE7") // Off-white for inverted CTAs (old: indigo)

    /// Accent color (made monochrome. Not gold)
    static let accent = Color(hex: "F2EFE7") // Old: purple

    // MARK: - Background Colors

    /// Main background (pure black. The whole app is unified to pure black, following BeReal. User-specified
    /// 2026-07-10)
    static let background = Color(hex: "000000")

    /// Card background
    static let cardBackground = Color(hex: "17171B")

    /// Secondary background
    static let secondaryBackground = Color(hex: "2A2A30")

    // MARK: - Text Colors

    /// Primary text
    static let textPrimary = Color(hex: "F2EFE7")

    /// Secondary text
    static let textSecondary = Color(hex: "97928A")

    /// Low-emphasis text
    static let textTertiary = Color(hex: "6E6A63")

    // MARK: - Semantic Colors

    /// Success
    static let success = Color(hex: "22C55E")

    /// Warning
    static let warning = Color(hex: "F59E0B")

    /// Error
    static let error = Color(hex: "EF4444")

    // MARK: - Mode Colors
    //
    // The brand is monochrome, so all 3 modes use the same dark neutral.
    // Modes are told apart by the SF Symbol and the label text (not by color).

    /// Timer block mode
    static let modeTimer = Color(hex: "2E2E33")

    /// Schedule mode
    static let modeSchedule = Color(hex: "2E2E33")

    /// Location lock mode
    static let modeLocation = Color(hex: "2E2E33")

    // MARK: - Shield Colors

    /// Shield background (pure black)
    static let shieldBlack = Color.black

    /// Shield background (dark)
    static let shieldDark = Color(hex: "111111")

    // MARK: - Gold (dedicated, limited use)

    /// Gold used only for the top percentile badge / 1% (Pro) badge / paywall emphasis / achievement
    /// numbers on the session complete screen.
    /// The brand is fully monochrome by default, so using it anywhere other than these 4 places is
    /// prohibited.
    static let gold = Color(hex: "C6A14B")
}

// MARK: - Gradients

enum AppGradients {

    /// Primary gradient (a single off-white color because of the monochrome change. Callers are in effect a
    /// flat fill)
    static let primary = LinearGradient(
        colors: [
            Color(hex: "F2EFE7"),
            Color(hex: "F2EFE7")
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Shield background gradient
    static let shieldBackground = LinearGradient(
        colors: [
            Color(hex: "0F0F0F"),
            Color(hex: "1A1A1A"),
            Color(hex: "0F0F0F")
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Card background gradient
    static let cardGlow = RadialGradient(
        colors: [
            Color.white.opacity(0.05),
            Color.clear
        ],
        center: .center,
        startRadius: 0,
        endRadius: 200
    )

    /// Timer mode gradient (monochrome: dark neutral shared by the 3 modes)
    static let timerMode = LinearGradient(
        colors: [
            Color(hex: "17171B"),
            Color(hex: "0F0F10")
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Schedule mode gradient (monochrome: dark neutral shared by the 3 modes)
    static let scheduleMode = LinearGradient(
        colors: [
            Color(hex: "17171B"),
            Color(hex: "0F0F10")
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Location mode gradient (monochrome: dark neutral shared by the 3 modes)
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
