//
//  SplashView.swift
//  AppBlocker
//
//  Launch splash (brought back on 2026-07-31 at the user's request).
//
//  ⚠️ Do not add animation (2026-07-31 real device feedback: the version that appears by scaling up
//     was rejected with "totally no good,
//  weird zoom-ins are absolutely not OK"). The correct answer is a still screen that **just puts a
//  smallish mark in the center**. Do not add motion here in the future: it has been rejected twice,
//  after the engraving animation removed on 2026-07-29.
//
//  The base color is the same as the measured base color of the app icon (#0A0A0B) = no color step
//  when switching from the Launch Screen (LaunchBackground color asset) to this view. The mark is a
//  white glyph cut out of the icon, so together with the base color it looks like "the icon is right
//  in the center of the screen".
//

import SwiftUI

struct SplashView: View {
    /// true = the "1%" wordmark in Montserrat BlackItalic / false = the glyph of the classic icon
    private let useWordmark = false

    var body: some View {
        ZStack {
            Color(hex: "0A0A0B").ignoresSafeArea()
            logo
        }
    }

    @ViewBuilder
    private var logo: some View {
        if useWordmark {
            Text("1%")
                .font(.custom("Montserrat-BlackItalic", size: 64))
                .foregroundColor(AppColors.textPrimary)
        } else {
            // 2026-07-31 real device feedback round 2: still too big at 84pt → 60pt
            Image("HeroClassicGlyph")
                .resizable()
                .scaledToFit()
                .frame(width: 60, height: 60)
        }
    }
}

#Preview {
    SplashView()
}
