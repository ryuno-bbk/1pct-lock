//
//  AppIconPickerView.swift
//  AppBlocker
//
//  アプリアイコンの切替 (エリート特典、2026-07-20 新設 / 2026-07-25 ギャラリー化)。
//
//  ■ 新しいアイコンを追加する手順 (ユーザーが画像を作るたびにやること):
//    1. Assets.xcassets に "AppIcon<名前>.appiconset" を作り 1024x1024 PNG (アルファなし) を入れる
//       (Contents.json は既存 appiconset をコピーして filename を差し替え)
//    2. プレビュー用に "IconPreview<名前>.imageset" にも同じ PNG を入れる
//    3. (あれば) 元アートを "Original<名前>.imageset" に入れる (ギャラリーの背景に出る)
//    4. pbxproj の ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES にセット名を追記 (スペース区切り)
//    5. 下の AppIconCatalog.all に1行追加
//    ※ アイコン画像の追加は必ずアプリ更新 (審査) が必要 — iOS の仕様で実行時追加は不可能。
//      「解禁のタイミング制御」だけを審査なしでやりたくなったら Supabase の app_icons
//      フラグテーブルを重ねる (2026-07-20 設計メモ)。
//
//  ■ UX (2026-07-25 ユーザー指定):
//    グリッドのアイコンをタップ → 中央モーダルのギャラリー。背景に元アートを暗めに敷き、
//    中央にアイコンをドンと置く。左右の矢印 (+スワイプ) で送り、CTA で適用。
//

import SwiftUI

// MARK: - Catalog

struct AppIconOption: Identifiable {
    /// setAlternateIconName に渡す名前。nil = プライマリ (AppIcon)
    let alternateName: String?
    /// 一覧に出すプレビュー画像 (imageset 名)
    let previewAssetName: String
    /// ギャラリー背景に敷く元アート (imageset 名)。nil = 単色背景
    let originalAssetName: String?
    let nameJa: String
    let nameEn: String

    var id: String { alternateName ?? "primary" }

    /// 無料で使えるアイコン (クラシック=プライマリ と ホワイト。2026-07-25 ユーザー確定)。
    /// ワードマークは 2026-07-29 のブランドテスト中につき暫定無料 (プライマリ昇格の可能性あり、
    /// 確定したら有料化 or プライマリ化を判断)。それ以外はエリート特典 (適用時のみゲート、閲覧無料)
    var isFree: Bool {
        alternateName == nil || alternateName == "AppIconWhite"
            || alternateName == "AppIconWordmark" || alternateName == "AppIconWordmarkWhite"
    }
}

enum AppIconCatalog {
    /// サブスク失効時の巻き戻し (C1系、2026-07-29 実機バグFB): 失効してもホーム画面が
    /// エリート限定アイコンのまま残っていた。現在の代替アイコンが有料ならプライマリへ戻す。
    /// 呼び出しは ProAccess.reconcileEntitlementMirror の「新鮮フェッチで失効確定」経路のみ —
    /// オフライン/キャッシュだけでの誤リバートは既存のC1ガードが防ぐ。
    /// カタログに無い名前 (旧バージョンの残骸等) も有料扱いで戻す。
    /// ⚠️ setAlternateIconName はOS標準の「アイコンを変更しました」アラートを出すが、
    /// 特典失効をユーザーに知らせる通知を兼ねるため許容 (消す公開APIは無い)
    @MainActor
    static func revertPaidIconIfLapsed() {
        guard let current = UIApplication.shared.alternateIconName else { return } // プライマリ使用中
        // 「今その名前が有料か」の判定なので、表示用の all ではなく定義の全量 catalog を見る
        // (all は hidesPaidIcons で絞られるため)
        let isFree = catalog.first(where: { $0.alternateName == current })?.isFree ?? false
        guard !isFree else { return }
        UIApplication.shared.setAlternateIconName(nil) { error in
            if let error {
                print("⚠️ Paid icon revert failed: \(error)")
            } else {
                print("🔒 Paid app icon reverted to primary (entitlement lapsed)")
            }
        }
    }

    /// 🔴 v1 では有料 (エリート限定) アイコン5種を出さない (2026-08-04 ユーザー判断:
    /// 出せる出来のアイコンが揃うまで伏せる)。**このフラグを false に戻すだけで復活する** —
    /// 定義も Assets も Info.plist の代替アイコン登録もそのまま残してあるので他は触らなくてよい。
    /// この間の Pro 特典はスケジュール/位置の遮断のみになる
    private static let hidesPaidIcons = true

    /// 画面に出すアイコン。伏せている間は無料4種 (クラシック/ホワイト/ワードマーク2種) だけ
    static let all: [AppIconOption] = hidesPaidIcons ? catalog.filter(\.isFree) : catalog

    // 文言 (アイコン名) はユーザー添削待ち。
    // プライマリ=クラシック (太字モノグラム黒、2026-07-25 ユーザー確定)
    private static let catalog: [AppIconOption] = [
        AppIconOption(alternateName: nil, previewAssetName: "IconPreviewClassic",
                      originalAssetName: nil, nameJa: "クラシック", nameEn: "Classic"),
        AppIconOption(alternateName: "AppIconWhite", previewAssetName: "IconPreviewWhite",
                      originalAssetName: nil, nameJa: "ホワイト", nameEn: "White"),
        AppIconOption(alternateName: "AppIconWordmark", previewAssetName: "IconPreviewWordmark",
                      originalAssetName: nil, nameJa: "ワードマーク", nameEn: "Wordmark"), // 文言はユーザー添削待ち
        AppIconOption(alternateName: "AppIconWordmarkWhite", previewAssetName: "IconPreviewWordmarkWhite",
                      originalAssetName: nil, nameJa: "ワードマーク・ホワイト", nameEn: "Wordmark White"), // 文言はユーザー添削待ち
        AppIconOption(alternateName: "AppIconLion", previewAssetName: "IconPreviewLion",
                      originalAssetName: "OriginalLion", nameJa: "ライオン", nameEn: "Lion"),
        AppIconOption(alternateName: "AppIconHuman", previewAssetName: "IconPreviewHuman",
                      originalAssetName: "OriginalHuman", nameJa: "ラッパー", nameEn: "Rapper"),
        AppIconOption(alternateName: "AppIconCobra", previewAssetName: "IconPreviewCobra",
                      originalAssetName: "OriginalCobra", nameJa: "コブラ", nameEn: "Cobra"),
        AppIconOption(alternateName: "AppIconGoat", previewAssetName: "IconPreviewGoat",
                      originalAssetName: "OriginalGoat", nameJa: "ヤギ", nameEn: "Goat"),
        AppIconOption(alternateName: "AppIconDoberman", previewAssetName: "IconPreviewDoberman",
                      originalAssetName: "OriginalDoberman", nameJa: "ドーベルマン", nameEn: "Doberman"),
    ]
}

// MARK: - Picker View

struct AppIconPickerView: View {
    @ObservedObject private var proAccess = ProAccess.shared
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    @State private var currentAlternate: String? = UIApplication.shared.alternateIconName
    @State private var galleryItem: GalleryItem?

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 16)]

    struct GalleryItem: Identifiable {
        let index: Int
        var id: Int { index }
    }

    var body: some View {
        ZStack {
            AppColors.background.ignoresSafeArea()

            ScrollView {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(Array(AppIconCatalog.all.enumerated()), id: \.element.id) { index, option in
                        iconCell(option, index: index)
                    }
                }
                .padding(20)

                // 文言はユーザー添削待ち
                Text(lang == .japanese
                     ? "アイコンは今後のアップデートで追加されます。"
                     : "More icons will arrive in future updates.")
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textTertiary)
                    .padding(.top, 4)
            }
        }
        .navigationTitle(lang == .japanese ? "アプリアイコン" : "App Icon") // 文言はユーザー添削待ち
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $galleryItem) { item in
            IconGalleryView(
                startIndex: item.index,
                lang: lang,
                currentAlternate: $currentAlternate
            )
        }
    }

    private func iconCell(_ option: AppIconOption, index: Int) -> some View {
        let isCurrent = option.alternateName == currentAlternate
        // アイコン切替はエリート特典 (クラシック/ホワイトは無料)。ギャラリー閲覧は誰でも可
        let isLocked = !proAccess.isPro && !isCurrent && !option.isFree

        return Button {
            galleryItem = GalleryItem(index: index)
        } label: {
            VStack(spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    Image(option.previewAssetName)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 84, height: 84)
                        .clipShape(RoundedRectangle(cornerRadius: 19))
                        .overlay(
                            RoundedRectangle(cornerRadius: 19)
                                .stroke(isCurrent ? Color.white : Color.white.opacity(0.1),
                                        lineWidth: isCurrent ? 2 : 1)
                        )
                        .opacity(isLocked ? 0.55 : 1)

                    if isCurrent {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(.white)
                            .background(Circle().fill(AppColors.background))
                            .offset(x: 6, y: 6)
                    } else if isLocked {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(AppColors.textPrimary)
                            .padding(6)
                            .background(Circle().fill(AppColors.cardBackground))
                            .offset(x: 6, y: 6)
                    }
                }

                Text(lang == .japanese ? option.nameJa : option.nameEn)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isCurrent ? AppColors.textPrimary : AppColors.textSecondary)
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Icon Gallery (中央モーダル + 左右送り + 背景に元アート)

private struct IconGalleryView: View {
    let startIndex: Int
    let lang: AppLanguage
    @Binding var currentAlternate: String?

    @ObservedObject private var proAccess = ProAccess.shared
    @Environment(\.dismiss) private var dismiss

    @State private var index: Int = 0
    @State private var showProPaywall = false
    @State private var errorMessage: String?

    private var options: [AppIconOption] { AppIconCatalog.all }
    /// 正方形モーダルの一辺 (左右の矢印ぶんの余白を確保)
    private var cardSide: CGFloat { min(UIScreen.main.bounds.width - 104, 320) }
    private var option: AppIconOption { options[index] }
    private var isCurrent: Bool { option.alternateName == currentAlternate }

    var body: some View {
        ZStack {
            // 暗幕バックドロップ (タップで閉じる)
            Color.black.opacity(0.82)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            // 中央: 正方形モーダル (2026-07-25 ユーザー指定: 縦長の元画像も正方形に切り抜いて統一、
            // アイコンはその中央、CTA はモーダルの外)。
            // 送りは TabView ページング = 隣のカードが横からスライドしてくる (瞬間切替は却下)
            VStack(spacing: 20) {
                // ビューポートは画面全幅 (2026-07-25 実機FB: カード幅の箱で見切れるのを却下)。
                // 各ページ内でカードが中央寄せされるため、スワイプ時は隣のカードが
                // 画面端の外から入ってきて画面端の外へ消えていく。スワイプ可能域も全幅に広がる
                TabView(selection: $index) {
                    ForEach(Array(options.enumerated()), id: \.offset) { i, opt in
                        galleryPage(opt).tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxWidth: .infinity)
                .frame(height: cardSide)
                // 矢印はカードの真横 (外側8pt)、Y=カード中央。ビューポートが全幅になったので
                // カード幅の透明フレームを基準にして従来の見た目位置を維持する
                // (Color.clear は hit 判定を持たないため TabView のスワイプは素通し)
                .overlay {
                    Color.clear
                        .frame(width: cardSide, height: cardSide)
                        .overlay(alignment: .leading) {
                            arrowButton(systemName: "chevron.left") { step(-1) }
                                .offset(x: -48)
                        }
                        .overlay(alignment: .trailing) {
                            arrowButton(systemName: "chevron.right") { step(+1) }
                                .offset(x: 48)
                        }
                }

                Text(lang == .japanese ? option.nameJa : option.nameEn)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)

                // CTA はモーダル (正方形カード) の外
                Button {
                    apply()
                } label: {
                    Text(isCurrent
                         ? (lang == .japanese ? "使用中" : "Current")  // 文言はユーザー添削待ち
                         : (lang == .japanese ? "このアイコンにする" : "Use this icon"))  // 文言はユーザー添削待ち
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(isCurrent ? AppColors.textTertiary : AppColors.background)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(
                            Capsule().fill(isCurrent ? Color.white.opacity(0.1) : AppColors.textPrimary)
                        )
                }
                .buttonStyle(.plain)
                .disabled(isCurrent)
                .frame(width: cardSide)
            }

            // 閉じる (右上)
            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
                            .environment(\.colorScheme, .dark)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 16)
                }
                Spacer()
            }
        }
        .presentationBackground(.clear)
        .onAppear { index = startIndex }
        .sheet(isPresented: $showProPaywall) {
            ProPaywallView(triggeredBy: .schedule)
        }
        .alert(errorMessage ?? "", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        }
    }

    /// 1ページぶんの正方形カード。クラシック/ホワイト (元アート無し) は
    /// 背景カードを敷かずアイコンだけを中央に置く (2026-07-25 ユーザー指定)
    @ViewBuilder
    private func galleryPage(_ opt: AppIconOption) -> some View {
        ZStack {
            if let original = opt.originalAssetName {
                Image(original)
                    .resizable()
                    .scaledToFill()
                    .frame(width: cardSide, height: cardSide)
                    .overlay(Color.black.opacity(0.45))
                    .clipShape(RoundedRectangle(cornerRadius: 28))
                    .overlay(RoundedRectangle(cornerRadius: 28).stroke(Color.white.opacity(0.12), lineWidth: 1))
            }

            Image(opt.previewAssetName)
                .resizable()
                .scaledToFill()
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 27))
                .overlay(RoundedRectangle(cornerRadius: 27).stroke(Color.white.opacity(0.2), lineWidth: 1))
                .shadow(color: .black.opacity(0.55), radius: 22, y: 8)
        }
        .frame(width: cardSide, height: cardSide)
    }

    private func arrowButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
                .environment(\.colorScheme, .dark)
        }
        .buttonStyle(.plain)
    }

    private func step(_ delta: Int) {
        withAnimation(.easeInOut(duration: 0.25)) {
            index = (index + delta + options.count) % options.count
        }
    }

    private func apply() {
        // 切替はエリート特典。ただしクラシック/ホワイトは無料 (2026-07-25 ユーザー確定)
        guard proAccess.isPro || option.isFree else {
            showProPaywall = true
            return
        }
        let target = option
        Task {
            do {
                try await UIApplication.shared.setAlternateIconName(target.alternateName)
                currentAlternate = target.alternateName
                // iOS標準の「アイコンを変更しました」アラートは消せない (公開APIなし) ため、
                // ギャラリーを先に閉じてアラートが素の一覧画面の上に出るようにする
                // (モーダルの上にモーダルが重なる違和感の解消、2026-07-25 実機FB)
                dismiss()
            } catch {
                errorMessage = lang == .japanese
                    ? "アイコンを変更できませんでした"
                    : "Couldn't change the app icon"  // 文言はユーザー添削待ち
                print("⚠️ setAlternateIconName failed: \(error)")
            }
        }
    }
}

#Preview {
    NavigationStack { AppIconPickerView() }
}
