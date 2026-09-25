//
//  BlockSessionTracker.swift
//  AppBlocker
//
//  3 モード (timer / schedule / location) のロックセッションを記録 → Supabase で累計集計
//
//  設計方針: 「完了時に App Group キューへ 1 行追加 → 起動時に一括 insert」
//  - active 状態は DB に持たない (バグり要素を最小化)
//  - 全モード同じパターン
//  - kill 中に完了したセッションは欠落許容 (累計の正確さは捨てる)
//

import Foundation
import Combine
import Supabase

@MainActor
final class BlockSessionTracker: ObservableObject {

    static let shared = BlockSessionTracker()

    // MARK: - Published

    /// 累計ロック秒数 (Supabase 由来)
    @Published private(set) var totalSeconds: Int = 0

    /// 上位% (get_block_percentile RPC 由来)
    @Published private(set) var percentile: BlockPercentile?

    /// 連続ロック日数 (get_streak_days RPC 由来)
    @Published private(set) var streakDays: Int = 0

    /// 完遂率 (直近30日・タイマーのみ・get_user_stats RPC 由来)
    @Published private(set) var completion: CompletionRate?

    /// 完遂率 (全期間)。統計セルの詳細シート用 (034)。034 未適用の DB では nil
    @Published private(set) var completionAllTime: CompletionRate?

    // MARK: - Private

    private let client: SupabaseClient
    private let appGroupID = AppGroupConstants.identifier
    private let queueKey = AppGroupConstants.Keys.pendingBlockSessions

    /// M9: flushQueue は @MainActor だが insert 中の suspension で再入され得る (起動task/onChange/
    /// SessionCompleteView/MyProfileView から並行に呼ばれる)。true の間は即 return して直列化する
    private var isFlushing = false

    private init(client: SupabaseClient = SupabaseManager.shared.client) {
        self.client = client
    }

    // MARK: - Enqueue (メインプロセス用ヘルパー)

    /// 完了したセッションを App Group キューに追加。
    /// timer / location から呼ぶ。Extension は直接 UserDefaults を操作する (別ターゲットのため)。
    /// - Parameters:
    ///   - status: "completed" (正常終了) または "aborted" (手動停止)
    ///   - plannedSeconds: 予定ロック秒数 (タイマーのみ)。完遂率の10分フィルタを実測でなく
    ///     予定時間で判定するための値 (033)。schedule/location は nil のまま渡す
    nonisolated static func enqueueSession(mode: String, startedAt: Date, endedAt: Date, status: String, plannedSeconds: Int? = nil) {
        guard let defaults = UserDefaults(suiteName: AppGroupConstants.identifier) else { return }

        // H2 対策: 015 の validate_block_session が永久拒否する形 (未来の ended_at /
        // start>end / 7日超 duration) を発生源で補正してから積む
        let (start, end) = repairedInterval(startedAt: startedAt, endedAt: endedAt, now: Date())
        let duration = max(0, Int(end.timeIntervalSince(start)))
        guard duration > 0 else { return }  // 0 秒はノイズなので捨てる

        var entry: [String: Any] = [
            // flush 後の個別削除用 ID (prefix-drop 廃止, H2/H3)。
            // このキーの有無が「新形式かどうか」の判定にも使われる (flushQueue の移行処理参照)
            "entry_id": UUID().uuidString,
            "mode": mode,
            "started_at": start.timeIntervalSince1970,
            "ended_at": end.timeIntervalSince1970,
            "duration_seconds": duration,
            "status": status
        ]
        // H3: 現サインインユーザーを刻印する。サインアウト中に完了した分は user_id 無しのまま
        // 積まれ、flush 時に破棄される (次にサインインした別人へ付け替えない)
        if let uid = defaults.string(forKey: AppGroupConstants.Keys.currentUserId) {
            entry["user_id"] = uid
        }
        if let plannedSeconds, plannedSeconds > 0 {
            // 033 の CHECK 制約 (1...604800) 違反でバッチごと拒否されるのを防ぐ
            entry["planned_seconds"] = min(plannedSeconds, 604800)
        }

        var queue = defaults.array(forKey: AppGroupConstants.Keys.pendingBlockSessions) as? [[String: Any]] ?? []
        queue.append(entry)
        defaults.set(queue, forKey: AppGroupConstants.Keys.pendingBlockSessions)

        // 🔴 2026-08-06 (Guideline 5.6.3 リジェクト対応): 評価依頼の前提条件
        // 「ロックを実際に使ったことがあるか」を数える。実際に聞くのは MainTabView 側。
        //
        // ⚠️ status で絞らない (2026-08-06 ユーザー判断)。当初は "completed" のみ数えていたが、
        // 完遂まで至る人は多くないという見立てで撤回した。完遂を条件にすると大半の
        // ユーザーに永久に聞けなくなる。手動停止でもコア機能には触れている。
        //
        // ⚠️ DeviceActivityMonitorExtension.recordSessionEnd は別ターゲットでここを通らない。
        // 拡張だけが記録したセッションは数えられないが、本体を一度も開かずに
        // 評価を聞かれることは無いので実害は無い。
        Task { @MainActor in ReviewPrompt.recordLockSessionUsed() }
    }

    /// 015 の validate_block_session が永久拒否する区間を送信可能な形へ補正する。
    /// - 未来の ended_at (時計を進めて完了→戻したケース): duration を保ったまま過去へ平行移動
    ///   (end を単純に now へ丸めるだけだと start との差が伸びて duration が水増しされるため)
    /// - start > end: start を end に丸める
    /// - 7日超 (scheduleActiveStart_ キーの残留等): started_at 側を切り詰める
    ///   (duration だけクランプすると 015 の timestamp 整合チェック ±2 秒に落ちるので、必ず両方揃える)
    /// ⚠️ DeviceActivityMonitorExtension.recordSessionEnd に同じクランプを複製してある。片方だけ直さないこと
    nonisolated static func repairedInterval(startedAt: Date, endedAt: Date, now: Date) -> (start: Date, end: Date) {
        var start = startedAt
        var end = endedAt
        if end > now {
            let shift = end.timeIntervalSince(now)
            end = now
            start = start.addingTimeInterval(-shift)
        }
        if start > end { start = end }
        if end.timeIntervalSince(start) > 604800 {
            start = end.addingTimeInterval(-604800)
        }
        return (start, end)
    }

    // MARK: - Flush

    /// App Group キューにあるセッションを Supabase へ insert。
    /// - H3: 各行は enqueue 時に user_id が刻印されており、現ユーザーと一致する行だけを送る。
    ///   不一致行は保留 (そのユーザーが再サインインした時に flush される)。
    ///   entry_id 付きで user_id 無しの行 = サインアウト中に完了したセッション → 破棄
    ///   (誰の実績でもないものを次のサインイン者へ付け替えない)。
    ///   entry_id 自体が無い行 = このアップデート以前の旧形式 → 現ユーザーに帰属させて移行
    ///   (同一端末・当時のサインイン者の実績である蓋然性が極めて高く、破棄はデータ消失になるため)。
    /// - H2: バッチ失敗時、PostgrestError の SQLSTATE で「行拒否」と「ネットワーク等」を判別。
    ///   行拒否なら 1 行ずつ再送して拒否行だけ破棄する (ポイズンピルの隔離)。
    ///   ネットワーク等は従来通り全保持 → 次回再試行。
    /// - M10: entry_id をサーバー行の id として upsert(onConflict: "id", ignoreDuplicates: true) する。
    ///   応答喪失後の再送や再入 (M9 で直列化済みだが起動taskとonChangeが別タイミングで呼ばれるケース等) で
    ///   同じ行が2度届いても ON CONFLICT DO NOTHING でサーバーが黙って無視するため二重計上されない。
    /// 起動時 / サインイン切替 / プロフィール表示前に呼ばれる。
    func flushQueue() async {
        // M9: 二重flush防止。@MainActor なのでここで直列化すれば insert の suspension 中の
        // 再入呼び出しは即 return する (同じキュー行の二重insertによる累計水増しを防ぐ)
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        guard let userId = UserAuthService.shared.userId else { return }
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        let currentUserId = userId.uuidString.lowercased()

        var queue = defaults.array(forKey: queueKey) as? [[String: Any]] ?? []
        guard !queue.isEmpty else { return }

        // --- 読み取り時マイグレーション (H3) ---
        // 旧形式 (entry_id 無し) に entry_id を採番し、現ユーザーへ帰属させて書き戻す。
        // この書き戻しの間に extension が append する窓は、従来の prefix-drop にもあった
        // 既知の許容リスク (UserDefaults はプロセス間アトミック append を提供しない) と同一。
        var migrated = false
        for i in queue.indices where queue[i]["entry_id"] == nil {
            queue[i]["entry_id"] = UUID().uuidString
            if queue[i]["user_id"] == nil {
                queue[i]["user_id"] = currentUserId
            }
            migrated = true
        }
        if migrated {
            defaults.set(queue, forKey: queueKey)
        }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        // --- 送信対象の選別 ---
        var garbageIds: Set<String> = []   // パース不能 / user_id 無し (サインアウト中の実績) → 破棄
        var targets: [(entryId: String, insert: SessionInsert)] = []
        for entry in queue {
            guard let entryId = entry["entry_id"] as? String else { continue }  // 直前で採番済みのはずだが安全側
            guard let entryUserId = entry["user_id"] as? String else {
                garbageIds.insert(entryId)
                continue
            }
            guard entryUserId == currentUserId else { continue }  // 他ユーザー分は保留 (本人の再サインイン待ち)
            guard let insert = Self.makeInsert(entry: entry, entryId: entryId, userId: currentUserId, formatter: isoFormatter) else {
                garbageIds.insert(entryId)  // パース不能 or 補正後 0 秒 = ゴミデータ
                continue
            }
            targets.append((entryId, insert))
        }

        guard !targets.isEmpty else {
            removeEntries(ids: garbageIds, defaults: defaults)
            return
        }

        do {
            // M10: id (= entry_id) で upsert。同一行の再送は ON CONFLICT DO NOTHING で無視される
            // (M31 でUPDATEポリシーは撤去済みなので DO UPDATE にはしない)
            try await client
                .from("block_sessions")
                .upsert(targets.map(\.insert), onConflict: "id", returning: .minimal, ignoreDuplicates: true)
                .execute()

            removeEntries(ids: Set(targets.map(\.entryId)).union(garbageIds), defaults: defaults)
            print("✅ Flushed \(targets.count) block sessions")
        } catch {
            guard Self.isRowRejection(error) else {
                // ネットワーク不達 / JWT 失効 (PGRST301) / RLS (42501) 等はデータ起因ではない
                // → キューは残す → 次回再試行 (従来挙動)
                print("⚠️ Failed to flush block sessions: \(error)")
                return
            }
            // ポイズンピル隔離: どれかの行がサーバーに拒否された。1 行ずつ再送して
            // 「拒否された行だけ破棄、通った行は削除」に分解する (H2)
            var removable = garbageIds
            for target in targets {
                do {
                    try await client
                        .from("block_sessions")
                        .upsert(target.insert, onConflict: "id", returning: .minimal, ignoreDuplicates: true)
                        .execute()
                    removable.insert(target.entryId)
                } catch {
                    if Self.isRowRejection(error) {
                        // 015 トリガー / CHECK 制約 / FK 違反 (削除済みユーザー) 等。
                        // リトライしても永久に通らないので破棄する
                        print("🗑️ Dropped rejected block session (\(target.insert.mode)): \(error)")
                        removable.insert(target.entryId)
                    } else {
                        // 途中でネットワーク起因に転じた → 残りは次回再試行
                        print("⚠️ Row-by-row flush interrupted: \(error)")
                        break
                    }
                }
            }
            removeEntries(ids: removable, defaults: defaults)
        }
    }

    /// キューから entry_id が一致する行を取り除いて書き戻す。
    /// prefix-drop (件数ベース) の後継: ユーザー別送信では送信行がキューの先頭連続とは限らないため、
    /// ID で個別に消す。flush 中に extension が追記した行は ID が一致しないので巻き込まれない
    /// (並行 flush が二重に呼ばれても削除は冪等 — M9 を悪化させない)
    private func removeEntries(ids: Set<String>, defaults: UserDefaults) {
        guard !ids.isEmpty else { return }
        let current = defaults.array(forKey: queueKey) as? [[String: Any]] ?? []
        let remainder = current.filter { entry in
            guard let id = entry["entry_id"] as? String else { return true }  // 採番前の行は残す
            return !ids.contains(id)
        }
        if remainder.isEmpty {
            defaults.removeObject(forKey: queueKey)
        } else {
            defaults.set(remainder, forKey: queueKey)
        }
    }

    /// サーバーがその行のデータ自体を拒否したか (= リトライ無意味) の判定。
    /// PostgrestError はサーバー (PostgREST) が返した構造化エラーで、code は Postgres の SQLSTATE:
    /// - "P0001" = RAISE EXCEPTION (015 validate_block_session トリガー)
    /// - クラス "23" = 整合性制約違反 (23514 CHECK = 033 planned_seconds 範囲, 23503 FK = 削除済みユーザー 等)
    /// - クラス "22" = データ例外
    /// PGRST301 (JWT 失効) / 42501 (RLS) / その他はデータ起因ではないので false (全保持リトライ側)。
    /// ネットワーク不達やタイムアウトは URLError 等で来るため PostgrestError にキャストできず false になる
    private static func isRowRejection(_ error: Error) -> Bool {
        guard let pgError = error as? PostgrestError, let code = pgError.code else { return false }
        return code == "P0001" || code.hasPrefix("22") || code.hasPrefix("23")
    }

    /// キューの 1 エントリを SessionInsert へ変換。パース不能 / 補正後 0 秒は nil (呼び出し側で破棄)。
    /// アップデート前に積まれてしまった「拒否必至の行」(未来 ended_at / 7日超) もここで補正して救済する。
    /// duration_seconds は保存値でなく補正後 timestamp から再計算する (015 の ±2 秒整合チェック対策)
    /// M10: entryId をそのままサーバー行の id として渡す (upsert の onConflict キー)
    private static func makeInsert(entry: [String: Any], entryId: String, userId: String, formatter: ISO8601DateFormatter) -> SessionInsert? {
        guard let mode = entry["mode"] as? String,
              let startedTs = entry["started_at"] as? TimeInterval,
              let endedTs = entry["ended_at"] as? TimeInterval,
              entry["duration_seconds"] is Int,
              let status = entry["status"] as? String else {
            return nil
        }
        let (start, end) = repairedInterval(
            startedAt: Date(timeIntervalSince1970: startedTs),
            endedAt: Date(timeIntervalSince1970: endedTs),
            now: Date()
        )
        let duration = max(0, Int(end.timeIntervalSince(start)))
        guard duration > 0 else { return nil }
        // planned_seconds は 033 で追加した新フィールド。古い形式のキューにはキー自体が無いので nil で通す。
        // 033 の CHECK (1...604800) に落ちる値はここでもクランプ / nil 化する
        let plannedSeconds = (entry["planned_seconds"] as? Int).flatMap { $0 > 0 ? min($0, 604800) : nil }
        return SessionInsert(
            id: entryId,
            user_id: userId,
            mode: mode,
            started_at: formatter.string(from: start),
            ended_at: formatter.string(from: end),
            duration_seconds: duration,
            status: status,
            planned_seconds: plannedSeconds
        )
    }

    /// アカウント削除時に、削除ユーザー宛の未送信行と旧形式行をキューから破棄する。
    /// 削除済みユーザーの行はサーバー側で永久に insert できず (FK / RLS)、
    /// 旧形式行 (entry_id 無し) を残すと次のサインイン者へ帰属されてしまうため、両方消す。
    /// AccountDeletionService が signOut() の前 (userId がまだ取れるうち) に呼ぶ
    nonisolated static func purgeQueue(for userId: UUID) {
        guard let defaults = UserDefaults(suiteName: AppGroupConstants.identifier) else { return }
        let target = userId.uuidString.lowercased()
        let queue = defaults.array(forKey: AppGroupConstants.Keys.pendingBlockSessions) as? [[String: Any]] ?? []
        guard !queue.isEmpty else { return }
        let remainder = queue.filter { entry in
            guard entry["entry_id"] != nil else { return false }  // 旧形式 = 削除アカウント時代の行
            return (entry["user_id"] as? String) != target
        }
        if remainder.isEmpty {
            defaults.removeObject(forKey: AppGroupConstants.Keys.pendingBlockSessions)
        } else {
            defaults.set(remainder, forKey: AppGroupConstants.Keys.pendingBlockSessions)
        }
    }

    // MARK: - Stats (累計ロック / 上位% / ストリーク / 完遂率を1 RPCで取得)

    /// 累計ロック秒数 + 上位% + 連続ロック日数 + 完遂率 (033 get_user_stats) を Supabase から取得。
    /// プロフィール1画面 = 1 RPC に集約するための統合呼び出し (旧 loadTotal は廃止・統合済み)。
    /// 033 未適用 (RPC 未デプロイ) の場合は失敗して print のみ。フォールバックは持たない
    /// (二重実装を避ける設計方針。033 適用が前提)
    func loadStats() async {
        guard let userId = UserAuthService.shared.userId else {
            self.totalSeconds = 0
            self.percentile = nil
            self.streakDays = 0
            self.completion = nil
            self.completionAllTime = nil
            return
        }

        do {
            let params: [String: AnyJSON] = [
                "target_user_id": .string(userId.uuidString),
                "tz": .string(TimeZone.current.identifier)
            ]
            let stats: UserStats = try await client
                .rpc("get_user_stats", params: params)
                .execute()
                .value
            self.totalSeconds = stats.totalBlockSeconds
            self.streakDays = stats.streakDays
            self.percentile = stats.percentile
            self.completion = stats.completion
            self.completionAllTime = stats.completionAllTime
        } catch {
            print("⚠️ Failed to load user stats: \(error)")
        }
    }

    /// 表示用フォーマット (X分 / Xh Ym)
    func formattedTotal() -> String {
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    // MARK: - Types

    private struct SessionInsert: Encodable {
        /// M10: enqueue 時に刻印済みの entry_id をそのままサーバー行の主キーとして送る。
        /// upsert(onConflict: "id", ignoreDuplicates: true) の冪等性の要
        let id: String
        let user_id: String
        let mode: String
        let started_at: String
        let ended_at: String
        let duration_seconds: Int
        let status: String
        /// タイマーのみ非nil。nil の場合は合成 Encodable (encodeIfPresent) がキー自体を
        /// 省略する → カラムは nullable なので DB 側は NULL になる
        let planned_seconds: Int?
    }

    /// get_block_percentile RPC 戻り値。has_data=false はロック実績ゼロ
    struct BlockPercentile: Decodable {
        let hasData: Bool
        let topPercent: Double?
        let rank: Int?
        let totalUsers: Int?

        enum CodingKeys: String, CodingKey {
            case hasData = "has_data"
            case topPercent = "top_percent"
            case rank
            case totalUsers = "total_users"
        }
    }

    /// 完遂率 (直近30日・タイマーのみ)。has_data=false は対象セッション0件 (10分未満除外後)
    struct CompletionRate: Decodable {
        let hasData: Bool
        let ratePercent: Int?
        let completedCount: Int?
        let eligibleCount: Int?

        enum CodingKeys: String, CodingKey {
            case hasData = "has_data"
            case ratePercent = "rate_percent"
            case completedCount = "completed_count"
            case eligibleCount = "eligible_count"
        }
    }

    /// get_user_stats RPC 戻り値 (プロフィール統計の統合レスポンス)。
    /// completionAllTime は 034 で追加 (033 のみ適用の DB ではキーが無い → Optional で許容)
    private struct UserStats: Decodable {
        let totalBlockSeconds: Int
        let streakDays: Int
        let percentile: BlockPercentile
        let completion: CompletionRate
        let completionAllTime: CompletionRate?

        enum CodingKeys: String, CodingKey {
            case totalBlockSeconds = "total_block_seconds"
            case streakDays = "streak_days"
            case percentile
            case completion
            case completionAllTime = "completion_all_time"
        }
    }
}
