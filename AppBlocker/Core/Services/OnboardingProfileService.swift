//
//  OnboardingProfileService.swift
//  AppBlocker
//
//  Upsert the answers from the diagnosis onboarding into user_onboarding_profiles (026 SQL).
//  Answers before sign-in are kept in @AppStorage and pushed here after a successful sign-in.
//  On failure, pending is not consumed (the "consume only on success" pattern established in
//  5ee7905).
//

import Foundation
import Supabase

enum OnboardingProfileService {

    /// If all answers are empty, do nothing and return true (the case where the quiz was not taken on the
    /// existing account path)
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

        // Send null explicitly with AnyJSON (avoids an Encodable struct omitting nil keys)
        func textOrNull(_ raw: String) -> AnyJSON {
            let t = raw.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? .null : .string(t)
        }

        let apps = wastedAppsRaw.split(separator: ",").map { AnyJSON.string(String($0)) }

        let payload: [String: AnyJSON] = [
            "user_id":         .string(userId.uuidString),
            "birth_date":      textOrNull(birthDateRaw),   // "yyyy-MM-dd" (the date column accepts an ISO string)
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
