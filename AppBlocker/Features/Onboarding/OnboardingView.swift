//
//  OnboardingView.swift
//  AppBlocker
//
//  オンボーディングフロー (2026-07-08 診断クイズ型に全面再設計、設計書 v3 準拠):
//  Splash(モノグラム) → フィードプレビュー → 診断クイズ6問+ショック2拍+理想の未来
//  → Dream → NameInput → AppleSignIn → FamilyControls → プラン生成 → Paywall → MainTab
//
//  設計原則:
//   - Cal AI / Opal 型「診断させて投資させる」構造。全質問はショック演出・プラン・
//     将来のペイウォール文言のどれかに必ず接続する (使い道のない質問は置かない)
//   - ショックは過去形 (「もう失った」)。依存年数 × 1日時間 → 総損失 → 資格の買い物カゴ
//   - FamilyControls と AppleSignIn の順序: サインイン (小さなお願い) → Screen Time 権限
//     (大きなお願い) のフット・イン・ザ・ドア。権限付与は必ずペイウォールより前
//   - クイズ回答は @AppStorage 保持 → サインイン後に user_onboarding_profiles へ push
//     (成功時のみ pending 消費)
//

import SwiftUI
import AuthenticationServices
import StoreKit
import FamilyControls

// MARK: - 流入元 (2026-07-17 追加)

/// 「1%をどこで知ったか」。rawValue = 036_referral_source.sql の値と一致させること。
/// OnboardingQuiz.swift は別エージェントが編集中のため、このファイルに定義する
/// (QuizSingleChoiceStepView は Option: RawRepresentable & CaseIterable & Hashable, RawValue == String を要求するのみ)
enum QuizReferralSource: String, CaseIterable {
    // 表示順 = allCases (宣言順)。2026-07-25 ユーザー指定で「友達・知人」を App Store の下へ移動。
    // rawValue は 036_referral_source.sql と一致させること (順序を変えても DB 値は不変)
    case tiktok    = "tiktok"
    case instagram = "instagram"
    case youtube   = "youtube"
    case appStore  = "app_store"
    case friend    = "friend"
    case other     = "other"

    func label(_ lang: AppLanguage) -> String {
        let jp = lang == .japanese
        switch self {
        case .tiktok:    return "TikTok" // 文言はユーザー添削待ち
        case .instagram: return "Instagram" // 文言はユーザー添削待ち
        case .youtube:   return "YouTube" // 文言はユーザー添削待ち
        case .friend:    return jp ? "友達・知人" : "Friends or family" // 文言はユーザー添削待ち
        case .appStore:  return "App Store" // 2026-07-17 ユーザー添削済み (「で見つけた」削除)
        case .other:     return jp ? "その他" : "Other" // 文言はユーザー添削待ち
        }
    }

    // 行頭の本物ブランドアイコン (Assets/ReferralIcons、2026-07-25 実機FBでSF Symbols代替を
    // 却下されgit履歴 13bb33b から復元)。TikTok/Instagram/YouTube は実アプリアイコン、
    // App Store は Apple 公式素材
    var iconAsset: String? {
        switch self {
        case .tiktok:    return "referral-tiktok"
        case .instagram: return "referral-instagram"
        case .youtube:   return "referral-youtube"
        case .appStore:  return "referral-appstore"
        case .friend, .other: return nil
        }
    }

    /// ブランドアイコンが無い選択肢の SF Symbol
    var iconSystemName: String? {
        switch self {
        case .friend: return "person.2.fill"
        case .other:  return "ellipsis.circle.fill"
        default:      return nil
        }
    }
}

// MARK: - Step

enum OnboardingStep: Int, CaseIterable {
    // PHASE 0 — フック
    case splash
    case feedPreview
    // 流入元 (2026-07-17 追加): 「どこで知ったか」はフィードプレビューの直後・記憶が
    // 最も新しいタイミングで聞く。TikTok 広告の流入比率把握用 (036 SQL)
    case referralSource
    case moderationPolicy
    // PHASE 1 — 権限プライミング (2026-07 再設計で診断より前に移動。
    // Screen Time は「アプリの使用に必須」の単独ページとして先に片付ける)
    case familyControls
    // PHASE 2 — 診断
    case quizBirthDate
    case quizGender
    // quizOccupation (現在の立場) は 2026-07-19 ユーザー決定で削除 — QuizLossReport.build の
    // occupation 引数は元々未使用で副作用ゼロ。user_onboarding_profiles.occupation は NULL になる
    case quizDailyHours
    case usageReveal
    // quizAddictionYears / shockAchievements は 2026-07-17 ユーザー承認で廃止
    // (「今の1日時間×依存年数」の過去総額が数学的に無理くりのため。shockLoss = 80歳投影に一本化)
    case shockLoss
    case recovery
    // 🔴 2026-08-06 追加: 3つのロックモードを1枚で見せる。
    // オンボが「なぜやめるべきか」しか語らず、このアプリが何をするのかを一度も見せないまま
    // ペイウォールに到達していたため (= 何を売っているか見せずに売っていた)。
    // 置き場所は「ショック → 覚悟」の直後 = 「覚悟はできていますか?」の次に手段を出す並び。
    // ⚠️ step は @State で永続化していないので、ここに case を挿しても rawValue のズレは無害
    case lockModes
    // quizGoal (取り戻した時間で何を成し遂げますか? 6択) は 2026-07-19 ユーザー決定で削除 —
    // 目標宣言 (dream) と実質重複のため。回答は user_onboarding_profiles.goal に NULL が入る
    case idealFuture
    // PHASE 3 — 宣言 (既存資産)
    case dream
    // 署名 (2026-07-17 追加): 宣言した目標に指で署名させ、コミットメントを再度刻ませる
    case signature
    case nameInput
    case appleSignIn
    // PHASE 4 — ペイウォール直行 (2026-07-19 ユーザー決定: 「プラン構築」はこのアプリに合わないため
    // .plan を除外。将来「スケジュール提案 → 手直し → 有効化はPro」ページに作り直す構想あり)
    case paywall
    // PHASE 5 — 初期セットアップ (2026-07-15 追加): 最初にロックするアプリを選ばせ、
    // 3モード共通の初期値として保存する (診断で見せた「トップ3」の直後の記憶が残っているうちに)
    case appSelect
    // PHASE 6 — App Store 評価 (2026-07-19 新設。タイミングは「最後」がユーザー指定)
    case rating
    // PHASE 7 — 最初のロックをその場で開始させる (2026-09-05 新設)。
    // 🔴 enum の末尾に足すこと。途中に挿すと既存 case の rawValue が全部ずれて
    //    advance()/retreat() の連番と progressFraction が壊れる
    case firstLock

    /// enum に残してあるがフローを通らない step。
    /// 進捗バーの分母から外さないと、飛ばした分だけバーが飛び跳ねて見える。
    /// (case ごと消さないのは、いつでも1行で復活できるようにしておくため)
    static let excludedFromFlow: Set<OnboardingStep> = [
        .quizGender,  // 2026-08-06 削除。収集していたがアプリのどこからも読んでいなかった
        .nameInput,   // 2026-08-06 削除。Guideline 4 対応で入力欄を全廃
        .rating       // 2026-08-06 削除。Guideline 5.6.3 でオンボ中の評価依頼が禁止
    ]

    /// 上部 2px 進捗バーの進捗率 (クイズ開始〜サインインで 0→1)。対象外ステップは nil。
    /// 実際に通る step だけを数える (rawValue の連番ではない)
    var progressFraction: Double? {
        let start = OnboardingStep.quizBirthDate.rawValue
        let end = OnboardingStep.appleSignIn.rawValue
        guard rawValue >= start, rawValue <= end else { return nil }
        let active = (start...end)
            .compactMap { OnboardingStep(rawValue: $0) }
            .filter { !Self.excludedFromFlow.contains($0) }
        guard let index = active.firstIndex(of: self) else { return nil }
        return Double(index + 1) / Double(active.count)
    }
}

// MARK: - Root

struct OnboardingView: View {
    @StateObject private var familyControlsService = AuthorizationService.shared
    @StateObject private var userAuth = UserAuthService.shared
    @Binding var hasCompletedOnboarding: Bool
    /// M8 (2026-07-22 監査): OnboardingView が画面に滞在している間 true。AppBlockerApp の
    /// ルート条件に使い、再サインイン直後に条件が揃っても (返却フロー実行中は) MainTabView へ
    /// 切り替わらないようにする。
    @Binding var onboardingActive: Bool

    // 2026-07-29 ユーザー指示でスプラッシュ (刻印アニメ) を廃止し、ARISE型ヒーローから開始。
    // .splash の enum case と MonogramSplashView はロールバック用に残置 (rawValue 順序も不変)
    @State private var step: OnboardingStep = .feedPreview
    /// L17 (2026-07-20 監査): 直近の遷移が「戻る」(retreat) だったか。ShockLossStepView が
    /// 80歳以上判定で onAppear 即スキップする際、前進 (advance) と後退 (retreat) を区別するために使う
    @State private var lastMoveWasBack = false

    /// 「すでにアカウントを持っている」経路か。true の間は advance() が診断クイズ・プラン等を
    /// スキップする短縮フロー (appleSignIn → familyControls → rating → paywall → appSelect) になる。
    /// 2026-07-19 実機バグの根本原因: 旧実装はこの経路が familyControls を一度も通らず、
    /// 完了時の表示条件 (isAuthorized) を満たせずに appSelect で無反応 (詰み) になっていた
    @State private var isReturningUser = false
    /// M23 (2026-07-22 監査): 「すでにアカウントを持っている」を誤タップした経路の戻り先ステップ
    /// (feedPreview/nameInput のどちらから来たか)。AppleSignInStepView の
    /// 「アカウントを作成する」導線で、誤タップ前の画面へ戻すために使う。
    @State private var returningEntryStep: OnboardingStep?
    /// L7 (2026-07-22 監査): スクリーンタイム権限だけ後から取り消されたユーザー
    /// (hasCompletedOnboarding=true, isSignedIn=true, isAuthorized=false) を、フル再オンボ+
    /// Apple再サインインではなく familyControls だけの短縮経路に通すためのフラグ
    @State private var isPermissionRecovery = false

    // PHASE 2 の pending (従来どおり)
    @AppStorage("onboardingDisplayName") private var pendingDisplayName: String = ""
    @AppStorage("onboardingHandle") private var pendingHandle: String = ""
    @AppStorage("onboardingDream") private var pendingDream: String = ""
    // 初期値は公開 ON (2026-07-19 ユーザー指定: プロフィール公開トグルはデフォルトオン、タップでオフ)
    @AppStorage("onboardingDreamPublic") private var pendingDreamPublic: Bool = true

    // 診断クイズの pending (raw 値。サインイン後に user_onboarding_profiles へ push)
    @AppStorage("onboardingBirthDate") private var pendingBirthDate: String = ""
    @AppStorage("onboardingGender") private var pendingGender: String = ""
    @AppStorage("onboardingOccupation") private var pendingOccupation: String = ""
    @AppStorage("onboardingDailyHours") private var pendingDailyHours: String = ""
    @AppStorage("onboardingAddictionYears") private var pendingAddictionYears: String = ""
    @AppStorage("onboardingGoal") private var pendingGoal: String = ""
    @AppStorage("onboardingReferralSource") private var pendingReferralSource: String = ""

    private var lang: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: "mainLanguage") ?? "") ?? .english
    }

    var body: some View {
        ZStack(alignment: .top) {
            AppColors.background.ignoresSafeArea()

            // 実測レポートの事前暖機 (2026-07-25): 生年月日/性別の入力中 (ユーザーが時間を使う
            // ステップ) に裏で拡張プロセス+クエリを暖め、usageReveal 到達時に1回目から実測を出す。
            // familyControls (権限付与) より後のステップに限定。quizDailyHours では外す
            // (usageReveal のレポートと遷移中も共存させない — 2個目白紙バグ回避)
            if step == .quizBirthDate || step == .quizGender {
                UsageReportWarmUpView()
            }

            Group {
                switch step {
                case .splash:
                    MonogramSplashView(onContinue: advance)
                case .feedPreview:
                    FeedPreviewHookView(
                        onStart: advance,
                        onAlreadyHasAccount: {
                            // M23: 誤タップ経路から戻れるよう、遷移前のステップを記録しておく
                            returningEntryStep = step
                            isReturningUser = true
                            step = .appleSignIn
                        }
                    )
                case .referralSource:
                    QuizSingleChoiceStepView<QuizReferralSource>(
                        question: lang == .japanese ? "1%をどこで知りましたか?" : "Where did you hear about 1%?", // 文言はユーザー添削待ち
                        labelProvider: { $0.label(lang) },
                        // 2026-07-25: 本物ブランドアイコン再導入 (SF Symbols代替は実機FBで却下)
                        iconAssetProvider: { $0.iconAsset },
                        iconSystemNameProvider: { $0.iconSystemName },
                        selectionRaw: $pendingReferralSource,
                        onContinue: advance
                    )
                case .moderationPolicy:
                    ModerationPolicyStepView(onContinue: advance)
                case .familyControls:
                    FamilyControlsStepView(
                        service: familyControlsService,
                        onContinue: advance
                    )
                case .quizBirthDate:
                    QuizBirthDateStepView(birthDateRaw: $pendingBirthDate, onContinue: advance)
                case .quizGender:
                    QuizSingleChoiceStepView<QuizGender>(
                        question: lang == .japanese ? "性別を教えてください" : "How do you identify?", // 文言はユーザー添削待ち
                        labelProvider: { $0.label(lang) },
                        selectionRaw: $pendingGender,
                        onContinue: advance
                    )
                case .quizDailyHours:
                    QuizSingleChoiceStepView<QuizDailyHours>(
                        question: lang == .japanese ? "1日、何時間スマホを見ていますか?" : "How many hours a day do you spend on your phone?",
                        hint: lang == .japanese ? "設定 → スクリーンタイムで確認できます" : "You can check under Settings → Screen Time",
                        labelProvider: { $0.label(lang) },
                        selectionRaw: $pendingDailyHours,
                        onContinue: advance
                    )
                case .usageReveal:
                    UsageRevealStepView(
                        dailyHours: QuizDailyHours(rawValue: pendingDailyHours),
                        onContinue: advance
                    )
                case .shockLoss:
                    ShockLossStepView(
                        report: lossReport,
                        hoursLabel: hoursLabel,
                        dailyPaceLabel: QuizDailyHours(rawValue: pendingDailyHours)?.label(lang),
                        onContinue: advance,
                        // L17: 80歳以上の自動スキップは「戻る」で再訪した場合、前進ではなく
                        // usageReveal へ後退させる (でないと recovery との間で戻れず詰む)
                        onAutoSkipBack: shockLossAutoSkipBack
                    )
                case .recovery:
                    RecoveryStepView(onContinue: advance)
                case .lockModes:
                    // 「覚悟はできていますか?」の次に、その手段 (3モード) を見せる (2026-08-06)
                    LockModesStepView(onContinue: advance)
                case .idealFuture:
                    IdealFutureStepView(goal: selectedGoal, onContinue: advance)
                case .dream:
                    DreamStepView(
                        dream: $pendingDream,
                        isPublic: $pendingDreamPublic,
                        goal: QuizGoal(rawValue: pendingGoal),
                        onContinue: advance
                    )
                case .signature:
                    SignatureStepView(dreamText: pendingDream, onContinue: advance)
                case .nameInput:
                    NameInputStepView(
                        // 表示名は Apple から受け取るのでここでは扱わない (2026-08-06)
                        handle: $pendingHandle,
                        onContinue: advance,
                        onAlreadyHasAccount: {
                            // M23: 誤タップ経路から戻れるよう、遷移前のステップを記録しておく
                            returningEntryStep = step
                            isReturningUser = true
                            step = .appleSignIn
                        }
                    )
                case .appleSignIn:
                    AppleSignInStepView(
                        userAuth: userAuth,
                        isReturningUser: isReturningUser,
                        pendingDisplayName: pendingDisplayName,
                        pendingHandle: pendingHandle,
                        pendingDream: pendingDream,
                        pendingDreamPublic: pendingDreamPublic,
                        onContinue: advance,
                        // M23: 誤タップして来た場合に元の画面へ戻す
                        onCreateAccountInstead: {
                            isReturningUser = false
                            step = returningEntryStep ?? .feedPreview
                        },
                        // M23: 「すでにアカウントを持っている」経路のまま新規 Apple ID でサインイン
                        // してしまった場合、新規オンボ (13歳ゲート+診断+名前入力) へ回す
                        onDetectedNewAccount: {
                            isReturningUser = false
                            step = .quizBirthDate
                        }
                    )
                case .paywall:
                    // 実ペイウォール (RevenueCat 実配線済み)。閉じる/あとで/購入成功のすべてで
                    // onClose → advance され、オンボが先へ進む (旧 PaywallPlaceholderStepView は廃止)
                    ProPaywallView(triggeredBy: .schedule, onClose: advance)
                case .appSelect:
                    AppSelectStepView(lang: lang, onFinish: advance)
                case .rating:
                    RatingStepView(lang: lang, onContinue: advance)
                case .firstLock:
                    FirstLockStepView(lang: lang, onFinish: advance)
                }
            }
            .id(step)
            // 非対称スライド: 新画面は右から 24pt + フェードで入り、旧画面は左へ 8pt 逃げる
            .transition(.asymmetric(
                insertion: .offset(x: 24).combined(with: .opacity),
                removal: .offset(x: -8).combined(with: .opacity)
            ))

            // 上部ナビ (戻る + 2px 進捗バー)。診断フェーズ〜プランのみ表示。
            // 戻るボタンと進捗バーを1つの HStack に統一し、常に同じ高さ・間隔で並べる
            // (以前は個別 overlay で padding.top が 8 と 2 に食い違い、詰まって見えていた)
            if step.progressFraction != nil || canGoBack {
                OnboardingTopNav(
                    fraction: step.progressFraction,
                    canGoBack: canGoBack,
                    onBack: retreat
                )
            }
        }
        .animation(.spring(response: 0.42, dampingFraction: 0.9), value: step)
        .onAppear {
            // M8: OnboardingView 表示中は MainTabView へ切り替えさせない
            onboardingActive = true
            // L7 (検知a): オンボ完了済み+サインイン済みユーザーがこの画面に居る場合の振り分け
            if hasCompletedOnboarding && userAuth.isSignedIn {
                routeCompletedSignedInUser()
            }
        }
        .onChange(of: userAuth.isSignedIn) { _, signedIn in
            // L7 (検知b): 起動直後は restoreSession() が未完了で isSignedIn=false のままのことがあり、
            // 上の onAppear 時点では検知できない。まだ splash/feedPreview に居る間に signedIn に
            // なった場合のみここで拾う (それ以降のステップに居れば、ユーザーは既に新規オンボ/
            // 返却ユーザー選択などの別経路を選んでいるので上書きしない)
            if signedIn && hasCompletedOnboarding && (step == .splash || step == .feedPreview) {
                routeCompletedSignedInUser()
            }
        }
    }

    /// L7/M8 (2026-07-22 Fableレビュー修正): オンボ完了済み+サインイン済みユーザーが
    /// OnboardingView に居る場合の振り分け。
    /// - 権限が生きている場合は即 completeOnboarding() して MainTabView へ流す。
    ///   isSignedIn は毎起動 false から始まり restoreSession() で復元されるため、通常起動でも
    ///   一瞬 OnboardingView (splash) が出る。M8 の onboardingActive がルートの自動切替を
    ///   止めるようになったため、この即完了が無いと「毎起動 familyControls 画面で『次へ』を
    ///   タップさせられる」退行になる (旧挙動 = 復元完了と同時にルートが自動で MainTabView)。
    /// - 権限が失効している場合のみ familyControls 短縮経路 (真の L7 リカバリ) に入る。
    private func routeCompletedSignedInUser() {
        if familyControlsService.isAuthorized {
            completeOnboarding()
        } else {
            isPermissionRecovery = true
            step = .familyControls
        }
    }

    /// 戻れるステップか。splash/feedPreview と、副作用のある認証〜プラン以降は不可
    private var canGoBack: Bool {
        switch step {
        case .splash, .feedPreview, .appleSignIn, .familyControls, .paywall, .appSelect, .rating, .firstLock:
            return false
        default:
            return true
        }
    }

    /// L17: shockLoss の 80歳以上自動スキップに渡す方向付きコールバック。直近が「戻る」なら
    /// retreat (後退)、それ以外 (通常の前進到達) なら nil を返し onContinue にフォールバックさせる
    private var shockLossAutoSkipBack: (() -> Void)? {
        if lastMoveWasBack {
            return { retreat() }
        }
        return nil
    }

    private func retreat() {
        lastMoveWasBack = true
        // 🔴 2026-08-06: advance 側で飛ばした .quizGender は戻る時も飛ばす。
        // これが無いと「戻る」でフロー外の画面に着地してしまう
        if step == .quizDailyHours {
            step = .quizBirthDate
            return
        }
        guard let prev = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        step = prev
    }

    // MARK: - 診断の派生値

    /// 過去の総損失レポート (Q1年齢 + Q3時間 + Q4年数 + Q2立場から)
    private var lossReport: QuizLossReport {
        QuizLossReport.build(
            hours: QuizDailyHours(rawValue: pendingDailyHours) ?? .h4to6,
            years: QuizAddictionYears(rawValue: pendingAddictionYears) ?? .y3to5,
            age: QuizBirthDateStepView.age(fromRaw: pendingBirthDate),
            occupation: QuizOccupation(rawValue: pendingOccupation),
            lang: lang
        )
    }

    private var selectedGoal: QuizGoal {
        QuizGoal(rawValue: pendingGoal) ?? .work
    }

    /// 「1日5時間 × 4年」等 (ショック第1拍の内訳表示)
    private var hoursLabel: String {
        let h = QuizDailyHours(rawValue: pendingDailyHours) ?? .h4to6
        let y = QuizAddictionYears(rawValue: pendingAddictionYears) ?? .y3to5
        return lang == .japanese
            ? "1日\(h.label(lang)) × \(y.label(lang))"
            : "\(h.label(lang))/day × \(y.label(lang))"
    }

    private func advance() {
        lastMoveWasBack = false
        // L7: 権限回復の短縮経路。familyControls を通過 (= 再許可完了) したら即オンボ完了とする
        if isPermissionRecovery && step == .familyControls {
            completeOnboarding()
            return
        }
        // 返却ユーザー (すでにアカウントを持っている) の短縮フロー。
        // 診断クイズ・プラン構築は初回診断済みの前提でスキップし、
        // 権限 (未許可の場合のみ) → 評価 → ペイウォール → アプリ選択 だけを通す
        if isReturningUser {
            switch step {
            case .appleSignIn:
                step = familyControlsService.isAuthorized ? .paywall : .familyControls
                return
            case .familyControls:
                step = .paywall
                return
            default:
                break  // paywall 以降 (appSelect → rating → 完了) は通常の連番と同じ
            }
        }
        // 🔴 2026-08-06 ユーザー決定: 性別の質問 (.quizGender) をフローから外す。
        // 収集して user_onboarding_profiles.gender に保存していたが、アプリのどこからも
        // 読んでいなかった (既に削除済みの「立場」「目標」と同じ状態)。
        // enum case と QuizGender はロールバック用に残置。⚠️ retreat 側にも同じ分岐が要る
        if step == .quizBirthDate {
            step = .quizDailyHours
            return
        }
        // 🔴 2026-08-06 審査リジェクト対応 (Guideline 4 / Sign in with Apple) 第2弾:
        // .nameInput (@ユーザーID 入力) をフローから外し、オンボから入力欄を全廃する。
        //   - 表示名 → Apple が返した氏名を signInWithApple 内で自動採用
        //   - @handle → AppleSignInStepView でサインイン成功後に user_xxxxxxxx を自動発番
        // どちらも プロフィール編集 で後から変更できる (ProfileEditView に両方の編集UIあり)。
        // ⚠️ .nameInput を消しても「既にアカウントをお持ちですか?」の復帰導線は生きている
        //    (.feedPreview の FeedPreviewHookView にも同じ導線があるため)。
        // enum case と NameInputStepView はロールバック用に残置 (rawValue 順序も不変)。
        if step == .signature {
            step = .appleSignIn
            return
        }
        // 🔴 2026-08-06 審査リジェクト対応 (Guideline 5.6.3 Developer Code of Conduct):
        // 「オンボーディング中/初回起動時に評価を求めてはいけない。十分に使ってもらってから」。
        // .rating ステップを飛ばしてオンボを終える。enum case と RatingStepView は
        // ロールバック用に残置 (rawValue 順序も不変)。
        // 評価依頼は「ロックセッションを一定回数完遂した後」など、価値が伝わった後に
        // 出す形へ作り直すこと (ローンチ後の宿題)。
        // .appSelect の次は .rating ではなく .firstLock (rawValue の連番では届かない)。
        // 🔴 .rating は 5.6.3 対応で除外済みなので、ここで明示的に飛ばす
        if step == .appSelect {
            step = .firstLock
            return
        }
        if step == .firstLock {
            completeOnboarding()
            return
        }
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else {
            completeOnboarding()
            return
        }
        step = next
    }

    private func completeOnboarding() {
        // FamilyControls 権限が未取得のまま完了すると、App 側の表示条件
        // (hasCompletedOnboarding && isAuthorized && isSignedIn) を満たせず
        // 「ボタンを押しても何も起きない」詰みになる (2026-07-19 実機バグ)。権限取得へ差し戻す
        guard familyControlsService.isAuthorized else {
            isReturningUser = true  // 差し戻し後は短縮フロー (familyControls → rating → ...) で復帰
            step = .familyControls
            return
        }
        // クイズ pending の消費はオンボ完了時。push 成功済み (onboardingQuizPushed) の場合のみ
        // 消す — 失敗していた場合は残し、回答を無言で失わない
        let d = UserDefaults.standard
        if d.bool(forKey: "onboardingQuizPushed") {
            for key in ["onboardingBirthDate", "onboardingGender", "onboardingOccupation", "onboardingDailyHours",
                        "onboardingAddictionYears", "onboardingGoal", "onboardingReferralSource",
                        "onboardingQuizPushed", "onboardingPendingOwnerUserId"] {
                d.removeObject(forKey: key)
            }
        }
        // M8: MainTabView への切り替えを許可してから完了フラグを立てる
        // (先に hasCompletedOnboarding を true にすると、onboardingActive がまだ true の
        // 1フレームは意図通り MainTabView への切替を止めるが、順序を揃えておく方が安全)
        onboardingActive = false
        withAnimation(.easeInOut(duration: 0.3)) {
            hasCompletedOnboarding = true
        }
    }
}

// MARK: - 上部ナビ (戻る + 2px 進捗バー) 統一レイアウト

/// 全クイズ/診断ページ共通の上部ナビ。戻るボタンは常に 44pt の領域を確保し (非表示時も
/// 幅だけ残す)、進捗バーがボタンの有無で左右にジャンプしないようにする。
private struct OnboardingTopNav: View {
    let fraction: Double?
    let canGoBack: Bool
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(AppColors.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .opacity(canGoBack ? 1 : 0)
            .disabled(!canGoBack)

            if let fraction {
                QuizProgressBar(fraction: fraction)
                    .frame(height: 2)
            }
        }
        // バグ修正 (2026-07): 進捗バー (fraction != nil) がある画面では中の GeometryReader が
        // HStack を可変幅にし、結果として左寄せに "見えていた" だけだった。fraction が nil の
        // 画面 (例: moderationPolicy) では HStack がボタン分だけの固定幅に縮み、親の
        // ZStack(alignment: .top) に中央寄せされてチェブロンが中央に浮いて見えるバグになっていた。
        // 明示的に幅いっぱい + 左寄せにして、fraction の有無に関わらず常に左上固定にする。
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 4)
        .padding(.trailing, 24)
        .padding(.top, 16)
    }
}

private struct QuizProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(AppColors.textTertiary.opacity(0.25))
                Capsule()
                    .fill(AppColors.textPrimary)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 2)
        .animation(.spring(response: 0.5, dampingFraction: 0.9), value: fraction)
    }
}

// MARK: - 1. Splash

private struct SplashStepView: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(AppGradients.primary.opacity(0.2))
                    .frame(width: 140, height: 140)

                Image(systemName: "shield.checkered")
                    .font(.system(size: 60, weight: .medium))
                    .foregroundStyle(AppGradients.primary)
            }

            Text("1%")
                .font(AppTypography.largeTitle)
                .foregroundColor(AppColors.textPrimary)

            Text("スマホ依存から解放される")
                .font(AppTypography.title3)
                .foregroundColor(AppColors.textSecondary)

            Spacer()
        }
        .onAppear {
            // 1.5 秒後に自動で次へ
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                onContinue()
            }
        }
    }
}

// MARK: - 2. Value Proposition

private struct ValuePropositionStepView: View {
    let onContinue: () -> Void
    @State private var page: Int = 0
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    // 2026-07 再設計: 旧「名言アプリ」の語りを廃し、SNS + 規律ステータスの訴求に刷新
    private var pages: [ValuePage] {
        let jp = lang == .japanese
        return [
            ValuePage(
                imageName: "onboarding_value_1",
                systemFallback: "figure.run",
                title: jp ? "見せるのは、変化した姿だけ。" : "Only your progress belongs here.",
                description: jp
                    ? "進捗・食事・トレーニング・作業。\nあなたを高める投稿だけが流れる場所。"
                    : "Progress, meals, training, work —\nonly posts that sharpen you."
            ),
            ValuePage(
                imageName: "onboarding_value_2",
                systemFallback: "chart.line.uptrend.xyaxis",
                title: jp ? "規律は、可視化できる。" : "Discipline, made visible.",
                description: jp
                    ? "累計ロック時間と上位%がプロフィールに刻まれる。\n他のSNSには真似できないステータス。"
                    : "Your total locked time and top-% are carved\ninto your profile — a status no app can copy."
            ),
            ValuePage(
                imageName: "onboarding_value_3",
                systemFallback: "flame.fill",
                title: jp ? "Not for everyone." : "Not for everyone.",
                description: jp
                    ? "意志の弱い人のためのアプリじゃない。\n本気で変わる人だけ、進め。"
                    : "This isn't for the weak-willed.\nIf you're serious, continue."
            )
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                ForEach(pages.indices, id: \.self) { idx in
                    ValuePageView(page: pages[idx])
                        .tag(idx)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .always))

            PrimaryButton(
                page == pages.count - 1
                    ? (lang == .japanese ? "はじめる" : "Begin")
                    : (lang == .japanese ? "続ける" : "Continue"),
                icon: "arrow.right"
            ) {
                if page == pages.count - 1 {
                    onContinue()
                } else {
                    withAnimation { page += 1 }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }
}

private struct ValuePage {
    let imageName: String
    let systemFallback: String
    let title: String
    let description: String
}

private struct ValuePageView: View {
    let page: ValuePage

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // 画像スロット: Assets に同名画像があれば表示、無ければ SF Symbol で代用
            ZStack {
                if UIImage(named: page.imageName) != nil {
                    Image(page.imageName)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 280, maxHeight: 280)
                } else {
                    Circle()
                        .fill(AppGradients.primary.opacity(0.15))
                        .frame(width: 200, height: 200)
                    Image(systemName: page.systemFallback)
                        .font(.system(size: 90, weight: .light))
                        .foregroundStyle(AppGradients.primary)
                }
            }

            VStack(spacing: 16) {
                Text(page.title)
                    .font(AppTypography.title1)
                    .foregroundColor(AppColors.textPrimary)
                    .multilineTextAlignment(.center)

                Text(page.description)
                    .font(AppTypography.body)
                    .foregroundColor(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer()
        }
    }
}

// MARK: - 3. Dream (夢の宣言)

/// 2026-07 新設。「なりたい自分」を自由記述で宣言させる (サンクコスト/IKEA効果/目標設定)。
/// 旧 CommitmentStepView (指署名キャンバス、何もDB保存しない空の儀式) を置き換える。
/// ユーザー決定: 凝った署名儀式ではなく普通のテキスト入力。夢は @AppStorage に保持し、
/// サインイン成功後に AppleSignInStepView で users.dream へ push する (サインイン前は行に書けないため)。
/// 2026-07再設計: 入力必須化 (空では進めない) + 記入例チップで書き始めのハードルを下げる。
private struct DreamStepView: View {
    @Binding var dream: String
    @Binding var isPublic: Bool
    /// 診断クイズ Q6 の回答。プレースホルダー/例文チップの出し分けにのみ使う
    /// (2026-07-17 まで背景画像の敷き込みにも使っていたが、背景は真っ黒固定に変更)
    var goal: QuizGoal? = nil
    let onContinue: () -> Void

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    /// フィールドの外側 (背景の余白) をタップした時にキーボードを閉じるための共有フォーカス。
    /// DreamTextField 側の @FocusState をここへ引き上げ、親から false を書き込めるようにする。
    @FocusState private var isDreamFieldFocused: Bool

    private var trimmed: String {
        dream.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canContinue: Bool { !trimmed.isEmpty }

    private var placeholder: String {
        if let goal { return goal.dreamPlaceholder(lang) }
        return lang == .japanese
            ? "例: 痩せて自信を取り戻す / 独立して自分の力で稼ぐ"
            : "e.g. Get lean and reclaim my confidence"
    }

    /// 記入例チップ。タップでフィールドに反映され、そのまま自由編集できる
    private var exampleChips: [String] {
        lang == .japanese
            ? ["東京大学に合格する", "司法試験に合格する", "朝5時に起きて勉強する", "半年で体を変える"]
            : ["Get into University of Tokyo",
               "Pass the bar exam",
               "Wake at 5am to study",
               "Change my body in 6 months"]
    }

    var body: some View {
        ZStack {
            // 背景は真っ黒に固定 (2026-07-17 ユーザー指定)。以前は IdealFutureBackdrop を
            // 薄敷きしていたが、夢画像のデッキ化で背景のカードが動き続けてしまい
            // 宣言 (目標入力) の集中を削ぐため廃止。goal はプレースホルダー出し分けにのみ使う
            AppColors.background.ignoresSafeArea()

            // 背景の余白タップでキーボードを閉じる透明レイヤー。content の下に置くことで、
            // チップ/フィールド/トグル/ボタンなど content 自身の要素タップはそちらが優先して受け取り、
            // Spacer 等の空白部分だけこのレイヤーがタップを拾ってフォーカスを外す。
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { isDreamFieldFocused = false }

            content
        }
        // キーボード上部に「完了」を常設 (NameInput と同じ洗練挙動、2026-07-17 キーボードUX監査)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(lang == .japanese ? "完了" : "Done") {
                    isDreamFieldFocused = false
                }
                .foregroundColor(AppColors.textPrimary)
            }
        }
    }

    private var content: some View {
        VStack(spacing: 20) {
            Spacer().frame(height: 64)

            Text(lang == .japanese ? "あなたの目標をここに宣言してください" : "Put into words who you want to become.")
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            // 記入例チップ (タップでフィールドに反映、自由に編集できる)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(exampleChips, id: \.self) { example in
                        Button {
                            dream = example
                        } label: {
                            Text(example)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(AppColors.textSecondary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(Capsule().fill(AppColors.cardBackground))
                                .overlay(Capsule().stroke(AppColors.textTertiary.opacity(0.25), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
            }

            DreamTextField(text: $dream, placeholder: placeholder, isFocused: $isDreamFieldFocused)
                .padding(.horizontal, 24)

            // 公開トグル。夢が空のときは意味を持たないので無効化する
            Toggle(isOn: $isPublic) {
                Text(lang == .japanese ? "この目標をプロフィールに公開する" : "Show this goal on my profile")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(AppColors.textPrimary)
            }
            .tint(AppColors.textPrimary)
            .disabled(trimmed.isEmpty)
            .opacity(trimmed.isEmpty ? 0.4 : 1)
            .padding(.horizontal, 24)

            Spacer()

            PrimaryButton(
                lang == .japanese ? "刻む" : "Engrave",
                icon: "checkmark",
                isDisabled: !canContinue
            ) {
                onContinue()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }
}

/// 夢入力の TextField を独立子View に局所化 (実機パフォーマンス対策)。120字上限。自動フォーカス。
/// フォーカスは親 (DreamStepView) の @FocusState を FocusState.Binding で受け取る形に変更。
/// バグ修正 (2026-07): 以前は @FocusState がこの View にローカルに閉じており、親から
/// 「背景タップで閉じる」を実装できず、一度キーボードを開くと閉じる手段が無かった。
private struct DreamTextField: View {
    @Binding var text: String
    let placeholder: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .lineLimit(2...4)
            .font(.system(size: 17))
            .foregroundColor(AppColors.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(AppColors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(AppColors.accent.opacity(0.6), lineWidth: 1.2)
            )
            .autocorrectionDisabled()
            .focused(isFocused)
            .submitLabel(.done)
            .onSubmit { isFocused.wrappedValue = false }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    isFocused.wrappedValue = true
                }
            }
            .onChange(of: text) { _, newValue in
                var next = newValue
                // axis: .vertical の TextField は Return キーで改行が入り onSubmit が
                // 発火しないため、末尾の改行を「確定操作」として検知しフォーカスを外す
                if next.hasSuffix("\n") {
                    next.removeLast()
                    isFocused.wrappedValue = false
                }
                if next.count > 120 {
                    next = String(next.prefix(120))
                }
                if next != newValue {
                    text = next
                }
            }
    }
}

// MARK: - 3(旧). Commitment (Signature) — 未使用 (DreamStepView が置換。参照はされないが削除しない)

private struct CommitmentStepView: View {
    let onContinue: () -> Void

    @State private var paths: [Path] = []
    @State private var currentPath = Path()

    private var hasSignature: Bool { !paths.isEmpty || !currentPath.isEmpty }

    var body: some View {
        VStack(spacing: 24) {
            Spacer().frame(height: 60)

            VStack(spacing: 12) {
                Text("人生を変える準備はできていますか？")
                    .font(AppTypography.title2)
                    .foregroundColor(AppColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Text("ここに署名して、自分への約束を刻む")
                    .font(AppTypography.subheadline)
                    .foregroundColor(AppColors.textSecondary)
            }

            // 署名キャンバス
            ZStack(alignment: .bottomLeading) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(AppColors.cardBackground)
                    .frame(height: 220)

                Canvas { context, _ in
                    for path in paths {
                        context.stroke(path, with: .color(.white), lineWidth: 2.5)
                    }
                    context.stroke(currentPath, with: .color(.white), lineWidth: 2.5)
                }
                .frame(height: 220)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if currentPath.isEmpty {
                                currentPath.move(to: value.location)
                            } else {
                                currentPath.addLine(to: value.location)
                            }
                        }
                        .onEnded { _ in
                            paths.append(currentPath)
                            currentPath = Path()
                        }
                )

                // 下線（署名欄を示すライン）
                Rectangle()
                    .fill(AppColors.textTertiary.opacity(0.4))
                    .frame(height: 1)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 40)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 24)

            // クリアボタン
            if hasSignature {
                Button {
                    paths.removeAll()
                    currentPath = Path()
                } label: {
                    Text("やり直す")
                        .font(AppTypography.footnote)
                        .foregroundColor(AppColors.textTertiary)
                }
            }

            Spacer()

            PrimaryButton(
                "約束する",
                icon: "checkmark",
                isDisabled: !hasSignature
            ) {
                onContinue()
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }
}

// MARK: - 3.5. Name Input (S15)

/// 🔴 2026-08-06 審査リジェクト対応 (Guideline 4 Design / Sign in with Apple):
/// 「Authentication Services が名前を提供しているのに、ユーザーに名前を入力させている」と
/// 指摘されたため、**表示名の入力欄を撤去**しユーザーIDのみを決めるステップにした。
/// 表示名は UserAuthService.signInWithApple() が Apple の fullName から設定する。
/// ⚠️ ユーザーIDは Apple から取得できない情報なので、ここで聞くのは要件違反にならない。
private struct NameInputStepView: View {
    @Binding var handle: String
    let onContinue: () -> Void
    let onAlreadyHasAccount: () -> Void

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    @FocusState private var isFocused: Bool

    @State private var handleCheckState: OnboardingHandleCheckState = .idle
    @State private var handleCheckTask: Task<Void, Never>?

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    private var normalizedHandle: String {
        HandleValidator.normalized(handle)
    }

    private var handleFormatValid: Bool {
        !normalizedHandle.isEmpty && HandleValidator.isValidFormat(normalizedHandle)
    }

    /// ハンドルが有効フォーマット + サーバー可用性チェック済み (.available) の時のみ進める。
    /// (表示名の条件は 2026-08-06 に撤去 — Apple から受け取るため)
    private var canContinue: Bool {
        handleFormatValid && handleCheckState == .available
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 28) {
                    Spacer().frame(height: 24)

                    ZStack {
                        Circle()
                            .fill(AppGradients.primary.opacity(0.18))
                            .frame(width: 110, height: 110)

                        Image(systemName: "person.crop.circle.badge.plus")
                            .font(.system(size: 46, weight: .medium))
                            .foregroundStyle(AppGradients.primary)
                    }

                    VStack(spacing: 12) {
                        // 見出しは既存の文字列を流用 (ユーザーID / Username)。
                        // 🔴 文言はユーザー添削待ち — 「あなたの名前を教えてください」は
                        // 名前欄の撤去に伴い使えなくなったため差し替えた
                        Text(OnboardingHandleStrings.label(lang))
                            .font(AppTypography.title1)
                            .foregroundColor(AppColors.textPrimary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)

                        // 「投稿やプロフィールに表示されます。後から変更できます。」は
                        // ユーザーIDにもそのまま当てはまるので流用する
                        Text(L.onboardingNameSubtitle(lang))
                            .font(AppTypography.body)
                            .foregroundColor(AppColors.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        // 小見出しは撤去 (2026-08-06): 名前欄が無くなり、
                        // 大見出しが同じ「ユーザーID」になったため重複する
                        OnboardingHandleField(
                            text: $handle,
                            placeholder: OnboardingHandleStrings.placeholder(lang)
                        )

                        handleStatusView
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 16)
                // 余白タップでキーボードを閉じる (2026-07-17 キーボードUX監査。
                // TextField / ボタン自身のタップはそれぞれが先に消費するため干渉しない)
                .contentShape(Rectangle())
                .onTapGesture { NameInputStepView.dismissKeyboard() }
            }
            .frame(maxHeight: .infinity)
            // 下スワイプでもキーボードを閉じられるように (標準の洗練挙動)
            .scrollDismissesKeyboard(.interactively)
            // キーボード上部に「完了」を常設 (どのフィールドからでも閉じられる)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(lang == .japanese ? "完了" : "Done") {
                        NameInputStepView.dismissKeyboard()
                    }
                    .foregroundColor(AppColors.textPrimary)
                }
            }

            PrimaryButton(
                L.onboardingNameNext(lang),
                icon: "arrow.right",
                isDisabled: !canContinue
            ) {
                onContinue()
            }
            .padding(.horizontal, 24)

            // 既存アカウント向けリンク (NameInput をスキップしてサインインへ)
            // → 再オンボ時に AppStorage の古い名前で users.display_name を上書きしないためのフォールバック
            Button {
                onAlreadyHasAccount()
            } label: {
                Text(lang == .japanese
                     ? "既にアカウントをお持ちですか? サインイン"
                     : "Already have an account? Sign in")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(AppColors.textSecondary)
                    .underline()
            }
            .padding(.top, 16)
            .padding(.bottom, 40)
        }
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isFocused = true
            }
            // 未入力なら候補をプレフィル (ワンタップで進める逃げ道)。
            // 入力済みハンドルがあれば (再表示時など) 上書きしない。
            if HandleValidator.normalized(handle).isEmpty {
                handle = "user_" + UUID().uuidString.prefix(8).lowercased()
            }
            scheduleHandleCheck()
        }
        .onChange(of: handle) { _, _ in
            scheduleHandleCheck()
        }
    }

    /// フォーカス状態の所在に依存しない確実なキーボード閉じ
    /// (name / handle どちらのフィールドがアクティブでも効く)
    static func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    @ViewBuilder
    private var handleStatusView: some View {
        switch handleCheckState {
        case .idle:
            Text(OnboardingHandleStrings.hint(lang))
                .font(.system(size: 12))
                .foregroundColor(AppColors.textTertiary)
        case .checking:
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.7)
                Text(OnboardingHandleStrings.checking(lang))
                    .font(.system(size: 12))
                    .foregroundColor(AppColors.textTertiary)
            }
        case .available:
            Text(OnboardingHandleStrings.available(lang))
                .font(.system(size: 12))
                .foregroundColor(AppColors.success)
        case .unavailable:
            Text(OnboardingHandleStrings.unavailable(lang))
                .font(.system(size: 12))
                .foregroundColor(AppColors.error)
        case .error:
            // 通信エラーは「使用中」と区別してリトライ導線を出す
            // (オフライン/Supabase pause でオンボが「使用できません」のまま詰まらないように)
            Button {
                scheduleHandleCheck()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                    Text(OnboardingHandleStrings.checkFailed(lang))
                        .font(.system(size: 12))
                }
                .foregroundColor(AppColors.error)
            }
        case .invalid:
            Text(OnboardingHandleStrings.hint(lang))
                .font(.system(size: 12))
                .foregroundColor(AppColors.error)
        }
    }

    /// ハンドル入力を 400ms デバウンスして可用性チェック (ProfileEditView と同じ挙動)。
    private func scheduleHandleCheck() {
        handleCheckTask?.cancel()

        guard !normalizedHandle.isEmpty else {
            handleCheckState = .idle
            return
        }
        guard handleFormatValid else {
            handleCheckState = .invalid
            return
        }

        handleCheckState = .checking
        let candidate = normalizedHandle
        handleCheckTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            let result = await UserAuthService.shared.checkHandleAvailable(candidate)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard candidate == normalizedHandle else { return }
                switch result {
                case .available: handleCheckState = .available
                case .taken:     handleCheckState = .unavailable
                case .error:     handleCheckState = .error
                }
            }
        }
    }
}

// MARK: - Onboarding Name Field (TextField 局所化)

private struct OnboardingNameField: View {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .font(.system(size: 18))
            .foregroundColor(AppColors.textPrimary)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(AppColors.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(AppColors.textTertiary.opacity(0.3), lineWidth: 1)
            )
            .focused($isFocused)
            .submitLabel(.next)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .onSubmit(onSubmit)
    }
}

// MARK: - Onboarding Handle Field (TextField 局所化)

private struct OnboardingHandleField: View {
    @Binding var text: String
    let placeholder: String

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text("@")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(AppColors.textSecondary)

            TextField(placeholder, text: $text)
                .font(.system(size: 17))
                .foregroundColor(AppColors.textPrimary)
                .focused($isFocused)
                .submitLabel(.done)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppColors.textTertiary.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Onboarding Handle Check State

private enum OnboardingHandleCheckState: Equatable {
    case idle
    case checking
    case available
    case unavailable
    /// サーバー可用性チェックの通信エラー (使用中とは区別してリトライ導線を出す)
    case error
    case invalid
}

// MARK: - Onboarding Handle Strings (このファイル限定)

private enum OnboardingHandleStrings {
    static func label(_ lang: AppLanguage) -> String {
        lang == .japanese ? "ユーザーID" : "Username"
    }

    static func placeholder(_ lang: AppLanguage) -> String {
        "username"
    }

    static func hint(_ lang: AppLanguage) -> String {
        lang == .japanese
            ? "3〜20字の英小文字・数字・._"
            : "3-20 characters: lowercase letters, numbers, . _"
    }

    static func checking(_ lang: AppLanguage) -> String {
        lang == .japanese ? "確認中…" : "Checking…"
    }

    static func available(_ lang: AppLanguage) -> String {
        lang == .japanese ? "使用できます" : "Available"
    }

    static func unavailable(_ lang: AppLanguage) -> String {
        lang == .japanese ? "使用できません" : "Not available"
    }

    static func checkFailed(_ lang: AppLanguage) -> String {
        lang == .japanese ? "確認できませんでした。タップで再試行" : "Couldn't check. Tap to retry"
    }
}

// MARK: - 4. FamilyControls (StayLocked型 最小黒画面。2026-07 再設計で PHASE 1 = 診断より前に移動)

/// 権限プライミングの単独ページ。診断より前に来るため夢等のパーソナライズ材料はまだ無く、
/// 汎用の1文だけで完結させる (競合 StayLocked を参照: 黒背景 + 大きく平易な見出し + 明るいCTA1つ)。
/// システムの認証ダイアログは CTA タップ後にのみ発火する (service.requestAuthorization() 呼び出し時)。
private struct FamilyControlsStepView: View {
    @ObservedObject var service: AuthorizationService
    let onContinue: () -> Void

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    private var isDenied: Bool { service.authorizationStatus == .denied }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 16) {
                Text(lang == .japanese ? "アプリの使用に必須です" : "Required to use the app")
                    .font(.system(size: 30, weight: .semibold, design: .default))
                    .foregroundColor(AppColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)

                Text(lang == .japanese
                     ? "スクリーンタイムへのアクセスにより、アプリのロックと使用時間の計測ができます。"
                     : "Screen Time access lets the app lock other apps and measure your usage.")
                    .font(.system(size: 15))
                    .foregroundColor(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            VStack(spacing: 14) {
                // 失敗/拒否状態: プレーンなリトライ導線 (拒否済みの場合はOSの都合で再度ダイアログが
                // 出ないため、設定アプリへの導線を出す。既存の openSettingsURLString パターンを踏襲)
                if isDenied {
                    Text(lang == .japanese
                         ? "アクセスがまだ有効になっていません。設定から許可してください。"
                         : "Access isn't enabled yet. Please allow it in Settings.")
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.error)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                } else if let error = service.errorMessage {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundColor(AppColors.error)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                } else {
                    Text(lang == .japanese
                         ? "続けると Face ID の確認が表示されます"
                         : "You'll be asked to confirm with Face ID next")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textTertiary)
                }

                // CTA はオフホワイト1色 (競合のオレンジは踏襲しない)
                PrimaryButton(
                    service.isAuthorized
                        ? (lang == .japanese ? "次へ" : "Next")
                        : (lang == .japanese ? "許可する" : "Allow"),
                    isLoading: service.isAuthorizing
                ) {
                    if service.isAuthorized {
                        onContinue()
                    } else {
                        Task {
                            await service.requestAuthorization()
                            if service.isAuthorized {
                                onContinue()
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)

                if isDenied {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Text(lang == .japanese ? "設定を開く" : "Open Settings")
                            .font(.system(size: 14))
                            .foregroundColor(AppColors.textSecondary)
                            .underline()
                    }
                }
            }
            .padding(.bottom, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.background.ignoresSafeArea())
    }
}

// MARK: - 5. Apple Sign-In

private struct AppleSignInStepView: View {
    @ObservedObject var userAuth: UserAuthService
    /// 「すでにアカウントを持っている」経路なら見出しを「サインイン」に切り替える
    let isReturningUser: Bool
    let pendingDisplayName: String
    let pendingHandle: String
    let pendingDream: String
    let pendingDreamPublic: Bool
    let onContinue: () -> Void
    /// M23 (2026-07-22 監査): 「すでにアカウントを持っている」経路の誤タップから戻る導線。
    /// isReturningUser の時のみ表示するため、通常フローの呼び出し元では省略できる。
    var onCreateAccountInstead: (() -> Void)? = nil
    /// M23: isReturningUser のまま新規 Apple ID でサインインしてしまった (誤タップ) を検知した時の
    /// コールバック。全呼び出し元で必須の配線 (デフォルトなし)。
    var onDetectedNewAccount: () -> Void

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 120, height: 120)

                Image(systemName: "person.crop.circle.badge.checkmark")
                    .font(.system(size: 50, weight: .medium))
                    .foregroundStyle(AppGradients.primary)
            }

            VStack(spacing: 16) {
                // 文言はユーザー添削待ち (旧「あなたの記録と名言を保存します」は名言時代の残骸のため撤去)
                Text(isReturningUser
                     ? (lang == .japanese ? "サインイン" : "Sign in")
                     : (lang == .japanese ? "アカウントを作成" : "Create your account"))
                    .font(AppTypography.title1)
                    .foregroundColor(AppColors.textPrimary)

                Text(isReturningUser
                     ? (lang == .japanese
                        ? "Apple ID でサインインして、\nあなたの記録を引き継ぎます"
                        : "Sign in with Apple to\npick up where you left off")
                     : (lang == .japanese
                        ? "Apple ID でサインインして、\nあなたの記録を保存します"
                        : "Sign in with Apple to\nsave your progress"))
                    .font(AppTypography.body)
                    .foregroundColor(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer()

            if let error = userAuth.errorMessage {
                Text(error)
                    .font(AppTypography.footnote)
                    .foregroundColor(AppColors.error)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            // Apple 提供の SignInWithAppleButton (ASAuthorizationAppleIDButton)
            // 実際の認証フローは UserAuthService 側で ASAuthorizationController を使う
            Button {
                Task {
                    // M23: appleSignIn ステップに「既にサインイン済み」で再到達するケース
                    // (誤タップ→新規アカウント検知→新規オンボ完走→ここへ戻る) では、
                    // 二重サインインを避けて既存セッションのまま先へ進む
                    if !userAuth.isSignedIn {
                        await userAuth.signInWithApple()
                    }
                    guard userAuth.isSignedIn else { return }
                    // M23: 「すでにアカウントを持っている」経路のまま、未登録の新規 Apple ID で
                    // サインインしてしまった誤タップを検知。pending 永続化より前に early return し、
                    // 新規オンボ (13歳ゲート+診断) へ回す。
                    //
                    // 🔴 2026-08-06: 判定から display_name の条件を外した。
                    // 同日の リジェクト対応 第1弾 で「Apple が返した氏名を signInWithApple 内で
                    // 自動採用」するようにしたため、新規 Apple ID でも display_name が埋まるように
                    // なり、旧条件 (display_name と handle が両方空) が永久に成立しなくなっていた
                    // = 誤タップ検知が丸ごと死んでいた (1.0(3) 時点のバグ)。
                    // handle は Apple から取れず、アカウント作成時にしか付かないので、
                    // 「handle が空 = このアプリでまだアカウントを作っていない」が正しい判定になる。
                    if isReturningUser
                        && (userAuth.handle ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        onDetectedNewAccount()
                        return
                    }
                    // S15: オンボーディング nameInput で入力した名前を users.display_name に保存。
                    // ただし「再ログイン時に AppStorage の古い名前で上書き」しないよう、
                    // users.display_name が既に設定されている場合はスキップ (signInWithApple 内で
                    // refreshProfile が走っているので auth.displayName は最新の DB 値を反映済み)。
                    let trimmed = pendingDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let existing = userAuth.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !trimmed.isEmpty && existing.isEmpty {
                        _ = try? await userAuth.setDisplayName(trimmed)
                    }
                    // @handle も同様に、既存値が無い場合のみ設定する。
                    // 🔴 2026-08-06 リジェクト対応 第2弾: @ユーザーID の入力ステップ (.nameInput) を
                    // オンボから撤去したため、通常は pendingHandle が空で到達する。
                    // その場合はここで自動発番する — 撤去後は他に発番する場所が無い
                    // (旧発番点は NameInputStepView.onAppear のプレフィルだった)。
                    let normalizedHandle = HandleValidator.normalized(pendingHandle)
                    let existingHandle = userAuth.handle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let handleSaved: Bool
                    if !existingHandle.isEmpty {
                        handleSaved = true  // 既存値あり (再サインイン) — 触らない
                    } else if !normalizedHandle.isEmpty {
                        // 撤去前のオンボを途中まで進めていた端末など、入力済みの値があれば尊重する
                        handleSaved = await userAuth.updateHandle(normalizedHandle)
                    } else {
                        handleSaved = await Self.assignGeneratedHandle(userAuth)
                    }
                    // 🔴 2026-08-06: Apple が氏名を返さなかった場合の表示名フォールバック。
                    // Apple が fullName を返すのは「そのApple IDでこのアプリを初めて承認した時」
                    // だけで、2回目以降 (アカウントを消して作り直した等) は必ず nil。
                    // 名前欄を撤去した今のオンボでは display_name が永久に空のままになり、
                    // プロフィールが「未設定」+ ヒーローに「—」になる (2026-08-06 実機で確認)。
                    // 発番済みの @ユーザーID を初期値として入れて、空の状態を作らない。
                    // ⚠️ Apple が名前を返した場合は signInWithApple 内で先に保存されているので、
                    //    ここは空の時しか動かない = Apple の名前を上書きしない。
                    // ⚠️ handle より後に置くこと (handle が未発番だと入れる値が無い)。
                    let currentName = (userAuth.displayName ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let currentHandle = (userAuth.handle ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if currentName.isEmpty && !currentHandle.isEmpty {
                        _ = try? await userAuth.setDisplayName(currentHandle)
                    }
                    // 夢も同様に、既存値が無い場合のみオンボーディングで宣言した値を保存
                    // (サインイン前は users 行に書けないため、ここまで @AppStorage に保持していた)
                    let trimmedDream = pendingDream.trimmingCharacters(in: .whitespacesAndNewlines)
                    let existingDream = userAuth.dream?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let dreamSaved: Bool
                    if !trimmedDream.isEmpty && existingDream.isEmpty {
                        dreamSaved = await userAuth.updateDream(trimmedDream, isPublic: pendingDreamPublic)
                    } else {
                        dreamSaved = true
                    }
                    // Shield (案A) のサブタイトル用に App Group へミラー
                    AppGroupStorage.shared.saveUserDream(userAuth.dream)
                    // pending 値の消費は保存成功時のみ (次回オンボに古い値を持ち越さない)。
                    // 失敗時 (ユニーク衝突/マイグレーション未適用/通信断) に消すと
                    // 入力した夢・ハンドルが無言で失われる (2026-07-07 Fable レビュー指摘)
                    UserDefaults.standard.removeObject(forKey: "onboardingDisplayName")
                    if handleSaved {
                        UserDefaults.standard.removeObject(forKey: "onboardingHandle")
                    }
                    if dreamSaved {
                        UserDefaults.standard.removeObject(forKey: "onboardingDream")
                        UserDefaults.standard.removeObject(forKey: "onboardingDreamPublic")
                    }
                    // 診断クイズの回答を user_onboarding_profiles へ push (026 SQL)。
                    // pending の削除はここではしない — この後のプラン画面が回答を表示に使うため、
                    // 消費はオンボ完了時 (completeOnboarding) に行う。push 失敗時 (026 未適用/
                    // 通信断) はフラグを立てず、pending を残して回答を失わない
                    if let uid = userAuth.userId {
                        let d = UserDefaults.standard
                        // M22 (2026-07-20 監査): push 失敗のまま残った pending は、端末を共有した
                        // 別アカウントの次回サインインでそのまま upsert され、他人の生年月日等が
                        // 混入しうる。所有者刻印 (サインイン成功直後・push 前) を持たせ、現在の uid
                        // と食い違う場合は別アカウントの残骸とみなして push せず破棄する。
                        // 刻印が空 (初回 or 前回消費済み) or 現在の uid と一致する場合は通常どおり
                        // push する — 正常フロー (新規ユーザーが quiz→サインイン→push) は無変更
                        let owner = d.string(forKey: "onboardingPendingOwnerUserId") ?? ""
                        if !owner.isEmpty && owner != uid.uuidString {
                            for key in ["onboardingBirthDate", "onboardingGender", "onboardingOccupation",
                                        "onboardingDailyHours", "onboardingAddictionYears", "onboardingGoal",
                                        "onboardingReferralSource", "onboardingQuizPushed",
                                        "onboardingPendingOwnerUserId"] {
                                d.removeObject(forKey: key)
                            }
                            print("⚠️ [Onboarding] 別アカウントのクイズ pending を検知、push せず破棄 (owner=\(owner), current=\(uid))")
                        } else {
                            // UUID は plist 非対応型なので必ず uuidString で保存する (比較側も uuidString)
                            d.set(uid.uuidString, forKey: "onboardingPendingOwnerUserId")
                            let quizSaved = await OnboardingProfileService.push(
                                userId: uid,
                                birthDateRaw: d.string(forKey: "onboardingBirthDate") ?? "",
                                genderRaw: d.string(forKey: "onboardingGender") ?? "",
                                occupationRaw: d.string(forKey: "onboardingOccupation") ?? "",
                                dailyHoursRaw: d.string(forKey: "onboardingDailyHours") ?? "",
                                addictionYearsRaw: d.string(forKey: "onboardingAddictionYears") ?? "",
                                // Q5 (溶かしアプリ) は廃止。wasted_apps 列は残すが常に空 (NULL) を送る
                                wastedAppsRaw: "",
                                goalRaw: d.string(forKey: "onboardingGoal") ?? "",
                                referralSourceRaw: d.string(forKey: "onboardingReferralSource") ?? ""
                            )
                            d.set(quizSaved, forKey: "onboardingQuizPushed")
                        }
                    }
                    onContinue()
                }
            } label: {
                HStack(spacing: 8) {
                    if userAuth.isSigningIn {
                        ProgressView()
                            .tint(.black)
                    } else if !userAuth.isSignedIn {
                        Image(systemName: "applelogo")
                            .font(.system(size: 18, weight: .medium))
                    }
                    // M23: appleSignIn に「既にサインイン済み」で再到達した場合は Apple ロゴなしの
                    // 「続ける」に切り替える (Apple 認証 UI を再度見せる必要がないため)
                    Text(userAuth.isSignedIn
                         ? (lang == .japanese ? "続ける" : "Continue") // 文言はユーザー添削待ち
                         : (lang == .japanese ? "Apple でサインイン" : "Sign in with Apple"))
                        .font(.system(size: 17, weight: .semibold))
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(userAuth.isSigningIn)
            .padding(.horizontal, 24)

            // 画面下部のクラスタ (2026-07-31 実機FB「下がダサい」→ 作り直し)。
            // 旧: 下線付きの「アカウントを作成する」+ 同意文 + その下に同じ語をもう一度並べた
            //     下線リンク行 (利用規約/プライバシーポリシーが画面内に2回出る二段構成)。
            // 新: ①リンクは同意文の中にインラインで1回だけ ②下線を全廃 ③2要素の間隔を
            //     32→16 に詰めて「下部の締め」として1つの塊に見せる
            VStack(spacing: 16) {
                // M23: 「すでにアカウントを持っている」経路の誤タップから戻れるようにする導線
                if isReturningUser {
                    Button {
                        onCreateAccountInstead?()
                    } label: {
                        HStack(spacing: 5) {
                            Text(lang == .japanese ? "アカウントをお持ちでない方は" : "Don't have an account?") // 文言はユーザー添削待ち
                                .foregroundColor(AppColors.textTertiary)
                            Text(lang == .japanese ? "新規作成" : "Create one") // 文言はユーザー添削待ち
                                .fontWeight(.semibold)
                                .foregroundColor(AppColors.textPrimary)
                        }
                        .font(.system(size: 13))
                    }
                }

                // M6/M15 (2026-07-22 監査): 規約同意の定番文言。
                // 2026-07-31: 文中インラインリンク (Markdown) に統合。tint がリンク色になる
                Text(consentText)
                    .font(.system(size: 11))
                    .foregroundColor(AppColors.textTertiary)
                    .tint(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .padding(.horizontal, 32)
            }
            .padding(.bottom, 40)
        }
    }

    /// @ユーザーID の自動発番 (2026-08-06 リジェクト対応 第2弾)。
    /// オンボから入力ステップを撤去したため、アカウント作成時にここで一意な handle を確定させる。
    /// 形式は `user_` + UUID 先頭8桁 (例 `user_a3f9b2c1`) — 13文字で `^[a-z0-9._]{3,20}$` を満たし、
    /// 予約語とも衝突しない。
    ///
    /// ⚠️ `updateHandle` は失敗理由を返さない (ユニーク衝突も通信断も false) ため、
    /// 別候補で数回リトライして衝突だけを吸収する。全部落ちた場合は handle 未設定のまま先へ進む
    /// (users.handle は NULL 許容。本人が プロフィール編集 → ユーザーID で後から付けられる)。
    private static func assignGeneratedHandle(_ userAuth: UserAuthService) async -> Bool {
        for _ in 0..<3 {
            let candidate = "user_" + UUID().uuidString.prefix(8).lowercased()
            if await userAuth.updateHandle(candidate) { return true }
        }
        print("⚠️ [Onboarding] @ユーザーID の自動発番に失敗。プロフィール編集で設定してもらう")
        return false
    }

    /// 同意文。利用規約/プライバシーポリシーを文中のリンクにする (別行に並べない)。
    /// Markdown の解釈に失敗した場合はリンク無しのプレーン文へフォールバックする
    private var consentText: AttributedString {
        let markdown = lang == .japanese
            ? "続行すると、[利用規約](\(LegalLinks.termsURL))と[プライバシーポリシー](\(LegalLinks.privacyURL))に同意したものとみなされます" // 文言はユーザー添削待ち
            : "By continuing, you agree to the [Terms of Service](\(LegalLinks.termsURL)) and [Privacy Policy](\(LegalLinks.privacyURL))"
        if let attributed = try? AttributedString(markdown: markdown) {
            return attributed
        }
        return AttributedString(lang == .japanese
            ? "続行すると、利用規約とプライバシーポリシーに同意したものとみなされます"
            : "By continuing, you agree to the Terms of Service and Privacy Policy")
    }
}

// MARK: - 6. Rating (App Store 評価リクエスト、2026-07-19 新設)

/// サインイン直後 (新規/返却ユーザー両経路が必ず通る位置) に App Store 評価を依頼するページ。
/// 表示から少し置いて OS 標準の評価ダイアログ (requestReview) を出す。OS 側のスロットリングで
/// ダイアログが出ないことがあるため、ページ自体は「続ける」でいつでも先へ進める。
/// 2026-07-31 実機FB「もうちょっとかっこよく」対応。足したのは3つだけ:
///   1. 背景をヒーロー/公式プロフィールと同じ動く煙にしてブランドの面に乗せる
///   2. 星の後ろに金のごく淡いグロウ (色を足すのでなく、光を1枚敷く)
///   3. 星が左から順に灯る (0.09秒差のスケール+フェード。跳ね返り・回転・光沢は不使用)
/// 却下済みの文法 (描き起こし/バウンス/シマー) には触れない。ReduceMotion では即点灯
private struct RatingStepView: View {
    let lang: AppLanguage
    let onContinue: () -> Void

    @Environment(\.requestReview) private var requestReview
    @State private var starsLit = 0
    @State private var contentIn = false

    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    /// 評価の星。SF Symbol (平板) → 絵文字 (「絵文字はダサい」) と2回却下されたため、
    /// 実素材に差し替え: Microsoft Fluent Emoji の 3D 星 (MIT ライセンス、商用可。
    /// 出典と条文は Docs/third_party_licenses.md)。差し替えたい時は RatingStar.imageset の
    /// 画像を置き換えるだけでよい (コード変更不要)。素材が無い環境では絵文字にフォールバック
    @ViewBuilder
    private var ratingStar: some View {
        if UIImage(named: "RatingStar") != nil {
            Image("RatingStar")
                .resizable()
                .scaledToFit()
                // 素材自体が上下左右 6% ずつ余白を持つため、見た目を揃えるぶん大きめに取る
                .frame(width: 40, height: 40)
        } else {
            Text("⭐️")
                .font(.system(size: 30))
        }
    }

    var body: some View {
        ZStack {
            SmokeBackdrop().ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // アプリアイコン (角丸くり抜き) を星の上に (2026-07-19 ユーザー指定)
                Image("OnePercentIcon")
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 15)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .padding(.bottom, 22)

                HStack(spacing: 8) {
                    ForEach(0..<5, id: \.self) { i in
                        ratingStar
                            .scaleEffect(i < starsLit ? 1 : 0.72)
                            .opacity(i < starsLit ? 1 : 0)
                    }
                }

                // 文言はユーザー添削待ち
                Text(lang == .japanese ? "1% の評価をお願いします" : "Rate 1% on the App Store")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(AppColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 28)

                // 文言はユーザー添削待ち
                Text(lang == .japanese
                     ? "あなたの評価が、1% を続ける力になります。"
                     : "Your rating keeps 1% going.")
                    .font(.system(size: 14))
                    .foregroundColor(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)

                Spacer()

                PrimaryButton(lang == .japanese ? "続ける" : "Continue", icon: "arrow.right") {
                    onContinue()
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
            // 画面全体はボケ→結像 (ヒーローと同じ登場の文法)
            .blur(radius: contentIn ? 0 : 6)
            .opacity(contentIn ? 1 : 0)
        }
        .task {
            guard !reduceMotion else {
                contentIn = true
                starsLit = 5
                try? await Task.sleep(nanoseconds: 800_000_000)
                requestReview()
                return
            }
            withAnimation(.easeOut(duration: 0.45)) { contentIn = true }
            // 星を左から順に灯す
            for i in 1...5 {
                try? await Task.sleep(nanoseconds: 90_000_000)
                withAnimation(.easeOut(duration: 0.22)) { starsLit = i }
            }
            // ページの意図が伝わってからダイアログを出す (表示直後だと文脈なく被さる)
            try? await Task.sleep(nanoseconds: 700_000_000)
            requestReview()
        }
    }
}

// MARK: - 7. App Select (初期セットアップ 2026-07-15)

/// オンボ末尾: 最初にロックするアプリを選ばせる。選択は 3 モード共通の初期値として保存
/// (BlockingService.saveInitialSharedSelection)。以後は各モード画面で個別に変更できる。
/// FamilyControls 権限はオンボ前半 (.familyControls) で取得済みの前提
private struct AppSelectStepView: View {
    let lang: AppLanguage
    let onFinish: () -> Void

    @State private var selection = FamilyActivitySelection()
    @State private var showPicker = false
    /// L18 (2026-07-22 監査): ピッカーを開いた瞬間の選択状態を退避しておく。閉じた時に
    /// これと差分が無ければ「キャンセル相当」とみなし、保存も次画面への前進もしない
    /// (何も選ばず/変えずに閉じただけで誤って先へ進んでしまうのを防ぐ)
    @State private var selectionAtPickerOpen = FamilyActivitySelection()

    private var totalCount: Int {
        selection.applicationTokens.count + selection.categoryTokens.count
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // 文言はユーザー添削待ち
            Text(lang == .japanese ? "最初にロックする\nアプリを選ぶ" : "Choose the first apps\nto lock")
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(AppColors.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // 文言はユーザー添削待ち
            Text(lang == .japanese
                 ? "いつでも変更できます。\nまずは一番時間を奪っているものから。"
                 : "You can change this anytime.\nStart with what eats the most time.")
                .font(.system(size: 13))
                .foregroundColor(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.top, 14)

            if totalCount > 0 {
                Text(lang == .japanese ? "\(totalCount)個を選択中" : "\(totalCount) selected") // 文言はユーザー添削待ち
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(AppColors.textPrimary)
                    .padding(.top, 20)
            }

            Spacer()

            VStack(spacing: 12) {
                PrimaryButton(
                    totalCount > 0
                        ? (lang == .japanese ? "この選択で始める" : "Start with these") // 文言はユーザー添削待ち
                        : (lang == .japanese ? "アプリを選択" : "Select apps") // 文言はユーザー添削待ち
                ) {
                    if totalCount > 0 {
                        BlockingService.shared.saveInitialSharedSelection(selection)
                        onFinish()
                    } else {
                        // L18: 差分検知の基準として、開く直前の選択状態を退避
                        selectionAtPickerOpen = selection
                        showPicker = true
                    }
                }

                Button(lang == .japanese ? "あとで選ぶ" : "Later") { // 文言はユーザー添削待ち
                    onFinish()
                }
                .font(AppTypography.footnote)
                .foregroundColor(AppColors.textTertiary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .familyActivityPicker(isPresented: $showPicker, selection: $selection)
        // ピッカーの右上チェックで閉じた瞬間、選択があればそのまま次へ進む
        // (「チェック→さらに下のボタン」の二度手間を廃止、2026-07-19 ユーザーFB)
        .onChange(of: showPicker) { _, isPresented in
            // L18: 開いた時点の選択 (selectionAtPickerOpen) と差分が無ければキャンセル相当
            // (何も選ばず/変えずに閉じた) とみなし、保存も次画面への前進もしない
            if !isPresented && totalCount > 0 && selection != selectionAtPickerOpen {
                BlockingService.shared.saveInitialSharedSelection(selection)
                onFinish()
            }
        }
    }
}

// MARK: - Preview

#Preview {
    OnboardingView(hasCompletedOnboarding: .constant(false), onboardingActive: .constant(false))
}
