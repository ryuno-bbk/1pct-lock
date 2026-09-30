//
//  OnboardingQuiz.swift
//  AppBlocker
//
//  Questions, shock and ideal future of the diagnostic onboarding (follows the 2026-07 v3 design doc).
//  Design doc: 6 questions (birth date / role / daily hours / years of dependence / time-draining
//  apps / goal) + 2 shock beats (total past loss → opportunity loss in past tense) + ideal future
//  (AI image).
//
//  UI principles:
//   - One decision per screen. Single choice: haptics the moment it is picked + auto transition after
//     250ms (no "次へ" ("Next") button)
//   - 2px progress bar at the top (shown in common by OnboardingView)
//   - Numbers are serif + tabular + count-up
//   - Fully monochrome (AppColors). No gold
//

import SwiftUI

// MARK: - Answer vocabulary (raw value must match the values in 026_onboarding_profile.sql)

enum QuizOccupation: String, CaseIterable {
    case studentHS   = "student_hs"
    case studentUniv = "student_univ"
    case employee    = "employee"
    case founder     = "founder"
    case other       = "other"

    func label(_ lang: AppLanguage) -> String {
        let jp = lang == .japanese
        switch self {
        case .studentHS:   return jp ? "中高生" : "Middle / high school"
        case .studentUniv: return jp ? "大学生・専門学生" : "College student"
        case .employee:    return jp ? "会社員・公務員" : "Employed"
        case .founder:     return jp ? "フリーランス・経営者" : "Freelance / founder"
        case .other:       return jp ? "その他" : "Other"
        }
    }
}

/// Gender (added 2026-07-17, right after birth date). For LGBTQ+ inclusion, it is not a binary choice +
/// "回答しない" ("Prefer not to say") is always provided
enum QuizGender: String, CaseIterable {
    case male      = "male"
    case female    = "female"
    case nonbinary = "nonbinary"
    case preferNot = "prefer_not"

    func label(_ lang: AppLanguage) -> String {
        let jp = lang == .japanese
        switch self {
        case .male:      return jp ? "男性" : "Male" // Text waiting for user review
        case .female:    return jp ? "女性" : "Female" // Text waiting for user review
        case .nonbinary: return jp ? "ノンバイナリー・その他" : "Non-binary / other" // Text waiting for user review
        case .preferNot: return jp ? "回答しない" : "Prefer not to say" // Text waiting for user review
        }
    }
}

enum QuizDailyHours: String, CaseIterable {
    case lt2    = "lt2"
    case h2to4  = "2_4"
    case h4to6  = "4_6"
    case h6to8  = "6_8"
    case h8plus = "8plus"

    func label(_ lang: AppLanguage) -> String {
        let jp = lang == .japanese
        switch self {
        case .lt2:    return jp ? "2時間未満" : "Under 2 hours"
        case .h2to4:  return jp ? "2〜4時間" : "2–4 hours"
        case .h4to6:  return jp ? "4〜6時間" : "4–6 hours"
        case .h6to8:  return jp ? "6〜8時間" : "6–8 hours"
        case .h8plus: return jp ? "8時間以上" : "8+ hours"
        }
    }

    /// Median used for the shock calculation (hours/day)
    var medianHours: Double {
        switch self {
        case .lt2:    return 1.5
        case .h2to4:  return 3
        case .h4to6:  return 5
        case .h6to8:  return 7
        case .h8plus: return 9
        }
    }
}

enum QuizAddictionYears: String, CaseIterable {
    case lt1     = "lt1"
    case y1to3   = "1_3"
    case y3to5   = "3_5"
    case y5to10  = "5_10"
    case y10plus = "10plus"

    func label(_ lang: AppLanguage) -> String {
        let jp = lang == .japanese
        switch self {
        case .lt1:     return jp ? "1年未満" : "Under a year"
        case .y1to3:   return jp ? "1〜3年" : "1–3 years"
        case .y3to5:   return jp ? "3〜5年" : "3–5 years"
        case .y5to10:  return jp ? "5〜10年" : "5–10 years"
        case .y10plus: return jp ? "10年以上" : "10+ years"
        }
    }

    /// Median used for the shock calculation (years)
    var medianYears: Double {
        switch self {
        case .lt1:     return 0.5
        case .y1to3:   return 2
        case .y3to5:   return 4
        case .y5to10:  return 7.5
        case .y10plus: return 12
        }
    }
}

// QuizWastedApp (Q5 time-draining apps) was removed in the 2026-07 redesign. The wasted_apps column
// from the 026 SQL stays nullable, and on push we always send an empty string (= NULL) (on the
// OnboardingProfileService caller side).

enum QuizGoal: String, CaseIterable {
    case study    = "study"
    case work     = "work"
    case fitness  = "fitness"
    case creation = "creation"
    case reading  = "reading"
    case health   = "health"

    func label(_ lang: AppLanguage) -> String {
        let jp = lang == .japanese
        switch self {
        case .study:    return jp ? "受験・資格・勉強" : "Exams & study"
        case .work:     return jp ? "仕事・独立・副業" : "Work & independence"
        case .fitness:  return jp ? "筋トレ・身体づくり" : "Training & body"
        case .creation: return jp ? "創作・スキル習得" : "Creation & skills"
        case .reading:  return jp ? "読書・教養" : "Reading & knowledge"
        case .health:   return jp ? "睡眠・心の健康" : "Sleep & mental health"
        }
    }

    /// Asset name of the ideal future (AI image). Putting an image with the same name in Assets replaces it
    var idealImageName: String { "IdealFuture_\(rawValue)" }

    /// Placeholder variants for the dream declaration
    func dreamPlaceholder(_ lang: AppLanguage) -> String {
        let jp = lang == .japanese
        switch self {
        case .study:    return jp ? "例: 半年で TOEIC 900 / 第一志望に受かる" : "e.g. TOEIC 900 in 6 months"
        case .work:     return jp ? "例: 独立して自分の力で稼ぐ" : "e.g. Go independent and earn on my own"
        case .fitness:  return jp ? "例: 夏までに腹筋を割る" : "e.g. Visible abs by summer"
        case .creation: return jp ? "例: 作品を完成させて世に出す" : "e.g. Finish my work and ship it"
        case .reading:  return jp ? "例: 年間50冊読む人間になる" : "e.g. Read 50 books a year"
        case .health:   return jp ? "例: 23時に寝る生活を取り戻す" : "e.g. In bed by 11, every night"
        }
    }

    /// Copy for the ideal future (per goal). In the 2026-07 review the IdealFutureStepView heading was
    /// replaced with one shared text, and this function is currently unused. Kept in case we want to vary
    /// it per goal again in the future
    func idealCopy(_ lang: AppLanguage) -> String {
        let jp = lang == .japanese
        switch self {
        case .study:    return jp ? "1年後のあなたは、\n合格発表の画面を見つめている。" : "One year from now,\nyou're staring at your acceptance letter."
        case .work:     return jp ? "1年後のあなたは、\n自分のデスクから世界を動かしている。" : "One year from now,\nyou run the world from your own desk."
        case .fitness:  return jp ? "1年後のあなたは、\n鏡の前で別人になっている。" : "One year from now,\nthe mirror shows someone new."
        case .creation: return jp ? "1年後のあなたは、\n完成した作品と並んで立っている。" : "One year from now,\nyou stand next to your finished work."
        case .reading:  return jp ? "1年後のあなたは、\n50冊ぶん深い人間になっている。" : "One year from now,\nyou're 50 books deeper."
        case .health:   return jp ? "1年後のあなたは、\n朝日と一緒に目を覚ましている。" : "One year from now,\nyou wake with the sun."
        }
    }
}

// MARK: - Loss calculation (input for the 2 shock beats)

struct QuizLossReport {
    let totalHours: Int      // Total past loss (hours)
    let totalDays: Int       // Total past loss (days), not used in the UI since 2026-07-13, kept internally only
    let achievements: [(label: String, hours: Int)]  // 2026-07-17: changed approach to a shopping-cart style (greedy packing) as specified by the user:
                                                       // Showing "10,000 hours to master a craft" when "there are only 1278 hours" would be a lie, so we
                                                       // stack up and return, without duplicates, only the items that fit in the user's total lost hours
                                                       // (the 2026-07-13 design of "always return the same 12 items" was dropped. Details in
                                                       // greedyAchievements)
    /// The additional loss if the current daily hours continue until age 80, converted to "years". nil if
    /// the age is unknown or 80 or older
    let yearsLostBy80: Int?

    /// The catalog itself (added 2026-07-13). Representative values (rough guides) of the required hours
    /// commonly cited for things like research and certification exams.
    /// Ascending, one shared list regardless of occupation. This function itself does not filter:
    /// narrowing by total lost hours is done in greedyAchievements in the caller build() (2026-07-17)
    static func achievementsCatalog(_ lang: AppLanguage) -> [(label: String, hours: Int)] {
        let jp = lang == .japanese
        // 2026-07-17 reviewed by the user: the English version is localized for English-speaking regions
        // instead of a literal translation (University of Tokyo → Oxford, "English" → "a second language").
        // Japanese stays as is
        return [
            (jp ? "フルマラソンを完走できる体" : "A marathon-ready body", 150),
            (jp ? "本を一冊書き上げる" : "Write a whole book", 300),
            (jp ? "新しい外国語を日常会話レベルに" : "Hold a conversation in a new language", 600),
            (jp ? "プログラミングを習得してアプリを作る" : "Learn to code and ship an app", 1000),
            (jp ? "世界一周の旅費を自力で稼ぐ" : "Earn enough to travel the world", 2000),
            (jp ? "英語をネイティブ級に操る" : "Speak a second language like a native", 2200),
            (jp ? "公認会計士に合格する" : "Pass the CPA exam", 3500),
            (jp ? "東京大学に合格する" : "Get into Oxford", 4000),
            (jp ? "医師国家試験に合格し医者になる" : "Become a licensed doctor", 4000),
            (jp ? "司法試験に合格し法曹になる" : "Pass the bar and become a lawyer", 5000),
            (jp ? "起業し事業を軌道に乗せる" : "Start a business and get it off the ground", 6000)
            // "Master one craft to world level (10,000 hours)" was removed on 2026-07-17 per user feedback
            // (weak as the hero item. As a result, the hero item for users with many hours becomes "starting a
            // business")
        ]
    }

    /// Greedily pack only the items that fit in the total lost hours (totalHours), largest hours first
    /// (2026-07-17 user-specified, shopping-cart style).
    /// Example: 1278h → take programming 1000h (278h left) → take marathon 150h (128h left) → stop = 2 items.
    /// Display order is the same, largest hours first (the packing order).
    /// Only when the total loss is below the smallest item (150h) and nothing can be taken, fall back to
    /// the one smallest item.
    /// In practice, even the smallest diagnostic answers (under 2 hours a day × under 1 year of dependence,
    /// under-13 clamp) give a total loss of about 274h, so this fallback never fires in real use
    private static func greedyAchievements(totalHours: Int, lang: AppLanguage) -> [(label: String, hours: Int)] {
        let sortedDesc = achievementsCatalog(lang).sorted { $0.hours > $1.hours }
        var remaining = totalHours
        var picked: [(label: String, hours: Int)] = []
        for item in sortedDesc where item.hours <= remaining {
            picked.append(item)
            remaining -= item.hours
        }
        if picked.isEmpty, let smallest = sortedDesc.last {
            picked = [smallest]
        }
        return picked
    }

    /// Years of dependence are clamped to (age - 13) years (do not go back before the assumption that they
    /// got a smartphone at 13 = do not exaggerate)
    static func build(
        hours: QuizDailyHours,
        years: QuizAddictionYears,
        age: Int?,
        occupation: QuizOccupation?,
        lang: AppLanguage
    ) -> QuizLossReport {
        let maxYears: Double = {
            guard let age else { return years.medianYears }
            return max(Double(age - 13), 0.5)
        }()
        let effectiveYears = min(years.medianYears, maxYears)
        let totalHours = Int((hours.medianHours * 365 * effectiveYears).rounded())
        let totalDays = max(Int((Double(totalHours) / 24).rounded()), 1)

        // Convert the extra time consumed if this pace continues until age 80 into "years" (divide by
        // 24 hours × 365 days = one year of time)
        let yearsLostBy80: Int? = {
            guard let age, age < 80 else { return nil }
            let remainingYears = Double(80 - age)
            let futureHours = hours.medianHours * 365 * remainingYears
            return max(Int((futureHours / (24 * 365)).rounded()), 1)
        }()

        return QuizLossReport(
            totalHours: totalHours,
            totalDays: totalDays,
            achievements: greedyAchievements(totalHours: totalHours, lang: lang),
            yearsLostBy80: yearsLostBy80
        )
    }
}

// MARK: - Shared parts

enum QuizHaptics {
    static func light()  { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func medium() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
}

/// Question heading (serif) + note
struct QuizQuestionHeader: View {
    let question: String
    var hint: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(question)
                .font(.system(size: 25, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)

            if let hint {
                Text(hint)
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 28)
    }
}

/// Single-choice row. On tap: haptics + selected state → onPick after 250ms (auto transition)
struct QuizOptionRow: View {
    let label: String
    let isSelected: Bool
    /// Brand icon at the start of the row (asset name in Assets). Used to show real app icons in the
    /// referral source question (2026-07-17 user request: "proper native icons"). If nil, text only as
    /// before
    var iconAsset: String? = nil
    /// Fallback SF Symbol when iconAsset is nil (for options with no brand icon, such as friends or other)
    var iconSystemName: String? = nil
    let onPick: () -> Void

    var body: some View {
        Button {
            QuizHaptics.light()
            onPick()
        } label: {
            HStack(spacing: 12) {
                if let iconAsset {
                    // Clip real app icons into the same rounded squircle-like shape as on the home screen
                    Image(iconAsset)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                } else if let iconSystemName {
                    Image(systemName: iconSystemName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(isSelected ? AppColors.background : AppColors.textSecondary)
                        .frame(width: 30, height: 30)
                }

                Text(label)
                    .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? AppColors.background : AppColors.textPrimary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, iconAsset != nil || iconSystemName != nil ? 12 : 15)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? AppColors.textPrimary : AppColors.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(AppColors.textTertiary.opacity(isSelected ? 0 : 0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Multi-select chip
struct QuizChipToggle: View {
    let label: String
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button {
            QuizHaptics.light()
            onToggle()
        } label: {
            Text(label)
                .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                .foregroundColor(isSelected ? AppColors.background : AppColors.textPrimary)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(isSelected ? AppColors.textPrimary : AppColors.cardBackground))
                .overlay(Capsule().stroke(AppColors.textTertiary.opacity(isSelected ? 0 : 0.25), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// Count-up number in serif + tabular (shock beat 1)
struct CountUpNumber: View {
    let target: Int
    var duration: Double = 1.6
    var fontSize: CGFloat = 68
    /// When set, the number is drawn with a vertical gradient of these colors (if not set, monochrome
    /// textPrimary).
    /// 2026-07-13 review fix: dropped the warm-color gradient for shock beat 1 and unified to fully
    /// monochrome. Currently every caller in onboarding leaves it unset (nil); the parameter itself is kept
    /// for future reuse
    var gradientColors: [Color]? = nil
    var onFinished: (() -> Void)? = nil

    @State private var startDate: Date? = nil
    @State private var finished = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: finished)) { context in
            let value: Int = {
                guard let startDate else { return 0 }
                let t = min(context.date.timeIntervalSince(startDate) / duration, 1)
                let eased = 1 - pow(1 - t, 3)   // easeOutCubic
                return Int((Double(target) * eased).rounded())
            }()
            Group {
                if let gradientColors {
                    Text("\(value)")
                        .foregroundStyle(LinearGradient(colors: gradientColors, startPoint: .top, endPoint: .bottom))
                } else {
                    Text("\(value)")
                        .foregroundColor(AppColors.textPrimary)
                }
            }
            .font(.system(size: fontSize, weight: .semibold))
            .monospacedDigit()
            .onChange(of: value) { _, newValue in
                if newValue >= target && !finished {
                    finished = true
                    QuizHaptics.medium()
                    onFinished?()
                }
            }
        }
        .onAppear {
            if startDate == nil {
                if UIAccessibility.isReduceMotionEnabled {
                    startDate = Date.distantPast   // Final value immediately
                } else {
                    startDate = Date()
                }
            }
        }
    }
}

// MARK: - Q1 Birth date

struct QuizBirthDateStepView: View {
    /// Saved as "yyyy-MM-dd" (@AppStorage)
    @Binding var birthDateRaw: String
    let onContinue: () -> Void

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    @State private var date: Date = QuizBirthDateStepView.defaultDate
    @State private var isBlocked = false

    private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .english }

    static let storageFormat: Date.FormatStyle = .init()

    private static var defaultDate: Date {
        var comps = DateComponents(); comps.year = 2005; comps.month = 6; comps.day = 15
        return Calendar.current.date(from: comps) ?? Date()
    }

    static func parse(_ raw: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: raw)
    }

    static func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: date)
    }

    static func age(fromRaw raw: String) -> Int? {
        guard let d = parse(raw) else { return nil }
        return Calendar.current.dateComponents([.year], from: d, to: Date()).year
    }

    private var age: Int {
        Calendar.current.dateComponents([.year], from: date, to: Date()).year ?? 0
    }

    var body: some View {
        if isBlocked {
            blockedView
        } else {
            VStack(spacing: 0) {
                Spacer().frame(height: 64)

                QuizQuestionHeader(
                    question: lang == .japanese ? "生まれた日を教えてほしい。" : "When were you born?",
                    hint: lang == .japanese ? "年齢はプロフィールに公開されない" : "Your age is never shown on your profile."
                )

                DatePicker("", selection: $date, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.wheel)
                    .labelsHidden()
                    .colorScheme(.dark)
                    .padding(.top, 12)

                Spacer()

                PrimaryButton(lang == .japanese ? "次へ" : "Next", icon: "arrow.right") {
                    if age < 13 {
                        QuizHaptics.medium()
                        withAnimation(.easeInOut(duration: 0.25)) { isBlocked = true }
                    } else {
                        birthDateRaw = Self.format(date)
                        onContinue()
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
            .onAppear {
                if let saved = Self.parse(birthDateRaw) { date = saved }
            }
        }
    }

    /// Under-13 gate (complies with the App Store 13+ rating). No data is saved
    private var blockedView: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "hand.raised")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(AppColors.textTertiary)

            Text(lang == .japanese ? "このアプリは13歳以上が対象です。" : "This app is for ages 13 and up.")
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Text(lang == .japanese
                 ? "また会える日を待っている。"
                 : "We'll be here when you're ready.")
                .font(.system(size: 14))
                .foregroundColor(AppColors.textSecondary)

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.25)) { isBlocked = false }
            } label: {
                Text(lang == .japanese ? "生年月日を修正する" : "Fix my birth date")
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textSecondary)
                    .underline()
            }
            .padding(.bottom, 48)
        }
    }
}

// MARK: - Q2 role / Q3 hours / Q4 years of dependence (shared form: single choice, auto transition)

struct QuizSingleChoiceStepView<Option: RawRepresentable & CaseIterable & Hashable>: View where Option.RawValue == String, Option.AllCases: RandomAccessCollection {
    let question: String
    /// 2026-07 review: decided to remove all notes on single-choice screens
    /// ("設定でスクリーンタイムを確認できます" ("You can check Screen Time in Settings"),
    /// "だいたいで構いません" ("A rough answer is fine") etc.) and show only the question + options.
    /// The caller's (OnboardingView.swift) `hint:` argument stays, but this screen does not draw it
    /// (a parameter kept for compatibility, so the caller does not need to be rewritten)
    var hint: String? = nil
    let labelProvider: (Option) -> String
    /// Icon at the start of the row (optional). For brand icons in the referral source question (2026-07-17)
    var iconAssetProvider: ((Option) -> String?)? = nil
    var iconSystemNameProvider: ((Option) -> String?)? = nil
    @Binding var selectionRaw: String
    let onContinue: () -> Void

    // H10 (2026-07-20 audit): on a double tap / re-pick within 250ms, several delayed closures pile up,
    // onContinue (= advance) fires more than once, and a step is skipped. Re-picking itself (updating
    // selectionRaw) is still allowed within 250ms; only the firing of onContinue is limited to once.
    // This View itself is recreated on every step by .id(step), so it naturally goes back to false on the
    // next step
    @State private var advanced = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 64)

            QuizQuestionHeader(question: question)

            VStack(spacing: 10) {
                ForEach(Array(Option.allCases), id: \.self) { option in
                    QuizOptionRow(
                        label: labelProvider(option),
                        isSelected: selectionRaw == option.rawValue,
                        iconAsset: iconAssetProvider?(option),
                        iconSystemName: iconSystemNameProvider?(option)
                    ) {
                        selectionRaw = option.rawValue
                        // Show the white inverted selection, then auto transition (one decision per screen, no "次へ" ("Next"))
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            guard !advanced else { return }
                            advanced = true
                            onContinue()
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 26)

            Spacer()
        }
    }
}

// Q5 (time-draining apps, QuizWastedAppsStepView / FlowChips) was removed in the 2026-07 redesign.

// MARK: - ◆ Shock: projection to age 80 (unified into one in the 2026-07-17 redesign)
//
// The old setup (total past loss = daily hours × years of dependence) was dropped after the user
// themself pointed out its mathematical stretch: "I did not always spend this much time in the past".
// The years-of-dependence question and the whole "what you could have done" page were taken out of
// the flow, and it was unified into the projection to age 80 (current pace × remaining years), which
// stands on honest math only

struct ShockLossStepView: View {
    let report: QuizLossReport
    // Leftover from the old calculation breakdown display. Only the property is kept for compatibility
    // with the caller's init signature
    let hoursLabel: String
    /// "◯ hours a day" label shown as the basis of the conversion (e.g. "6〜8時間" ("6-8 hours")). If nil,
    /// the basis line is hidden
    var dailyPaceLabel: String? = nil
    let onContinue: () -> Void
    /// L17 (2026-07-20 audit): for age 80 or older, yearsLostBy80 becomes nil and onAppear skips
    /// immediately. The old implementation called only onContinue (forward) regardless of direction, so the
    /// moment the user came back to this screen from recovery with "back", the forward skip fired again,
    /// and in effect the user was stuck and "could not go back".
    /// When the caller (OnboardingView) decides that this is a revisit via "back", it calls this, and we
    /// move back to the previous step. If not set (nil), it falls back to onContinue as before
    var onAutoSkipBack: (() -> Void)? = nil

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    @State private var showTail = false
    @State private var showCTA = false

    private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .english }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            if let years = report.yearsLostBy80 {
                // The text is only the approved sentence "このままだと80歳までに◯年分無駄にすることになります"
                // ("At this pace, you will waste ◯ years by age 80") split into heading / big number / closing
                // (no new copy is invented)
                Text(lang == .japanese ? "このままだと80歳までに" : "At this pace, you'll waste")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)
                    .multilineTextAlignment(.center)

                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    CountUpNumber(target: years, fontSize: 96) {
                        withAnimation(.easeOut(duration: 0.5)) { showTail = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                            withAnimation(.easeOut(duration: 0.5)) { showCTA = true }
                        }
                    }
                    Text(lang == .japanese ? "年分" : "years")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary)
                }
                .padding(.top, 20)

                Text(lang == .japanese ? "無駄にすることになります" : "by age 80")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 16)
                    .opacity(showTail ? 1 : 0)

                // Basis of the conversion (this number is "◯ hours a day × years left until age 80"). // Text waiting for user review
                if let pace = dailyPaceLabel {
                    Text(lang == .japanese
                         ? "1日\(pace)のペースで換算"
                         : "Based on your \(pace)/day pace")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textTertiary)
                        .padding(.top, 22)
                        .opacity(showTail ? 1 : 0)
                }
            }

            Spacer()

            PrimaryButton(lang == .japanese ? "続きを見る" : "Continue") {
                onContinue()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
            .opacity(showCTA ? 1 : 0)
        }
        .padding(.horizontal, 24)
        .onAppear {
            // If the birth date cannot be read and no projection can be made (roughly including age 80+ where the
            // remaining years cannot be computed), this page has no purpose, so skip it immediately (birthDate is
            // a required step, so this is a defense that is almost never reached in real use). On a revisit via
            // "back", move back instead of forward (L17)
            if report.yearsLostBy80 == nil {
                if let skipBack = onAutoSkipBack {
                    skipBack()
                } else {
                    onContinue()
                }
            }
        }
    }
}

// MARK: - ◆ (Removed from the flow, kept) Opportunity loss in past tense (shopping-cart style)
//
// Removed from the flow with user approval on 2026-07-17 (with the years-of-dependence question gone,
// the premise "total past loss" can no longer be computed). The View and the catalog are kept in code
// in case they come back.
// To bring it back, just put shockAchievements back into OnboardingStep and wire it in the switch

struct ShockAchievementsStepView: View {
    let report: QuizLossReport
    let onContinue: () -> Void

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    @State private var revealedCount = 0
    @State private var showCTA = false

    private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .english }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 64)

            // 2026-07-13 review fix: the heading uses only "hours", to match the unit of ShockLoss (the day
            // conversion was removed)
            QuizQuestionHeader(
                // 2026-07-17: English rewritten at the user's request (the old "◯ hours - of what you could have done"
                // was not natural as a sentence)
                question: lang == .japanese
                    ? "\(report.totalHours.formatted())時間で\nできていたこと"
                    : "What you could have done\nwith \(report.totalHours.formatted()) hours",
                hint: lang == .japanese ? "一般的な必要時間の目安で換算" : "Based on commonly cited time estimates"
            )

            // 2026-07-17: renewed to a hero layout (user feedback: greedy packing reduced the number of items, and
            // a row of pills looked sparse).
            // The single largest achievement is the hero in large type, and the rest are listed small under the
            // "さらに" ("And still") line.
            // report.achievements is already narrowed down by greedyAchievements, largest first (first = hero)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if let hero = report.achievements.first {
                        Text(hero.label)
                            .font(.system(size: 30, weight: .bold))
                            .foregroundColor(AppColors.textPrimary)
                            .lineSpacing(6)
                            .fixedSize(horizontal: false, vertical: true)

                        // The big number is off-white, not gold (brand rule: gold is only for achievements / top percentile)
                        HStack(alignment: .lastTextBaseline, spacing: 6) {
                            Rectangle()
                                .fill(AppColors.textTertiary.opacity(0.5))
                                .frame(width: 28, height: 2)
                                .offset(y: -6)
                            Text(hoursDisplay(hero.hours))
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundColor(AppColors.textSecondary)
                                .monospacedDigit()
                        }
                        .padding(.top, 14)
                        .opacity(revealedCount > 0 ? 1 : 0)
                    }

                    let rest = Array(report.achievements.dropFirst())
                    if !rest.isEmpty {
                        // Text waiting for user review
                        Text(lang == .japanese ? "さらに —" : "And still —")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(AppColors.textTertiary)
                            .padding(.top, 34)
                            .opacity(revealedCount > 1 ? 1 : 0)

                        VStack(spacing: 8) {
                            ForEach(Array(rest.enumerated()), id: \.offset) { idx, item in
                                HStack(alignment: .center, spacing: 14) {
                                    Text(item.label)
                                        .font(.system(size: 14.5))
                                        .foregroundColor(AppColors.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    Text(hoursDisplay(item.hours))
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundColor(AppColors.textPrimary)
                                        .monospacedDigit()
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .fill(AppColors.cardBackground)
                                )
                                // One by one after the hero (the first of revealedCount)
                                .opacity(idx + 1 < revealedCount ? 1 : 0)
                                .offset(y: idx + 1 < revealedCount ? 0 : 8)
                            }
                        }
                        .padding(.top, 10)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 26)
                .padding(.bottom, 12)
                // The hero itself appears with a fade + a slight sink
                .opacity(revealedCount > 0 ? 1 : 0)
                .offset(y: revealedCount > 0 ? 0 : 10)
            }

            PrimaryButton(lang == .japanese ? "続ける" : "Continue") {
                onContinue()
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)
            .padding(.bottom, 40)
            .opacity(showCTA ? 1 : 0)
        }
        .onAppear { revealSequentially() }
    }

    /// Time display format. Exactly 10000 hours is written as "1万時間" ("10,000 hours") (anything else is
    /// plainly "◯時間" ("◯ hours"))
    private func hoursDisplay(_ hours: Int) -> String {
        let jp = lang == .japanese
        if jp && hours == 10000 {
            return "1万時間"
        }
        return jp ? "\(hours.formatted())時間" : "\(hours.formatted())h"
    }

    /// Rows one at a time at 160ms intervals (light haptics per row). Even 12 items come out at a good tempo
    private func revealSequentially() {
        guard revealedCount == 0 else { return }
        if UIAccessibility.isReduceMotionEnabled {
            revealedCount = report.achievements.count
            showCTA = true
            return
        }
        // Show the hero for one beat, then the items under "さらに" ("And still") at 160ms intervals
        for i in 0..<report.achievements.count {
            let delay = i == 0 ? 0.3 : 0.85 + Double(i - 1) * 0.16
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.easeOut(duration: 0.35)) { revealedCount = i + 1 }
                QuizHaptics.light()
            }
        }
        let total = 0.85 + Double(max(report.achievements.count - 1, 0)) * 0.16 + 0.4
        DispatchQueue.main.asyncAfter(deadline: .now() + total) {
            withAnimation(.easeOut(duration: 0.4)) { showCTA = true }
        }
    }
}

// MARK: - ◆ Recovery (a light single screen right after the shock, so it does not end on blame)

struct RecoveryStepView: View {
    let onContinue: () -> Void

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .english }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Reviewed by the user on 2026-07-17 (changed to a form that asks about the user's "resolve")
            Text(lang == .japanese
                 ? "ここまでが現状です。人生を変える覚悟はできていますか？"
                 : "That's where you stand today. Are you ready to change your life?")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(AppColors.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()

            PrimaryButton(lang == .japanese ? "続ける" : "Continue") {
                onContinue()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }
}

// MARK: - ◆ Ideal future (AI-generated image, linked to Q6)

struct IdealFutureStepView: View {
    let goal: QuizGoal
    let onContinue: () -> Void

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    @State private var appeared = false

    private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .english }

    var body: some View {
        ZStack {
            // Changed from a full-screen photo → black background + a deck of rounded cards stacked at an angle
            // (2026-07-17, user-specified)
            AppColors.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // Space to avoid OnboardingTopNav (back + progress bar)
                Spacer().frame(height: 84)

                // Reviewed by the user on 2026-07-17 (added the condition "もし継続できれば" ("If you can keep it up")
                // at the start). The per-goal idealCopy() is not used, kept for later
                Text(lang == .japanese
                     ? "もし継続できれば1年後\nあなたは理想の姿になっている"
                     : "Stay the course, and in one year\nyou'll be the person you set out to become.")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(7)
                    .padding(.horizontal, 28)
                    .opacity(appeared ? 1 : 0)
                    .animation(.easeOut(duration: 0.6).delay(0.2), value: appeared)

                DreamCardDeck(goal: goal)
                    .padding(.vertical, 20)
                    .opacity(appeared ? 1 : 0)
                    .animation(.easeOut(duration: 0.6).delay(0.5), value: appeared)

                Text(lang == .japanese
                     ? "取り戻した時間が、この景色を買い戻す。"
                     : "The time you take back buys this view.")
                    .font(.system(size: 13))
                    .foregroundColor(AppColors.textSecondary)
                    .opacity(appeared ? 1 : 0)
                    .animation(.easeOut(duration: 0.6).delay(0.8), value: appeared)

                // In the 2026-07 review, pushy "Declare"-style copy was removed and this became a plain transition button
                PrimaryButton(lang == .japanese ? "次へ" : "Next") {
                    onContinue()
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 40)
                .opacity(appeared ? 1 : 0)
                .animation(.easeOut(duration: 0.6).delay(1.0), value: appeared)
            }
        }
        .onAppear { appeared = true }
    }
}

/// Deck of "dream photos" shown in the ideal future (Assets/OnboardingDream, 11 images provided by the
/// user on 2026-07-17).
/// The order follows the arc body → work → refinement → freedom → connection.
/// To replace material, just replace the contents of the imageset with the same name (names with no
/// image are skipped automatically)
enum OnboardingDreamAssets {
    static let deck: [String] = [
        "dream-body-male",         // Abs seen in a mirror (ideal body). Body images go first (2026-07-17, confirmed by the user)
        "dream-body-female",       // Gym wear seen in a mirror (ideal body)
        "dream-cabin-work",        // Laptop + coffee in a forest cabin (free way of working)
        "dream-watch-wrist",       // Wristwatch and coffee (refinement)
        "dream-watch-collection",  // Watch collection (refinement)
        "dream-dinner-toast",      // Toast at a dinner with a night view (connection). Partner images go right before the car (2026-07-17, user-specified)
        "dream-sunset-couple",     // Two people watching the sunset (connection)
        "dream-car-drive",         // Driver's seat of a car (success)
        "dream-yacht-reading",     // Reading on a boat (freedom)
        "dream-santorini-coffee",  // Morning in Santorini (travel)
        "dream-paris-night"        // Paris at night (travel)
    ]
}

/// Dream photo deck (changed on 2026-07-17, user-specified, from a full-screen background → rounded
/// cards stacked at an angle).
/// Rounded cards are stacked slightly tilted; at a fixed interval the front card leaves to the left,
/// and the card one behind rises up to the front as is.
/// If you put "IdealFuture_{goal}" in Assets, that goal's image comes first in the deck.
/// If there is no image at all, it falls back to one card with a per-goal gradient (can ship even with
/// no assets added)
struct DreamCardDeck: View {
    let goal: QuizGoal

    /// Deck of existing assets only. Resolved once in init so UIImage(named:) is not called on every body
    /// evaluation
    private let deck: [String]

    @State private var index = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Display time before moving to the next card
    private let holdSeconds: UInt64 = 1_600_000_000

    init(goal: QuizGoal) {
        self.goal = goal
        let goalLead = UIImage(named: goal.idealImageName) != nil ? [goal.idealImageName] : []
        self.deck = goalLead + OnboardingDreamAssets.deck.filter { UIImage(named: $0) != nil }
    }

    /// One card of the deck. Its identity is the image name: when the index advances, the card with the
    /// same image moves from slot 1 → slot 0, which connects into the "back card rises to the front"
    /// animation
    private struct DeckEntry: Identifiable {
        let name: String
        let slot: Int
        var id: String { name }
    }

    var body: some View {
        GeometryReader { geo in
            let cardWidth = min(geo.size.width * 0.64, 270)
            let cardHeight = cardWidth * 1.5   // Source images are 1024x1536 (2:3)

            ZStack {
                if deck.isEmpty {
                    card(fill: fallbackGradient, width: cardWidth, height: cardHeight)
                } else {
                    // Draw in back → front order
                    ForEach(visibleCards().reversed()) { entry in
                        card(
                            fill: Image(entry.name).resizable().scaledToFill(),
                            width: cardWidth, height: cardHeight
                        )
                        .scaleEffect(1 - CGFloat(entry.slot) * 0.06)
                        .rotationEffect(.degrees(rotationDegrees(slot: entry.slot)))
                        .offset(x: xOffset(slot: entry.slot), y: CGFloat(entry.slot) * 10)
                        .opacity(entry.slot == 2 ? 0.65 : 1)
                        .zIndex(Double(3 - entry.slot))
                        // The front card disappears while leaving toward the bottom left, and the new back card is stacked
                        // with a fade
                        .transition(.asymmetric(
                            insertion: .opacity,
                            removal: .offset(x: -cardWidth * 0.55, y: 26).combined(with: .opacity)
                        ))
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(maxHeight: .infinity)
        .task { await flipThroughDeck() }
    }

    /// Up to 3 cards from the front (slot 0 = front / 1 = middle / 2 = back)
    private func visibleCards() -> [DeckEntry] {
        let visible = min(3, deck.count)
        return (0..<visible).map { DeckEntry(name: deck[(index + $0) % deck.count], slot: $0) }
    }

    /// Card tilt. The front card is also slightly tilted (if it is perfectly level, the stacked look is lost)
    private func rotationDegrees(slot: Int) -> Double {
        switch slot {
        case 0:  return -2
        case 1:  return 5
        default: return -6
        }
    }

    private func xOffset(slot: Int) -> CGFloat {
        switch slot {
        case 1:  return 12
        case 2:  return -10
        default: return 0
        }
    }

    private func card<Fill: View>(fill: Fill, width: CGFloat, height: CGFloat) -> some View {
        fill
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(
                RoundedRectangle(cornerRadius: 22)
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.45), radius: 18, y: 10)
    }

    /// The first card is shown immediately. Only the 2nd and later cards are flipped at a fixed interval.
    /// It is a .task, so it is canceled automatically when leaving the screen
    private func flipThroughDeck() async {
        guard !reduceMotion, deck.count > 1 else { return }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: holdSeconds)
            if Task.isCancelled { return }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) {
                index = (index + 1) % deck.count
            }
        }
    }

    private var fallbackGradient: some View {
        let top: Color = {
            switch goal {
            case .study:    return Color(white: 0.28)
            case .work:     return Color(red: 0.24, green: 0.24, blue: 0.28)
            case .fitness:  return Color(red: 0.26, green: 0.24, blue: 0.22)
            case .creation: return Color(red: 0.25, green: 0.23, blue: 0.27)
            case .reading:  return Color(red: 0.27, green: 0.25, blue: 0.21)
            case .health:   return Color(red: 0.22, green: 0.25, blue: 0.26)
            }
        }()
        return LinearGradient(colors: [top, Color(white: 0.06)], startPoint: .topTrailing, endPoint: .bottom)
    }
}
