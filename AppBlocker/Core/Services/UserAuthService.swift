//
//  UserAuthService.swift
//  AppBlocker
//
//  Apple Sign-In + Supabase Auth integration service
//  Named UserAuth to avoid a name clash with the existing AuthorizationService (FamilyControls)
//

import Foundation
import Combine
import AuthenticationServices
import CryptoKit
import UIKit
import Supabase

/// Manages the combined Apple Sign-In + Supabase Auth state
@MainActor
final class UserAuthService: ObservableObject {

    static let shared = UserAuthService()

    @Published private(set) var isSignedIn: Bool = false
    @Published private(set) var userId: UUID?
    @Published private(set) var displayName: String?
    @Published private(set) var handle: String?
    @Published private(set) var bio: String?
    @Published private(set) var dream: String?
    @Published private(set) var dreamIsPublic: Bool = false
    @Published private(set) var avatarUrl: URL?
    @Published private(set) var isPro: Bool = false
    @Published private(set) var isSigningIn: Bool = false
    /// H6 (2026-07-22 audit): whether restoreSession/signInWithApple could confirm isSignedIn against the
    /// server. isSignedIn=true while this is still false means "local-trust fallback on offline launch",
    /// and AppBlockerApp uses it as the trigger to retry restoreSession() on every return to foreground.
    @Published private(set) var isSessionServerVerified = false
    @Published var errorMessage: String?

    private var client: SupabaseClient { SupabaseManager.shared.client }
    private var appleCoordinator: AppleSignInCoordinator?

    /// H6: guard against running restoreSession() more than once at a time (the launch .task and the
    /// scenePhase trigger on return to foreground can race, so on re-entry it does nothing and returns)
    private var isRestoringSession = false

    /// H6: UserDefaults key for the userId of the last successful sign-in. Fallback value used to treat
    /// the user as signed in by local trust on offline launch / temporary Supabase outage
    private static let lastKnownUserIdKey = "lastKnownUserId"

    /// 073: language (rawValue) last sent to the server. In-process cache so the same value is not sent
    /// again. Updated only when the server write actually succeeded (on failure it stays nil so the next
    /// call retries)
    private var lastSyncedLanguageRaw: String?

    private init() {}

    // MARK: - Session Restore

    /// Called at launch (+ H6: re-verification on return to foreground). The Supabase SDK restores the
    /// session from the Keychain automatically, so if there is a session this only sets isSignedIn=true.
    /// H6: has a re-entry guard. Even if the launch .task and the foreground trigger race,
    /// isSignedIn does not flip back and forth depending on which one finishes last.
    func restoreSession() async {
        guard !isRestoringSession else { return }
        isRestoringSession = true
        defer { isRestoringSession = false }

        do {
            let session = try await client.auth.session
            self.userId = session.user.id
            self.isSignedIn = true
            self.isSessionServerVerified = true
            // H6: persist the userId of the last successful sign-in for the local-trust fallback on offline
            // launch (used in the catch branch of this function)
            UserDefaults.standard.set(session.user.id.uuidString, forKey: Self.lastKnownUserIdKey)
            // Mirror used to stamp user_id at enqueue time (H3). Do not clear it in the failure (catch) branch.
            // If it is cleared on offline launch, schedule sessions during that time are discarded as
            // "rows that belong to nobody" (same reason as F5 for the dream mirror)
            AppGroupStorage.shared.saveCurrentUserId(session.user.id)
            await refreshProfile()
        } catch {
            // H6 (2026-07-22 audit): when an offline launch / temporary Supabase outage lands here, the old code
            // always set isSignedIn=false and pushed a signed-in user out to onboarding
            // (a fatal dead end where the user could not even unlock an active block).
            // If there is a recent sign-in record (lastKnownUserId), treat it as a "temporary failure" and
            // set isSignedIn=true by local trust, without server verification.
            // The AppGroup side (saveCurrentUserId) is not touched here. The value written on success stays.
            if let lastKnownIdString = UserDefaults.standard.string(forKey: Self.lastKnownUserIdKey),
               let lastKnownId = UUID(uuidString: lastKnownIdString) {
                self.userId = lastKnownId
                self.isSignedIn = true
                // isSessionServerVerified stays false (the default). The profile keeps
                // its degraded display. clearProfileState() is not called.
            } else {
                self.isSignedIn = false
                self.userId = nil
                self.isSessionServerVerified = false
                clearProfileState()
            }
        }
    }

    /// Reset all profile-related @Published on sign-out / session loss.
    /// If bio/dream is not cleared, when switching accounts on the same device the previous user's
    /// dream (including private ones) shows for a moment (pointed out in the 2026-07-07 Fable review)
    ///
    /// Note: the App Group dream mirror (AppGroupStorage.saveUserDream) is not cleared here.
    /// clearProfileState is also called from the catch of restoreSession() (offline launch, Supabase
    /// pause and other temporary network failures), so clearing it here would be a regression: the dream
    /// disappears from the Shield until the next successful login even though the user did not sign out
    /// (fixed 2026-07). The dream mirror is cleared only in signOut(), where it is certain that the user
    /// really signed out.
    private func clearProfileState() {
        self.displayName = nil
        self.handle = nil
        self.bio = nil
        self.dream = nil
        self.dreamIsPublic = false
        self.avatarUrl = nil
        self.isPro = false
    }

    // MARK: - Sign In with Apple

    /// Runs Apple Sign-In. Policy: do not request the fullName scope (S15).
    /// The user types the display name directly in the nameInput step of onboarding, and it is
    /// saved to users.display_name with `setDisplayName(_:)` after a successful sign-in.
    func signInWithApple() async {
        guard !isSigningIn else { return }
        isSigningIn = true
        errorMessage = nil

        do {
            let coordinator = AppleSignInCoordinator()
            self.appleCoordinator = coordinator

            let result = try await coordinator.requestSignIn()

            guard let idTokenData = result.credential.identityToken,
                  let idTokenString = String(data: idTokenData, encoding: .utf8) else {
                throw AppleSignInError.missingIDToken
            }

            try await client.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(
                    provider: .apple,
                    idToken: idTokenString,
                    nonce: result.rawNonce
                )
            )

            let session = try await client.auth.session
            self.userId = session.user.id
            self.isSignedIn = true
            self.isSessionServerVerified = true
            // H6: persist the userId of the last successful sign-in for the local-trust fallback on offline
            // launch (used in the catch branch of restoreSession())
            UserDefaults.standard.set(session.user.id.uuidString, forKey: Self.lastKnownUserIdKey)
            AppGroupStorage.shared.saveCurrentUserId(session.user.id)

            // The users row has already been created by the handle_new_user trigger.
            await refreshProfile()

            // 🔴 Fix for the 2026-08-06 App Review rejection (Guideline 4 / Sign in with Apple):
            // If Apple returns a name, use it as the display name. Do not make the user type it.
            // If users.display_name already exists (re-sign-in etc.), do not overwrite it.
            // Apple returns the name only on the first authorization, so if it is missed here it is gone for good.
            if let appleName = Self.formattedName(from: result.credential.fullName) {
                let existing = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if existing.isEmpty {
                    _ = try? await setDisplayName(appleName)
                }
            }
        } catch let error as ASAuthorizationError where error.code == .canceled {
            // User cancelled: do not show an error
        } catch {
            errorMessage = "Apple サインインに失敗しました"
            print("⚠️ Apple Sign-In error: \(error)")
        }

        self.appleCoordinator = nil
        isSigningIn = false
    }

    /// Turns Apple's `PersonNameComponents` into a display name string (2026-08-06).
    /// ⚠️ The word order depends on the locale (Japanese is "family given", English is "Given Family"),
    /// so do not join the parts ourselves. Leave it to PersonNameComponentsFormatter.
    /// If it is whitespace only / all components are nil, return nil (the caller treats it as "not
    /// available"). Truncate to 30 characters to match the display_name length limit.
    private static func formattedName(from components: PersonNameComponents?) -> String? {
        guard let components else { return nil }
        let formatter = PersonNameComponentsFormatter()
        formatter.style = .default
        let name = formatter.string(from: components).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        return String(name.prefix(30))
    }

    // MARK: - Sign Out

    func signOut() async {
        // 🔴 Remove it BEFORE cutting auth. The RPC checks auth.uid(), so afterwards it cannot be removed.
        //    If it is left, the next person using this device gets notifications meant for the previous owner
        await PushNotificationService.shared.removeTokenFromServer()

        do {
            try await client.auth.signOut()
        } catch {
            print("⚠️ Sign out error: \(error)")
        }
        self.isSignedIn = false
        self.userId = nil
        // H6: on explicit sign-out also lower the server-verified flag (next time it becomes true only after
        // a successful sign-in / restoreSession)
        self.isSessionServerVerified = false
        clearProfileState()

        // M17 (audit 2026-07-20): after sign-out the user lands on the onboarding screen and cannot reach
        // the unlock UI, so explicitly stop the blocking engines (timer/schedule/location) before cleaning up
        // the App Group. Uses only the existing public APIs of each Manager (no new stop API is added).
        // ⚠️ Behavior change: because of this, an explicit sign-out removes the schedule/location settings
        // and running sessions. Settings are not synced to the server and are local to the device, so they
        // are not restored on re-sign-in.
        TimerManager.shared.stopTimer()
        ScheduleManager.shared.stopMonitoring()
        // LocationManager has no public "remove all" API like stopMonitoring(), so calling the existing
        // removeLocation(_:) on every registered location does the same job (removes geofences + the shield)
        // (removeLocation is an existing public API that runs unregisterGeofence + syncShield on each call)
        for location in LocationManager.shared.registeredLocations {
            LocationManager.shared.removeLocation(location)
        }
        // Safety net: even with 0 registered locations, remove the shield if one remains in the store
        // (existing public API)
        LocationManager.shared.removeShield()

        // Clear the App Group dream mirror only on paths where sign-out is really confirmed (here, and this
        // signOut() when AccountDeletionService calls it after delete_my_account succeeds).
        // Do not clear it on the temporary failure path of restoreSession() (F5, fixed 2026-07)
        AppGroupStorage.shared.saveUserDream(nil)
        // Stop stamping user_id on enqueue (H3). The queue itself is not cleared here:
        // every row already has its user_id stamped, so unsent rows are flushed correctly when that user
        // signs in again
        AppGroupStorage.shared.saveCurrentUserId(nil)
        // H6: on explicit sign-out, leave nothing behind for the local-trust fallback
        // (prevents auto sign-in as the previous user on the next offline launch)
        UserDefaults.standard.removeObject(forKey: Self.lastKnownUserIdKey)
        // 073: on a shared device, when switching accounts, the next account's users.lang could fail to sync
        // (because it has the same rawValue as the previous account). To prevent that, drop the cache only on
        // paths where sign-out is really confirmed
        // (clearProfileState is also called from temporary restoreSession failures, so the cache is kept
        // there = same policy as saveUserDream(nil) above)
        lastSyncedLanguageRaw = nil

        // M16 (audit 2026-07-20): on a shared device, prevent the previous user's location coordinates /
        // schedule settings / Shield quote cache from leaking to the next user by cleaning only
        // user-specific data (pendingBlockSessions and proBlockingEntitled are excluded, see
        // clearUserSpecificData for details)
        AppGroupStorage.shared.clearUserSpecificData()
    }

    // MARK: - Profile

    /// Fetch display_name / handle / bio / avatar_url / is_pro from the users row and apply them.
    /// The dream is fetched with a separate query from its own table user_dreams (024 v2).
    /// On failure the previous values are kept (log only).
    func refreshProfile() async {
        guard let uid = userId else {
            clearProfileState()
            return
        }
        struct ProfileRow: Decodable {
            let displayName: String?
            let handle: String?
            let bio: String?
            let avatarUrl: String?
            let isPro: Bool?
            enum CodingKeys: String, CodingKey {
                case displayName = "display_name"
                case handle
                case bio
                case avatarUrl   = "avatar_url"
                case isPro       = "is_pro"
            }
        }
        do {
            let row: ProfileRow = try await client
                .from("users")
                .select("display_name, handle, bio, avatar_url, is_pro")
                .eq("id", value: uid.uuidString)
                .single()
                .execute()
                .value
            self.displayName = row.displayName
            self.handle = row.handle
            self.bio = row.bio
            self.avatarUrl = row.avatarUrl.flatMap { URL(string: $0) }
            self.isPro = row.isPro ?? false
        } catch {
            print("⚠️ Failed to fetch profile: \(error)")
        }

        // Dream: user_dreams (RLS always shows your own row). No row = not declared
        struct DreamRow: Decodable {
            let dream: String?
            let isPublic: Bool
            enum CodingKeys: String, CodingKey {
                case dream
                case isPublic = "is_public"
            }
        }
        do {
            let rows: [DreamRow] = try await client
                .from("user_dreams")
                .select("dream, is_public")
                .eq("user_id", value: uid.uuidString)
                .execute()
                .value
            self.dream = rows.first?.dream
            self.dreamIsPublic = rows.first?.isPublic ?? false
            // Mirror to the App Group for the Shield subtitle (plan A). The launch load (refreshProfile via
            // restoreSession/signInWithApple) goes through here, so edits on another device show on next launch
            AppGroupStorage.shared.saveUserDream(self.dream)
        } catch {
            print("⚠️ Failed to fetch dream: \(error)")
        }
    }

    /// C1: fetch only is_pro, fresh, in a single call. On success also apply it to self.isPro and return it.
    /// On failure (offline / Supabase pause etc.) return nil to tell the caller it is "unknown".
    /// refreshProfile keeps the previous value on failure, so it cannot tell whether the fetch succeeded.
    /// This dedicated fetch fills that gap
    func fetchIsProFresh() async -> Bool? {
        guard let uid = userId else { return nil }
        struct Row: Decodable {
            let isPro: Bool?
            enum CodingKeys: String, CodingKey { case isPro = "is_pro" }
        }
        do {
            let row: Row = try await client
                .from("users")
                .select("is_pro")
                .eq("id", value: uid.uuidString)
                .single()
                .execute()
                .value
            let fresh = row.isPro ?? false
            self.isPro = fresh   // @Published → also propagates to serverIsPro via the ProAccess sink
            return fresh
        } catch {
            print("⚠️ fetchIsProFresh failed: \(error)")
            return nil
        }
    }

    /// Update the bio (UPDATE users.bio). Max 160 characters, an empty string becomes NULL.
    @discardableResult
    func updateBio(_ bio: String) async -> Bool {
        guard let uid = userId else { return false }
        let trimmed = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String? = trimmed.isEmpty ? nil : String(trimmed.prefix(160))

        // For an Encodable struct with Optionals, synthesized Codable omits nil keys, so
        // "save with an empty bio" never reaches the DB. Send null explicitly with AnyJSON.null
        let payload: [String: AnyJSON] = ["bio": value.map(AnyJSON.string) ?? .null]
        do {
            try await client
                .from("users")
                .update(payload)
                .eq("id", value: uid.uuidString)
                .execute()

            self.bio = value
            return true
        } catch {
            print("⚠️ Failed to update bio: \(error)")
            return false
        }
    }

    /// 073: sync the viewer's (own) device language (users.lang) to the server.
    /// It is the input for the same-language priority scoring (viewer_lang) in fetch_mixed_feed_random.
    /// Called both at sign-in (AppBlockerApp.syncSignInState) and when the language Picker in settings
    /// changes (AppBlockerApp detects it by subscribing to UserDefaults.didChangeNotification).
    /// Does nothing if the value is the same as the one last sent to the server (didChangeNotification
    /// also fires for UserDefaults changes other than language, so this guard avoids useless network
    /// calls even when it is called often).
    /// On failure, only log and swallow the error (same style as loadAuthors. A failed lang sync must not
    /// break the user experience of sign-in or of switching languages)
    func syncLanguage(_ lang: AppLanguage) async {
        guard let uid = userId else { return }
        guard lastSyncedLanguageRaw != lang.rawValue else { return }

        struct Payload: Encodable {
            let lang: String
        }
        do {
            try await client
                .from("users")
                .update(Payload(lang: lang.rawValue))
                .eq("id", value: uid.uuidString)
                .execute()
            lastSyncedLanguageRaw = lang.rawValue
        } catch {
            print("⚠️ Failed to sync language: \(error)")
        }
    }

    /// Update the "dream" (a one-line declaration of who you want to become) (upsert into user_dreams,
    /// 024 v2). Max 120 characters, an empty string becomes NULL. isPublic defaults to private (unlike
    /// bio, the content is a declaration). RLS (user_dreams_select_public_or_own) hides private dreams
    /// from everyone except the owner.
    @discardableResult
    func updateDream(_ dream: String, isPublic: Bool) async -> Bool {
        guard let uid = userId else { return false }
        let trimmed = dream.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String? = trimmed.isEmpty ? nil : String(trimmed.prefix(120))

        // Send null explicitly with AnyJSON.null (with an Encodable struct the nil key is omitted, and
        // "save with an empty dream" never reaches the DB)
        let payload: [String: AnyJSON] = [
            "user_id":   .string(uid.uuidString),
            "dream":     value.map(AnyJSON.string) ?? .null,
            "is_public": .bool(isPublic)
        ]
        do {
            try await client
                .from("user_dreams")
                .upsert(payload, onConflict: "user_id")
                .execute()

            self.dream = value
            self.dreamIsPublic = isPublic
            return true
        } catch {
            print("⚠️ Failed to update dream: \(error)")
            return false
        }
    }

    /// Check in real time whether the handle is available on the server (is_handle_available RPC).
    /// An invalid format returns .taken immediately without asking the server.
    /// A network error returns .error, separate from .taken (in use). This keeps onboarding from getting
    /// stuck by wrongly showing "使用できません" ("Not available") when offline or during a Supabase
    /// pause (pointed out in the 2026-07-07 Fable review)
    func checkHandleAvailable(_ handle: String) async -> HandleAvailability {
        let normalized = HandleValidator.normalized(handle)
        guard HandleValidator.isValidFormat(normalized) else { return .taken }

        do {
            let available: Bool = try await client
                .rpc("is_handle_available", params: ["h": normalized])
                .execute()
                .value
            return available ? .available : .taken
        } catch {
            print("⚠️ Failed to check handle availability: \(error)")
            return .error
        }
    }

    /// Update the handle (UPDATE users.handle). Applied after normalizing + validation.
    @discardableResult
    func updateHandle(_ handle: String) async -> Bool {
        guard let uid = userId else { return false }
        let normalized = HandleValidator.normalized(handle)
        guard HandleValidator.isValidFormat(normalized),
              !HandleValidator.isReserved(normalized) else {
            return false
        }

        struct Payload: Encodable {
            let handle: String
        }
        do {
            try await client
                .from("users")
                .update(Payload(handle: normalized))
                .eq("id", value: uid.uuidString)
                .execute()

            self.handle = normalized
            return true
        } catch {
            print("⚠️ Failed to update handle: \(error)")
            return false
        }
    }

    /// Update the display name (UPDATE users.display_name).
    /// Called both right after onboarding nameInput and from ProfileEditView.
    @discardableResult
    func setDisplayName(_ name: String) async throws -> String {
        guard let uid = userId else { throw ProfileError.notSignedIn }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ProfileError.nameEmpty }
        guard trimmed.count <= 30 else { throw ProfileError.nameTooLong }

        struct Payload: Encodable {
            let display_name: String
        }
        try await client
            .from("users")
            .update(Payload(display_name: trimmed))
            .eq("id", value: uid.uuidString)
            .execute()

        self.displayName = trimmed
        return trimmed
    }

    /// Upload the avatar image to Storage and update users.avatar_url.
    /// Path: fixed as `{uid}/avatar.jpg` (overwritten with upsert).
    /// Returns: the applied publicURL (with ?v=timestamp, to bust the cache)
    /// Note: Swift's uuidString is uppercase, Supabase auth.uid() is lowercase.
    /// The RLS policy compares strings with storage.foldername, so always normalize with lowercased().
    @discardableResult
    func uploadAvatar(jpegData: Data) async throws -> URL {
        guard let uid = userId else { throw ProfileError.notSignedIn }
        let path = "\(uid.uuidString.lowercased())/avatar.jpg"

        _ = try await client.storage
            .from("avatars")
            .upload(
                path,
                data: jpegData,
                options: FileOptions(contentType: "image/jpeg", upsert: true)
            )

        let publicURL = try client.storage.from("avatars").getPublicURL(path: path)
        let versioned = appendCacheBuster(to: publicURL)

        struct Payload: Encodable {
            let avatar_url: String
        }
        try await client
            .from("users")
            .update(Payload(avatar_url: versioned.absoluteString))
            .eq("id", value: uid.uuidString)
            .execute()

        self.avatarUrl = versioned
        return versioned
    }

    /// Delete the avatar image (delete the Storage object + set users.avatar_url to NULL).
    func removeAvatar() async throws {
        guard let uid = userId else { throw ProfileError.notSignedIn }
        let path = "\(uid.uuidString.lowercased())/avatar.jpg"

        do {
            _ = try await client.storage.from("avatars").remove(paths: [path])
        } catch {
            // If it no longer exists this is an error, but setting the DB side to NULL still continues
            print("⚠️ Avatar storage remove (ignored if not found): \(error)")
        }

        // Send null explicitly with AnyJSON.null (with an Encodable struct the nil key is omitted,
        // the PATCH body becomes {} and avatar_url is not set to NULL)
        try await client
            .from("users")
            .update(["avatar_url": AnyJSON.null])
            .eq("id", value: uid.uuidString)
            .execute()

        self.avatarUrl = nil
    }

    // MARK: - Helpers

    private func appendCacheBuster(to url: URL) -> URL {
        let ts = Int(Date().timeIntervalSince1970)
        let separator = url.absoluteString.contains("?") ? "&" : "?"
        return URL(string: "\(url.absoluteString)\(separator)v=\(ts)") ?? url
    }
}

// MARK: - Handle Availability

/// Result of checkHandleAvailable. Keeping a network error (.error) separate from "in use" (.taken)
/// lets the caller show a retry path
enum HandleAvailability {
    case available
    case taken
    case error
}

// MARK: - Profile Errors

enum ProfileError: LocalizedError {
    case notSignedIn
    case nameEmpty
    case nameTooLong

    var errorDescription: String? {
        switch self {
        case .notSignedIn: return "サインインしていません"
        case .nameEmpty:   return "名前を入力してください"
        case .nameTooLong: return "名前は30文字以内で入力してください"
        }
    }
}

// MARK: - Errors

enum AppleSignInError: LocalizedError {
    case missingIDToken
    case invalidCredential

    var errorDescription: String? {
        switch self {
        case .missingIDToken: return "ID トークンを取得できませんでした"
        case .invalidCredential: return "認証情報が不正です"
        }
    }
}

// MARK: - Apple Sign-In Coordinator (NSObject)

/// NSObject wrapper that acts as the ASAuthorizationController delegate.
/// It is separated from UserAuthService because declaring NSObject + @MainActor + ObservableObject
/// together gets stuck with the Swift 6 default isolation.
private final class AppleSignInCoordinator: NSObject,
                                            ASAuthorizationControllerDelegate,
                                            ASAuthorizationControllerPresentationContextProviding {

    struct Result {
        let credential: ASAuthorizationAppleIDCredential
        let rawNonce: String
    }

    private var continuation: CheckedContinuation<Result, Error>?
    private var rawNonce: String?

    func requestSignIn() async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let nonce = Self.randomNonceString()
            self.rawNonce = nonce

            let provider = ASAuthorizationAppleIDProvider()
            let request = provider.createRequest()
            // 🔴 Fix for the 2026-08-06 App Review rejection (Guideline 4 Design / Sign in with Apple):
            // Apple pointed out: "Authentication Services provides the name, but the app asks the user to type
            // their name". The old S15 policy (do not take fullName, have the user type it in onboarding) is
            // withdrawn. Request .fullName and use the name Apple returns as the display name as is.
            // ⚠️ Apple returns fullName only "the first time this app is authorized with that Apple ID".
            // From the second time on it is nil, so treat the saved users.display_name as the source of truth.
            request.requestedScopes = [.fullName, .email]
            request.nonce = Self.sha256(nonce)

            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    // MARK: - Delegate

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
            continuation?.resume(throwing: AppleSignInError.invalidCredential)
            continuation = nil
            return
        }
        guard let nonce = rawNonce else {
            continuation?.resume(throwing: AppleSignInError.invalidCredential)
            continuation = nil
            return
        }
        continuation?.resume(returning: Result(credential: credential, rawNonce: nonce))
        continuation = nil
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        continuation?.resume(throwing: error)
        continuation = nil
    }

    // MARK: - Presentation Anchor

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first(where: { $0.isKeyWindow }) ?? ASPresentationAnchor()
    }

    // MARK: - Nonce

    private static func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        var randomBytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        if status != errSecSuccess {
            fatalError("SecRandomCopyBytes failed: OSStatus \(status)")
        }
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(randomBytes.map { charset[Int($0) % charset.count] })
    }

    private static func sha256(_ input: String) -> String {
        let hashed = SHA256.hash(data: Data(input.utf8))
        return hashed.compactMap { String(format: "%02x", $0) }.joined()
    }
}
