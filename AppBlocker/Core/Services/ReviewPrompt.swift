//
//  ReviewPrompt.swift
//  AppBlocker
//
//  Keeps "when to show" the App Store rating request in one place (added 2026-08-06).
//
//  Background: 1.0(2) was rejected under Guideline 5.6.3 (Developer Code of Conduct).
//  The finding was: "the app asks for a rating during onboarding / on first launch. Ask only after
//  the user has used it enough". The .rating step in onboarding and requestReview() in
//  OnboardingPlan were removed, and it now only asks people who "have opened the app many times &
//  have actually used a lock".
//
//  🔴 To change where it is shown, look at this file only.
//

import Foundation

@MainActor
enum ReviewPrompt {

    /// Number of times a lock session was actually used (completed or stopped manually)
    private static let lockUsedCountKey = "reviewPromptLockUsedCount"
    /// Total number of times the app was brought to the foreground after onboarding finished
    private static let openCountKey = "reviewPromptAppOpenCount"
    /// The "app open count" milestone at which the rating was last requested (0 = never asked yet)
    private static let lastAskedOpenMilestoneKey = "reviewPromptLastAskedOpenMilestone"

    /// Milestones of "app open count" at which to ask for a rating.
    ///
    /// ⚠️ Setting several does not show it too often. `requestReview` is **throttled by iOS to 3 times
    /// a year**, so the OS always makes the final decision on whether it actually shows.
    /// The app only passes "moments when it is OK to ask".
    ///
    /// 5.6.3 forbids asking "**on first launch and during onboarding**". The 5th launch is
    /// neither. The caller is limited to MainTabView (a screen shown only after onboarding finishes),
    /// so a violation cannot happen by structure.
    /// 🔴 2026-09-05: with [5, 12] it could ask at most 2 times in a lifetime, and almost no reviews came
    ///    in. requestReview is throttled by the OS to 3 times a year, so more chances do not mean too
    ///    many prompts. The app only adds "moments when it is OK to ask", and the OS always makes the
    ///    final decision.
    private static let openMilestones = [5, 12, 25, 40]

    /// Precondition for asking by open count = a lock has been used at least this many times.
    ///
    /// 🔴 2026-08-06 user decision: at first the condition was "at least 1 **completion**", but
    /// it was withdrawn on the view that **not many people get as far as completion**. With completion
    /// as the condition, most users would never be asked.
    /// "Actually used a lock (completed or stopped manually)" = touched the core feature, is enough.
    private static let minLockUsesForPrompt = 1

    /// Call when a lock session ends (completed or stopped manually).
    /// Only counts, shows nothing.
    ///
    /// Why count at the "end" and not the "start": the only common exit of the 3 modes (timer /
    /// schedule / location) is BlockSessionTracker.enqueueSession. The start points are spread across the
    /// modes, and schedule/location start in the Extension, so they cannot be caught.
    /// "Ended at least once" means "used at least once", so it works the same as a condition.
    static func recordLockSessionUsed() {
        let d = UserDefaults.standard
        d.set(d.integer(forKey: lockUsedCountKey) + 1, forKey: lockUsedCountKey)
    }

    /// Call when the app comes to the foreground (only after onboarding). Only counts, shows nothing.
    static func recordAppOpen() {
        let d = UserDefaults.standard
        d.set(d.integer(forKey: openCountKey) + 1, forKey: openCountKey)
    }

    // MARK: - Completion-based trigger (added 2026-09-05)

    /// Number of completed locks
    private static let completedCountKey = "reviewPromptCompletedCount"
    /// The milestone at which the rating was last requested on "completion"
    private static let lastAskedCompletedMilestoneKey = "reviewPromptLastAskedCompletedMilestone"

    /// Milestones at which to ask on completion. Asking at the moment of greatest achievement gets the
    /// highest stars.
    ///
    /// ⚠️ The completion-based trigger was removed entirely on 2026-08-06, but the reason was that
    ///    "making completion a **precondition** means most users would never be asked".
    ///    This is not a precondition but **an extra chance**, so it does not contradict that decision
    ///    (the open count trigger is still there).
    private static let completedMilestones = [1, 3, 8]

    /// Call when a lock is completed (when the completion screen shows). Only counts
    static func recordSessionCompleted() {
        let d = UserDefaults.standard
        d.set(d.integer(forKey: completedCountKey) + 1, forKey: completedCountKey)
    }

    /// Whether it is OK to ask right after a completion. Same as the open count side: consumes the
    /// largest milestone that was reached and not yet used
    static func shouldAskAfterCompletedSession() -> Bool {
        let d = UserDefaults.standard
        let completed = d.integer(forKey: completedCountKey)
        let lastAsked = d.integer(forKey: lastAskedCompletedMilestoneKey)
        guard let reached = completedMilestones.last(where: { completed >= $0 && $0 > lastAsked }) else {
            return false
        }
        d.set(reached, forKey: lastAskedCompletedMilestoneKey)
        return true
    }

    /// Whether it is OK to ask for a rating now. When it returns true, that milestone is recorded as
    /// "used" (the caller runs requestReview() only when true).
    ///
    /// Consume **the largest** of the milestones reached and not yet used.
    /// This way, even if the count skips ahead, the same milestone is never asked twice.
    static func shouldAskOnAppOpen() -> Bool {
        let d = UserDefaults.standard
        guard d.integer(forKey: lockUsedCountKey) >= minLockUsesForPrompt else { return false }
        let opens = d.integer(forKey: openCountKey)
        let lastAsked = d.integer(forKey: lastAskedOpenMilestoneKey)
        guard let reached = openMilestones.last(where: { opens >= $0 && $0 > lastAsked }) else {
            return false
        }
        d.set(reached, forKey: lastAskedOpenMilestoneKey)
        return true
    }
}
