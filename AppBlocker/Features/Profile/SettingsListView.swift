//
//  SettingsListView.swift
//  AppBlocker
//
//  マイページの歯車アイコンから遷移する設定画面
//

import SwiftUI

struct SettingsListView: View {
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    @StateObject private var userAuth = UserAuthService.shared

    @State private var showSignOutConfirm = false
    @State private var showDeleteConfirm1 = false
    @State private var showDeleteConfirm2 = false
    @State private var showDeleteFailed = false
    @State private var isDeleting = false

    private var mainLanguage: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    var body: some View {
        List {
            Section(L.settingsSectionDisplay(mainLanguage)) {
                // 既定は端末言語に追従 (キー無し)。この Picker で明示選択した時だけ固定される。
                // 「端末の設定に従う」の明示行は不要 (ユーザー判断 2026-07-25)
                Picker(selection: $mainLanguageRaw) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang.rawValue)
                    }
                } label: {
                    Label(L.settingsLanguage(mainLanguage), systemImage: "globe")
                        .foregroundColor(AppColors.textPrimary)
                }

                // 「英語の原文を併記」トグルは 2026-07-19 ユーザー決定で撤去 —
                // 公式名言アカウント専用の設定が全体設定に居るのは不自然 (「何の原文?」となる)。
                // 併記の挙動自体は AppStorage("showOriginal") の初期値 (日本語端末=ON) のまま維持。
                // 「背景デザイン」「著者アイコン」の近日公開行も 2026-07-20 ユーザー決定で撤去
                // (トーストを出すだけのハリボテはリリースに載せない。機能実装時に行ごと復活させる)

                // アプリアイコン切替 (エリート特典、2026-07-20 新設)
                NavigationLink {
                    AppIconPickerView()
                } label: {
                    Label(mainLanguage == .japanese ? "アプリアイコン" : "App Icon", // 文言はユーザー添削待ち
                          systemImage: "app.badge.checkmark")
                        .foregroundColor(AppColors.textPrimary)
                }
            }

            Section(L.settingsSectionAbout(mainLanguage)) {
                HStack {
                    Label(L.settingsVersion(mainLanguage), systemImage: "info.circle.fill")
                    Spacer()
                    Text(appVersion)
                        .foregroundColor(AppColors.textSecondary)
                }
                // お問い合わせ: 準備中トーストから実装に差し替え (M26)
                settingRow(icon: "envelope.fill", label: mainLanguage == .japanese ? "お問い合わせ" : "Contact us") { // 文言はユーザー添削待ち
                    if let url = LegalLinks.supportMailURL {
                        UIApplication.shared.open(url)
                    }
                }

                // 利用規約・プライバシーポリシー (M6一部/M26): URL は LegalLinks の TODO プレースホルダ、公開後差し替え (M6/H1)
                settingRow(icon: "doc.text", label: mainLanguage == .japanese ? "利用規約" : "Terms of Service") { // 文言はユーザー添削待ち
                    UIApplication.shared.open(LegalLinks.termsURL)
                }
                settingRow(icon: "hand.raised.fill", label: mainLanguage == .japanese ? "プライバシーポリシー" : "Privacy Policy") { // 文言はユーザー添削待ち
                    UIApplication.shared.open(LegalLinks.privacyURL)
                }
            }

            if userAuth.isSignedIn {
                // 週次レポート (080)。過去分は block_sessions から再集計するので
                // 「保存された履歴」ではなく、いつ開いても最新の集計定義で出る
                Section(mainLanguage == .japanese ? "レポート" : "Reports") {  // 文言はユーザー添削待ち
                    NavigationLink {
                        WeeklyReportListView()
                    } label: {
                        Label(mainLanguage == .japanese ? "週次レポート" : "Weekly Reports",  // 文言はユーザー添削待ち
                              systemImage: "chart.bar.doc.horizontal")
                            .foregroundColor(AppColors.textPrimary)
                    }
                }

                Section(L.settingsSectionAccount(mainLanguage)) {
                    NavigationLink {
                        ProfileEditView()
                    } label: {
                        Label(L.settingsEditProfile(mainLanguage), systemImage: "person.crop.circle")
                            .foregroundColor(AppColors.textPrimary)
                    }

                    // フォロー中一覧 (2026-07-30 D案改2: プロフィールの導線を撤去しここへ移動。
                    // 低頻度の管理機能=設定が定位置)
                    NavigationLink {
                        FollowedAccountsView()
                    } label: {
                        Label(mainLanguage == .japanese ? "フォロー中のアカウント" : "Following", systemImage: "person.2")  // 文言はユーザー添削待ち
                            .foregroundColor(AppColors.textPrimary)
                    }

                    NavigationLink {
                        BlockedAccountsView()
                    } label: {
                        Label(L.settingsBlockedAccounts(mainLanguage), systemImage: "hand.raised")
                            .foregroundColor(AppColors.textPrimary)
                    }

                    Button {
                        showSignOutConfirm = true
                    } label: {
                        Label(L.settingsSignOut(mainLanguage), systemImage: "rectangle.portrait.and.arrow.right")
                            .foregroundColor(AppColors.error)
                    }

                    Button {
                        showDeleteConfirm1 = true
                    } label: {
                        Label(L.settingsDeleteAccount(mainLanguage), systemImage: "trash")
                            .foregroundColor(AppColors.error)
                    }
                    .disabled(isDeleting)
                }
            }
        }
        .navigationTitle(L.settingsTitle(mainLanguage))
        .navigationBarTitleDisplayMode(.inline)
        // ProfileEditView と同じ「ヘッダー貫通」対策 (2026-08-04)。
        // 親 (MyProfileView) の toolbarBackground(.hidden) を引き継ぐと List の中身が
        // ナビバーを素通りして見える。歯車から1タップで来る画面なので同時に塞ぐ
        .toolbarBackground(AppColors.background, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .alert(L.settingsSignOutConfirmTitle(mainLanguage), isPresented: $showSignOutConfirm) {
            Button(L.settingsSignOutCancel(mainLanguage), role: .cancel) { }
            Button(L.settingsSignOut(mainLanguage), role: .destructive) {
                Task { await userAuth.signOut() }
            }
        } message: {
            Text(L.settingsSignOutConfirmMessage(mainLanguage))
        }
        .alert(L.settingsDeleteAccountConfirm1Title(mainLanguage), isPresented: $showDeleteConfirm1) {
            Button(L.settingsSignOutCancel(mainLanguage), role: .cancel) { }
            Button(L.settingsDeleteAccountAction(mainLanguage), role: .destructive) {
                showDeleteConfirm2 = true
            }
        } message: {
            Text(L.settingsDeleteAccountConfirm1Message(mainLanguage))
        }
        .alert(L.settingsDeleteAccountConfirm2Title(mainLanguage), isPresented: $showDeleteConfirm2) {
            Button(L.settingsSignOutCancel(mainLanguage), role: .cancel) { }
            Button(L.settingsDeleteAccountAction(mainLanguage), role: .destructive) {
                Task { await deleteAccount() }
            }
        } message: {
            Text(L.settingsDeleteAccountConfirm2Message(mainLanguage))
        }
        .alert(L.settingsDeleteAccountFailed(mainLanguage), isPresented: $showDeleteFailed) {
            Button("OK", role: .cancel) { }
        }
    }

    @MainActor
    private func deleteAccount() async {
        isDeleting = true
        let ok = await AccountDeletionService.shared.deleteMyAccount()
        isDeleting = false
        if !ok {
            showDeleteFailed = true
        }
    }

    private func settingRow(icon: String, label: String, detail: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(label, systemImage: icon)
                    .foregroundColor(AppColors.textPrimary)
                Spacer()
                if let detail {
                    Text(detail)
                        .foregroundColor(AppColors.textSecondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(AppColors.textTertiary)
            }
        }
    }
}

#Preview {
    NavigationStack { SettingsListView() }
}
