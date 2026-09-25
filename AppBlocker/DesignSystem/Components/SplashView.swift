//
//  SplashView.swift
//  AppBlocker
//
//  起動スプラッシュ (2026-07-31 ユーザー要望で復活)。
//
//  ⚠️ アニメーションは入れない (2026-07-31 実機FB: 拡大して現れる版は「全然ダメ、
//  変なアップは絶対ダメ」で却下)。**小さめのマークを中央に置くだけ**の静止画面が正解。
//  今後ここに動きを足さないこと — 2026-07-29 に廃止した刻印アニメに続き2回却下されている。
//
//  地色はアプリアイコンの実測地色 (#0A0A0B) と同じ = Launch Screen (LaunchBackground
//  カラーアセット) から本ビューへの切り替わりで色段差が出ない。マークはアイコンから
//  切り出した白グリフなので、地色と合わせて「アイコンがそのまま画面中央にある」状態になる。
//

import SwiftUI

struct SplashView: View {
    /// true = Montserrat BlackItalic の「1%」ワードマーク / false = クラシックアイコンのグリフ
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
            // 2026-07-31 実機FB2巡目: 84pt でもまだ大きい → 60pt へ
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
