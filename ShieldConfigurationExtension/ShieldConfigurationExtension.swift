//
//  ShieldConfigurationExtension.swift
//  ShieldConfigurationExtension
//
//  アプリがブロックされた時に表示される名言Shield UI
//

import Foundation
import ManagedSettings
import ManagedSettingsUI
import UIKit
import os.log

private let logger = Logger(subsystem: "com.jeimii.AppBlocker.ShieldConfigurationExtension", category: "ShieldConfig")

// App Group identifier / keys は AppGroupConstants と必ず一致させる
// (Extension はメインアプリと別ターゲットなので import 不可、ハードコード必須)
private let appGroupID = "group.com.ryunosuke.appblocker.shared"
private let keyCurrentQuote = "currentQuote"
private let keyQuotePool = "quotePool"
/// 案A (アプリ名主導) のサブタイトル用。本体が users_dreams をミラー保存する (AppGroupStorage.saveUserDream)
private let keyUserDream = "userDream"
/// UsageReportExtension と共有の表示言語キー ("japanese"/"english")。未設定は日本語扱い
private let keyOnboardingLang = "onboardingLanguage"

/// 名言タプル型 (Extension はメインアプリの型を import できないため独自定義)
private typealias ShieldQuote = (textEn: String, textJp: String, author: String)

class ShieldConfigurationExtension: ShieldConfigurationDataSource {

    // MARK: - Cached (Extension lifetime)

    private static var cachedConfig: ShieldConfiguration?
    /// 直近に生成した title (=アプリ名主導の文言)。キャッシュはこれが変わったら即座に無効化する
    /// (例: A→ホーム→B と連続でロック画面を見た時に A の文言が B に残らないようにするため)
    private static var cachedTitle: String?
    /// 直近表示時刻。1 回の表示中に複数回 configuration() が呼ばれてもチラつかないよう
    /// 短時間 (1.5 秒) だけ同じ config を返す。それを超えたら新しい名言を引き直す
    /// = ロック画面が出るたびに名言(夢が無い場合のフォールバック)がローテーションする
    private static var lastShownTime: Date = .distantPast

    /// App Group の UserDefaults は Extension プロセス内で使い回す (getShieldConfig 1 回につき
    /// 最大 4 回 UserDefaults(suiteName:) を作っていたのを 1 個に集約。suiteName は不変なので
    /// プロセス生存中は再構築の必要が無い
    private static let sharedDefaults = UserDefaults(suiteName: appGroupID)

    /// 1% モノグラム (拡張バンドル同梱の 180px 縮小版)。
    /// 1024px の原本アセットをそのまま渡すとデコードだけで約 4MB 食い、
    /// Shield 拡張の約 6MB メモリ上限に接触しかねないため縮小コピーを使う
    private static let shieldIcon = UIImage(named: "ShieldIcon")

    /// App Group が読めない時 (フレッシュインストール直後 / 端末ロック中のデータ保護) の
    /// 埋め込みフォールバック。❌ 175 件バンドル JSON のパースはしない
    /// (コールドスタート時 11 秒フリーズの主因だったため完全に廃止)
    /// author は画面には一切出していない (resolvedSubtitle 参照) が、実名全廃方針により
    /// バイナリ解析で偉人の実名が読み取れてしまうのを防ぐため "Anonymous" に統一している
    private static let embeddedFallback: [ShieldQuote] = [
        ("The job's not finished.", "仕事はまだ終わっていない。", "Anonymous"),
        ("Discipline is choosing between what you want now and what you want most.", "規律とは、今欲しいものと最も欲しいものを選び分けること。", "Anonymous"),
        ("We are what we repeatedly do. Excellence, then, is not an act, but a habit.", "我々は繰り返す行動の総体である。卓越とは行為ではなく習慣である。", "Anonymous"),
        ("The pain you feel today will be the strength you feel tomorrow.", "今日感じる痛みは、明日の強さになる。", "Anonymous"),
        ("Don't count the days, make the days count.", "日々を数えるな。日々を意味あるものにせよ。", "Anonymous"),
        ("Hard work beats talent when talent doesn't work hard.", "才能が努力を怠れば、努力が才能に勝る。", "Anonymous"),
        ("It always seems impossible until it's done.", "成し遂げるまでは、いつも不可能に見える。", "Anonymous"),
        ("The successful warrior is the average man, with laser-like focus.", "勝つ者とは、レーザーのような集中力を持った普通の人間だ。", "Anonymous"),
        ("Do something today that your future self will thank you for.", "未来の自分が感謝するようなことを、今日やれ。", "Anonymous"),
        ("Motivation gets you going, but discipline keeps you growing.", "動機は始めさせ、規律は成長させ続ける。", "Anonymous"),
        ("Suffer the pain of discipline or suffer the pain of regret.", "規律の痛みを取るか、後悔の痛みを取るか。", "Anonymous"),
        ("Your future is created by what you do today, not tomorrow.", "未来は明日ではなく、今日の行動が創る。", "Anonymous")
    ]

    override init() {
        super.init()
        logger.log("🛡️ ShieldConfigurationExtension INIT — process launched")
        // ❌ init で重い処理をしない（XPC cold start を最短化）
    }

    // MARK: - App Group Read（軽量パスのみ、重い JSON パースは一切しない）

    private func loadQuoteFromAppGroup() -> ShieldQuote? {
        guard let defaults = Self.sharedDefaults,
              let data = defaults.data(forKey: keyCurrentQuote),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parseQuoteDict(json)
    }

    /// App Group の名言プール (メインアプリが事前シャッフルして書いた数十件) を読む。
    /// 175 件のバンドル JSON と違い、数十件の軽量デコードなのでフリーズしない
    private func loadQuotePoolFromAppGroup() -> [ShieldQuote]? {
        guard let defaults = Self.sharedDefaults,
              let data = defaults.data(forKey: keyQuotePool),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        let pool = arr.compactMap { parseQuoteDict($0) }
        return pool.isEmpty ? nil : pool
    }

    private func parseQuoteDict(_ dict: [String: Any]) -> ShieldQuote? {
        guard let textEn = dict["text_en"] as? String,
              let textJp = dict["text_jp"] as? String,
              let author = dict["author"] as? String else {
            return nil
        }
        return (textEn, textJp, author)
    }

    /// 表示のたびに引く 1 件を選ぶ。
    /// プール（複数件・ローテーション用）→ 単一 currentQuote → 埋め込みフォールバック の順
    private func pickRandomQuote() -> ShieldQuote {
        if let pool = loadQuotePoolFromAppGroup(), let quote = pool.randomElement() {
            return quote
        }
        if let single = loadQuoteFromAppGroup() {
            return single
        }
        return Self.embeddedFallback.randomElement()
            ?? ("The job's not finished.", "仕事はまだ終わっていない。", "Anonymous")
    }

    // MARK: - Dream / Language (案A: アプリ名主導)

    /// 本体が users_dreams からミラー保存した「夢」を読む (AppGroupStorage.saveUserDream)。
    /// UserDefaults の string 読み出しのみで JSON パースは無いため軽量
    private func loadUserDreamFromAppGroup() -> String? {
        guard let defaults = Self.sharedDefaults,
              let raw = defaults.string(forKey: keyUserDream) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// UsageReportExtension と同じ判定式 (raw != "english" → 日本語扱い)。
    /// キー未設定 (=本体の言語同期がまだ一度も走っていない: フレッシュインストール、または
    /// 既存の英語ユーザーがアップデート後に本体を一度も起動しないまま schedule/location の
    /// Shield が先に発火したケース) は、キー未設定を即日本語扱いにせず端末言語にフォールバックする
    /// (2026-07 リグレッション修正: 既存英語ユーザーに日本語オンリー Shield が出る事故を防ぐ)
    private func loadIsJapanese() -> Bool {
        guard let raw = Self.sharedDefaults?.string(forKey: keyOnboardingLang) else {
            return Locale.preferredLanguages.first?.hasPrefix("ja") == true
        }
        return raw != "english"
    }

    /// タイトル = 「[アプリ名] はロック中」。アプリ名が取れない場合は
    /// WebDomain か通常アプリかで文言を分ける (F2: サイトとアプリで別コピー)
    private func resolvedTitle(applicationName: String?, isWebDomain: Bool, isJapanese: Bool) -> String {
        if let name = applicationName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return isJapanese ? "\(name) はロック中" : "\(name) is locked"
        }
        if isWebDomain {
            return isJapanese ? "このサイトはロック中" : "This site is locked"
        }
        return isJapanese ? "このアプリはロック中" : "This app is locked"
    }

    /// サブタイトル = 「あなたの目標」ラベル + 夢 + 空行 + いいね名言 (2026-07-16 ユーザー確定)。
    /// - 名言に**著者名は出さない** (ユーザー指定「ここで偉人の名前は使わない」。偉人実名の法的リスク方針とも整合)
    /// - ShieldConfiguration のラベルは title/subtitle の2つ・各1色のみ。夢と名言の濃淡差は
    ///   API上つけられないため、空行と引用符で階層を表現する
    /// - 夢が未宣言なら名言のみ (こちらも著者名なし)
    private func resolvedSubtitle(isJapanese: Bool) -> String {
        let quote = pickRandomQuote()
        let quoteText = isJapanese ? quote.textJp : quote.textEn
        let quoteLine = "\u{201C}\(quoteText)\u{201D}"

        if let dream = loadUserDreamFromAppGroup() {
            let label = isJapanese ? "あなたの目標" : "YOUR GOAL" // 文言はユーザー添削待ち
            // 先頭の空行 = タイトル「◯◯はロック中」との隙間 (実機FB第15弾)。
            // ラベルだけ小さく/夢だけ色変えはサブタイトル1枠1色のAPI制約で不可のため、
            // 夢本文は鍵括弧で括って名言と区別する (2026-07-16 ユーザー確定)。EN は括弧文化が
            // 異なるので素のまま (名言側が引用符を持つため区別はつく)
            let dreamLine = isJapanese ? "「\(dream)」" : dream
            return "\n\(label)\n\(dreamLine)\n\n\(quoteLine)"
        }
        return "\n\(quoteLine)"
    }

    // MARK: - Shield Configuration

    private func getShieldConfig(applicationName: String?, isWebDomain: Bool) -> ShieldConfiguration {
        let now = Date()
        let isJapanese = loadIsJapanese()
        let title = resolvedTitle(applicationName: applicationName, isWebDomain: isWebDomain, isJapanese: isJapanese)

        // 1 回の表示中に複数回呼ばれてもチラつかないよう、短時間・同じアプリ名なら
        // キャッシュを返す。1.5 秒を超える、またはアプリ名が変わったら引き直す
        // (= ロック画面が出るたびに夢が無い場合の名言がローテーションし、
        //   異なるアプリを連続でロックした時に前のアプリ名が残らない)
        if let cached = Self.cachedConfig,
           Self.cachedTitle == title,
           now.timeIntervalSince(Self.lastShownTime) < 1.5 {
            return cached
        }

        let subtitle = resolvedSubtitle(isJapanese: isJapanese)
        let closeLabel = isJapanese ? "閉じる" : "Close"
        // オフホワイト F2EFE7 (デザイン承認案A)
        let titleColor = UIColor(red: 0xF2 / 255.0, green: 0xEF / 255.0, blue: 0xE7 / 255.0, alpha: 1.0)

        let config = ShieldConfiguration(
            backgroundBlurStyle: nil,
            backgroundColor: UIColor.black,
            icon: Self.shieldIcon,
            title: ShieldConfiguration.Label(
                text: title,
                color: titleColor
            ),
            subtitle: ShieldConfiguration.Label(
                text: subtitle,
                color: UIColor(white: 0.58, alpha: 1.0)
            ),
            // ラベル色と背景色は必ずペアで指定する (F3: 黒文字 + nil=システム既定背景だと
            // ダークモード等で黒地に黒文字になり判読不能になるリスクがあったため)。
            // オフホワイト F2EFE7 の背景に黒文字を固定ペアにしてブランド統一・判読性を両立する
            primaryButtonLabel: ShieldConfiguration.Label(text: closeLabel, color: UIColor.black),
            primaryButtonBackgroundColor: UIColor(red: 242 / 255.0, green: 239 / 255.0, blue: 231 / 255.0, alpha: 1.0),
            secondaryButtonLabel: nil
        )

        Self.cachedConfig = config
        Self.cachedTitle = title
        Self.lastShownTime = now
        return config
    }

    // MARK: - DataSource Methods

    override func configuration(shielding application: Application) -> ShieldConfiguration {
        return getShieldConfig(applicationName: application.localizedDisplayName, isWebDomain: false)
    }

    override func configuration(shielding application: Application, in category: ActivityCategory) -> ShieldConfiguration {
        return getShieldConfig(applicationName: application.localizedDisplayName, isWebDomain: false)
    }

    override func configuration(shielding webDomain: WebDomain) -> ShieldConfiguration {
        return getShieldConfig(applicationName: nil, isWebDomain: true)
    }

    override func configuration(shielding webDomain: WebDomain, in category: ActivityCategory) -> ShieldConfiguration {
        return getShieldConfig(applicationName: nil, isWebDomain: true)
    }
}
