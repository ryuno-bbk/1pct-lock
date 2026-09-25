//
//  WeeklyReportService.swift
//  AppBlocker
//
//  週次レポートの取得 (080_weekly_report.sql)
//
//  🔴 新しいデータ収集はゼロ。既存の block_sessions をサーバー側で集計して返すだけ。
//     レポートは保存されていないので、過去分も weekOffset を変えて取り直す。
//
//  🔴 レポート本体は @Published で持たない。
//     履歴一覧 → 過去のレポート、と push で複数枚開ける画面なので、共有の1枚に
//     書き戻す作りにすると後から開いた方が前の画面の中身を書き換えてしまう。
//     取得結果は呼び出し元 (View) のローカル state に持たせる。
//     一覧 (history) だけは1画面しか無いので @Published のままでよい。
//

import Foundation
import Combine
import Supabase

@MainActor
final class WeeklyReportService: ObservableObject {

    static let shared = WeeklyReportService()

    /// 過去レポートの一覧 (新しい順・完了週のみ)
    @Published private(set) var history: [WeeklyReportSummary] = []
    @Published private(set) var isLoadingHistory = false

    private let client: SupabaseClient

    /// サーバー側の週境界を端末のタイムゾーンで切らせる。
    /// ⚠️ 016 の get_streak_days と同じ渡し方 (不正な識別子はサーバー側で UTC に落ちる)
    private var timeZoneID: String { TimeZone.current.identifier }

    private init(client: SupabaseClient = SupabaseManager.shared.client) {
        self.client = client
    }

    // MARK: - 取得

    /// - Parameter weekOffset: 何週前か。0 = 進行中の今週、1 = 先週 (既定)。
    ///   通知から開くときもレポート画面の既定も 1 (直近の完了週)。
    /// - Returns: 取得できなければ nil (未サインイン / 通信失敗 / 080 未適用)
    func fetchReport(weekOffset: Int = 1) async -> WeeklyReport? {
        guard UserAuthService.shared.userId != nil else { return nil }

        let params: [String: AnyJSON] = [
            "p_week_offset": .integer(max(0, weekOffset)),
            "p_tz": .string(timeZoneID)
        ]

        do {
            return try await client
                .rpc("get_weekly_report", params: params)
                .execute()
                .value
        } catch {
            print("⚠️ Failed to load weekly report: \(error)")
            return nil
        }
    }

    /// 設定 → 週次レポート の一覧用
    func loadHistory(limit: Int = 12) async {
        guard UserAuthService.shared.userId != nil else {
            history = []
            return
        }

        isLoadingHistory = true
        defer { isLoadingHistory = false }

        let params: [String: AnyJSON] = [
            "p_limit": .integer(limit),
            "p_tz": .string(timeZoneID)
        ]

        do {
            history = try await client
                .rpc("get_weekly_report_list", params: params)
                .execute()
                .value
        } catch {
            print("⚠️ Failed to load weekly report history: \(error)")
        }
    }

    /// サインアウト時に呼ぶ。次にその端末を使う人に前の持ち主のレポートを見せない
    func clear() {
        history = []
    }
}
