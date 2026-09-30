//
//  UnlockChallengeService.swift
//  AppBlocker
//
//  Setting for the unlock challenge (difficulty mode), and baking it into the running session.
//
//  🔴 Why "baking" is needed:
//    The setting is a global value shared by the 3 modes and can be changed at any time. If a
//    running session read the current setting on the spot, the user could escape just by
//    loosening the setting during a lock, and it would not work as a restriction.
//    → Save the value at session start and use it until that session ends.
//      A setting change takes effect from the next session.
//    Thanks to this, logic to "block setting changes during a session" is not needed at all, and
//    we avoid the awkwardness of a component in the 3-mode shared area being disabled at times.
//
//  🔴 Do not modify BlockSession (Codable, persisted):
//    It is the model that restores real users' running sessions, so we do not take the risk of
//    adding fields and changing its decoding behavior. The baked value is kept separately here.
//

import Foundation
import Combine

@MainActor
final class UnlockChallengeService: ObservableObject {

    static let shared = UnlockChallengeService()

    private enum Keys {
        static let selected = "unlockChallenge.selected"
        static let randomPool = "unlockChallenge.randomPool"
        /// The challenge baked into the running session
        static let activeChallenge = "unlockChallenge.active.challenge"
        /// Owner of the baked value (session ID), so that a different session's baked value is not used by
        /// mistake
        static let activeOwner = "unlockChallenge.active.owner"
    }

    private let defaults: UserDefaults

    /// The challenge the user has selected. ⚠️ A change takes effect from the next session
    @Published var selected: UnlockChallenge {
        didSet {
            guard selected != oldValue else { return }
            defaults.set(selected.rawValue, forKey: Keys.selected)
        }
    }

    /// Candidates for the draw when random. 🔴 Never empty (if empty, nothing can be drawn and
    /// unlocking becomes impossible)
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
        // 🔴 If an unimplemented challenge was saved, reset to the default.
        //    If a value chosen in a build before it was implemented remains, unlocking becomes impossible
        self.selected = (restored?.isImplemented == true) ? restored! : .longPress

        let rawPool = defaults.stringArray(forKey: Keys.randomPool) ?? []
        let pool = Set(rawPool.compactMap(UnlockChallenge.init(rawValue:)))
            .filter { $0.canBeRandomCandidate && $0.isImplemented }
        self.randomPool = pool.isEmpty ? [.longPress] : pool
    }

    // MARK: - Baking into the session

    /// Call at session start. Fixes the current setting as that session's challenge.
    /// If random, draw here (if it were redrawn every time, the user could aim for an easy challenge just
    /// by closing and reopening)
    func beginSession(id: UUID) {
        let resolved = resolve(selected)
        defaults.set(resolved.rawValue, forKey: Keys.activeChallenge)
        defaults.set(id.uuidString, forKey: Keys.activeOwner)
    }

    /// Bake if nothing is baked yet.
    /// A schedule starts through the Extension or the 15-second reconcile, so a session ID cannot be
    /// carried around. Keep just one, as "the challenge of the lock running now"
    func beginSessionIfNeeded() {
        guard defaults.string(forKey: Keys.activeChallenge) == nil else { return }
        defaults.set(resolve(selected).rawValue, forKey: Keys.activeChallenge)
    }

    /// Call at session end
    func endSession() {
        defaults.removeObject(forKey: Keys.activeChallenge)
        defaults.removeObject(forKey: Keys.activeOwner)
    }

    /// The challenge assigned to the running session.
    /// If nothing is baked (e.g. a session that was already running before this code shipped), fall
    /// back to the default.
    /// 🔴 Do not fall back to the current setting here. The user could escape by loosening the setting
    /// during a lock
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

    /// The challenge baked into the running session (for display). nil if none.
    /// 🔴 The card during a lock must show this. Showing the setting value would be a lie:
    ///    "the card says push-ups but it is actually a long press"
    var activeChallenge: UnlockChallenge? {
        guard let raw = defaults.string(forKey: Keys.activeChallenge),
              let challenge = UnlockChallenge(rawValue: raw),
              challenge.isImplemented
        else { return nil }
        return challenge
    }

    // MARK: - Draw

    /// Resolve random into an actual challenge. Anything else is returned as-is
    private func resolve(_ challenge: UnlockChallenge) -> UnlockChallenge {
        guard challenge == .random else { return challenge }
        let candidates = randomPool.filter { $0.canBeRandomCandidate && $0.isImplemented }
        // 🔴 If there are no candidates, fall back to the default. Returning nil here would leave no way to
        // unlock
        return candidates.randomElement() ?? .longPress
    }
}
