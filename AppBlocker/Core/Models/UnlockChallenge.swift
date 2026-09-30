//
//  UnlockChallenge.swift
//  AppBlocker
//
//  The "challenge" you must complete to unlock = difficulty mode.
//
//  Background (designed with the user on 2026-08-28):
//    Similar apps growing overseas (Touch Grass / PushUp Time etc.) make you prove a real-world
//    action with the camera to unlock. The starting point was that this is far stronger than any
//    difficulty that stays inside the app.
//
//  🔴 Push-ups and squats were removed on 2026-08-29.
//    They were implemented with on-device Vision body pose detection, but on a real device they were
//    unusable both times ("a small movement at the bottom counts many times"). Because the design
//    normalizes by shoulder width, when the denominator shakes, the ratio jumps. Motion tracking
//    itself was unstable, so we decided to go with only "notebook + pen", which judges from one
//    still image.
//    If you need to restore it, look at commit 8ace469 or earlier.
//
//  🔴 Core of the design:
//    - The challenge is decided "when starting the lock". If you could choose it at the moment you
//      are trying to stop, it would not bind you
//    - A running session keeps the challenge from its start baked in (UnlockChallengeService).
//      So even if the settings are changed later, the lock that is running now does not get looser
//    - There is always an escape (deleting the app also removes the Screen Time blocking).
//      We cannot close it, and we must not lie that it is closed
//

import Foundation

enum UnlockChallenge: String, CaseIterable, Codable, Identifiable {

    /// 2-second long press. The friction the existing interruption screen already has = the default that
    /// keeps the status quo
    case longPress
    /// Write one line about the work you will do after the break ends (implementation intention / if-then
    /// plan). d=0.65 in a meta-analysis (Gollwitzer & Sheeran 2006, 94 tests), the best-proven technique
    /// for behavior change.
    /// 🔴 Ask "what will you do when the break ends", not "what will you do after you unlock".
    ///    The honest answer to the latter is "scroll", so there is no point asking it (pointed out by the
    ///    user 2026-08-29)
    case declaration
    /// View N posts in the feed (core loop: satisfy the urge during a lock inside the app)
    case scrollFeed
    /// View images you registered yourself. The content is random each time. Stored on the device (not
    /// uploaded to the server)
    case imageScroll
    /// Draw from a candidate pool. 🔴 The user chooses the pool.
    /// Fully random from all missions gets you stuck with "notebook comes up while you are on the train"
    case random
    /// Mode that shows no way to unlock.
    /// 🔴 Do not use the text "No matter what you do, you cannot unlock". It is not true
    ///    (deleting the app always unlocks). "このモードでは解除できません" ("You cannot unlock in this
    ///    mode") = true inside the app
    case none

    var id: String { rawValue }

    /// Order shown in the picker. random / none go at the bottom
    static var pickable: [UnlockChallenge] {
        [.longPress, .declaration, .scrollFeed, .imageScroll, .none]
    }

    /// Whether it can be a candidate for the draw (random itself and none are not candidates)
    var canBeRandomCandidate: Bool {
        switch self {
        case .random, .none: return false
        default:             return true
        }
    }

    /// Whether it is Pro only (2026-08-28 confirmed by the user: only post and scroll are free)
    var requiresPro: Bool {
        switch self {
        // We do not charge for unlock methods. The lock methods (schedule/location) are already Pro, so there
        // is no need to pad the perks here with weak features (confirmed 2026-08-29)
        case .longPress, .declaration, .scrollFeed, .imageScroll, .random: return false
        // 🔴 Only hard mode is Pro. Opal also makes Deep Focus paid
        case .none:                                                        return true
        }
    }

    /// Whether it is implemented. They are added step by step, so unimplemented ones are not shown in the
    /// picker.
    /// 🔴 Do not mix unimplemented ones into the default or the random candidates (unlocking would become
    /// impossible)
    var isImplemented: Bool {
        switch self {
        case .longPress, .declaration, .scrollFeed, .imageScroll, .none: return true
        // random is postponed (if there are several methods, the switching itself becomes the variation)
        case .random:                                                    return false
        }
    }

    /// SF Symbol shown at the left of the row (2026-09-05, user-specified).
    /// 🔴 Response to real-device feedback that the text is plain and "you can't tell which is which".
    ///    Put the icon in a fixed-width column separate from the text (mixing it into the same HStack
    ///    shifts the title's wrap position for each method)
    var icon: String {
        switch self {
        case .longPress:   return "stop.circle.fill"   // Stop mark = keep pressing the end button
        case .declaration: return "note.text"          // Notebook = write a declaration
        case .scrollFeed:  return "person.3.fill"      // A few other people = rivals
        case .imageScroll: return "photo.fill"         // Image
        case .random:      return "shuffle"
        case .none:        return "lock.fill"          // Padlock = hard lock
        }
    }

    /// ✅ The Japanese was dictated by the user (2026-09-05). The endings are unified to the pattern
    ///    "unlock by doing X / unlock after doing X", so the title alone tells "what you need to do to unlock".
    /// ⚠️ The English is waiting for user review (the full native check has not been done)
    func title(_ lang: AppLanguage) -> String {
        let ja = lang == .japanese
        switch self {
        case .longPress:   return ja ? "2秒長押し"              : "Hold for 2 seconds"
        case .declaration: return ja ? "やることを宣言"          : "Declare what's next"
        case .scrollFeed:  return ja ? "ライバルの進捗を見る"     : "See your rivals' progress"
        case .imageScroll: return ja ? "自分で設定した画像を見る" : "See the image you chose"
        case .random:      return ja ? "ランダム"                          : "Random"
        case .none:        return ja ? "ハードロックモード"                  : "Hard lock"
        }
    }

    /// ⚠️ Text waiting for user review
    func detail(_ lang: AppLanguage) -> String {
        let ja = lang == .japanese
        switch self {
        case .longPress:
            return ja ? "終了ボタンを2秒長押ししてから解除" : "Hold the end button for 2 seconds, then unlock"
        case .declaration:
            return ja
                ? "休憩が終わったら何をやるか、一行で書いてから解除"
                : "Write one line on what you'll do after the break, then unlock"
        case .scrollFeed:
            return ja
                ? "ライバルがどれだけ前に進んでいるか確認してから解除"
                : "Check how far your rivals have moved ahead, then unlock"
        case .imageScroll:
            // ✅ Confirmed by the user on 2026-09-05 (chosen from 3 options). Only here, instead of "unlock after
            //    doing X", the user chose a form that uses "必ず見る" ("must view") to add force
            return ja
                ? "自分を奮い立たせる画像を、解除の前に必ず見る"
                : "Always look at the image that fires you up before unlocking"
        case .random:
            return ja ? "選んだ中からどれが来るか分からない" : "You won't know which one you get"
        case .none:
            // ⚠️ The user will review all of the text later (2026-08-29).
            //    Claude pointed out twice that "it would be a lie, because deleting the app unlocks it", but
            //    the user decided to adopt this wording. Do not bring it up again
            return ja
                ? "何をしてもロックを解除できない。セッションも終了できない"
                : "Nothing can lift this lock. The session can't be ended"
        }
    }
}
