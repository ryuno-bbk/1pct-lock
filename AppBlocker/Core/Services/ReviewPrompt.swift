//
//  ReviewPrompt.swift
//  AppBlocker
//
//  App Store の評価依頼を「いつ出すか」を1箇所に集約する (2026-08-06 新設)。
//
//  経緯: 1.0(2) が Guideline 5.6.3 (Developer Code of Conduct) でリジェクトされた。
//  指摘は「オンボーディング中/初回起動時に評価を求めている。十分に使ってもらってから聞け」。
//  オンボの .rating ステップと OnboardingPlan の requestReview() を撤去し、
//  「アプリを何度も開いている & ロックを実際に使ったことがある」人にだけ聞く形へ移した。
//
//  🔴 出し所を変える時はこのファイルだけ見ればよい。
//

import Foundation

@MainActor
enum ReviewPrompt {

    /// ロックセッションを実際に使った回数 (完遂・手動停止を問わない)
    private static let lockUsedCountKey = "reviewPromptLockUsedCount"
    /// オンボ完了後にアプリを前面に出した累計回数
    private static let openCountKey = "reviewPromptAppOpenCount"
    /// 最後に評価を聞いた「起動回数」マイルストーン (0 = まだ一度も聞いていない)
    private static let lastAskedOpenMilestoneKey = "reviewPromptLastAskedOpenMilestone"

    /// 評価を聞く「アプリ起動回数」のマイルストーン。
    ///
    /// ⚠️ 複数仕掛けても出し過ぎにはならない。`requestReview` は **iOS が年3回までに
    /// 間引く**ので、実際に出るかの最終判断は常に OS が持っている。
    /// アプリ側は「聞いてよい瞬間」を渡すだけ。
    ///
    /// 5.6.3 が禁じているのは「**初回起動時とオンボーディング中**」。5回目の起動は
    /// どちらにも当たらない。呼び出し元を MainTabView (オンボ完了後にしか出ない画面) に
    /// 限定しているので、違反は構造的に起きない。
    /// 🔴 2026-09-05: [5, 12] だと生涯で最大2回しか聞けず、レビューがほとんど集まらなかった。
    ///    requestReview は OS が年3回に間引くので、機会を増やしても出し過ぎにはならない。
    ///    アプリ側は「聞いてよい瞬間」を増やすだけで、最終判断は常に OS が持つ。
    private static let openMilestones = [5, 12, 25, 40]

    /// 起動回数で聞く前提条件 = ロックを最低この回数は使っていること。
    ///
    /// 🔴 2026-08-06 ユーザー判断: 当初は「**完遂**1回以上」を条件にしていたが、
    /// **完遂まで至る人は多くない**という見立てで撤回した。完遂を条件にすると
    /// 大半のユーザーに永久に聞けなくなる。
    /// 「ロックを実際に使った (完遂でも手動停止でも)」= コア機能に触れた、で十分とする。
    private static let minLockUsesForPrompt = 1

    /// ロックセッションが終わった時に呼ぶ (完遂・手動停止のどちらでも)。
    /// 数えるだけで何も表示しない。
    ///
    /// なぜ「開始」ではなく「終了」で数えるか: 3モード (タイマー/スケジュール/位置) の
    /// 共通の出口が BlockSessionTracker.enqueueSession しかないため。開始地点は
    /// モードごとに散っており、スケジュール/位置は Extension 側で始まるので拾えない。
    /// 「1回でも終わった」なら「1回は使った」ので、条件としては等価に働く。
    static func recordLockSessionUsed() {
        let d = UserDefaults.standard
        d.set(d.integer(forKey: lockUsedCountKey) + 1, forKey: lockUsedCountKey)
    }

    /// アプリを前面に出した時に呼ぶ (オンボ完了後のみ)。数えるだけで何も表示しない。
    static func recordAppOpen() {
        let d = UserDefaults.standard
        d.set(d.integer(forKey: openCountKey) + 1, forKey: openCountKey)
    }

    // MARK: - 完遂ベースのトリガー (2026-09-05 追加)

    /// ロックを完遂した回数
    private static let completedCountKey = "reviewPromptCompletedCount"
    /// 最後に「完遂」で聞いたマイルストーン
    private static let lastAskedCompletedMilestoneKey = "reviewPromptLastAskedCompletedMilestone"

    /// 完遂で聞くマイルストーン。達成感が最大の瞬間に聞くのが最も星が高くなる。
    ///
    /// ⚠️ 2026-08-06 に完遂ベースを一度全廃したが、あれは「完遂を**前提条件**にすると
    ///    大半のユーザーに永久に聞けなくなる」という理由だった。
    ///    ここは前提条件ではなく**追加の機会**なので、当時の判断と矛盾しない
    ///    (起動回数のトリガーはそのまま残っている)。
    private static let completedMilestones = [1, 3, 8]

    /// ロックを完遂した時に呼ぶ (完遂画面が出るタイミング)。数えるだけ
    static func recordSessionCompleted() {
        let d = UserDefaults.standard
        d.set(d.integer(forKey: completedCountKey) + 1, forKey: completedCountKey)
    }

    /// 完遂直後に聞いてよいか。起動回数側と同じく、到達済みで未消化の最大マイルストーンを消化する
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

    /// いま評価を聞いてよいか。true を返した時点で「そのマイルストーンは消化済み」と記録する
    /// (呼び出し側は true の時だけ requestReview() を実行する)。
    ///
    /// 到達済みで未消化のマイルストーンのうち **最大のもの** を消化する。
    /// こうしておくと、途中で数が飛んでも同じマイルストーンを二度聞かない。
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
