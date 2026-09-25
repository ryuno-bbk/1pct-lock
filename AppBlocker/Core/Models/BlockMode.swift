//
//  BlockMode.swift
//  AppBlocker
//
//  制限モード定義 - 3つのブロックモード
//

import Foundation
import SwiftUI

// MARK: - Block Mode

/// 3つの制限モード
enum BlockMode: String, CaseIterable, Identifiable {
    /// タイマーブロック - 指定時間だけブロック（カウントダウン）
    case timer = "timer"

    /// スケジュール - DeviceActivitySchedule で時間帯指定ブロック
    case schedule = "schedule"

    /// 位置情報ロック - 特定の場所に入ったらブロック
    case location = "location"

    var id: String { rawValue }

    /// 表示名（日本語フォールバック）
    var displayName: String {
        L.blockModeDisplayName(self, .japanese)
    }

    /// 言語対応の表示名
    func displayName(lang: AppLanguage) -> String {
        L.blockModeDisplayName(self, lang)
    }

    /// 説明文（日本語フォールバック）
    var description: String {
        L.blockModeDescription(self, .japanese)
    }

    /// 言語対応の説明文
    func description(lang: AppLanguage) -> String {
        L.blockModeDescription(self, lang)
    }

    /// 詳細説明（日本語フォールバック）
    var detailDescription: String {
        L.blockModeDetail(self, .japanese)
    }

    /// 言語対応の詳細説明
    func detailDescription(lang: AppLanguage) -> String {
        L.blockModeDetail(self, lang)
    }

    /// アイコン名（SF Symbols）
    var iconName: String {
        switch self {
        case .timer: return "stopwatch.fill"
        case .schedule: return "calendar.badge.clock"
        case .location: return "location.fill"
        }
    }

    /// カードの背景色（モノクロブランドのため 3 モード共通トークンを参照）
    var accentColor: Color {
        switch self {
        case .timer: return AppColors.modeTimer
        case .schedule: return AppColors.modeSchedule
        case .location: return AppColors.modeLocation
        }
    }
}

// MARK: - Block Session

/// ブロックセッションの状態
struct BlockSession: Identifiable, Codable {
    let id: UUID
    let mode: String
    let startDate: Date
    let endDate: Date?
    let isActive: Bool

    // タイマーモード用
    let timerConfig: TimerConfig?

    // スケジュールモード用
    let scheduleConfig: ScheduleConfig?

    init(
        id: UUID = UUID(),
        mode: BlockMode,
        startDate: Date = Date(),
        endDate: Date? = nil,
        isActive: Bool = true,
        timerConfig: TimerConfig? = nil,
        scheduleConfig: ScheduleConfig? = nil
    ) {
        self.id = id
        self.mode = mode.rawValue
        self.startDate = startDate
        self.endDate = endDate
        self.isActive = isActive
        self.timerConfig = timerConfig
        self.scheduleConfig = scheduleConfig
    }

    var blockMode: BlockMode? {
        BlockMode(rawValue: mode)
    }
}

// MARK: - Timer Config

/// タイマーモードの設定
struct TimerConfig: Codable {
    let durationMinutes: Int  // ブロック時間（分）
    let endTime: Date         // 終了予定時刻

    init(durationMinutes: Int) {
        self.durationMinutes = durationMinutes
        self.endTime = Date().addingTimeInterval(TimeInterval(durationMinutes * 60))
    }

    init(durationMinutes: Int, endTime: Date) {
        self.durationMinutes = durationMinutes
        self.endTime = endTime
    }

    /// 残り時間（秒）
    var remainingSeconds: Int {
        let remaining = Int(endTime.timeIntervalSinceNow)
        return max(0, remaining)
    }

    /// タイマーが終了したか
    var isExpired: Bool {
        remainingSeconds <= 0
    }
}

// MARK: - Schedule Config (Phase 4)

/// スケジュールモードの設定 (複数保持可、上限は ScheduleManager.maxSchedules)
///
/// ⚠️ フィールド構成は DeviceActivityMonitorExtension.ScheduleConfigMirror と手動同期すること
/// (Extension は別ターゲットでこの型を import できない)。
/// id/isEnabled は複数スケジュール化 (2026-07-15) で追加。旧単一形式の保存データには
/// 存在しないため decodeIfPresent でフォールバックする (id は移行時に採番され、
/// AppGroupStorage.getScheduleConfigs が配列形式で即永続化するので以後は安定する)
struct ScheduleConfig: Codable, Identifiable, Equatable {
    let id: UUID
    let startHour: Int
    let startMinute: Int
    let endHour: Int
    let endMinute: Int
    let weekdays: [Int] // 1=日曜, 2=月曜, ... 7=土曜
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        startHour: Int,
        startMinute: Int,
        endHour: Int,
        endMinute: Int,
        weekdays: [Int] = [2, 3, 4, 5, 6], // デフォルト: 平日
        isEnabled: Bool = true
    ) {
        self.id = id
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
        self.weekdays = weekdays
        self.isEnabled = isEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        startHour = try container.decode(Int.self, forKey: .startHour)
        startMinute = try container.decode(Int.self, forKey: .startMinute)
        endHour = try container.decode(Int.self, forKey: .endHour)
        endMinute = try container.decode(Int.self, forKey: .endMinute)
        weekdays = try container.decode([Int].self, forKey: .weekdays)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

