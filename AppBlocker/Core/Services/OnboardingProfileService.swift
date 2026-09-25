//
//  OnboardingProfileService.swift
//  AppBlocker
//
//  診断オンボーディングの回答を user_onboarding_profiles (026 SQL) へ upsert する。
//  サインイン前の回答は @AppStorage に保持し、サインイン成功後にここへ push。
//  失敗時は pending を消費しない (5ee7905 で確立した「成功時のみ消費」パターン)。
//

import Foundation
import Supabase

enum OnboardingProfileService {

    /// 全回答が空なら何もせず true (既存アカウント導線でクイズを踏んでいないケース)
    @discardableResult
    static func push(
        userId: UUID,
        birthDateRaw: String,
        genderRaw: String,
        occupationRaw: String,
        dailyHoursRaw: String,
        addictionYearsRaw: String,
        wastedAppsRaw: String,
        goalRaw: String,
        referralSourceRaw: String = ""
    ) async -> Bool {
        let allEmpty = [birthDateRaw, genderRaw, occupationRaw, dailyHoursRaw, addictionYearsRaw, wastedAppsRaw, goalRaw, referralSourceRaw]
            .allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        if allEmpty { return true }

        // AnyJSON で明示的に null を送る (Encodable struct の nil キー省略を避ける)
        func textOrNull(_ raw: String) -> AnyJSON {
            let t = raw.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? .null : .string(t)
        }

        let apps = wastedAppsRaw.split(separator: ",").map { AnyJSON.string(String($0)) }

        let payload: [String: AnyJSON] = [
            "user_id":         .string(userId.uuidString),
            "birth_date":      textOrNull(birthDateRaw),   // "yyyy-MM-dd" (date 列は ISO 文字列で受かる)
            "gender":          textOrNull(genderRaw),      // male / female / nonbinary / prefer_not (035 SQL)
            "occupation":      textOrNull(occupationRaw),
            "daily_hours":     textOrNull(dailyHoursRaw),
            "addiction_years": textOrNull(addictionYearsRaw),
            "wasted_apps":     apps.isEmpty ? .null : .array(apps),
            "goal":            textOrNull(goalRaw),
            "referral_source": textOrNull(referralSourceRaw)  // tiktok/instagram/youtube/friend/app_store/other (036 SQL)
        ]

        do {
            try await SupabaseManager.shared.client
                .from("user_onboarding_profiles")
                .upsert(payload, onConflict: "user_id")
                .execute()
            print("✅ Pushed onboarding profile")
            return true
        } catch {
            print("⚠️ Failed to push onboarding profile: \(error)")
            return false
        }
    }
}
