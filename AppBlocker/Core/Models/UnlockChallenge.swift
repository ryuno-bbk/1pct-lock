//
//  UnlockChallenge.swift
//  AppBlocker
//
//  ロックを解除するために課す「課題」= 難易度モード。
//
//  背景 (2026-08-28 ユーザーと設計):
//    海外で伸びている同種アプリ (Touch Grass / PushUp Time 等) は、
//    カメラで現実の行動を証明させて解除させる。アプリ内で完結する難しさより
//    段違いに強い、というのが出発点。
//
//  🔴 腕立て・スクワットは 2026-08-29 に廃止した。
//    端末内 Vision の身体ポーズ検出で実装したが、実機で2度とも使い物にならなかった
//    (「ボトムで少し動いただけで大量にカウント」)。肩幅で正規化する設計上、
//    分母が揺れると比が跳ね上がる。動きの追跡そのものが不安定だったため、
//    静止画1枚で判定する「ノート+ペン」に一本化する判断。
//    復元が要る場合は commit 8ace469 以前を見ること。
//
//  🔴 設計の芯:
//    - 課題は「ロックを始めるとき」に決める。止めようとしている瞬間に選べたら縛りにならない
//    - 走っているセッションは開始時の課題を焼き付けて持つ (UnlockChallengeService)。
//      そのため設定を後から変えても、いま走っているロックは緩まない
//    - 脱出口は常にある (アプリを消せば Screen Time の遮断も消える)。
//      それを塞ぐことはできないし、塞いだと嘘をついてもいけない
//

import Foundation

enum UnlockChallenge: String, CaseIterable, Codable, Identifiable {

    /// 2秒長押し。既存の中断画面がすでにやっている摩擦 = 現状維持の既定値
    case longPress
    /// 休憩が終わったあとにやる作業を1行書く (実行意図 / if-then プラン)。
    /// メタ分析で d=0.65 (Gollwitzer & Sheeran 2006, 94試験) と、行動変容で最も実証された技法。
    /// 🔴 「解除したら何をするか」ではなく「休憩が終わったら何をやるか」を聞く。
    ///    前者の正直な答えは「スクロールする」で、聞く意味が無い (2026-08-29 ユーザー指摘)
    case declaration
    /// フィードの投稿を N 件見る (中核ループ: ロック中の衝動をアプリ内で満たす)
    case scrollFeed
    /// 自分で登録した画像を見る。中身は毎回ランダム。端末内保存 (サーバーに上げない)
    case imageScroll
    /// 候補プールから抽選。🔴 プールはユーザーが選ぶ。
    /// 全ミッションから完全ランダムにすると「電車の中でノートが出る」で詰む
    case random
    /// 解除手段を出さないモード。
    /// 🔴 文言に「何をしてもロックを解除できません」は使わないこと。事実ではない
    ///    (アプリを消せば必ず解除される)。「このモードでは解除できません」= アプリ内では真実
    case none

    var id: String { rawValue }

    /// ピッカーに出す順序。random / none は下に置く
    static var pickable: [UnlockChallenge] {
        [.longPress, .declaration, .scrollFeed, .imageScroll, .none]
    }

    /// 抽選の候補になれるか (random 自身と none は候補にしない)
    var canBeRandomCandidate: Bool {
        switch self {
        case .random, .none: return false
        default:             return true
        }
    }

    /// Pro 限定か (2026-08-28 ユーザー確定: 投稿とスクロールのみ無料)
    var requiresPro: Bool {
        switch self {
        // 解除方法で課金は作らない。ロックの手段 (スケジュール/位置) が既に Pro なので、
        // ここで弱い機能を並べて特典を水増しする必要が無い (2026-08-29 確定)
        case .longPress, .declaration, .scrollFeed, .imageScroll, .random: return false
        // 🔴 ハードモードだけ Pro。Opal も Deep Focus を有料にしている
        case .none:                                                        return true
        }
    }

    /// 実装済みか。段階的に足すので、未実装のものはピッカーに出さない。
    /// 🔴 未実装のものを既定やランダム候補に混ぜないこと (解除不能になる)
    var isImplemented: Bool {
        switch self {
        case .longPress, .declaration, .scrollFeed, .imageScroll, .none: return true
        // random は後回し (方法が複数あれば切替自体が変化になる)
        case .random:                                                    return false
        }
    }

    /// 行の左に出す SF Symbol (2026-09-05 ユーザー指定)。
    /// 🔴 文字が地味で「どれがどれか分からない」という実機フィードバックへの対応。
    ///    アイコンはテキストとは別の固定幅カラムに置くこと (同じ HStack に混ぜると
    ///    タイトルの折り返し位置が方法ごとにズレる)
    var icon: String {
        switch self {
        case .longPress:   return "stop.circle.fill"   // 停止マーク = 終了ボタンを押し続ける
        case .declaration: return "note.text"          // ノート = 宣言を書く
        case .scrollFeed:  return "person.3.fill"      // 他人が何人か = ライバル
        case .imageScroll: return "photo.fill"         // 画像
        case .random:      return "shuffle"
        case .none:        return "lock.fill"          // 南京錠 = ハードロック
        }
    }

    /// ✅ 日本語はユーザー口述 (2026-09-05)。「〜して解除 / 〜してから解除」で語尾を統一し、
    ///    タイトルだけで「何をすれば解除できるか」が分かる形にした。
    /// ⚠️ 英語はユーザー添削待ち (ネイティブ総点検が未実施)
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

    /// ⚠️ 文言はユーザー添削待ち
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
            // ✅ 2026-09-05 ユーザー確定 (3案から選択)。ここだけ「〜してから解除」ではなく
            //    「必ず見る」で強制力を出す形をユーザーが選んだ
            return ja
                ? "自分を奮い立たせる画像を、解除の前に必ず見る"
                : "Always look at the image that fires you up before unlocking"
        case .random:
            return ja ? "選んだ中からどれが来るか分からない" : "You won't know which one you get"
        case .none:
            // ⚠️ 文言はユーザーが後で全部添削する (2026-08-29)。
            //    Claude は「アプリを消せば解除されるので嘘になる」と2度指摘したが、
            //    ユーザー判断でこの表現を採用。再度蒸し返さないこと
            return ja
                ? "何をしてもロックを解除できない。セッションも終了できない"
                : "Nothing can lift this lock. The session can't be ended"
        }
    }
}
