//
//  OnboardingView.swift
//  AppBlocker
//
//  Onboarding flow (2026-07-08 fully redesigned as a diagnostic quiz, follows design doc v3):
//  Splash (monogram) → feed preview → 6 diagnostic quiz questions + 2 shock beats + ideal future
//  → Dream → NameInput → AppleSignIn → FamilyControls → plan generation → Paywall → MainTab
//
//  Design principles:
//   - Cal AI / Opal style "make them diagnose, make them invest" structure. Every question must connect
//     to at least one of: the shock scene, the plan, or future paywall copy (no question without a use)
//   - The shock is in the past tense ("already lost"). Years of addiction × hours per day → total loss
//     → a shopping cart of qualifications
//   - Order of FamilyControls and AppleSignIn: sign-in (small ask) → Screen Time permission
//     (big ask), foot-in-the-door. Permission is always granted before the paywall
//   - Quiz answers are kept in @AppStorage → pushed to user_onboarding_profiles after sign-in
//     (pending values are consumed only on success)
//

import SwiftUI
import AuthenticationServices
import StoreKit
import FamilyControls

// MARK: - Referral source (added 2026-07-17)

/// "Where did you hear about 1%?". rawValue must match the values in 036_referral_source.sql.
/// Defined in this file because OnboardingQuiz.swift is being edited by another agent
/// (QuizSingleChoiceStepView only requires Option: RawRepresentable & CaseIterable & Hashable,
/// RawValue == String)
enum QuizReferralSource: String, CaseIterable {
    // Display order = allCases (declaration order). On 2026-07-25 the user asked to move
    // "友達・知人" ("Friends or family") below App Store.
    // rawValue must match 036_referral_source.sql (changing the order does not change the DB values)
    case tiktok    = "tiktok"
    case instagram = "instagram"
    case youtube   = "youtube"
    case appStore  = "app_store"
    case friend    = "friend"
    case other     = "other"

    func label(_ lang: AppLanguage) -> String {
        let jp = lang == .japanese
        switch self {
        case .tiktok:    return "TikTok" // Copy waiting for user review
        case .instagram: return "Instagram" // Copy waiting for user review
        case .youtube:   return "YouTube" // Copy waiting for user review
        case .friend:    return jp ? "友達・知人" : "Friends or family" // Copy waiting for user review
        case .appStore:  return "App Store" // Reviewed by the user on 2026-07-17 (removed "で見つけた" ("found on"))
        case .other:     return jp ? "その他" : "Other" // Copy waiting for user review
        }
    }

    // Real brand icon at the start of the row (Assets/ReferralIcons. On 2026-07-25 real-device feedback
    // rejected the SF Symbols substitute, so they were restored from git history 13bb33b).
    // TikTok/Instagram/YouTube use the real app icons, App Store uses official Apple material
    var iconAsset: String? {
        switch self {
        case .tiktok:    return "referral-tiktok"
        case .instagram: return "referral-instagram"
        case .youtube:   return "referral-youtube"
        case .appStore:  return "referral-appstore"
        case .friend, .other: return nil
        }
    }

    /// SF Symbol for options that have no brand icon
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
    // PHASE 0: hook
    case splash
    case feedPreview
    // Referral source (added 2026-07-17): "where did you hear about us" is asked right after the feed
    // preview, when the memory is freshest. Used to measure the share of users coming from TikTok ads
    // (036 SQL)
    case referralSource
    case moderationPolicy
    // PHASE 1: permission priming (moved before the diagnosis in the 2026-07 redesign.
    // Screen Time is handled first, as a standalone page saying it is "required to use the app")
    case familyControls
    // PHASE 2: diagnosis
    case quizBirthDate
    case quizGender
    // quizOccupation (current status) was removed by user decision on 2026-07-19. The occupation argument
    // of QuizLossReport.build was never used, so there are zero side effects.
    // user_onboarding_profiles.occupation becomes NULL
    case quizDailyHours
    case usageReveal
    // quizAddictionYears / shockAchievements were dropped with user approval on 2026-07-17
    // (the past total of "current hours per day × years of addiction" was mathematically far-fetched.
    // shockLoss is now only the projection to age 80)
    case shockLoss
    case recovery
    // 🔴 Added 2026-08-06: show the 3 lock modes on one page.
    // Onboarding only talked about "why you should quit" and reached the paywall without ever showing what
    // this app does (= it was selling without showing what it sells).
    // Placement is right after "shock → resolve", so the means come right after
    // "覚悟はできていますか?" ("Are you ready?").
    // ⚠️ step is a @State and is not persisted, so the rawValue shift from inserting a case here is harmless
    case lockModes
    // quizGoal ("What will you achieve with the time you get back?", 6 choices) was removed by user
    // decision on 2026-07-19, because it effectively duplicates the goal declaration (dream).
    // The answer is stored as NULL in user_onboarding_profiles.goal
    case idealFuture
    // PHASE 3: declaration (existing assets)
    case dream
    // Signature (added 2026-07-17): have the user sign the declared goal with a finger to lock in the
    // commitment again
    case signature
    case nameInput
    case appleSignIn
    // PHASE 4: straight to the paywall (2026-07-19 user decision: "plan building" does not fit this app,
    // so .plan is excluded. There is an idea to rebuild it later as a "schedule suggestion → edit →
    // enabling it requires Pro" page)
    case paywall
    // PHASE 5: initial setup (added 2026-07-15): have the user choose the first apps to lock, and save them
    // as the shared initial value for all 3 modes (while the "top 3" shown in the diagnosis is still fresh
    // in memory)
    case appSelect
    // PHASE 6: App Store rating (new on 2026-07-19. The user specified the timing as "last")
    case rating
    // PHASE 7: make the user start the first lock right there (new on 2026-09-05).
    // 🔴 Add it at the end of the enum. Inserting it in the middle shifts the rawValue of every existing
    //    case and breaks the sequential numbering in advance()/retreat() and progressFraction
    case firstLock

    /// Steps that remain in the enum but are not part of the flow.
    /// If they are not removed from the progress bar denominator, the bar appears to jump by the skipped
    /// amount.
    /// (The cases are not deleted so they can be restored with one line at any time)
    static let excludedFromFlow: Set<OnboardingStep> = [
        .quizGender,  // Removed 2026-08-06. It was collected but never read anywhere in the app
        .nameInput,   // Removed 2026-08-06. All input fields were removed to address Guideline 4
        .rating       // Removed 2026-08-06. Guideline 5.6.3 forbids rating requests during onboarding
    ]

    /// Progress of the 2px progress bar at the top (0→1 from quiz start to sign-in). nil for steps not
    /// covered. Counts only the steps actually passed through (not the rawValue sequence)
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
    /// M8 (2026-07-22 audit): true while OnboardingView is on screen. Used in the root condition of
    /// AppBlockerApp so that the app does not switch to MainTabView right after re-sign-in even if the
    /// conditions are met (while the returning-user flow is running).
    @Binding var onboardingActive: Bool

    // On 2026-07-29 the splash (engraving animation) was removed on user instruction, and the flow now
    // starts from the ARISE-style hero.
    // The .splash enum case and MonogramSplashView are kept for rollback (rawValue order is unchanged too)
    @State private var step: OnboardingStep = .feedPreview
    /// L17 (2026-07-20 audit): whether the most recent transition was "back" (retreat). Used to tell forward
    /// (advance) from backward (retreat) when ShockLossStepView skips immediately in onAppear for age 80+
    @State private var lastMoveWasBack = false

    /// Whether this is the "I already have an account" path. While true, advance() uses a short flow that
    /// skips the diagnostic quiz, plan, etc. (appleSignIn → familyControls → rating → paywall → appSelect).
    /// Root cause of the 2026-07-19 real-device bug: in the old implementation this path never went through
    /// familyControls, so the display condition on completion (isAuthorized) was never met, and appSelect
    /// did nothing (stuck)
    @State private var isReturningUser = false
    /// M23 (2026-07-22 audit): the step to return to on the path where "I already have an account" was
    /// tapped by mistake (whether the user came from feedPreview or nameInput). Used by the
    /// "アカウントを作成する" ("Create account") link in AppleSignInStepView to go back to the screen before
    /// the mistaken tap.
    @State private var returningEntryStep: OnboardingStep?
    /// L7 (2026-07-22 audit): flag that sends users whose Screen Time permission alone was revoked later
    /// (hasCompletedOnboarding=true, isSignedIn=true, isAuthorized=false) through a short path with only
    /// familyControls, instead of full re-onboarding + Apple re-sign-in
    @State private var isPermissionRecovery = false

    // pending values for PHASE 2 (same as before)
    @AppStorage("onboardingDisplayName") private var pendingDisplayName: String = ""
    @AppStorage("onboardingHandle") private var pendingHandle: String = ""
    @AppStorage("onboardingDream") private var pendingDream: String = ""
    // Default is public ON (2026-07-19 user spec: the profile public toggle is on by default, tap to turn
    // it off)
    @AppStorage("onboardingDreamPublic") private var pendingDreamPublic: Bool = true

    // pending values of the diagnostic quiz (raw values. Pushed to user_onboarding_profiles after sign-in)
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

            // Pre-warming the usage report (2026-07-25): while the user enters birth date/gender (steps where the
            // user spends time), warm up the extension process + query in the background so that usageReveal shows
            // real measured data from the first try.
            // Limited to steps after familyControls (permission grant). Not done on quizDailyHours
            // (so it never coexists with the usageReveal report during the transition, to avoid the
            // "second report is blank" bug)
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
                            // M23: record the step before the transition so the user can go back from the mistaken-tap path
                            returningEntryStep = step
                            isReturningUser = true
                            step = .appleSignIn
                        }
                    )
                case .referralSource:
                    QuizSingleChoiceStepView<QuizReferralSource>(
                        question: lang == .japanese ? "1%をどこで知りましたか?" : "Where did you hear about 1%?", // Copy waiting for user review
                        labelProvider: { $0.label(lang) },
                        // 2026-07-25: reintroduced the real brand icons (the SF Symbols substitute was rejected in real-device
                        // feedback)
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
                        question: lang == .japanese ? "性別を教えてください" : "How do you identify?", // Copy waiting for user review
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
                        // L17: when the user comes back here with "back", the auto-skip for age 80+ goes backward to
                        // usageReveal instead of forward (otherwise the user gets stuck, unable to go back past recovery)
                        onAutoSkipBack: shockLossAutoSkipBack
                    )
                case .recovery:
                    RecoveryStepView(onContinue: advance)
                case .lockModes:
                    // After "覚悟はできていますか?" ("Are you ready?"), show the means to do it (3 modes) (2026-08-06)
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
                        // The display name comes from Apple, so it is not handled here (2026-08-06)
                        handle: $pendingHandle,
                        onContinue: advance,
                        onAlreadyHasAccount: {
                            // M23: record the step before the transition so the user can go back from the mistaken-tap path
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
                        // M23: if the user came here by a mistaken tap, return to the original screen
                        onCreateAccountInstead: {
                            isReturningUser = false
                            step = returningEntryStep ?? .feedPreview
                        },
                        // M23: if the user signs in with a new Apple ID while still on the "I already have an account" path,
                        // send them to the new-user onboarding (age 13 gate + diagnosis + name input)
                        onDetectedNewAccount: {
                            isReturningUser = false
                            step = .quizBirthDate
                        }
                    )
                case .paywall:
                    // Real paywall (RevenueCat fully wired). Close / later / purchase success all call onClose → advance,
                    // and onboarding moves on (the old PaywallPlaceholderStepView was removed)
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
            // Asymmetric slide: the new screen enters from the right by 24pt + fade, the old screen moves 8pt left
            .transition(.asymmetric(
                insertion: .offset(x: 24).combined(with: .opacity),
                removal: .offset(x: -8).combined(with: .opacity)
            ))

            // Top nav (back + 2px progress bar). Shown only from the diagnosis phase to the plan.
            // The back button and progress bar are combined into one HStack so they always have the same height
            // and spacing (before, they were separate overlays with padding.top of 8 and 2, which looked cramped)
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
            // M8: do not allow switching to MainTabView while OnboardingView is shown
            onboardingActive = true
            // L7 (detection a): routing when a user who completed onboarding and is signed in is on this screen
            if hasCompletedOnboarding && userAuth.isSignedIn {
                routeCompletedSignedInUser()
            }
        }
        .onChange(of: userAuth.isSignedIn) { _, signedIn in
            // L7 (detection b): right after launch, restoreSession() may not have finished and isSignedIn stays
            // false, so the onAppear above cannot detect it. Only catch it here if signedIn becomes true while
            // still on splash/feedPreview (if the user is on a later step, they already chose another path such as
            // new-user onboarding or returning user, so do not override it)
            if signedIn && hasCompletedOnboarding && (step == .splash || step == .feedPreview) {
                routeCompletedSignedInUser()
            }
        }
    }

    /// L7/M8 (2026-07-22 Fable review fix): routing when a user who completed onboarding and is signed in is
    /// on OnboardingView.
    /// - If the permission is still valid, call completeOnboarding() right away and go to MainTabView.
    ///   isSignedIn starts as false on every launch and is restored by restoreSession(), so even a normal
    ///   launch shows OnboardingView (splash) for a moment. Since M8's onboardingActive now stops the
    ///   automatic root switch, without this immediate completion there would be a regression where the user
    ///   has to tap "次へ" ("Next") on the familyControls screen on every launch (old behavior = the root
    ///   switched to MainTabView automatically as soon as the restore finished).
    /// - Only if the permission has expired does it enter the familyControls short path (the real L7
    ///   recovery).
    private func routeCompletedSignedInUser() {
        if familyControlsService.isAuthorized {
            completeOnboarding()
        } else {
            isPermissionRecovery = true
            step = .familyControls
        }
    }

    /// Whether the user can go back from this step. Not allowed on splash/feedPreview, or from
    /// authentication (which has side effects) through the plan and later
    private var canGoBack: Bool {
        switch step {
        case .splash, .feedPreview, .appleSignIn, .familyControls, .paywall, .appSelect, .rating, .firstLock:
            return false
        default:
            return true
        }
    }

    /// L17: direction-aware callback passed to the age-80+ auto-skip of shockLoss. If the latest move was
    /// "back", return retreat (go backward). Otherwise (normal forward arrival) return nil and fall back to
    /// onContinue
    private var shockLossAutoSkipBack: (() -> Void)? {
        if lastMoveWasBack {
            return { retreat() }
        }
        return nil
    }

    private func retreat() {
        lastMoveWasBack = true
        // 🔴 2026-08-06: .quizGender, which advance skips, is also skipped when going back.
        // Without this, "back" lands on a screen that is outside the flow
        if step == .quizDailyHours {
            step = .quizBirthDate
            return
        }
        guard let prev = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        step = prev
    }

    // MARK: - Derived values of the diagnosis

    /// Total past loss report (from Q1 age + Q3 hours + Q4 years + Q2 status)
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

    /// "5 hours a day × 4 years" etc. (breakdown shown in the first shock beat)
    private var hoursLabel: String {
        let h = QuizDailyHours(rawValue: pendingDailyHours) ?? .h4to6
        let y = QuizAddictionYears(rawValue: pendingAddictionYears) ?? .y3to5
        return lang == .japanese
            ? "1日\(h.label(lang)) × \(y.label(lang))"
            : "\(h.label(lang))/day × \(y.label(lang))"
    }

    private func advance() {
        lastMoveWasBack = false
        // L7: short path for permission recovery. Once familyControls is passed (= permission granted again),
        // finish onboarding immediately
        if isPermissionRecovery && step == .familyControls {
            completeOnboarding()
            return
        }
        // Short flow for returning users (who already have an account).
        // The diagnostic quiz and plan building are skipped on the assumption that the first diagnosis was
        // already done, and only permission (only if not granted) → rating → paywall → app selection is shown
        if isReturningUser {
            switch step {
            case .appleSignIn:
                step = familyControlsService.isAuthorized ? .paywall : .familyControls
                return
            case .familyControls:
                step = .paywall
                return
            default:
                break  // After paywall (appSelect → rating → done) it is the same as the normal sequence
            }
        }
        // 🔴 2026-08-06 user decision: remove the gender question (.quizGender) from the flow.
        // It was collected and saved to user_onboarding_profiles.gender, but never read anywhere in the app
        // (the same situation as "status" and "goal", which were already removed).
        // The enum case and QuizGender are kept for rollback. ⚠️ The same branch is also needed on the retreat
        // side
        if step == .quizBirthDate {
            step = .quizDailyHours
            return
        }
        // 🔴 2026-08-06 App Review rejection fix (Guideline 4 / Sign in with Apple), part 2:
        // remove .nameInput (@user ID input) from the flow, removing every input field from onboarding.
        //   - Display name → the name returned by Apple is adopted automatically inside signInWithApple
        //   - @handle → user_xxxxxxxx is issued automatically after sign-in succeeds in AppleSignInStepView
        // Both can be changed later in profile editing (ProfileEditView has edit UI for both).
        // ⚠️ Even with .nameInput removed, the "既にアカウントをお持ちですか?" ("Already have an account?")
        //    return link still works (FeedPreviewHookView in .feedPreview has the same link).
        // The enum case and NameInputStepView are kept for rollback (rawValue order is unchanged too).
        if step == .signature {
            step = .appleSignIn
            return
        }
        // 🔴 2026-08-06 App Review rejection fix (Guideline 5.6.3 Developer Code of Conduct):
        // "Do not ask for a rating during onboarding / at first launch. Wait until the app has been used
        // enough." Finish onboarding by skipping the .rating step. The enum case and RatingStepView are kept
        // for rollback (rawValue order is unchanged too).
        // Rebuild the rating request so it appears after the value is clear, for example "after completing a
        // lock session a certain number of times" (post-launch homework).
        // After .appSelect comes .firstLock, not .rating (the rawValue sequence does not reach it).
        // 🔴 .rating is already excluded for 5.6.3, so skip it explicitly here
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
        // If onboarding completes without FamilyControls permission, the app-side display condition
        // (hasCompletedOnboarding && isAuthorized && isSignedIn) is never met, and the user gets stuck with
        // "nothing happens when I press the button" (2026-07-19 real-device bug). Send them back to get the
        // permission
        guard familyControlsService.isAuthorized else {
            isReturningUser = true  // After being sent back, recover through the short flow (familyControls → rating → ...)
            step = .familyControls
            return
        }
        // Quiz pending values are consumed when onboarding completes. Delete them only if the push already
        // succeeded (onboardingQuizPushed). If it failed, keep them so the answers are not silently lost
        let d = UserDefaults.standard
        if d.bool(forKey: "onboardingQuizPushed") {
            for key in ["onboardingBirthDate", "onboardingGender", "onboardingOccupation", "onboardingDailyHours",
                        "onboardingAddictionYears", "onboardingGoal", "onboardingReferralSource",
                        "onboardingQuizPushed", "onboardingPendingOwnerUserId"] {
                d.removeObject(forKey: key)
            }
        }
        // M8: allow switching to MainTabView first, then set the completion flag
        // (if hasCompletedOnboarding were set to true first, the one frame where onboardingActive is still true
        // would block the switch to MainTabView as intended, but keeping this order is safer)
        onboardingActive = false
        withAnimation(.easeInOut(duration: 0.3)) {
            hasCompletedOnboarding = true
        }
    }
}

// MARK: - Top nav (back + 2px progress bar) unified layout

/// Top nav shared by all quiz/diagnosis pages. The back button always reserves a 44pt area (the width
/// stays even when hidden), so the progress bar does not jump left and right depending on the button.
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
        // Bug fix (2026-07): on screens with a progress bar (fraction != nil), the GeometryReader inside made
        // the HStack flexible width, so it only "looked" left-aligned. On screens where fraction is nil
        // (e.g. moderationPolicy), the HStack shrank to a fixed width of just the button and was centered by
        // the parent ZStack(alignment: .top), so the chevron appeared to float in the center.
        // Set full width + left alignment explicitly so it is always fixed at the top left, with or without
        // fraction.
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
            // Automatically go to the next step after 1.5 seconds
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

    // 2026-07 redesign: dropped the old "quote app" story and switched to the SNS + discipline status pitch
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

            // Image slot: show the image with the same name if it exists in Assets, otherwise use an SF Symbol
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

// MARK: - 3. Dream (dream declaration)

/// New in 2026-07. Have the user declare "the person I want to become" as free text (sunk cost / IKEA
/// effect / goal setting).
/// Replaces the old CommitmentStepView (finger signature canvas, an empty ritual that saved nothing to
/// the DB).
/// User decision: a normal text input instead of an elaborate signature ritual. The dream is kept in
/// @AppStorage and pushed to users.dream by AppleSignInStepView after sign-in succeeds (the row cannot
/// be written before sign-in).
/// 2026-07 redesign: input is required (cannot proceed if empty) + example chips lower the barrier to
/// start writing.
private struct DreamStepView: View {
    @Binding var dream: String
    @Binding var isPublic: Bool
    /// Answer to diagnostic quiz Q6. Used only to choose the placeholder/example chips
    /// (until 2026-07-17 it was also used to lay out the background image, but the background is now fixed
    /// black)
    var goal: QuizGoal? = nil
    let onContinue: () -> Void

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    /// Shared focus used to close the keyboard when the area outside the field (background margin) is
    /// tapped. The @FocusState of DreamTextField is lifted here so the parent can write false to it.
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

    /// Example chips. Tapping one fills the field, and it can then be edited freely
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
            // The background is fixed black (2026-07-17 user spec). Before, IdealFutureBackdrop was laid thinly
            // underneath, but after the dream images became a deck, the background cards kept moving and hurt
            // focus on the declaration (goal input), so it was removed. goal is used only to choose the placeholder
            AppColors.background.ignoresSafeArea()

            // Transparent layer that closes the keyboard when the background margin is tapped. Because it is
            // placed under content, taps on content's own elements (chips/field/toggle/buttons) are received by
            // them first, and only empty areas such as Spacer are picked up by this layer, which removes focus.
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { isDreamFieldFocused = false }

            content
        }
        // Always show "完了" ("Done") above the keyboard (same polished behavior as NameInput, 2026-07-17
        // keyboard UX audit)
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

            // Example chips (tap to fill the field, can be edited freely)
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

            // Public toggle. Disabled when the dream is empty because it has no meaning then
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

/// The dream TextField is isolated in its own child View (real-device performance fix). 120 character
/// limit. Auto focus.
/// Focus now comes from the parent's (DreamStepView) @FocusState as a FocusState.Binding.
/// Bug fix (2026-07): before, @FocusState was local to this View, so the parent could not implement
/// "close on background tap", and once the keyboard was open there was no way to close it.
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
                // A TextField with axis: .vertical inserts a newline on Return and does not fire onSubmit, so a
                // trailing newline is detected as the "confirm" action and focus is removed
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

// MARK: - 3(old). Commitment (Signature), unused (replaced by DreamStepView. Not referenced, but not deleted)

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

            // Signature canvas
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

                // Underline (the line that marks the signature field)
                Rectangle()
                    .fill(AppColors.textTertiary.opacity(0.4))
                    .frame(height: 1)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 40)
                    .allowsHitTesting(false)
            }
            .padding(.horizontal, 24)

            // Clear button
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

/// 🔴 2026-08-06 App Review rejection fix (Guideline 4 Design / Sign in with Apple):
/// We were told "Authentication Services provides the name, but the app makes the user enter a name",
/// so **the display name input field was removed** and this step now only picks the user ID.
/// The display name is set by UserAuthService.signInWithApple() from Apple's fullName.
/// ⚠️ The user ID is not available from Apple, so asking for it here does not violate the requirement.
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

    /// Can proceed only when the handle has a valid format + the server availability check passed
    /// (.available). (The display name condition was removed on 2026-08-06, because it comes from Apple)
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
                        // The heading reuses an existing string ("ユーザーID" / "Username").
                        // 🔴 Copy waiting for user review. "あなたの名前を教えてください" ("Tell us your name") could no longer
                        // be used after the name field was removed, so it was replaced
                        Text(OnboardingHandleStrings.label(lang))
                            .font(AppTypography.title1)
                            .foregroundColor(AppColors.textPrimary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)

                        // "投稿やプロフィールに表示されます。後から変更できます。" ("Shown on your posts and profile. You can change it
                        // later.") also applies to the user ID as is, so it is reused
                        Text(L.onboardingNameSubtitle(lang))
                            .font(AppTypography.body)
                            .foregroundColor(AppColors.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        // The subheading was removed (2026-08-06): the name field is gone, and the main heading became the same
                        // "ユーザーID" ("User ID"), so it would be a duplicate
                        OnboardingHandleField(
                            text: $handle,
                            placeholder: OnboardingHandleStrings.placeholder(lang)
                        )

                        handleStatusView
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.bottom, 16)
                // Tapping the margin closes the keyboard (2026-07-17 keyboard UX audit.
                // Taps on the TextField / buttons are consumed by them first, so there is no interference)
                .contentShape(Rectangle())
                .onTapGesture { NameInputStepView.dismissKeyboard() }
            }
            .frame(maxHeight: .infinity)
            // Also lets the user close the keyboard by swiping down (standard polished behavior)
            .scrollDismissesKeyboard(.interactively)
            // Always show "完了" ("Done") above the keyboard (can close it from any field)
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

            // Link for existing accounts (skips NameInput and goes to sign-in)
            // → fallback so that re-onboarding does not overwrite users.display_name with an old name in AppStorage
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
            // If empty, prefill a suggestion (an escape hatch to proceed with one tap).
            // If a handle has already been entered (e.g. when shown again), do not overwrite it.
            if HandleValidator.normalized(handle).isEmpty {
                handle = "user_" + UUID().uuidString.prefix(8).lowercased()
            }
            scheduleHandleCheck()
        }
        .onChange(of: handle) { _, _ in
            scheduleHandleCheck()
        }
    }

    /// Reliable keyboard dismissal that does not depend on where the focus state lives
    /// (works whichever field, name or handle, is active)
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
            // Network errors are shown separately from "in use", with a retry option
            // (so onboarding does not get stuck on "使用できません" ("Not available") when offline / Supabase is paused)
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

    /// Debounce handle input by 400ms and check availability (same behavior as ProfileEditView).
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

// MARK: - Onboarding Name Field (TextField isolated)

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

// MARK: - Onboarding Handle Field (TextField isolated)

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
    /// Network error in the server availability check (shown separately from "in use", with a retry option)
    case error
    case invalid
}

// MARK: - Onboarding Handle Strings (this file only)

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

// MARK: - 4. FamilyControls (StayLocked-style minimal black screen. Moved to PHASE 1, before diagnosis, in 2026-07)

/// Standalone page for permission priming. It comes before the diagnosis, so there is no personalization
/// material such as the dream yet, and it is done with just one generic sentence (see competitor
/// StayLocked: black background + large plain heading + one bright CTA).
/// The system authorization dialog fires only after the CTA is tapped (when
/// service.requestAuthorization() is called).
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
                // Failed/denied state: a plain retry option (if already denied, the OS does not show the dialog again,
                // so a link to the Settings app is shown instead. Follows the existing openSettingsURLString pattern)
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

                // The CTA is a single off-white color (we do not copy the competitor's orange)
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
    /// On the "I already have an account" path, switch the heading to "sign in"
    let isReturningUser: Bool
    let pendingDisplayName: String
    let pendingHandle: String
    let pendingDream: String
    let pendingDreamPublic: Bool
    let onContinue: () -> Void
    /// M23 (2026-07-22 audit): link to go back from a mistaken tap on the "I already have an account" path.
    /// Shown only when isReturningUser, so callers in the normal flow can omit it.
    var onCreateAccountInstead: (() -> Void)? = nil
    /// M23: callback when we detect that the user signed in with a new Apple ID while isReturningUser was
    /// still set (a mistaken tap). Required wiring for every caller (no default).
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
                // Copy waiting for user review (the old "あなたの記録と名言を保存します" ("We save your records and
                // quotes") was removed because it was left over from the quote era)
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

            // Apple-provided SignInWithAppleButton (ASAuthorizationAppleIDButton)
            // The actual authentication flow uses ASAuthorizationController in UserAuthService
            Button {
                Task {
                    // M23: when the appleSignIn step is reached again while "already signed in"
                    // (mistaken tap → new account detected → new-user onboarding completed → back here),
                    // avoid a double sign-in and move on with the existing session
                    if !userAuth.isSignedIn {
                        await userAuth.signInWithApple()
                    }
                    guard userAuth.isSignedIn else { return }
                    // M23: detect a mistaken tap where the user, still on the "I already have an account" path, signed in
                    // with a new unregistered Apple ID. Return early before persisting pending values, and send them to
                    // new-user onboarding (age 13 gate + diagnosis).
                    //
                    // 🔴 2026-08-06: removed the display_name condition from the check.
                    // The same day's rejection fix part 1 made signInWithApple adopt "the name returned by Apple"
                    // automatically, so display_name is filled even for a new Apple ID, and the old condition
                    // (display_name and handle both empty) could never be true again
                    // = the mistaken-tap detection was completely dead (bug as of 1.0(3)).
                    // handle is not available from Apple and is only set when an account is created, so
                    // "handle is empty = no account has been created in this app yet" is the correct check.
                    if isReturningUser
                        && (userAuth.handle ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        onDetectedNewAccount()
                        return
                    }
                    // S15: save the name entered in the onboarding nameInput to users.display_name.
                    // However, to avoid "overwriting it with an old name in AppStorage on re-login",
                    // skip it if users.display_name is already set (refreshProfile runs inside signInWithApple, so
                    // auth.displayName already reflects the latest DB value).
                    let trimmed = pendingDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
                    let existing = userAuth.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if !trimmed.isEmpty && existing.isEmpty {
                        _ = try? await userAuth.setDisplayName(trimmed)
                    }
                    // @handle is also set only if there is no existing value.
                    // 🔴 2026-08-06 rejection fix part 2: the @user ID input step (.nameInput) was removed from onboarding,
                    // so normally we get here with pendingHandle empty.
                    // In that case it is issued automatically here, because after the removal there is no other place that
                    // issues it (the old place was the prefill in NameInputStepView.onAppear).
                    let normalizedHandle = HandleValidator.normalized(pendingHandle)
                    let existingHandle = userAuth.handle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let handleSaved: Bool
                    if !existingHandle.isEmpty {
                        handleSaved = true  // Existing value present (re-sign-in), do not touch it
                    } else if !normalizedHandle.isEmpty {
                        // If a value was already entered (e.g. a device that got partway through the onboarding before the
                        // removal), respect it
                        handleSaved = await userAuth.updateHandle(normalizedHandle)
                    } else {
                        handleSaved = await Self.assignGeneratedHandle(userAuth)
                    }
                    // 🔴 2026-08-06: display name fallback when Apple does not return a name.
                    // Apple returns fullName only "the first time this Apple ID authorizes this app",
                    // and it is always nil from the second time on (e.g. after deleting and recreating the account).
                    // With the current onboarding, which no longer has a name field, display_name would stay empty forever,
                    // and the profile would show "未設定" ("Not set") + a dash placeholder in the hero (confirmed on a real
                    // device on 2026-08-06).
                    // Put the issued @user ID in as the initial value so there is never an empty state.
                    // ⚠️ If Apple returned a name, it has already been saved inside signInWithApple,
                    //    so this only runs when it is empty = it does not overwrite Apple's name.
                    // ⚠️ Keep this after the handle (if the handle has not been issued, there is no value to put in).
                    let currentName = (userAuth.displayName ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let currentHandle = (userAuth.handle ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if currentName.isEmpty && !currentHandle.isEmpty {
                        _ = try? await userAuth.setDisplayName(currentHandle)
                    }
                    // Likewise for the dream, save the value declared in onboarding only if there is no existing value
                    // (it cannot be written to the users row before sign-in, so it was kept in @AppStorage until now)
                    let trimmedDream = pendingDream.trimmingCharacters(in: .whitespacesAndNewlines)
                    let existingDream = userAuth.dream?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let dreamSaved: Bool
                    if !trimmedDream.isEmpty && existingDream.isEmpty {
                        dreamSaved = await userAuth.updateDream(trimmedDream, isPublic: pendingDreamPublic)
                    } else {
                        dreamSaved = true
                    }
                    // Mirror it to the App Group for the Shield (plan A) subtitle
                    AppGroupStorage.shared.saveUserDream(userAuth.dream)
                    // pending values are consumed only when saving succeeds (so old values do not carry over to the next
                    // onboarding). Deleting them on failure (unique conflict / migration not applied / network loss)
                    // would silently lose the entered dream and handle (2026-07-07 Fable review finding)
                    UserDefaults.standard.removeObject(forKey: "onboardingDisplayName")
                    if handleSaved {
                        UserDefaults.standard.removeObject(forKey: "onboardingHandle")
                    }
                    if dreamSaved {
                        UserDefaults.standard.removeObject(forKey: "onboardingDream")
                        UserDefaults.standard.removeObject(forKey: "onboardingDreamPublic")
                    }
                    // Push the diagnostic quiz answers to user_onboarding_profiles (026 SQL).
                    // pending values are not deleted here, because the plan screen after this uses the answers for
                    // display. They are consumed when onboarding completes (completeOnboarding). If the push fails (026 not
                    // applied / network loss), the flag is not set and pending values are kept so no answers are lost
                    if let uid = userAuth.userId {
                        let d = UserDefaults.standard
                        // M22 (2026-07-20 audit): pending values left over after a failed push could be upserted as is on the
                        // next sign-in of another account sharing the device, mixing in someone else's birth date etc.
                        // Give them an owner stamp (right after sign-in succeeds, before the push), and if it differs from the
                        // current uid, treat them as leftovers of another account and discard them without pushing.
                        // If the stamp is empty (first time or already consumed last time) or matches the current uid, push as
                        // usual. The normal flow (new user: quiz → sign-in → push) is unchanged
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
                            // UUID is not a plist type, so always save it as uuidString (the comparison side also uses uuidString)
                            d.set(uid.uuidString, forKey: "onboardingPendingOwnerUserId")
                            let quizSaved = await OnboardingProfileService.push(
                                userId: uid,
                                birthDateRaw: d.string(forKey: "onboardingBirthDate") ?? "",
                                genderRaw: d.string(forKey: "onboardingGender") ?? "",
                                occupationRaw: d.string(forKey: "onboardingOccupation") ?? "",
                                dailyHoursRaw: d.string(forKey: "onboardingDailyHours") ?? "",
                                addictionYearsRaw: d.string(forKey: "onboardingAddictionYears") ?? "",
                                // Q5 (apps that ate your time) was dropped. The wasted_apps column is kept but always sent empty (NULL)
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
                    // M23: when appleSignIn is reached again while "already signed in", switch to "続ける" ("Continue")
                    // without the Apple logo (there is no need to show the Apple authentication UI again)
                    Text(userAuth.isSignedIn
                         ? (lang == .japanese ? "続ける" : "Continue") // Copy waiting for user review
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

            // Cluster at the bottom of the screen (rebuilt after 2026-07-31 real-device feedback "the bottom looks
            // bad").
            // Old: an underlined "アカウントを作成する" ("Create account") + consent text + below it an underlined
            //     link row repeating the same words (a two-tier layout where Terms/Privacy Policy appeared twice
            //     on the screen).
            // New: (1) the links appear only once, inline in the consent text (2) all underlines removed (3) the
            //     gap between the 2 elements was tightened from 32→16 so they look like one block that "closes"
            //     the bottom
            VStack(spacing: 16) {
                // M23: link that lets the user go back from a mistaken tap on the "I already have an account" path
                if isReturningUser {
                    Button {
                        onCreateAccountInstead?()
                    } label: {
                        HStack(spacing: 5) {
                            Text(lang == .japanese ? "アカウントをお持ちでない方は" : "Don't have an account?") // Copy waiting for user review
                                .foregroundColor(AppColors.textTertiary)
                            Text(lang == .japanese ? "新規作成" : "Create one") // Copy waiting for user review
                                .fontWeight(.semibold)
                                .foregroundColor(AppColors.textPrimary)
                        }
                        .font(.system(size: 13))
                    }
                }

                // M6/M15 (2026-07-22 audit): standard wording for agreeing to the terms.
                // 2026-07-31: merged into inline links in the sentence (Markdown). tint becomes the link color
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

    /// Automatic issuing of the @user ID (2026-08-06 rejection fix part 2).
    /// The input step was removed from onboarding, so a unique handle is fixed here when the account is
    /// created.
    /// Format is `user_` + first 8 characters of a UUID (e.g. `user_a3f9b2c1`). At 13 characters it matches
    /// `^[a-z0-9._]{3,20}$` and does not collide with reserved words.
    ///
    /// ⚠️ `updateHandle` does not return the reason for failure (both a unique conflict and a network loss
    /// return false), so retry a few times with other candidates to absorb only conflicts. If all fail,
    /// move on with no handle set
    /// (users.handle allows NULL. The user can set it later in profile editing → User ID).
    private static func assignGeneratedHandle(_ userAuth: UserAuthService) async -> Bool {
        for _ in 0..<3 {
            let candidate = "user_" + UUID().uuidString.prefix(8).lowercased()
            if await userAuth.updateHandle(candidate) { return true }
        }
        print("⚠️ [Onboarding] @ユーザーID の自動発番に失敗。プロフィール編集で設定してもらう")
        return false
    }

    /// Consent text. Terms of Service / Privacy Policy are links inside the sentence (not on a separate
    /// row). If the Markdown fails to parse, fall back to plain text without links
    private var consentText: AttributedString {
        let markdown = lang == .japanese
            ? "続行すると、[利用規約](\(LegalLinks.termsURL))と[プライバシーポリシー](\(LegalLinks.privacyURL))に同意したものとみなされます" // Copy waiting for user review
            : "By continuing, you agree to the [Terms of Service](\(LegalLinks.termsURL)) and [Privacy Policy](\(LegalLinks.privacyURL))"
        if let attributed = try? AttributedString(markdown: markdown) {
            return attributed
        }
        return AttributedString(lang == .japanese
            ? "続行すると、利用規約とプライバシーポリシーに同意したものとみなされます"
            : "By continuing, you agree to the Terms of Service and Privacy Policy")
    }
}

// MARK: - 6. Rating (App Store rating request, new on 2026-07-19)

/// Page that asks for an App Store rating right after sign-in (a point both the new and returning user
/// paths always pass). After a short delay from display, the OS standard rating dialog (requestReview)
/// is shown. OS-side throttling can prevent the dialog from appearing, so the page itself can always be
/// passed with "続ける" ("Continue").
/// Response to 2026-07-31 real-device feedback "make it a bit cooler". Only 3 things were added:
///   1. The background uses the same moving smoke as the hero/official profile, to put it on the brand
///      surface
///   2. A very faint gold glow behind the stars (not adding a color, just one layer of light)
///   3. The stars light up one by one from the left (scale + fade with a 0.09 s offset. No bounce,
///      rotation or shine)
/// Styles already rejected (draw-on/bounce/shimmer) are not used. With ReduceMotion they light up
/// instantly
private struct RatingStepView: View {
    let lang: AppLanguage
    let onContinue: () -> Void

    @Environment(\.requestReview) private var requestReview
    @State private var starsLit = 0
    @State private var contentIn = false

    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    /// Rating stars. SF Symbol (flat) → emoji ("emoji look cheap") were both rejected, so they were replaced
    /// with real assets: the 3D star from Microsoft Fluent Emoji (MIT license, commercial use allowed.
    /// Source and license text in Docs/third_party_licenses.md). To change it, just replace the image in
    /// RatingStar.imageset (no code change needed). Falls back to the emoji where the asset is missing
    @ViewBuilder
    private var ratingStar: some View {
        if UIImage(named: "RatingStar") != nil {
            Image("RatingStar")
                .resizable()
                .scaledToFit()
                // The asset itself has 6% padding on every side, so it is sized larger to make the look match
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

                // The app icon (rounded-corner cutout) above the stars (2026-07-19 user spec)
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

                // Copy waiting for user review
                Text(lang == .japanese ? "1% の評価をお願いします" : "Rate 1% on the App Store")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundColor(AppColors.textPrimary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 28)

                // Copy waiting for user review
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
            // The whole screen goes from blurred to sharp (the same entrance style as the hero)
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
            // Light up the stars one by one from the left
            for i in 1...5 {
                try? await Task.sleep(nanoseconds: 90_000_000)
                withAnimation(.easeOut(duration: 0.22)) { starsLit = i }
            }
            // Show the dialog after the purpose of the page is clear (right after display it would cover the page
            // with no context)
            try? await Task.sleep(nanoseconds: 700_000_000)
            requestReview()
        }
    }
}

// MARK: - 7. App Select (initial setup 2026-07-15)

/// End of onboarding: have the user choose the first apps to lock. The selection is saved as the
/// shared initial value for all 3 modes
/// (BlockingService.saveInitialSharedSelection). After that it can be changed separately on each mode
/// screen.
/// Assumes FamilyControls permission was already obtained earlier in onboarding (.familyControls)
private struct AppSelectStepView: View {
    let lang: AppLanguage
    let onFinish: () -> Void

    @State private var selection = FamilyActivitySelection()
    @State private var showPicker = false
    /// L18 (2026-07-22 audit): save the selection state at the moment the picker opens. When it closes, if
    /// there is no difference from this, treat it as "equivalent to cancel" and neither save nor move to the
    /// next screen
    /// (prevents moving on by mistake when the picker was just closed without choosing/changing anything)
    @State private var selectionAtPickerOpen = FamilyActivitySelection()

    private var totalCount: Int {
        selection.applicationTokens.count + selection.categoryTokens.count
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Copy waiting for user review
            Text(lang == .japanese ? "最初にロックする\nアプリを選ぶ" : "Choose the first apps\nto lock")
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(AppColors.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // Copy waiting for user review
            Text(lang == .japanese
                 ? "いつでも変更できます。\nまずは一番時間を奪っているものから。"
                 : "You can change this anytime.\nStart with what eats the most time.")
                .font(.system(size: 13))
                .foregroundColor(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.top, 14)

            if totalCount > 0 {
                Text(lang == .japanese ? "\(totalCount)個を選択中" : "\(totalCount) selected") // Copy waiting for user review
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(AppColors.textPrimary)
                    .padding(.top, 20)
            }

            Spacer()

            VStack(spacing: 12) {
                PrimaryButton(
                    totalCount > 0
                        ? (lang == .japanese ? "この選択で始める" : "Start with these") // Copy waiting for user review
                        : (lang == .japanese ? "アプリを選択" : "Select apps") // Copy waiting for user review
                ) {
                    if totalCount > 0 {
                        BlockingService.shared.saveInitialSharedSelection(selection)
                        onFinish()
                    } else {
                        // L18: save the selection state right before opening, as the baseline for detecting a difference
                        selectionAtPickerOpen = selection
                        showPicker = true
                    }
                }

                Button(lang == .japanese ? "あとで選ぶ" : "Later") { // Copy waiting for user review
                    onFinish()
                }
                .font(AppTypography.footnote)
                .foregroundColor(AppColors.textTertiary)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .familyActivityPicker(isPresented: $showPicker, selection: $selection)
        // The moment the picker is closed with the check at the top right, if there is a selection, go straight
        // to the next step
        // (removes the double step "check → then the button further down", 2026-07-19 user feedback)
        .onChange(of: showPicker) { _, isPresented in
            // L18: if there is no difference from the selection when it opened (selectionAtPickerOpen), treat it
            // as equivalent to cancel (closed without choosing/changing anything), and neither save nor move to
            // the next screen
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
