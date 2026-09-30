//
//  AccountDeletionService.swift
//  AppBlocker
//
//  Account deletion (Supabase RPC delete_my_account)
//

import Foundation
import Supabase

@MainActor
final class AccountDeletionService {

    static let shared = AccountDeletionService()

    private let client: SupabaseClient

    private init(client: SupabaseClient = SupabaseManager.shared.client) {
        self.client = client
    }

    /// Runs the delete-account Edge Function → on success clears local state + signs out.
    /// The old delete_my_account RPC always failed because the platform forbids direct SQL deletion from
    /// storage (storage.protect_delete), so it moved to an Edge Function that uses the Storage API +
    /// Auth Admin API (found in the 2026-07-25 M8 live test, RPC removed in 051 SQL)
    /// Returns: true on success
    func deleteMyAccount() async -> Bool {
        guard UserAuthService.shared.userId != nil else {
            print("⚠️ deleteMyAccount ignored: not signed in")
            return false
        }

        do {
            try await client.functions.invoke("delete-account")

            // Discard unsent session rows for the deleted user (H3). After the server rows are gone they can
            // never be inserted, so there is no point keeping them
            if let uid = UserAuthService.shared.userId {
                BlockSessionTracker.purgeQueue(for: uid)
            }

            // Sign out (auth.users is already gone, but call it to clear the Keychain)
            await UserAuthService.shared.signOut()
            print("✅ Account deleted")
            return true
        } catch {
            print("⚠️ deleteMyAccount failed: \(error)")
            return false
        }
    }
}
