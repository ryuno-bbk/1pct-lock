//
//  UserAuthService.swift
//  AppBlocker
//
//  Apple Sign-In + Supabase Auth 統合サービス
//  既存 AuthorizationService (FamilyControls) との命名衝突回避のため UserAuth
//

import Foundation
import Combine
import AuthenticationServices
import CryptoKit
import UIKit
import Supabase

/// Apple Sign-In + Supabase Auth の統合状態管理
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
    /// H6 (2026-07-22 監査): restoreSession/signInWithApple がサーバーと突き合わせて
    /// isSignedIn を確定できたかどうか。false のまま isSignedIn=true な状態は「オフライン起動時の
    /// ローカル信頼フォールバック」を意味し、AppBlockerApp がフォアグラウンド復帰のたびに
    /// restoreSession() を再試行するトリガーとして使う。
    @Published private(set) var isSessionServerVerified = false
    @Published var errorMessage: String?

    private var client: SupabaseClient { SupabaseManager.shared.client }
    private var appleCoordinator: AppleSignInCoordinator?

    /// H6: restoreSession() の多重実行ガード (起動時 .task とフォアグラウンド復帰の scenePhase
    /// トリガーが競合しうるため、再入時は何もせず即 return する)
    private var isRestoringSession = false

    /// H6: 直近サインインに成功した userId の UserDefaults キー。オフライン起動 /
    /// Supabase 一時障害時にローカル信頼でサインイン済み扱いするためのフォールバック値
    private static let lastKnownUserIdKey = "lastKnownUserId"

    /// 073: 直近サーバーに送った言語 (rawValue)。同じ値を何度も送らないためのプロセス内キャッシュ。
    /// 実際にサーバーへ書き込めた時だけ更新する (失敗時は次回呼び出しでリトライされるよう nil のまま残す)
    private var lastSyncedLanguageRaw: String?

    private init() {}

    // MARK: - Session Restore

    /// 起動時 (+ H6: フォアグラウンド復帰時の再検証) に呼び出し。Supabase SDK が Keychain から
    /// 自動復元するのでセッションがあれば isSignedIn=true にするだけ。
    /// H6: 多重実行ガード付き — 起動時 .task とフォアグラウンド復帰トリガーが競合しても
    /// 後勝ちで isSignedIn を暴れさせない。
    func restoreSession() async {
        guard !isRestoringSession else { return }
        isRestoringSession = true
        defer { isRestoringSession = false }

        do {
            let session = try await client.auth.session
            self.userId = session.user.id
            self.isSignedIn = true
            self.isSessionServerVerified = true
            // H6: オフライン起動時のローカル信頼フォールバック用に、直近サインイン成功の
            // userId を永続化 (この関数の catch 側で使う)
            UserDefaults.standard.set(session.user.id.uuidString, forKey: Self.lastKnownUserIdKey)
            // enqueue 時の user_id 刻印用ミラー (H3)。失敗 (catch) 側では消さない —
            // オフライン起動で消すと、その間の schedule セッションが「誰のものでもない行」として
            // 破棄されてしまう (夢ミラーの F5 と同じ理由)
            AppGroupStorage.shared.saveCurrentUserId(session.user.id)
            await refreshProfile()
        } catch {
            // H6 (2026-07-22 監査): オフライン起動 / Supabase 一時障害でここに落ちると、従来は
            // 問答無用で isSignedIn=false にしてサインイン済みユーザーをオンボーディングへ
            // 追い出していた (進行中の遮断の解除操作すら不能になる致命的な詰み)。
            // 直近サインイン実績 (lastKnownUserId) があれば「一時的な失敗」とみなし、
            // サーバー未検証のままローカル信頼で isSignedIn=true にする。
            // AppGroup 側 (saveCurrentUserId) はここでは触らない — 成功時に書かれた値がそのまま残る。
            if let lastKnownIdString = UserDefaults.standard.string(forKey: Self.lastKnownUserIdKey),
               let lastKnownId = UUID(uuidString: lastKnownIdString) {
                self.userId = lastKnownId
                self.isSignedIn = true
                // isSessionServerVerified は false のまま (デフォルト値) — プロフィールは
                // 劣化表示のまま維持する。clearProfileState() は呼ばない。
            } else {
                self.isSignedIn = false
                self.userId = nil
                self.isSessionServerVerified = false
                clearProfileState()
            }
        }
    }

    /// サインアウト/セッション消失時にプロフィール系 @Published を全てリセットする。
    /// bio/dream を消し漏らすと、同端末でのアカウント切替時に前ユーザーの
    /// (非公開含む) 夢が一瞬表示される (2026-07-07 Fable レビュー指摘)
    ///
    /// 注意: ここでは App Group の夢ミラー (AppGroupStorage.saveUserDream) は消さない。
    /// clearProfileState は restoreSession() の catch (オフライン起動 / Supabase pause 等の
    /// 一時的な通信失敗) からも呼ばれるため、ここで消すと本人はサインアウトしていないのに
    /// 次回ログイン成功まで Shield から夢が消える regression になる (2026-07 修正)。
    /// 夢ミラーのクリアは「本当にサインアウトした」ことが確定する signOut() 内でのみ行う。
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

    /// Apple Sign-In を実行。fullName スコープは要求しない方針 (S15)。
    /// 表示名はオンボーディングの nameInput ステップでユーザーに直接入力させ、
    /// サインイン成功後に `setDisplayName(_:)` で users.display_name に保存する。
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
            // H6: オフライン起動時のローカル信頼フォールバック用に、直近サインイン成功の
            // userId を永続化 (restoreSession() の catch 側で使う)
            UserDefaults.standard.set(session.user.id.uuidString, forKey: Self.lastKnownUserIdKey)
            AppGroupStorage.shared.saveCurrentUserId(session.user.id)

            // users 行は handle_new_user trigger が作成済。
            await refreshProfile()

            // 🔴 2026-08-06 審査リジェクト対応 (Guideline 4 / Sign in with Apple):
            // Apple が名前を返したら、それを表示名として採用する。ユーザーに入力させない。
            // 既に users.display_name がある場合 (再サインイン等) は上書きしない。
            // Apple が名前を返すのは初回承認時だけなので、ここを逃すと二度と取れない。
            if let appleName = Self.formattedName(from: result.credential.fullName) {
                let existing = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if existing.isEmpty {
                    _ = try? await setDisplayName(appleName)
                }
            }
        } catch let error as ASAuthorizationError where error.code == .canceled {
            // ユーザーキャンセル: エラー表示しない
        } catch {
            errorMessage = "Apple サインインに失敗しました"
            print("⚠️ Apple Sign-In error: \(error)")
        }

        self.appleCoordinator = nil
        isSigningIn = false
    }

    /// Apple の `PersonNameComponents` を表示名の文字列にする (2026-08-06)。
    /// ⚠️ ロケールで語順が変わる (日本語は「姓 名」、英語は "Given Family") ため、
    /// 自前で連結せず PersonNameComponentsFormatter に任せる。
    /// 空白のみ / 全要素 nil の場合は nil を返す (呼び出し側で「取れなかった」と扱う)。
    /// display_name の長さ制限に合わせて 30 文字で切る。
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
        // 🔴 auth を切る「前」に消す。RPC は auth.uid() を見るので、後だと消せない。
        //    残したままにすると、次にこの端末を使う人に前の持ち主宛ての通知が飛ぶ
        await PushNotificationService.shared.removeTokenFromServer()

        do {
            try await client.auth.signOut()
        } catch {
            print("⚠️ Sign out error: \(error)")
        }
        self.isSignedIn = false
        self.userId = nil
        // H6: 明示的なサインアウトではサーバー検証済みフラグも下ろす (次回は必ずサインイン/
        // restoreSession の成功を経てから true にする)
        self.isSessionServerVerified = false
        clearProfileState()

        // M17 (監査2026-07-20): サインアウト後はオンボ画面に落ちて解除UIに到達できなくなるため、
        // 遮断エンジン (タイマー/スケジュール/位置) を明示的に止めてから App Group を掃除する。
        // 各 Manager の既存公開APIのみを使用 (新規の停止APIは作らない)。
        // ⚠️ 挙動変更: これにより明示的なサインアウトでスケジュール/位置の設定・実行中セッションが
        // 消える。設定はサーバー同期されておらず端末ローカルのため、再サインインしても復元されない。
        TimerManager.shared.stopTimer()
        ScheduleManager.shared.stopMonitoring()
        // LocationManager には stopMonitoring() 相当の「全解除」公開APIが無いため、
        // 既存の removeLocation(_:) を全登録地点に呼ぶことでジオフェンス解除+shield解除を代替する
        // (removeLocation は呼ぶたびに unregisterGeofence + syncShield を行う既存の公開API)
        for location in LocationManager.shared.registeredLocations {
            LocationManager.shared.removeLocation(location)
        }
        // 保険: 登録地点が既に0件でも store に shield が残っていれば解除する (既存公開API)
        LocationManager.shared.removeShield()

        // 本当にサインアウトが確定した経路 (ここ、および delete_my_account 成功後に
        // AccountDeletionService が呼ぶこの signOut()) でのみ App Group の夢ミラーを消す。
        // restoreSession() の一時的な失敗経路では消さない (F5, 2026-07 修正)
        AppGroupStorage.shared.saveUserDream(nil)
        // enqueue の user_id 刻印を止める (H3)。キュー本体はここでは消さない:
        // 各行に user_id が刻印済みなので、未送信分は本人の再サインイン時に正しく flush される
        AppGroupStorage.shared.saveCurrentUserId(nil)
        // H6: 明示的サインアウトではローカル信頼フォールバックの種を残さない
        // (次回オフライン起動時に前ユーザーとして自動サインインしてしまうのを防ぐ)
        UserDefaults.standard.removeObject(forKey: Self.lastKnownUserIdKey)
        // 073: 端末共有時のアカウント切替で「次のアカウントの users.lang が
        // (前アカウントと同じ rawValue だったため) 同期されない」事故を防ぐため、
        // 本当にサインアウトが確定した経路でだけキャッシュを捨てる
        // (clearProfileState は restoreSession の一時的失敗からも呼ばれるため、
        // そちらではキャッシュを残す = 上の saveUserDream(nil) と同じ方針)
        lastSyncedLanguageRaw = nil

        // M16 (監査2026-07-20): 端末共有時に前ユーザーの位置座標/スケジュール設定/Shield名言キャッシュが
        // 次ユーザーへ漏れるのを防ぐため、ユーザー固有データのみを個別に掃除する
        // (pendingBlockSessions と proBlockingEntitled は対象外、詳細は clearUserSpecificData 参照)
        AppGroupStorage.shared.clearUserSpecificData()
    }

    // MARK: - Profile

    /// users 行から display_name / handle / bio / avatar_url / is_pro を取得して反映。
    /// 夢は独立テーブル user_dreams (024 v2) から別クエリで取得する。
    /// 失敗時は前回値を維持 (ログのみ)。
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

        // 夢: user_dreams (RLS で自分の行は常に見える)。行が無い = 未宣言
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
            // Shield (案A) のサブタイトル用に App Group へミラー。起動時ロード (restoreSession/
            // signInWithApple 経由の refreshProfile) でここを通るので、他端末での編集も次回起動時に反映される
            AppGroupStorage.shared.saveUserDream(self.dream)
        } catch {
            print("⚠️ Failed to fetch dream: \(error)")
        }
    }

    /// C1: is_pro だけを単発で新鮮に取得する。成功時は self.isPro にも反映して値を返し、
    /// 失敗 (オフライン / Supabase pause 等) は nil を返して「未確定」を呼び出し側に伝える。
    /// refreshProfile は失敗時に前回値を維持するため「取得に成功したか」を区別できない — その穴を埋める専用フェッチ
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
            self.isPro = fresh   // @Published → ProAccess の sink 経由で serverIsPro にも伝播する
            return fresh
        } catch {
            print("⚠️ fetchIsProFresh failed: \(error)")
            return nil
        }
    }

    /// 自己紹介 (bio) を更新 (users.bio を UPDATE)。160文字以内、空文字は NULL 化。
    @discardableResult
    func updateBio(_ bio: String) async -> Bool {
        guard let uid = userId else { return false }
        let trimmed = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String? = trimmed.isEmpty ? nil : String(trimmed.prefix(160))

        // Optional を持つ Encodable struct は合成 Codable が nil キーを省略してしまい、
        // 「bio を空にして保存」が DB に届かない。AnyJSON.null で明示的に null を送る
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

    /// 073: 閲覧者(本人)の端末言語 (users.lang) をサーバーに同期する。
    /// fetch_mixed_feed_random の同一言語優先スコアリング (viewer_lang) の判定材料になる。
    /// サインイン時 (AppBlockerApp.syncSignInState) と、設定の言語 Picker 変更時
    /// (AppBlockerApp が UserDefaults.didChangeNotification を購読して検知) の両方から呼ばれる。
    /// 前回サーバーに送った値と同じなら何もしない (didChangeNotification は言語以外の
    /// UserDefaults 変更でも飛んでくるため、高頻度に呼ばれても無駄な通信をしないためのガード)。
    /// 失敗時はログのみで握りつぶす (loadAuthors と同じ流儀。lang 同期の失敗で
    /// サインインや言語切り替え自体のユーザー体験を壊してはいけない)
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

    /// 「夢」(なりたい自分の一言宣言) を更新 (user_dreams へ upsert、024 v2)。
    /// 120文字以内、空文字は NULL 化。isPublic は非公開が既定 (bio と異なり宣言的な内容のため)。
    /// 非公開の夢は RLS (user_dreams_select_public_or_own) で本人以外から見えない。
    @discardableResult
    func updateDream(_ dream: String, isPublic: Bool) async -> Bool {
        guard let uid = userId else { return false }
        let trimmed = dream.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String? = trimmed.isEmpty ? nil : String(trimmed.prefix(120))

        // AnyJSON.null で明示的に null を送る (Encodable struct だと nil キーが省略され、
        // 「夢を空にして保存」が DB に届かない)
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

    /// ハンドルがサーバー側で利用可能かをリアルタイムに確認 (is_handle_available RPC)。
    /// フォーマット不正はサーバーに問い合わせず .taken を即返す。
    /// 通信エラーは .taken (使用中) と区別して .error を返す — オフラインや Supabase pause 時に
    /// 「使用できません」と誤表示してオンボーディングを詰まらせないため (2026-07-07 Fable レビュー指摘)
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

    /// ハンドルを更新 (users.handle を UPDATE)。normalized + バリデーション後に反映。
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

    /// 表示名を更新 (users.display_name を UPDATE)。
    /// オンボーディング nameInput 直後と ProfileEditView 両方から呼ばれる。
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

    /// アバター画像を Storage にアップロードし、users.avatar_url を更新。
    /// パス: `{uid}/avatar.jpg` 固定 (upsert で上書き)。
    /// 戻り値: 反映された publicURL (?v=timestamp 付き、キャッシュ無効化)
    /// 注意: Swift の uuidString は uppercase、Supabase auth.uid() は lowercase。
    /// RLS ポリシーは storage.foldername で文字列比較するので必ず lowercased() で揃える。
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

    /// アバター画像を削除 (Storage オブジェクト削除 + users.avatar_url を NULL)。
    func removeAvatar() async throws {
        guard let uid = userId else { throw ProfileError.notSignedIn }
        let path = "\(uid.uuidString.lowercased())/avatar.jpg"

        do {
            _ = try await client.storage.from("avatars").remove(paths: [path])
        } catch {
            // 既に存在しない場合はエラーになるが、DB 側を NULL にする処理は続行
            print("⚠️ Avatar storage remove (ignored if not found): \(error)")
        }

        // AnyJSON.null で明示的に null を送る (Encodable struct だと nil キーが省略され、
        // PATCH ボディが {} になって avatar_url が NULL 化されない)
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

/// checkHandleAvailable の結果。通信エラー (.error) を「使用中」(.taken) と
/// 区別することで、呼び出し側がリトライ導線を出せる
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

/// ASAuthorizationController のデリゲートを担当する NSObject ラッパー。
/// UserAuthService から分離してあるのは、NSObject + @MainActor + ObservableObject の
/// 同時宣言が Swift 6 デフォルト isolation で詰まるため。
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
            // 🔴 2026-08-06 審査リジェクト対応 (Guideline 4 Design / Sign in with Apple):
            // 「Authentication Services が名前を提供しているのに、ユーザーに名前を入力させている」
            // と指摘された。旧 S15 方針 (fullName を取らずオンボで手入力させる) を撤回し、
            // .fullName を要求して Apple が返した名前をそのまま表示名に使う。
            // ⚠️ Apple が fullName を返すのは「そのApple IDで初めてこのアプリを承認した時」だけ。
            // 2回目以降は nil になるので、保存済みの users.display_name を正とすること。
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
