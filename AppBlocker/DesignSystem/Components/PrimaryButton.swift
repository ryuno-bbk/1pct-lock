//
//  PrimaryButton.swift
//  AppBlocker
//
//  プライマリボタンコンポーネント
//

import SwiftUI

/// プライマリボタンのスタイル
enum PrimaryButtonStyle {
    case filled
    case outlined
    case text
}

/// プライマリボタンのサイズ
enum PrimaryButtonSize {
    case large
    case medium
    case small

    var height: CGFloat {
        switch self {
        case .large: return 56
        case .medium: return 48
        case .small: return 40
        }
    }

    var font: Font {
        switch self {
        case .large: return AppTypography.buttonLarge
        case .medium: return AppTypography.buttonMedium
        case .small: return AppTypography.buttonSmall
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .large: return 32
        case .medium: return 24
        case .small: return 16
        }
    }
}

/// プライマリボタン
struct PrimaryButton: View {
    let title: String
    let icon: String?
    let style: PrimaryButtonStyle
    let size: PrimaryButtonSize
    let isLoading: Bool
    let isDisabled: Bool
    let action: () -> Void

    init(
        _ title: String,
        icon: String? = nil,
        style: PrimaryButtonStyle = .filled,
        size: PrimaryButtonSize = .large,
        isLoading: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.style = style
        self.size = size
        self.isLoading = isLoading
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: textColor))
                        .scaleEffect(0.8)
                } else {
                    if let icon = icon {
                        Image(systemName: icon)
                            .font(size.font)
                    }

                    Text(title)
                        .font(size.font)
                }
            }
            .foregroundColor(textColor)
            .frame(maxWidth: .infinity)
            .frame(height: size.height)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(borderColor, lineWidth: style == .outlined ? 2 : 0)
            )
        }
        .disabled(isDisabled || isLoading)
        .opacity(isDisabled ? 0.5 : 1.0)
    }

    private var textColor: Color {
        switch style {
        case .filled:
            // 反転CTA: 塗り (AppGradients.primary) がオフホワイトになったため文字は墨色
            return AppColors.background
        case .outlined, .text:
            return AppColors.primaryFallback
        }
    }

    private var background: some View {
        Group {
            switch style {
            case .filled:
                AppGradients.primary
            case .outlined, .text:
                Color.clear
            }
        }
    }

    private var borderColor: Color {
        switch style {
        case .outlined:
            return AppColors.primaryFallback
        case .filled, .text:
            return .clear
        }
    }
}

/// セカンダリボタン（テキストボタン）
struct SecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(AppTypography.buttonMedium)
                .foregroundColor(AppColors.textSecondary)
        }
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        AppColors.background.ignoresSafeArea()

        VStack(spacing: 20) {
            PrimaryButton("開始する", icon: "play.fill") {}

            PrimaryButton("スケジュール設定", style: .outlined) {}

            PrimaryButton("読み込み中", isLoading: true) {}

            PrimaryButton("無効", isDisabled: true) {}

            SecondaryButton(title: "キャンセル") {}
        }
        .padding()
    }
}
