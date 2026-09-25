//
//  WeeklyReport.swift
//  AppBlocker
//
//  週次レポート (080_weekly_report.sql の get_weekly_report / get_weekly_report_list 戻り値)
//
//  🔴 サーバー側はレポートを保存していない。block_sessions から毎回再計算している。
//     過去のレポートも weekOffset を変えて同じ RPC を呼ぶだけで出る。
//

import Foundation

// MARK: - 日付 (date 型) のデコード

/// RPC は Postgres の `date` を "2026-08-24" の文字列で返す (時刻もタイムゾーンも付かない)。
/// Supabase の既定デコーダは ISO8601 の日時を期待するのでそのままでは落ちる。
/// ここでは文字列のまま受けて、表示のときにカレンダー日付として解釈する。
enum WeekDay {
    static let parser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        // 週の境界はサーバー側で端末のタイムゾーンを使って切ってあるので、
        // ここも端末ローカルとして解釈する (UTC で解釈すると1日ずれる)
        f.timeZone = TimeZone.current
        return f
    }()

    static func date(from raw: String?) -> Date? {
        guard let raw else { return nil }
        return parser.date(from: raw)
    }
}

// MARK: - レポート本体

struct WeeklyReport: Decodable, Equatable {

    /// 過去に一度でもロックしたか。false ならレポートは全項目ゼロで画面が成立しない
    let hasHistory: Bool

    /// "2026-08-24" 形式。月曜始まり
    let weekStartRaw: String
    /// "2026-08-30" 形式。日曜
    let weekEndRaw: String

    /// 進行中の週かどうか。true のときは「途中経過」であることを画面に出す
    let isCurrentWeek: Bool

    /// その週のロック秒数
    let seconds: Int
    /// その週のセッション数
    let sessions: Int
    /// 前の週のロック秒数
    let prevSeconds: Int
    /// 先週比 (%)。前の週が 0 秒だと定義できないので nil
    let deltaPercent: Double?

    /// その週の順位。母数が閾値未満の週は nil (サーバー側で伏せている)
    let rank: Int?
    /// その週の上位%。同上
    let topPercent: Double?
    /// その週に1秒でもロックした人数
    let activeUsers: Int

    /// その週末時点の累計ロック秒数
    let totalSeconds: Int
    /// 直近4週 (初回セッションより前の週は除く) の平均
    let avg4Seconds: Int
    /// 上記ペースが1年続いた場合の秒数
    let projectionYearSeconds: Int

    /// モード別内訳 ("timer" / "schedule" / "location")。
    /// ❌ アプリ別の内訳は作れない (Screen Time API が実測値をアプリ本体に渡さない)
    let byMode: [String: Int]

    /// 曜日別の秒数。必ず7要素 (月=0 〜 日=6)
    let days: [Int]

    var weekStart: Date? { WeekDay.date(from: weekStartRaw) }
    var weekEnd: Date? { WeekDay.date(from: weekEndRaw) }

    enum CodingKeys: String, CodingKey {
        case hasHistory            = "has_history"
        case weekStartRaw          = "week_start"
        case weekEndRaw            = "week_end"
        case isCurrentWeek         = "is_current_week"
        case seconds, sessions, rank, days
        case prevSeconds           = "prev_seconds"
        case deltaPercent          = "delta_percent"
        case topPercent            = "top_percent"
        case activeUsers           = "active_users"
        case totalSeconds          = "total_seconds"
        case avg4Seconds           = "avg4_seconds"
        case projectionYearSeconds = "projection_year_seconds"
        case byMode                = "by_mode"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hasHistory            = try c.decodeIfPresent(Bool.self, forKey: .hasHistory) ?? false
        weekStartRaw          = try c.decode(String.self, forKey: .weekStartRaw)
        weekEndRaw            = try c.decode(String.self, forKey: .weekEndRaw)
        isCurrentWeek         = try c.decodeIfPresent(Bool.self, forKey: .isCurrentWeek) ?? false
        seconds               = try c.decodeIfPresent(Int.self, forKey: .seconds) ?? 0
        sessions              = try c.decodeIfPresent(Int.self, forKey: .sessions) ?? 0
        prevSeconds           = try c.decodeIfPresent(Int.self, forKey: .prevSeconds) ?? 0
        deltaPercent          = try c.decodeIfPresent(Double.self, forKey: .deltaPercent)
        rank                  = try c.decodeIfPresent(Int.self, forKey: .rank)
        topPercent            = try c.decodeIfPresent(Double.self, forKey: .topPercent)
        activeUsers           = try c.decodeIfPresent(Int.self, forKey: .activeUsers) ?? 0
        totalSeconds          = try c.decodeIfPresent(Int.self, forKey: .totalSeconds) ?? 0
        avg4Seconds           = try c.decodeIfPresent(Int.self, forKey: .avg4Seconds) ?? 0
        projectionYearSeconds = try c.decodeIfPresent(Int.self, forKey: .projectionYearSeconds) ?? 0
        byMode                = try c.decodeIfPresent([String: Int].self, forKey: .byMode) ?? [:]
        let rawDays           = try c.decodeIfPresent([Int].self, forKey: .days) ?? []
        // 表示側が index 0..6 を無条件に触るので、ここで必ず7要素に整える
        days = rawDays.count == 7 ? rawDays : Array(repeating: 0, count: 7)
    }

    // MARK: - 表示ルール

    /// 🔴 先週比を % で出してよいか。
    ///
    /// 本番実データで **+6603.1%** を返すケースが実在する (先週2時間 → 今週133時間)。
    /// 数値としては正しいが画面に出すと壊れて見えるので、次の両方を満たすときだけ % を出す:
    ///   - 前の週が10分以上ある (母数が小さすぎる比較をしない)
    ///   - 変化率が ±1000% 未満
    /// 満たさないときは実数の比較 (「先週 2時間 → 今週 133時間」) にフォールバックする。
    var showsDeltaPercent: Bool {
        guard let d = deltaPercent else { return false }
        return prevSeconds >= 600 && abs(d) < 1000
    }

    /// 前の週にも実績があり、比較そのものが意味を持つか
    var hasComparison: Bool { prevSeconds > 0 }
}

// MARK: - 履歴一覧の1行

struct WeeklyReportSummary: Decodable, Equatable, Identifiable {
    /// 今週から何週前か。レポートを開き直すときにそのまま RPC に渡す
    let weekOffset: Int
    let weekStartRaw: String
    let weekEndRaw: String
    let seconds: Int
    let sessions: Int

    var id: String { weekStartRaw }
    var weekStart: Date? { WeekDay.date(from: weekStartRaw) }
    var weekEnd: Date? { WeekDay.date(from: weekEndRaw) }

    enum CodingKeys: String, CodingKey {
        case weekOffset   = "week_offset"
        case weekStartRaw = "week_start"
        case weekEndRaw   = "week_end"
        case seconds, sessions
    }
}
