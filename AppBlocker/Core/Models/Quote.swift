//
//  Quote.swift
//  AppBlocker
//
//  名言データモデル
//

import Foundation

/// 名言を表すモデル（英語・日本語対応 + 著者プロフィール）
struct Quote: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let authorId: UUID?
    let textEn: String
    let textJp: String
    let author: String
    let authorBioEn: String
    let authorBioJp: String
    let category: String?
    let likeCount: Int
    /// コメント数 (quotes.comment_count denormalize 列。既存データ互換のため optional 扱い、デフォルト 0)
    let commentCount: Int

    enum CodingKeys: String, CodingKey {
        case id
        case authorId = "author_id"
        case textEn = "text_en"
        case textJp = "text_jp"
        case author
        case authorBioEn = "author_bio_en"
        case authorBioJp = "author_bio_jp"
        case category
        case likeCount = "like_count"
        case commentCount = "comment_count"
    }

    init(
        id: UUID = UUID(),
        authorId: UUID? = nil,
        textEn: String,
        textJp: String,
        author: String,
        authorBioEn: String = "",
        authorBioJp: String = "",
        category: String? = nil,
        likeCount: Int = 0,
        commentCount: Int = 0
    ) {
        self.id = id
        self.authorId = authorId
        self.textEn = textEn
        self.textJp = textJp
        self.author = author
        self.authorBioEn = authorBioEn
        self.authorBioJp = authorBioJp
        self.category = category
        self.likeCount = likeCount
        self.commentCount = commentCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        authorId = try container.decodeIfPresent(UUID.self, forKey: .authorId)
        textEn = try container.decode(String.self, forKey: .textEn)
        textJp = try container.decode(String.self, forKey: .textJp)
        author = try container.decodeIfPresent(String.self, forKey: .author) ?? ""
        authorBioEn = try container.decodeIfPresent(String.self, forKey: .authorBioEn) ?? ""
        authorBioJp = try container.decodeIfPresent(String.self, forKey: .authorBioJp) ?? ""
        category = (try? container.decodeIfPresent(String.self, forKey: .category)) ?? nil
        likeCount = try container.decodeIfPresent(Int.self, forKey: .likeCount) ?? 0
        commentCount = try container.decodeIfPresent(Int.self, forKey: .commentCount) ?? 0
    }
}

// MARK: - 言語別表示ヘルパー
extension Quote {
    /// 視覚的に上に大きく出るテキスト
    /// - メイン日本語 + 原文併記ON のときは「英語」を上に大きく出す（原文を主役に）
    /// - それ以外（英語メイン、または日本語のみ）はメイン言語のテキスト
    func displayPrimary(lang: AppLanguage, showOriginal: Bool) -> String {
        if lang == .japanese && showOriginal && !textEn.isEmpty {
            return textEn
        }
        switch lang {
        case .japanese: return textJp.isEmpty ? textEn : textJp
        case .english:  return textEn
        }
    }

    /// 下に小さく添えるサブテキスト。メイン日本語+原文併記ON のときだけ「日本語訳」を返す
    func displaySecondary(lang: AppLanguage, showOriginal: Bool) -> String? {
        guard lang == .japanese, showOriginal, !textJp.isEmpty else { return nil }
        return textJp
    }
}

// MARK: - カテゴリ表示用ヘルパー
extension Quote {
    /// カテゴリ raw key → 日本語表示名 辞書
    /// Supabase 側でカテゴリ追加されたらここに追記。未登録の category は raw string でフォールバック表示される。
    static let categoryDisplayJa: [String: String] = [
        "mindset":      "マインドセット",
        "action":       "行動",
        "discipline":   "規律",
        "work-ethic":   "努力",
        "growth":       "成長",
        "hardship":     "困難",
        "self-belief":  "自信",
        "consistency":  "継続",
        "failure":      "失敗",
        "focus":        "集中",
        "fear":         "恐怖",
        "sports":       "スポーツ",
        "philosophy":   "哲学",
        "success":      "成功",
        "motivation":   "モチベーション",
        "life":         "人生"
    ]

    /// カテゴリ raw key → 英語表示名 辞書
    static let categoryDisplayEn: [String: String] = [
        "mindset":      "Mindset",
        "action":       "Action",
        "discipline":   "Discipline",
        "work-ethic":   "Work Ethic",
        "growth":       "Growth",
        "hardship":     "Hardship",
        "self-belief":  "Self-Belief",
        "consistency":  "Consistency",
        "failure":      "Failure",
        "focus":        "Focus",
        "fear":         "Fear",
        "sports":       "Sports",
        "philosophy":   "Philosophy",
        "success":      "Success",
        "motivation":   "Motivation",
        "life":         "Life"
    ]

    /// カテゴリの表示名を返す。辞書未登録なら raw key そのままを返す (起動を壊さない安全フォールバック)
    static func categoryDisplay(_ category: String, lang: AppLanguage) -> String {
        let dict = lang == .japanese ? categoryDisplayJa : categoryDisplayEn
        return dict[category] ?? category
    }
}

// MARK: - 投稿タイトルの表示用クリーニング (2026-08-02: ハッシュタグ二重表示バグ修正)
// PostConfirmView の保存処理が「tags を抽出しつつ、#タグを含んだままの title」も
// 一緒に保存していたため、フィード上で同じタグが title 側とタグ行に二重表示されていた
// (末尾に単独 # が残ることもある、# チップボタンの押しっぱなし残骸)。
// 既に DB に入っている汚れた title も直すため表示側で吸収する。
// PostConfirmView.extractTagKeys (title → tags キー抽出) の逆方向にあたる処理:
// tags キー → title 上の対応するハッシュタグ表示トークンを特定して取り除く
extension Quote {
    /// title から、tags (キー配列) に対応する #トークンと、中身が空の単独 "#" を取り除く。
    /// tags に無い #なんとか はユーザーが書いた地の文の可能性があるため残す (無言で消さない)。
    /// title が nil ならそのまま nil、空文字ならそのまま空文字を返す
    static func displayTitle(from title: String?, tags: [String]) -> String? {
        guard let title else { return nil }
        guard !title.isEmpty else { return title }

        // tags (キー) の日英どちらの表示名でも一致させる。title には表示名が入っている
        // (例: キー "discipline" は日本語なら "#規律"、英語なら "#Discipline" として保存されている)
        // ⚠️ 表示名には空白を含むものがある ("work-ethic" → 英語で "Work Ethic")。
        // 空白でトークン分割すると "#Work" までしか拾えず取りこぼすため、
        // 「# + 表示名」を丸ごとリテラルとして探す。長い方から消さないと
        // 部分一致で短い方が先に食ってしまうので降順に並べる
        let needles = Set(tags.flatMap { tag in
            [Self.categoryDisplay(tag, lang: .japanese), Self.categoryDisplay(tag, lang: .english)]
        })
        .filter { !$0.isEmpty }
        .map { "#" + $0 }
        .sorted { $0.count > $1.count }

        var cleaned = title
        for needle in needles {
            // 後ろに空白 / 別の # / 行末 が来るものだけを消す。境界を見ないと
            // ユーザーが書いた "#Growthマインド" の頭を削って "マインド" にしてしまう
            let pattern = NSRegularExpression.escapedPattern(for: needle) + "(?=[\\s#]|$)"
            cleaned = cleaned.replacingOccurrences(
                of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
        }
        // 中身が空の単独 "#" (候補を選ばずに # だけ入力された残骸) を消す。
        // 前後が空白/行端のものに限る = "C#" のような語中の # は残す
        cleaned = cleaned.replacingOccurrences(
            of: "(^|\\s)#(?=\\s|$)", with: "$1", options: [.regularExpression])

        // 何も消していない = 掃除の必要が無い title なので、ユーザーの文字列を一切加工せず返す
        // (下の空白畳み込みが全角スペース等を勝手に半角化してしまうのを避ける)
        guard cleaned != title else { return title }

        // 除去でできた連続スペースを1つに畳む (改行は段落構造として触らない)
        let collapsed = cleaned.replacingOccurrences(of: "[ \u{3000}]+", with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - 匿名著者の表示ルール (2026-07-30 名言全件監査)
// 実名全廃で全名言が匿名著者 Anonymous に付け替えられた。「— Anonymous」の行自体を
// 出さない (名言はテキスト+ハッシュタグのみ)。将来著者付き名言が復活したら自然に表示が戻る
extension Quote {
    static func isAnonymousAuthor(_ name: String?) -> Bool {
        guard let name, !name.isEmpty else { return true }
        return name == "Anonymous"
    }

    /// 画面に出してよい著者名。匿名 (Anonymous/空) なら nil = 行ごと非表示
    var displayAuthor: String? {
        Self.isAnonymousAuthor(author) ? nil : author
    }
}

// MARK: - Sample Data
// 2026-07-30 名言全件監査: 実名は全廃 (Quotes.json/DBと同じく匿名化)。フォールバックも
// ユーザーが「残す」と判定した名言のみで構成する
extension Quote {
    private static let anonymousBioEn = "Quotes whose original author is unknown or attributed to multiple sources."
    private static let anonymousBioJp = "原著者不明、または複数ソースに帰される名言を集約。"

    static let samples: [Quote] = [
        Quote(
            textEn: "The job's not finished.",
            textJp: "仕事はまだ終わっていない。",
            author: "Anonymous",
            authorBioEn: anonymousBioEn,
            authorBioJp: anonymousBioJp,
            category: "sports"
        ),
        Quote(
            textEn: "Hard work beats talent when talent doesn't work hard.",
            textJp: "才能が努力を怠れば、努力が才能を超える。",
            author: "Anonymous",
            authorBioEn: anonymousBioEn,
            authorBioJp: anonymousBioJp,
            category: "motivation"
        ),
        Quote(
            textEn: "Don't stop when you're tired. Stop when you're done.",
            textJp: "疲れた時に止まるんじゃない。終わった時に止まれ。",
            author: "Anonymous",
            authorBioEn: anonymousBioEn,
            authorBioJp: anonymousBioJp,
            category: "discipline"
        ),
        Quote(
            textEn: "It does not matter how slowly you go as long as you do not stop.",
            textJp: "止まりさえしなければ、どんなにゆっくりでも構わない。",
            author: "Anonymous",
            authorBioEn: anonymousBioEn,
            authorBioJp: anonymousBioJp,
            category: "philosophy"
        ),
        Quote(
            textEn: "Yesterday you said tomorrow.",
            textJp: "昨日、お前は明日やると言った。",
            author: "Anonymous",
            authorBioEn: anonymousBioEn,
            authorBioJp: anonymousBioJp,
            category: "motivation"
        )
    ]
}
