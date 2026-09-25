//
//  OnboardingQuiz.swift
//  AppBlocker
//
//  診断オンボーディング (2026-07 v3 設計書準拠) の質問・ショック・理想の未来。
//  設計書: 質問6問 (生年月日/立場/1日時間/依存年数/溶かしアプリ/目的) +
//  ショック2拍 (過去の総損失 → 過去形の機会損失) + 理想の未来 (AI画像)。
//
//  UI原則:
//   - 1画面1判断。単一選択は選んだ瞬間ハプティクス + 250ms 後に自動遷移 (「次へ」を置かない)
//   - 上部 2px 進捗バー (OnboardingView 側で共通表示)
//   - 数字は serif + tabular + カウントアップ
//   - 完全モノクロ (AppColors)。金色不使用
//

import SwiftUI

// MARK: - 回答の語彙 (raw value = 026_onboarding_profile.sql の値と一致させること)

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

/// 性別 (2026-07-17 追加、生年月日の直後)。LGBTQ+ 配慮で二択にしない +「回答しない」を必ず用意する
enum QuizGender: String, CaseIterable {
    case male      = "male"
    case female    = "female"
    case nonbinary = "nonbinary"
    case preferNot = "prefer_not"

    func label(_ lang: AppLanguage) -> String {
        let jp = lang == .japanese
        switch self {
        case .male:      return jp ? "男性" : "Male" // 文言はユーザー添削待ち
        case .female:    return jp ? "女性" : "Female" // 文言はユーザー添削待ち
        case .nonbinary: return jp ? "ノンバイナリー・その他" : "Non-binary / other" // 文言はユーザー添削待ち
        case .preferNot: return jp ? "回答しない" : "Prefer not to say" // 文言はユーザー添削待ち
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

    /// ショック計算に使う中央値 (時間/日)
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

    /// ショック計算に使う中央値 (年)
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

// QuizWastedApp (Q5 溶かしアプリ) は 2026-07 再設計で廃止。026 SQL の wasted_apps 列は
// nullable のまま残し、push 時は常に空文字列 (= NULL) を送る (OnboardingProfileService 呼び出し側)。

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

    /// 理想の未来 (AI画像) のアセット名。Assets に同名画像を置けば差し替わる
    var idealImageName: String { "IdealFuture_\(rawValue)" }

    /// 夢の宣言のプレースホルダー出し分け
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

    /// 理想の未来のコピー (目標別)。2026-07 レビューで IdealFutureStepView の見出しは統一文言に置き換え、
    /// 現在この関数は未使用。将来また目標別に出し分けたくなった場合のために残置
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

// MARK: - 損失計算 (ショック2拍の燃料)

struct QuizLossReport {
    let totalHours: Int      // 過去の総損失 (時間)
    let totalDays: Int       // 過去の総損失 (日) — 2026-07-13 以降 UI表示では未使用、内部保持のみ
    let achievements: [(label: String, hours: Int)]  // 2026-07-17 ユーザー指定で買い物カゴ式 (貪欲詰め) に方針転換:
                                                       // 「1278時間しかないのに『1万時間の技芸』が出る」のは嘘になるため、
                                                       // ユーザーの総損失時間に収まる項目だけを重複なく積み上げて返す
                                                       // (2026-07-13 時点の「常に同じ12件を返す」設計は廃止。詳細は greedyAchievements)
    /// このままの1日時間を80歳まで続けた場合の追加損失を「年」換算した数字。年齢不明 or 80歳以上なら nil
    let yearsLostBy80: Int?

    /// カタログ本体 (2026-07-13 新設)。研究・資格試験等の一般に流通する必要時間の代表値 (目安)。
    /// 昇順・職業を問わず1本の共有リスト。この関数自体はフィルタしない —
    /// 総損失時間に応じた絞り込みは呼び出し元 build() の greedyAchievements で行う (2026-07-17)
    static func achievementsCatalog(_ lang: AppLanguage) -> [(label: String, hours: Int)] {
        let jp = lang == .japanese
        // 2026-07-17 ユーザー添削済み: 英語版は直訳でなく英語圏向けにローカライズする方針
        // (東大→Oxford、「英語を」→「第二言語を」)。日本語はそのまま
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
            // 「一つの技芸を世界レベルに極める (1万時間)」は 2026-07-17 ユーザーFBで削除
            // (ヒーロー型の主役として弱い。これにより大時間ユーザーの主役は「起業」になる)
        ]
    }

    /// 総損失時間 (totalHours) に収まる項目だけを、時間の大きい順に貪欲に詰める
    /// (2026-07-17 ユーザー指定・買い物カゴ式)。
    /// 例: 1278h → プログラミング1000h採用 (残278h) → マラソン150h採用 (残128h) → 打ち切り = 2件。
    /// 表示順はそのまま時間の大きい順 (詰めた順)。
    /// 総損失が最小項目 (150h) 未満で1件も採用できない場合のみ、最小の1件にフォールバックする。
    /// 実際には診断の最小回答 (1日2時間未満 × 依存1年未満、13歳未満クランプ) でも総損失は約274hになるため、
    /// このフォールバックが実運用で発火することはない
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

    /// 依存年数は (年齢 - 13) 年でクランプ (13歳からスマホを持った仮定より前に遡らせない = 誇張しない)
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

        // 80歳までこのペースを続けた場合の追加消費時間を「年」に換算 (24時間×365日 = 1年分の時間で割る)
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

// MARK: - 共通部品

enum QuizHaptics {
    static func light()  { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func medium() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
}

/// 質問見出し (serif) + 補足
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

/// 単一選択の行。タップでハプティクス + 選択表示 → 250ms 後に onPick (自動遷移)
struct QuizOptionRow: View {
    let label: String
    let isSelected: Bool
    /// 行頭のブランドアイコン (Assets のアセット名)。流入元質問で本物のアプリアイコンを出す用
    /// (2026-07-17 ユーザー指定「ネイティブのちゃんとしたアイコン」)。nil なら従来のテキストのみ
    var iconAsset: String? = nil
    /// iconAsset が nil の時の代替 SF Symbol (友達・その他など、ブランドアイコンが無い選択肢用)
    var iconSystemName: String? = nil
    let onPick: () -> Void

    var body: some View {
        Button {
            QuizHaptics.light()
            onPick()
        } label: {
            HStack(spacing: 12) {
                if let iconAsset {
                    // 実アプリアイコンはホーム画面と同じ角丸スクワークル風に切る
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

/// 複数選択のチップ
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

/// serif + tabular のカウントアップ数字 (ショック第1拍)
struct CountUpNumber: View {
    let target: Int
    var duration: Double = 1.6
    var fontSize: CGFloat = 68
    /// 指定時はこの色列の縦グラデーションで数字を描く (未指定なら textPrimary のモノクロ)。
    /// 2026-07-13 レビュー修正: ショック第1拍の暖色グラデーション運用は廃止し完全モノクロに統一。
    /// 現在オンボーディング内での呼び出し元は全て未指定 (nil) で、このパラメータ自体は将来の再利用のために残置
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
                    startDate = Date.distantPast   // 即座に確定値
                } else {
                    startDate = Date()
                }
            }
        }
    }
}

// MARK: - Q1 生年月日

struct QuizBirthDateStepView: View {
    /// "yyyy-MM-dd" で保存 (@AppStorage)
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

    /// 13歳未満ゲート (App Store 13+ レーティング準拠)。データは保存しない
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

// MARK: - Q2 立場 / Q3 時間 / Q4 依存年数 (単一選択・自動遷移の共通形)

struct QuizSingleChoiceStepView<Option: RawRepresentable & CaseIterable & Hashable>: View where Option.RawValue == String, Option.AllCases: RandomAccessCollection {
    let question: String
    /// 2026-07 レビュー: 単一選択画面の補足文言 (「設定でスクリーンタイムを確認できます」「だいたいで構いません」等) は
    /// 全廃し、質問+選択肢のみにすると決定。呼び出し元 (OnboardingView.swift) の `hint:` 引数はそのまま残すが
    /// 本画面では描画しない (呼び出し元を書き換えずに互換を保つためのパラメータ)
    var hint: String? = nil
    let labelProvider: (Option) -> String
    /// 行頭アイコン (任意)。流入元質問のブランドアイコン用 (2026-07-17)
    var iconAssetProvider: ((Option) -> String?)? = nil
    var iconSystemNameProvider: ((Option) -> String?)? = nil
    @Binding var selectionRaw: String
    let onContinue: () -> Void

    // H10 (2026-07-20 監査): 二重タップ/250ms以内の選び直しで遅延クロージャが複数積まれると
    // onContinue (= advance) が多重発火し、ステップを1つ飛ばす。選び直し自体 (selectionRaw の
    // 更新) は250ms以内でも許可したまま、onContinue の発火だけを1回に制限する。
    // .id(step) で毎ステップこの View 自体が作り直されるため、次のステップでは自然に false へ戻る
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
                        // 選択の白反転を見せてから自動遷移 (1画面1判断、「次へ」は置かない)
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

// Q5 (溶かしアプリ、QuizWastedAppsStepView / FlowChips) は 2026-07 再設計で廃止。

// MARK: - ◆ ショック: 80歳投影 (2026-07-17 再設計で一本化)
//
// 旧構成 (過去の総損失 = 1日時間 × 依存年数) は「昔から今の時間使ってたわけではない」という
// 数学的な無理くりをユーザー自身が指摘し廃止。依存年数の質問・「できていたこと」ページごと
// フローから外し、正直な計算だけで立つ80歳投影 (今のペース × 残り年数) に一本化した

struct ShockLossStepView: View {
    let report: QuizLossReport
    // 旧・計算内訳表示の名残。呼び出し元の init シグネチャ互換のためプロパティのみ残置
    let hoursLabel: String
    /// 換算根拠に出す「1日◯時間」ラベル (例: "6〜8時間")。nil なら根拠行は非表示
    var dailyPaceLabel: String? = nil
    let onContinue: () -> Void
    /// L17 (2026-07-20 監査): 80歳以上は yearsLostBy80 が nil になり、onAppear で即座に
    /// スキップする。旧実装は方向を問わず onContinue (前進) しか呼ばなかったため、recovery から
    /// 「戻る」で本画面に戻ってきた瞬間また前進スキップが発火し、実質「戻れない」詰みになっていた。
    /// 呼び出し元 (OnboardingView) が「戻る」経由での再訪と判断した場合はこちらを呼び、
    /// 1つ前のステップへ後退させる。未指定 (nil) の場合は従来どおり onContinue にフォールバック
    var onAutoSkipBack: (() -> Void)? = nil

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    @State private var showTail = false
    @State private var showCTA = false

    private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .english }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            if let years = report.yearsLostBy80 {
                // 文言は承認済みの1文「このままだと80歳までに◯年分無駄にすることになります」を
                // 見出し / 大数字 / 結びに分解して配置しただけ (新規コピーの発明はしない)
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

                // 換算根拠 (この数字は「1日◯時間 × 80歳までの残り年数」)。// 文言はユーザー添削待ち
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
            // 生年月日が読めず投影が出せない場合 (≒80歳以上で余命年数が算出できない場合含む)
            // このページに用が無いので即スキップ (birthDate は必須ステップなので実運用では
            // ほぼ到達しない防御)。「戻る」で再訪した場合は前進ではなく後退させる (L17)
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

// MARK: - ◆ (フロー除外・残置) 過去形の機会損失 (買い物カゴ式)
//
// 2026-07-17 ユーザー承認でフローから除外 (依存年数質問の廃止に伴い、前提の「過去の総損失」が
// 計算不能になったため)。復活の可能性を考慮して View とカタログはコードごと残置している。
// 復活させる場合は OnboardingStep に shockAchievements を戻し switch に配線するだけ

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

            // 2026-07-13 レビュー修正: 見出しは ShockLoss と単位を揃えて「時間」のみ (日換算は撤去)
            QuizQuestionHeader(
                // 2026-07-17 英語をユーザー依頼で整文 (旧 "◯ hours — of what you could have done" は文として不自然)
                question: lang == .japanese
                    ? "\(report.totalHours.formatted())時間で\nできていたこと"
                    : "What you could have done\nwith \(report.totalHours.formatted()) hours",
                hint: lang == .japanese ? "一般的な必要時間の目安で換算" : "Based on commonly cited time estimates"
            )

            // 2026-07-17 ヒーロー型に刷新 (ユーザーFB: 貪欲詰め化で項目が減り、ピルの羅列だと寂しい)。
            // 最大の達成1件を大型タイポで主役に、残りは「さらに —」以下に小さく列挙。
            // report.achievements は greedyAchievements が大きい順に絞り込み済み (先頭 = 主役)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if let hero = report.achievements.first {
                        Text(hero.label)
                            .font(.system(size: 30, weight: .bold))
                            .foregroundColor(AppColors.textPrimary)
                            .lineSpacing(6)
                            .fixedSize(horizontal: false, vertical: true)

                        // 大数字は金ではなくオフホワイト (金は達成/上位%系限定のブランドルール)
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
                        // 文言はユーザー添削待ち
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
                                // 主役 (revealedCount 1つ目) の後に1件ずつ
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
                // ヒーロー本体はフェード+わずかな沈み込みで登場
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

    /// 時間の表示形式。10000時間ちょうどは「1万時間」と表記 (それ以外は素直に「◯時間」)
    private func hoursDisplay(_ hours: Int) -> String {
        let jp = lang == .japanese
        if jp && hours == 10000 {
            return "1万時間"
        }
        return jp ? "\(hours.formatted())時間" : "\(hours.formatted())h"
    }

    /// 行を 160ms 間隔で1本ずつ (行ごとにハプティクス light)。12項目でもテンポよく出し切る
    private func revealSequentially() {
        guard revealedCount == 0 else { return }
        if UIAccessibility.isReduceMotionEnabled {
            revealedCount = report.achievements.count
            showCTA = true
            return
        }
        // 主役 (ヒーロー) を1拍見せてから「さらに —」以下を 160ms 間隔で
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

// MARK: - ◆ Recovery (ショックの直後、糾弾で終わらせない軽い1画面)

struct RecoveryStepView: View {
    let onContinue: () -> Void

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .english }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // 2026-07-17 ユーザー添削済み (「覚悟」を問う形に変更)
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

// MARK: - ◆ 理想の未来 (AI生成画像、Q6連動)

struct IdealFutureStepView: View {
    let goal: QuizGoal
    let onContinue: () -> Void

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    @State private var appeared = false

    private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .english }

    var body: some View {
        ZStack {
            // 全画面写真 → 真っ黒背景 + 角丸カードの斜め重ねデッキに変更 (2026-07-17 ユーザー指定)
            AppColors.background.ignoresSafeArea()

            VStack(spacing: 0) {
                // OnboardingTopNav (戻る+進捗バー) を避ける余白
                Spacer().frame(height: 84)

                // 2026-07-17 ユーザー添削済み (「もし継続できれば」の条件を頭に追加)。目標別の idealCopy() は不採用、温存
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

                // 2026-07 レビューで「宣言する」系の煽りコピーを撤去し、プレーンな遷移ボタンに変更
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

/// 理想の未来で流す「夢の写真」デッキ (Assets/OnboardingDream、2026-07-17 ユーザー支給の11枚)。
/// 順序は 体 → 仕事 → 品 → 自由 → つながり の弧を描く。
/// 素材差し替えは同名 imageset の中身を差し替えるだけ (画像が無い名前は自動で skip される)
enum OnboardingDreamAssets {
    static let deck: [String] = [
        "dream-body-male",         // 鏡越しの腹筋 (理想の体) — 体系が先頭 (2026-07-17 ユーザー確定)
        "dream-body-female",       // ジムウェアの鏡越し (理想の体)
        "dream-cabin-work",        // 森のキャビンでノートPC+珈琲 (自由な働き方)
        "dream-watch-wrist",       // 腕時計と珈琲 (品)
        "dream-watch-collection",  // 時計コレクション (品)
        "dream-dinner-toast",      // 夜景のディナーで乾杯 (つながり) — パートナー系は車の直前 (2026-07-17 ユーザー指定)
        "dream-sunset-couple",     // 夕陽を見る二人 (つながり)
        "dream-car-drive",         // 車の運転席 (成功)
        "dream-yacht-reading",     // 船上の読書 (自由)
        "dream-santorini-coffee",  // サントリーニの朝 (旅)
        "dream-paris-night"        // 夜のパリ (旅)
    ]
}

/// 夢の写真デッキ (2026-07-17 ユーザー指定で全画面背景 → 角丸カードの斜め重ねに変更)。
/// 角丸カードが少し斜めに重なって積まれ、一定間隔で前面カードが左へ抜け、
/// 1つ後ろのカードがそのまま前面へ立ち上がってくる。
/// Assets に "IdealFuture_{goal}" を置けばその目標別画像がデッキの先頭に来る。
/// 画像が1枚も無ければ目標別グラデーションのカード1枚でフォールバック (アセット未投入でも出荷可能)
struct DreamCardDeck: View {
    let goal: QuizGoal

    /// 実在するアセットだけのデッキ。body 評価のたびに UIImage(named:) を叩かないよう init で1回だけ解決する
    private let deck: [String]

    @State private var index = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 次の1枚に移るまでの表示時間
    private let holdSeconds: UInt64 = 1_600_000_000

    init(goal: QuizGoal) {
        self.goal = goal
        let goalLead = UIImage(named: goal.idealImageName) != nil ? [goal.idealImageName] : []
        self.deck = goalLead + OnboardingDreamAssets.deck.filter { UIImage(named: $0) != nil }
    }

    /// デッキの1枚。identity は画像名 — index が進むと同じ画像のカードが
    /// slot 1 → slot 0 へ移動し、「後ろのカードが前へ立ち上がる」アニメとして繋がる
    private struct DeckEntry: Identifiable {
        let name: String
        let slot: Int
        var id: String { name }
    }

    var body: some View {
        GeometryReader { geo in
            let cardWidth = min(geo.size.width * 0.64, 270)
            let cardHeight = cardWidth * 1.5   // 素材は 1024x1536 (2:3)

            ZStack {
                if deck.isEmpty {
                    card(fill: fallbackGradient, width: cardWidth, height: cardHeight)
                } else {
                    // 背面 → 前面の順に描く
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
                        // 前面カードは左下へ抜けながら消え、新しい背面カードはフェードで積まれる
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

    /// 前面から最大3枚 (slot 0 = 前面 / 1 = 中 / 2 = 背面)
    private func visibleCards() -> [DeckEntry] {
        let visible = min(3, deck.count)
        return (0..<visible).map { DeckEntry(name: deck[(index + $0) % deck.count], slot: $0) }
    }

    /// カードの傾き。前面もわずかに斜め (きっちり水平だと「重なってる感」が消える)
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

    /// 1枚目は即時表示。2枚目以降だけを一定間隔でめくる。
    /// .task なので画面を離れると自動でキャンセルされる
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
