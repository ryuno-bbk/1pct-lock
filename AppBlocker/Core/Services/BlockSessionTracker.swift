//
//  BlockSessionTracker.swift
//  AppBlocker
//
//  Record lock sessions of the 3 modes (timer / schedule / location) → aggregate totals in Supabase
//
//  Design policy: "on completion, append 1 row to the App Group queue → bulk insert at launch"
//  - Do not keep the active state in the DB (minimize what can break)
//  - Same pattern for all modes
//  - Sessions that complete while the app is killed may be lost (we give up exact totals)
//

import Foundation
import Combine
import Supabase

@MainActor
final class BlockSessionTracker: ObservableObject {

    static let shared = BlockSessionTracker()

    // MARK: - Published

    /// Total lock seconds (from Supabase)
    @Published private(set) var totalSeconds: Int = 0

    /// Top percentile (from the get_block_percentile RPC)
    @Published private(set) var percentile: BlockPercentile?

    /// Streak of lock days (from the get_streak_days RPC)
    @Published private(set) var streakDays: Int = 0

    /// Completion rate (last 30 days, timer only, from the get_user_stats RPC)
    @Published private(set) var completion: CompletionRate?

    /// Completion rate (all time). For the detail sheet of the stat cell (034). nil on a DB without 034
    @Published private(set) var completionAllTime: CompletionRate?

    // MARK: - Private

    private let client: SupabaseClient
    private let appGroupID = AppGroupConstants.identifier
    private let queueKey = AppGroupConstants.Keys.pendingBlockSessions

    /// M9: flushQueue is @MainActor but can be re-entered during the suspension in insert (called in
    /// parallel from the launch task/onChange/ SessionCompleteView/MyProfileView). While true, return
    /// immediately to serialize
    private var isFlushing = false

    private init(client: SupabaseClient = SupabaseManager.shared.client) {
        self.client = client
    }

    // MARK: - Enqueue (helper for the main process)

    /// Add a completed session to the App Group queue.
    /// Called from timer / location. The Extension works on UserDefaults directly (because it is a separate
    /// target).
    /// - Parameters:
    ///   - status: "completed" (finished normally) or "aborted" (stopped manually)
    ///   - plannedSeconds: planned lock seconds (timer only). Used so the 10-minute filter of the
    ///     completion rate is judged by the planned time, not the measured time (033). Pass nil for
    ///     schedule/location
    nonisolated static func enqueueSession(mode: String, startedAt: Date, endedAt: Date, status: String, plannedSeconds: Int? = nil) {
        guard let defaults = UserDefaults(suiteName: AppGroupConstants.identifier) else { return }

        // H2 fix: at the source, repair the shapes that 015's validate_block_session rejects forever (future
        // ended_at / start>end / duration over 7 days) before queueing
        let (start, end) = repairedInterval(startedAt: startedAt, endedAt: endedAt, now: Date())
        let duration = max(0, Int(end.timeIntervalSince(start)))
        guard duration > 0 else { return }  // 0 seconds is noise, so drop it

        var entry: [String: Any] = [
            // ID for deleting individual rows after flush (prefix-drop removed, H2/H3).
            // Whether this key exists is also used to tell whether a row is in the new format (see the migration
            // in flushQueue)
            "entry_id": UUID().uuidString,
            "mode": mode,
            "started_at": start.timeIntervalSince1970,
            "ended_at": end.timeIntervalSince1970,
            "duration_seconds": duration,
            "status": status
        ]
        // H3: Stamp the currently signed-in user. Sessions completed while signed out are queued without
        // user_id and discarded at flush (they are not reassigned to a different person who signs in next)
        if let uid = defaults.string(forKey: AppGroupConstants.Keys.currentUserId) {
            entry["user_id"] = uid
        }
        if let plannedSeconds, plannedSeconds > 0 {
            // Prevents the whole batch from being rejected for violating 033's CHECK constraint (1...604800)
            entry["planned_seconds"] = min(plannedSeconds, 604800)
        }

        var queue = defaults.array(forKey: AppGroupConstants.Keys.pendingBlockSessions) as? [[String: Any]] ?? []
        queue.append(entry)
        defaults.set(queue, forKey: AppGroupConstants.Keys.pendingBlockSessions)

        // 🔴 2026-08-06 (fix for the Guideline 5.6.3 rejection): count the precondition for asking for a rating:
        // "has the user actually used the lock". The actual prompt is shown on the MainTabView side.
        //
        // ⚠️ Do not filter by status (user decision 2026-08-06). At first only "completed" was counted,
        // but that was reverted on the view that not many people reach completion. Making completion the condition
        // would mean most users are never asked. Even a manual stop means they touched the core feature.
        //
        // ⚠️ DeviceActivityMonitorExtension.recordSessionEnd is a separate target and does not pass through here.
        // Sessions recorded only by the extension are not counted, but a user is never asked for a rating
        // without opening the main app at least once, so there is no real harm.
        Task { @MainActor in ReviewPrompt.recordLockSessionUsed() }
    }

    /// Repair intervals that 015's validate_block_session rejects forever into a sendable shape.
    /// - Future ended_at (clock moved forward, completed, then moved back): shift into the past keeping the
    ///   duration (simply rounding end down to now stretches the gap from start and inflates the duration)
    /// - start > end: round start to end
    /// - Over 7 days (leftover scheduleActiveStart_ keys etc.): trim the started_at side
    ///   (clamping only the duration fails 015's timestamp consistency check of ±2 seconds, so always
    ///   adjust both)
    /// ⚠️ The same clamp is duplicated in DeviceActivityMonitorExtension.recordSessionEnd. Do not fix only
    ///    one of them
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

    /// Insert the sessions in the App Group queue into Supabase.
    /// - H3: each row has user_id stamped at enqueue time, and only rows matching the current user are sent.
    ///   Non-matching rows are kept (flushed when that user signs in again).
    ///   Rows with entry_id but no user_id = sessions completed while signed out → discard
    ///   (do not reassign records that belong to nobody to the next person who signs in).
    ///   Rows without entry_id at all = old format from before this update → assign to the current user and
    ///   migrate (very likely the record of whoever was signed in on the same device at the time, and
    ///   discarding would lose data).
    /// - H2: when a batch fails, use the SQLSTATE in PostgrestError to tell "row rejected" from "network etc.".
    ///   If rows are rejected, resend one row at a time and discard only the rejected rows (isolating the
    ///   poison pill). For network etc., keep everything as before → retry next time.
    /// - M10: upsert with entry_id as the server row's id (onConflict: "id", ignoreDuplicates: true).
    ///   Even if the same row arrives twice due to a resend after a lost response or re-entry (serialized
    ///   by M9, but e.g. the launch task and onChange may call at different times), the server silently
    ///   ignores it with ON CONFLICT DO NOTHING, so it is not counted twice.
    /// Called at launch / on sign-in change / before showing the profile.
    func flushQueue() async {
        // M9: Prevent double flush. Because it is @MainActor, serializing here makes re-entrant calls during
        // the insert suspension return immediately (prevents inflated totals from inserting the same queue row
        // twice)
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        guard let userId = UserAuthService.shared.userId else { return }
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        let currentUserId = userId.uuidString.lowercased()

        var queue = defaults.array(forKey: queueKey) as? [[String: Any]] ?? []
        guard !queue.isEmpty else { return }

        // --- Read-time migration (H3) ---
        // Assign an entry_id to old-format rows (no entry_id), attribute them to the current user and write
        // them back. The window in which the extension appends during this write-back is the same known,
        // accepted risk that the old prefix-drop had (UserDefaults does not provide atomic cross-process append).
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

        // --- Select the rows to send ---
        var garbageIds: Set<String> = []   // Unparseable / no user_id (records from while signed out) → discard
        var targets: [(entryId: String, insert: SessionInsert)] = []
        for entry in queue {
            guard let entryId = entry["entry_id"] as? String else { continue }  // Should already be assigned just above, but stay on the safe side
            guard let entryUserId = entry["user_id"] as? String else {
                garbageIds.insert(entryId)
                continue
            }
            guard entryUserId == currentUserId else { continue }  // Other users' rows are kept (waiting for that user to sign in again)
            guard let insert = Self.makeInsert(entry: entry, entryId: entryId, userId: currentUserId, formatter: isoFormatter) else {
                garbageIds.insert(entryId)  // Unparseable or 0 seconds after repair = garbage data
                continue
            }
            targets.append((entryId, insert))
        }

        guard !targets.isEmpty else {
            removeEntries(ids: garbageIds, defaults: defaults)
            return
        }

        do {
            // M10: upsert by id (= entry_id). A resend of the same row is ignored with ON CONFLICT DO NOTHING
            // (the UPDATE policy was removed in M31, so do not use DO UPDATE)
            try await client
                .from("block_sessions")
                .upsert(targets.map(\.insert), onConflict: "id", returning: .minimal, ignoreDuplicates: true)
                .execute()

            removeEntries(ids: Set(targets.map(\.entryId)).union(garbageIds), defaults: defaults)
            print("✅ Flushed \(targets.count) block sessions")
        } catch {
            guard Self.isRowRejection(error) else {
                // No network / expired JWT (PGRST301) / RLS (42501) etc. are not caused by the data
                // → keep the queue → retry next time (previous behavior)
                print("⚠️ Failed to flush block sessions: \(error)")
                return
            }
            // Poison pill isolation: some row was rejected by the server. Resend one row at a time and
            // split it into "discard only the rejected rows, delete the rows that went through" (H2)
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
                        // 015 trigger / CHECK constraint / FK violation (deleted user) etc.
                        // These will never go through no matter how often we retry, so discard
                        print("🗑️ Dropped rejected block session (\(target.insert.mode)): \(error)")
                        removable.insert(target.entryId)
                    } else {
                        // Switched to a network-caused failure midway → retry the rest next time
                        print("⚠️ Row-by-row flush interrupted: \(error)")
                        break
                    }
                }
            }
            removeEntries(ids: removable, defaults: defaults)
        }
    }

    /// Remove the rows whose entry_id matches from the queue and write it back.
    /// Successor to prefix-drop (count-based): with per-user sending, the sent rows are not necessarily a
    /// contiguous block at the head of the queue, so delete them individually by ID. Rows the extension
    /// appends during flush have non-matching IDs and are not affected
    /// (deletion is idempotent even if flush is called twice in parallel, so it does not make M9 worse)
    private func removeEntries(ids: Set<String>, defaults: UserDefaults) {
        guard !ids.isEmpty else { return }
        let current = defaults.array(forKey: queueKey) as? [[String: Any]] ?? []
        let remainder = current.filter { entry in
            guard let id = entry["entry_id"] as? String else { return true }  // Keep rows that have no ID assigned yet
            return !ids.contains(id)
        }
        if remainder.isEmpty {
            defaults.removeObject(forKey: queueKey)
        } else {
            defaults.set(remainder, forKey: queueKey)
        }
    }

    /// Decide whether the server rejected the data of that row itself (= retrying is pointless).
    /// PostgrestError is a structured error returned by the server (PostgREST); code is the Postgres SQLSTATE:
    /// - "P0001" = RAISE EXCEPTION (015 validate_block_session trigger)
    /// - class "23" = integrity constraint violation (23514 CHECK = 033 planned_seconds range, 23503 FK =
    ///   deleted user, etc.)
    /// - class "22" = data exception
    /// PGRST301 (expired JWT) / 42501 (RLS) / others are not caused by the data, so false (keep all and retry).
    /// No network or timeouts come as URLError etc., which cannot be cast to PostgrestError, so they are false
    private static func isRowRejection(_ error: Error) -> Bool {
        guard let pgError = error as? PostgrestError, let code = pgError.code else { return false }
        return code == "P0001" || code.hasPrefix("22") || code.hasPrefix("23")
    }

    /// Convert 1 queue entry into a SessionInsert. Unparseable / 0 seconds after repair returns nil (the
    /// caller discards it). Rows queued before the update that are "certain to be rejected" (future
    /// ended_at / over 7 days) are also repaired and saved here. duration_seconds is recomputed from the
    /// repaired timestamps, not the stored value (for 015's ±2 second consistency check)
    /// M10: pass entryId as is as the server row's id (the onConflict key of the upsert)
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
        // planned_seconds is a new field added in 033. Old-format queues do not have the key at all, so pass nil.
        // Values that would fail 033's CHECK (1...604800) are clamped / set to nil here as well
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

    /// On account deletion, discard from the queue the unsent rows for the deleted user and old-format rows.
    /// Rows of a deleted user can never be inserted on the server (FK / RLS), and
    /// if old-format rows (no entry_id) are kept they get attributed to the next person who signs in, so
    /// delete both. AccountDeletionService calls this before signOut() (while userId is still available)
    nonisolated static func purgeQueue(for userId: UUID) {
        guard let defaults = UserDefaults(suiteName: AppGroupConstants.identifier) else { return }
        let target = userId.uuidString.lowercased()
        let queue = defaults.array(forKey: AppGroupConstants.Keys.pendingBlockSessions) as? [[String: Any]] ?? []
        guard !queue.isEmpty else { return }
        let remainder = queue.filter { entry in
            guard entry["entry_id"] != nil else { return false }  // Old format = rows from the time of the deleted account
            return (entry["user_id"] as? String) != target
        }
        if remainder.isEmpty {
            defaults.removeObject(forKey: AppGroupConstants.Keys.pendingBlockSessions)
        } else {
            defaults.set(remainder, forKey: AppGroupConstants.Keys.pendingBlockSessions)
        }
    }

    // MARK: - Stats (total lock / top percentile / streak / completion rate in 1 RPC)

    /// Fetch total lock seconds + top percentile + streak lock days + completion rate (033 get_user_stats)
    /// from Supabase. A combined call so that 1 profile screen = 1 RPC (the old loadTotal is removed and
    /// merged). If 033 is not applied (RPC not deployed), it fails and only prints. There is no fallback
    /// (design policy to avoid double implementations. Assumes 033 is applied)
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

    /// Display format ("X分" ("X min") / Xh Ym)
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
        /// M10: send the entry_id stamped at enqueue time as is as the primary key of the server row.
        /// This is what makes upsert(onConflict: "id", ignoreDuplicates: true) idempotent
        let id: String
        let user_id: String
        let mode: String
        let started_at: String
        let ended_at: String
        let duration_seconds: Int
        let status: String
        /// Non-nil only for timers. When nil, the synthesized Encodable (encodeIfPresent) omits the key itself
        /// → the column is nullable, so it becomes NULL in the DB
        let planned_seconds: Int?
    }

    /// Return value of the get_block_percentile RPC. has_data=false means zero lock records
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

    /// Completion rate (last 30 days, timer only). has_data=false means 0 target sessions (after excluding
    /// those under 10 minutes)
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

    /// Return value of the get_user_stats RPC (combined response for profile stats).
    /// completionAllTime was added in 034 (a DB with only 033 applied has no key → allowed via Optional)
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
