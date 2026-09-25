//
//  UnlockChallengeService.swift
//  AppBlocker
//
//  解除課題 (難易度モード) の設定と、走っているセッションへの焼き付け。
//
//  🔴 なぜ「焼き付け」が要るか:
//    設定は3モード共通のグローバル値で、いつでも変えられる。もし走っている
//    セッションが現在の設定をその場で読むと、ロック中に設定を緩めるだけで
//    逃げられてしまい、縛りとして成立しない。
//    → セッション開始時の値を保存し、そのセッションが終わるまでそれを使う。
//      設定変更が効くのは次のセッションから。
//    おかげで「セッション中は設定を触れないようにする」処理が丸ごと不要になり、
//    3モード共通の場所に置いた部品がときどき無効化される気持ち悪さも避けられる。
//
//  🔴 BlockSession (Codable・永続化済み) には手を加えない:
//    実ユーザーの実行中セッションを復元しているモデルなので、フィールドを足して
//    デコードの挙動を変えるリスクを取らない。焼き付けはここで別に持つ。
//

import Foundation
import Combine

@MainActor
final class UnlockChallengeService: ObservableObject {

    static let shared = UnlockChallengeService()

    private enum Keys {
        static let selected = "unlockChallenge.selected"
        static let randomPool = "unlockChallenge.randomPool"
        /// 走っているセッションに焼き付けた課題
        static let activeChallenge = "unlockChallenge.active.challenge"
        /// 焼き付けの持ち主 (セッションID)。別セッションの焼き付けを誤って使わないため
        static let activeOwner = "unlockChallenge.active.owner"
    }

    private let defaults: UserDefaults

    /// ユーザーが選んでいる課題。⚠️ 変更が効くのは次のセッションから
    @Published var selected: UnlockChallenge {
        didSet {
            guard selected != oldValue else { return }
            defaults.set(selected.rawValue, forKey: Keys.selected)
        }
    }

    /// random のときの抽選候補。🔴 空にはしない (空だと抽選できず解除不能になる)
    @Published var randomPool: Set<UnlockChallenge> {
        didSet {
            guard randomPool != oldValue else { return }
            defaults.set(randomPool.map(\.rawValue), forKey: Keys.randomPool)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        let rawSelected = defaults.string(forKey: Keys.selected) ?? ""
        let restored = UnlockChallenge(rawValue: rawSelected)
        // 🔴 未実装の課題が保存されていたら既定に戻す。
        //    実装前のビルドで選ばれた値が残っていると解除不能になる
        self.selected = (restored?.isImplemented == true) ? restored! : .longPress

        let rawPool = defaults.stringArray(forKey: Keys.randomPool) ?? []
        let pool = Set(rawPool.compactMap(UnlockChallenge.init(rawValue:)))
            .filter { $0.canBeRandomCandidate && $0.isImplemented }
        self.randomPool = pool.isEmpty ? [.longPress] : pool
    }

    // MARK: - セッションへの焼き付け

    /// セッション開始時に呼ぶ。この時点の設定をそのセッションの課題として固定する。
    /// random ならここで抽選する (毎回引き直すと、閉じて開くだけで楽な課題を狙えてしまう)
    func beginSession(id: UUID) {
        let resolved = resolve(selected)
        defaults.set(resolved.rawValue, forKey: Keys.activeChallenge)
        defaults.set(id.uuidString, forKey: Keys.activeOwner)
    }

    /// まだ焼き付けが無ければ焼き付ける。
    /// スケジュールは Extension や15秒リコンサイル経由で始まるためセッションIDを
    /// 持ち回れない。「いま走っているロックの課題」として1つだけ持つ
    func beginSessionIfNeeded() {
        guard defaults.string(forKey: Keys.activeChallenge) == nil else { return }
        defaults.set(resolve(selected).rawValue, forKey: Keys.activeChallenge)
    }

    /// セッション終了時に呼ぶ
    func endSession() {
        defaults.removeObject(forKey: Keys.activeChallenge)
        defaults.removeObject(forKey: Keys.activeOwner)
    }

    /// 走っているセッションに課された課題。
    /// 焼き付けが無い場合 (このコードが入る前から走っていたセッション等) は既定に倒す。
    /// 🔴 ここで現在の設定に倒してはいけない。ロック中に設定を緩めて逃げられてしまう
    func challenge(forSession id: UUID?) -> UnlockChallenge {
        guard let id,
              defaults.string(forKey: Keys.activeOwner) == id.uuidString,
              let raw = defaults.string(forKey: Keys.activeChallenge),
              let challenge = UnlockChallenge(rawValue: raw),
              challenge.isImplemented
        else {
            return .longPress
        }
        return challenge
    }

    /// 走っているセッションに焼き付いている課題 (表示用)。無ければ nil。
    /// 🔴 ロック中のカードはこれを出すこと。設定値を出すと
    ///    「カードは腕立てと言っているのに実際は長押し」という嘘になる
    var activeChallenge: UnlockChallenge? {
        guard let raw = defaults.string(forKey: Keys.activeChallenge),
              let challenge = UnlockChallenge(rawValue: raw),
              challenge.isImplemented
        else { return nil }
        return challenge
    }

    // MARK: - 抽選

    /// random を実際の課題に解決する。それ以外はそのまま返す
    private func resolve(_ challenge: UnlockChallenge) -> UnlockChallenge {
        guard challenge == .random else { return challenge }
        let candidates = randomPool.filter { $0.canBeRandomCandidate && $0.isImplemented }
        // 🔴 候補が空なら既定に倒す。ここで nil を返すと解除手段が無くなる
        return candidates.randomElement() ?? .longPress
    }
}
