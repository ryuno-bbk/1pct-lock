//
//  SettingsListView.swift
//  AppBlocker
//
//  Settings screen opened from the gear icon on My Page
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
                // By default it follows the device language (no key). It is fixed only when explicitly chosen in this
                // Picker. An explicit "follow device settings" row is not needed (user decision 2026-07-25)
                Picker(selection: $mainLanguageRaw) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang.rawValue)
                    }
                } label: {
                    Label(L.settingsLanguage(mainLanguage), systemImage: "globe")
                        .foregroundColor(AppColors.textPrimary)
                }

                // The "show the English original too" toggle was removed by user decision 2026-07-19:
                // a setting only for the official quote account does not belong in the global settings (people ask
                // "original of what?"). The side-by-side behavior itself stays as the initial value of
                // AppStorage("showOriginal") (Japanese device = ON).
                // The coming-soon rows "background design" and "author icon" were also removed by user decision
                // 2026-07-20 (fake rows that only show a toast do not ship in the release. Bring the whole row back
                // when the feature is implemented)

                // App icon switching (Elite perk, added 2026-07-20)
                NavigationLink {
                    AppIconPickerView()
                } label: {
                    Label(mainLanguage == .japanese ? "アプリアイコン" : "App Icon", // Wording is waiting for the user's review
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
                // Contact us: replaced the coming-soon toast with a real implementation (M26)
                settingRow(icon: "envelope.fill", label: mainLanguage == .japanese ? "お問い合わせ" : "Contact us") { // Wording is waiting for the user's review
                    if let url = LegalLinks.supportMailURL {
                        UIApplication.shared.open(url)
                    }
                }

                // Terms of Service / Privacy Policy (part of M6/M26): the URLs are TODO placeholders in LegalLinks,
                // to be replaced after publishing (M6/H1)
                settingRow(icon: "doc.text", label: mainLanguage == .japanese ? "利用規約" : "Terms of Service") { // Wording is waiting for the user's review
                    UIApplication.shared.open(LegalLinks.termsURL)
                }
                settingRow(icon: "hand.raised.fill", label: mainLanguage == .japanese ? "プライバシーポリシー" : "Privacy Policy") { // Wording is waiting for the user's review
                    UIApplication.shared.open(LegalLinks.privacyURL)
                }
            }

            if userAuth.isSignedIn {
                // Weekly report (080). Past weeks are recomputed from block_sessions, so
                // it is not a "saved history"; whenever it is opened it uses the latest aggregation definition
                Section(mainLanguage == .japanese ? "レポート" : "Reports") {  // Wording is waiting for the user's review
                    NavigationLink {
                        WeeklyReportListView()
                    } label: {
                        Label(mainLanguage == .japanese ? "週次レポート" : "Weekly Reports",  // Wording is waiting for the user's review
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

                    // Following list (2026-07-30 plan D revision 2: removed the entry point from the profile and moved
                    // it here. A low-frequency management feature = its place is Settings)
                    NavigationLink {
                        FollowedAccountsView()
                    } label: {
                        Label(mainLanguage == .japanese ? "フォロー中のアカウント" : "Following", systemImage: "person.2")  // Wording is waiting for the user's review
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
        // Same "header bleed-through" fix as ProfileEditView (2026-08-04).
        // If it inherits toolbarBackground(.hidden) from the parent (MyProfileView), the List contents
        // show through the nav bar. This screen is one tap from the gear, so fix it at the same time
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
