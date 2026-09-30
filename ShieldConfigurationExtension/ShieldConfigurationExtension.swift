//
//  ShieldConfigurationExtension.swift
//  ShieldConfigurationExtension
//
//  Quote Shield UI shown when an app is blocked
//

import Foundation
import ManagedSettings
import ManagedSettingsUI
import UIKit
import os.log

private let logger = Logger(subsystem: "com.jeimii.AppBlocker.ShieldConfigurationExtension", category: "ShieldConfig")

// App Group identifier / keys must always match AppGroupConstants
// (the Extension is a separate target from the main app and cannot import it, so hardcoding is required)
private let appGroupID = "group.com.ryunosuke.appblocker.shared"
private let keyCurrentQuote = "currentQuote"
private let keyQuotePool = "quotePool"
/// For the subtitle of plan A (app-name first). The main app saves a mirror of users_dreams
/// (AppGroupStorage.saveUserDream)
private let keyUserDream = "userDream"
/// Display language key shared with UsageReportExtension ("japanese"/"english"). Not set = treated as
/// Japanese
private let keyOnboardingLang = "onboardingLanguage"

/// Quote tuple type (defined here because the Extension cannot import the main app's types)
private typealias ShieldQuote = (textEn: String, textJp: String, author: String)

class ShieldConfigurationExtension: ShieldConfigurationDataSource {

    // MARK: - Cached (Extension lifetime)

    private static var cachedConfig: ShieldConfiguration?
    /// The most recently generated title (= app-name-first text). The cache is invalidated immediately when
    /// this changes
    /// (e.g. so that when the user sees lock screens for A → home → B in a row, A's text does not stay on B)
    private static var cachedTitle: String?
    /// Time of the most recent display. So that it does not flicker when configuration() is called several
    /// times during one display, the same config is returned only for a short time (1.5 seconds). After
    /// that, a new quote is picked
    /// = the quote (the fallback when there is no dream) rotates every time the lock screen appears
    private static var lastShownTime: Date = .distantPast

    /// The App Group UserDefaults is reused within the Extension process (one getShieldConfig used to create
    /// UserDefaults(suiteName:) up to 4 times, now it is one. suiteName never changes, so
    /// there is no need to rebuild it while the process is alive
    private static let sharedDefaults = UserDefaults(suiteName: appGroupID)

    /// 1% monogram (a 180px reduced version bundled with the extension).
    /// Passing the 1024px original asset as is uses about 4MB just to decode it,
    /// which could hit the Shield extension's memory limit of about 6MB, so a reduced copy is used
    private static let shieldIcon = UIImage(named: "ShieldIcon")

    /// Embedded fallback for when the App Group cannot be read (right after a fresh install / data
    /// protection while the device is locked). ❌ The 175-entry bundled JSON is not parsed
    /// (it was the main cause of an 11-second freeze on cold start, so it was removed completely)
    /// author is never shown on screen (see resolvedSubtitle), but under the policy of removing all real
    /// names, it is unified to "Anonymous" so that the real names of famous people cannot be read by
    /// analyzing the binary
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
        // ❌ Do no heavy work in init (keep the XPC cold start as short as possible)
    }

    // MARK: - App Group Read (lightweight paths only, no heavy JSON parsing at all)

    private func loadQuoteFromAppGroup() -> ShieldQuote? {
        guard let defaults = Self.sharedDefaults,
              let data = defaults.data(forKey: keyCurrentQuote),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return parseQuoteDict(json)
    }

    /// Reads the quote pool in the App Group (a few dozen entries pre-shuffled and written by the main app).
    /// Unlike the 175-entry bundled JSON, this is a light decode of a few dozen entries, so it does not freeze
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

    /// Picks the 1 entry drawn for each display.
    /// Order: pool (multiple entries, for rotation) → single currentQuote → embedded fallback
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

    // MARK: - Dream / Language (plan A: app-name first)

    /// Reads the "dream" that the main app mirrored from users_dreams (AppGroupStorage.saveUserDream).
    /// Only reads a string from UserDefaults with no JSON parsing, so it is light
    private func loadUserDreamFromAppGroup() -> String? {
        guard let defaults = Self.sharedDefaults,
              let raw = defaults.string(forKey: keyUserDream) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Same check as UsageReportExtension (raw != "english" → treated as Japanese).
    /// If the key is not set (= the main app's language sync has never run: a fresh install, or an
    /// existing English user whose schedule/location Shield fired first after an update, before the main
    /// app was launched even once), the missing key is not treated as Japanese right away and it falls
    /// back to the device language
    /// (2026-07 regression fix: prevents an accident where existing English users see a Japanese-only Shield)
    private func loadIsJapanese() -> Bool {
        guard let raw = Self.sharedDefaults?.string(forKey: keyOnboardingLang) else {
            return Locale.preferredLanguages.first?.hasPrefix("ja") == true
        }
        return raw != "english"
    }

    /// Title = "[app name] is locked". If the app name is not available,
    /// the text differs between a WebDomain and a normal app (F2: separate copy for sites and apps)
    private func resolvedTitle(applicationName: String?, isWebDomain: Bool, isJapanese: Bool) -> String {
        if let name = applicationName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return isJapanese ? "\(name) はロック中" : "\(name) is locked"
        }
        if isWebDomain {
            return isJapanese ? "このサイトはロック中" : "This site is locked"
        }
        return isJapanese ? "このアプリはロック中" : "This app is locked"
    }

    /// Subtitle = "あなたの目標" ("YOUR GOAL") label + dream + empty line + liked quote (2026-07-16 confirmed
    /// by the user).
    /// - **No author name** on the quote (user spec: "do not use the names of famous people here". Also
    ///   consistent with the policy on the legal risk of famous people's real names)
    /// - ShieldConfiguration has only 2 labels, title/subtitle, with one color each. The API does not
    ///   allow different shades for the dream and the quote, so the hierarchy is expressed with an empty
    ///   line and quotation marks
    /// - If no dream is declared, only the quote (also without the author name)
    private func resolvedSubtitle(isJapanese: Bool) -> String {
        let quote = pickRandomQuote()
        let quoteText = isJapanese ? quote.textJp : quote.textEn
        let quoteLine = "\u{201C}\(quoteText)\u{201D}"

        if let dream = loadUserDreamFromAppGroup() {
            let label = isJapanese ? "あなたの目標" : "YOUR GOAL" // Copy waiting for user review
            // The leading empty line = the gap from the title "◯◯はロック中" ("◯◯ is locked") (real-device feedback
            // round 15).
            // Making only the label smaller / only the dream a different color is impossible because of the API
            // limit of one color per subtitle, so the dream text is wrapped in Japanese corner brackets to tell it
            // apart from the quote (2026-07-16 confirmed by the user). In EN the bracket convention is different,
            // so it is left bare (the quote side has quotation marks, so they can still be told apart)
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

        // So that it does not flicker when called several times during one display, return the cache for a
        // short time with the same app name. If more than 1.5 seconds pass, or the app name changes, pick again
        // (= the quote shown when there is no dream rotates every time the lock screen appears, and
        //   when different apps are locked in a row, the previous app name does not remain)
        if let cached = Self.cachedConfig,
           Self.cachedTitle == title,
           now.timeIntervalSince(Self.lastShownTime) < 1.5 {
            return cached
        }

        let subtitle = resolvedSubtitle(isJapanese: isJapanese)
        let closeLabel = isJapanese ? "閉じる" : "Close"
        // Off-white F2EFE7 (design approved plan A)
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
            // Always specify the label color and background color as a pair (F3: black text + nil = the system
            // default background risked black text on a black background in dark mode etc., making it unreadable).
            // Black text on an off-white F2EFE7 background is a fixed pair for both brand consistency and
            // readability
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
