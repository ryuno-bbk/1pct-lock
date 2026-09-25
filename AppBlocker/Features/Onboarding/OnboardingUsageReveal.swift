//
//  OnboardingUsageReveal.swift
//  AppBlocker
//
//  診断オンボーディング NEW ステップ (2026-07 再設計): Q3 (1日時間) の直後に挿入。
//  実測スクリーンタイムは DeviceActivityReport (UsageReportExtension) が拡張の中で描画する
//  (実測値は拡張の外に持ち出せない)。本ファイルはその埋め込みと、拡張が描画されない時の
//  フォールバック表示を持つ。
//
//  内部フロー (すべて1つの OnboardingStep 内の @State phase で進行):
//    PHASE 1 loading  — 1% モノグラムのスプラッシュ演出 (「分析中…」の脈動ドットは廃止)
//    PHASE 2 reveal   — 予想 vs 実際の比較 (拡張) → CTA で進む
//    PHASE 3 topApps  — 使用量トップ3 (拡張) → onContinue()
//
//  実測データが遅い/取得不可の場合のフォールバックは実データを一切持たない:
//  reveal は本人の予想 (Q3 の回答) だけを「自分の予想」として出し、topApps は
//  topAppsCard の中身 (skeletonBarWidthRatios、ニュートラルなスケルトン行) を出す。
//  2026-09-26: 旧フォールバックの「自己申告 × 2.2 を実際の使用時間とした比較チャート」と
//  「予想より多く使っています」見出しは捏造値だったため撤去。
//

import SwiftUI
import DeviceActivity

struct UsageRevealStepView: View {
    /// Q3 (1日何時間スマホを見ているか) の回答。拡張へ渡す予想値と、
    /// 拡張が描画されない時のフォールバック表示 (自分の予想) に使う
    let dailyHours: QuizDailyHours?
    let onContinue: () -> Void

    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    @State private var phase: RevealPhase = .loading

    /// reveal フェーズのフォールバック表示 (自己申告の予想のみ) の不透明度。
    /// 実機で「棒グラフ出現の瞬間、捏造値(16h)のプレースホルダー棒が0.1秒だけ見えてから
    /// 実測レポートに置き換わる」フリッカーが報告された (2026-07-17)。原因はプレースホルダーが
    /// 即時表示されるのに対し、上に重なる DeviceActivityReport (拡張) の描画完了がわずかに
    /// 遅れること。対策として reveal 突入直後は不透明度0で隠し、拡張が普通に描画を終える
    /// であろう時間 (約0.8秒) が過ぎてから初めてフェードインさせる。
    /// → 拡張が通常どおり描画される限り、このプレースホルダーはユーザーの目に一切触れない。
    /// 拡張の描画が遅い/失敗した場合だけ、0.8秒後にフォールバックとして現れる。
    /// 2026-09-26: 捏造値 (自己申告×2.2) の棒は撤去し、中身は本人の予想だけになった。
    /// 拡張より先に別の画面が一瞬見えるフリッカー自体は同じく起きうるので、遅延はそのまま維持。
    /// topApps 側のニュートラルなスケルトンは「読み込み中」の表現として正当なので対象外 (即時表示のまま)
    @State private var revealPlaceholderOpacity: Double = 0

    /// レポート層 (DeviceActivityReport) の不透明度。
    /// reveal→topApps の context 切替時、拡張が新シーンを描き終わるまで古い比較チャート
    /// (実測値の棒) が 0.1 秒ほど残って見える実機FB (2026-07-17) → 切替の間だけレポート層を
    /// 隠し、下の topApps スケルトン (正当な読み込み表現) を見せてから再フェードインする
    @State private var reportOpacity: Double = 1

    /// レポートのマウントはステップ遷移アニメーション (スライド+フェード 0.42s) の完了後に遅らせる。
    /// SwiftUI の opacity は ZStack の子それぞれに乗算適用されるため、遷移フェード中は
    /// 「不透明なはずのローディング幕」も半透明になり、下にマウント済みのレポート (暖機中の
    /// 拡張が前回パスの描画を即時表示することがある) が一瞬透けて見える (2026-07-25 実機FB:
    /// 解析中へ遷移する瞬間のヒストグラムのチラつき)。遷移完了後にマウントすれば構造的に起きない
    @State private var reportMounted = false

    private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .english }

    private enum RevealPhase { case loading, reveal, topApps }

    // MARK: - 予想 (自己申告)

    /// 自己申告の1日時間 (中央値)
    private var estimateDailyHours: Double { dailyHours?.medianHours ?? 4 }

    /// フォールバック表示に出す予想。本人が選んだ選択肢の文言そのもの (例: "4〜6時間")。
    /// 中央値 (medianHours) は計算用の代表値で本人の回答ではないため、表示には使わない。
    /// 未回答 (nil) なら値は出さない
    private var estimateAnswerLabel: String? { dailyHours?.label(lang) }

    // 「実際の使用時間」のプレースホルダ (自己申告 × 2.2、上限16h) と、それを使っていた
    // 比較チャート・「予想より多く」見出しは 2026-09-26 に撤去 (捏造値のため)。
    // 実測値は拡張の外に持ち出せないので、拡張が描画されない時に本体側で出せる「実際の値」は無い

    var body: some View {
        ZStack {
            // 実測レポート層は「このステップに入った瞬間から常駐」させ、ローディング演出
            // (2〜3秒) の裏で拡張プロセスを暖機する。
            // 旧実装は reveal 到達時に初めて DeviceActivityReport をマウントしていたため、
            // 拡張のコールドスタート描画遅延で 1回目に必ずプレースホルダ (中央グラフ+灰トップ3) が
            // 見え、トップ3画面へ往復して暖機された2回目でようやく実測レポート (CTA寄りグラフ+
            // 実アプリ) が出る、という「レイアウトが2つある」ように見える持ち越しバグの原因だった
            // (2026-07-25 修正)。単一インスタンスのまま context だけ切替える構成は維持
            // (2個目白紙バグの唯一の回避策)
            reportLayer

            // ローディングスプラッシュは不透明オーバーレイ。裏で暖機中のレポートを覆い隠す
            if phase == .loading {
                loadingView
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AppColors.background)
                    .transition(.opacity)
            }
        }
        .onAppear {
            // Report 拡張への入力 (自己申告の予想値+言語) を先に App Group へ書いておく。
            // ローダーの2〜3秒が拡張のプリウォームも兼ねる
            AppGroupStorage.shared.saveOnboardingRevealInputs(
                estimateMinutes: Int((estimateDailyHours * 60).rounded()),
                languageRaw: lang == .japanese ? "japanese" : "english"
            )

            // レポートはステップ遷移アニメ完了後にマウント (詳細は reportMounted のコメント)。
            // App Group への入力書き込み (上) より必ず後になるので、拡張は正しい予想値で描画する
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                reportMounted = true
            }

            guard phase == .loading else { return }
            // モノグラム演出を2〜3秒ホールド (Reduce Motion 時は短縮)
            let delay = UIAccessibility.isReduceMotionEnabled ? 0.4 : Double.random(in: 2.0...3.0)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                withAnimation(.easeOut(duration: 0.4)) { phase = .reveal }
            }
        }
    }

    // MARK: - Phase 1: ローディング (モノグラムスプラッシュ)

    private var loadingView: some View {
        VStack(spacing: 28) {
            Spacer()
            // アプリの実アイコン (1% モノグラム) の静止形に斜めの光帯が走るシマーローダー
            // (2026-07-17 刷新。旧「2点が跳ねて入れ替わる」はユーザーFBで却下)
            MonogramSwapLoader(size: 108)
            // 「解析中」のグロウ文字 (2026-07-17 ユーザー要望。旧「1%」ワードマークを置換 —
            // モノグラムがブランドを担うので、文字は今なにをしているかを言う)
            GlowingAnalyzingText(lang: lang)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Phase 2: 予想 vs 実際

    private var reportLayer: some View {
        VStack(spacing: 0) {
            // 実測レポート (UsageReportExtension) を最前面に重ねる。
            // レポートが描画されれば不透明黒背景でプレースホルダを完全に覆い、
            // 描画されない/遅い場合は下のプレースホルダ (自己申告ベース) が見える。
            // DeviceActivityReport は単一インスタンスのまま context だけ切り替える
            ZStack {
                // プレースホルダ (拡張未描画時のフォールバック)。暖機済みなら拡張が上を覆う。
                // loading/reveal は comparison 用プレースホルダを敷く (topApps は topApps 用)
                if phase == .topApps {
                    placeholderTopAppsContent
                } else {
                    // フォールバックのフリッカー対策 (詳細は revealPlaceholderOpacity のコメント)
                    placeholderRevealContent
                        .opacity(revealPlaceholderOpacity)
                }
                // loading と reveal はどちらも comparison を出し続けるため、loading 中に暖めた
                // comparison レポートがそのまま reveal で使え、再コールドスタートしない。
                // topApps への切替は .id で「インスタンスごと再生成」する (2026-07-25 実機FB:
                // 同一インスタンスの context 差し替えだと初回だけ topApps シーンが描画されず、
                // 戻って再突入 (=ビュー再生成) すると出る症状 → 再生成が効いている状況証拠。
                // 同時マウントは常に1個なので「2個目白紙」バグ (2026-07-13) は踏まない。
                // データクエリはフィルタ同一で暖機済みのため再描画は速く、切替中の空白は
                // 下のスケルトン+reportOpacity の演出が既にカバーしている)
                if reportMounted {
                    usageReport(.init(phase == .topApps ? "onboardingTopApps" : "onboardingComparison"))
                        .id(phase == .topApps ? "report-topApps" : "report-comparison")
                        .opacity(reportOpacity)
                }
            }
            .task(id: phase) {
                guard phase == .reveal else { return }
                revealPlaceholderOpacity = 0
                try? await Task.sleep(nanoseconds: 800_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .easeIn(duration: 0.3)) {
                    revealPlaceholderOpacity = 1
                }
            }

            // CTA は常設し、ローディング中は opacity で隠すだけにする (2026-07-25 レビュー修正)。
            // `if` で外すと loading→reveal でレポート層の高さが CTA 分変わり、
            // 暖機したレイアウトと表示レイアウトのサイズがズレる (拡張のリモートビューが
            // フェード中に再レイアウトされてガタつくリスク)。枠を固定して暖機を表示サイズと一致させる
            PrimaryButton(lang == .japanese ? "次へ" : "Next") {
                if phase == .reveal {
                    // context 切替フリッカー対策 (詳細は reportOpacity のコメント):
                    // ①レポート層を隠す → ②phase 切替 (下はスケルトンが見える) →
                    // ③新シーンの描画が終わる頃に再フェードイン。
                    // レポートを消す前にプレースホルダを即座に 0 へ (2026-07-25 実機FB:
                    // レポートのフェードアウトで下のフォールバック (当時は捏造値チャート 11h 等) が一瞬露出していた)
                    revealPlaceholderOpacity = 0
                    withAnimation(.easeOut(duration: 0.1)) { reportOpacity = 0 }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        withAnimation(.easeOut(duration: 0.3)) { phase = .topApps }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                            withAnimation(.easeIn(duration: 0.25)) { reportOpacity = 1 }
                        }
                    }
                } else {
                    onContinue()
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
            .opacity(phase == .loading ? 0 : 1)
            .allowsHitTesting(phase != .loading)
        }
    }

    /// 自己申告のみのフォールバック表示 (レポート未描画時)。実測が無いので「実際の使用時間」・
    /// 「予想より多く」・比較チャートは出さず、本人の予想だけを「自分の予想」として見せる (2026-09-26)
    private var placeholderRevealContent: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 72)

            Text(revealHeadline)
                .font(.system(size: 26, weight: .bold)) // 拡張の見出しと同一書体 (2026-07-27 統一)
                .foregroundColor(AppColors.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)

            Spacer()

            // 予想の1本棒のみ (棒の高さは固定で、値を表さない)。旧実装は自己申告×2.2 の捏造値との
            // 比較チャート / 「実際の使用時間」の1本棒を出していた (2026-09-26 撤去)
            SingleUsageBar(valueLabel: estimateAnswerLabel, lang: lang)

            // 拡張の ComparisonReportView と同じ下寄せ (Spacer 44) に揃える。旧実装はここが
            // 可変 Spacer() でチャートが画面中央に来ていたため、拡張 (CTA寄り) と位置が食い違い
            // 「グラフの場所が2つある」ように見えていた (2026-07-25 修正)
            Spacer().frame(height: 44)
        }
    }

    // MARK: - 実測レポート埋め込み (UsageReportExtension)

    /// 集計期間 (昨日までの丸7日間)。@State で固定して再レンダーごとに DateInterval が変わり
    /// レポートが再クエリされ続けるのを防ぐ。
    /// 端を日付境界に揃える理由 (2026-07-19 実機FB「平均が実際より少なく出る」の修正):
    /// 旧実装は「今この瞬間〜7日前の同時刻」だったため、先頭・末尾に不完全な日 (部分データ) が
    /// 2つ混ざり、拡張側は日次セグメント数で割るので平均が系統的に低く出ていた。
    /// 今日 (進行中で不完全) を含めず、日付境界で切った丸7日にすることで正しい1日平均になる
    @State private var reportInterval: DateInterval = {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -7, to: todayStart) ?? todayStart
        return DateInterval(start: start, end: todayStart)
    }()

    /// 過去7日・日次セグメントのフィルタ。Context の rawValue は拡張側の宣言と完全一致必須
    private func usageReport(_ context: DeviceActivityReport.Context) -> some View {
        let filter = DeviceActivityFilter(
            segment: .daily(during: reportInterval),
            users: .all,
            devices: .init([.iPhone])
        )
        return DeviceActivityReport(context, filter: filter)
            .allowsHitTesting(false)
    }

    private var revealHeadline: String {
        // フォールバックは実測を持たないので「実際の使用時間」「予想より多く使っています」は出さない
        // (どちらも実測があって初めて言える文言。出すのは拡張側 TotalActivityView だけ)。
        // 見出しは既存ラベル「自分の予想」を流用し、新規文言は作らない (2026-09-26)
        lang == .japanese ? "自分の予想" : "Your guess" // 文言はユーザー添削待ち (既存ラベルの流用)
    }

    // MARK: - Phase 3: 使用量トップ3

    /// スケルトン行の名前バー幅比率 (0...1)。以前はここに「YouTube 7時間18分」等の具体的な
    /// 捏造データを並べていたが、実測レポートの描画が遅れた瞬間にこのプレースホルダが見えると
    /// 本物のデータと誤認されるリスクがあったため、中身を持たないニュートラルなスケルトン行に
    /// 変更した (2026-07 クリーンアップ)。行ごとに幅を変えて不揃いなスケルトンらしさだけ残す
    private let skeletonBarWidthRatios: [CGFloat] = [0.62, 0.46, 0.52]

    /// プレースホルダ表示 (レポート未描画時のフォールバック)
    private var placeholderTopAppsContent: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 72)

            Text(lang == .japanese ? "最近最も\n使っているアプリ" : "Apps you use\nthe most")
                .font(.system(size: 26, weight: .semibold))
                .foregroundColor(AppColors.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            Spacer().frame(height: 36)

            topAppsCard

            Spacer()
        }
    }

    private var topAppsCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(lang == .japanese ? "使用量トップ3" : "Top 3 by usage")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(AppColors.textTertiary)

            VStack(spacing: 18) {
                ForEach(Array(skeletonBarWidthRatios.enumerated()), id: \.offset) { _, ratio in
                    SkeletonTopAppRow(nameBarWidthRatio: ratio)
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(AppColors.cardBackground)
        )
        .padding(.horizontal, 24)
    }
}

// MARK: - 実測レポートの事前暖機 (2026-07-25 実機FB第26弾)

/// 生年月日/性別ステップの裏に見えない DeviceActivityReport をマウントし、
/// 拡張プロセスの起動 + DeviceActivity クエリを事前に済ませておく。
/// 実機観測: usageReveal 到達時のコールドスタートはローディング演出 (2〜3秒) より遅く、
/// 1回目は比較チャートすらプレースホルダ (当時は捏造値) のまま + トップ3不発。一度通した「2回目」は
/// 即描画される → クエリ/プロセスが暖まってさえいれば速い、が事前暖機の根拠。
/// ⚠️ サイズは 1×1 固定 (2026-07-27 確定): FB27で「縦縮み」の犯人を1×1レイアウトキャッシュと
/// 誤診して全画面化したが、実態は縮んだグラフ=プレースホルダの別実装 (現在は拡張と完全一致に修正済み)。
/// しかも全画面化した回はトップ3まで不発に退行 (1×1だったFB27はトップ3成功) → 実績のある1×1へ巻き戻し。
/// ⚠️ フィルタは UsageRevealStepView.reportInterval / usageReport と完全一致させること
/// (deviceactivityd のクエリキャッシュを共有させるため)。
/// ⚠️ マウントは quizBirthDate/quizGender のみ (usageReveal と同時マウントすると
/// 「2個目が白紙」の既知バグを踏む。間に quizDailyHours を挟んで共存を構造的に防ぐ)
struct UsageReportWarmUpView: View {
    private let interval: DateInterval = {
        let cal = Calendar.current
        let todayStart = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .day, value: -7, to: todayStart) ?? todayStart
        return DateInterval(start: start, end: todayStart)
    }()

    var body: some View {
        DeviceActivityReport(
            .init("onboardingComparison"),
            filter: DeviceActivityFilter(
                segment: .daily(during: interval),
                users: .all,
                devices: .init([.iPhone])
            )
        )
        .frame(width: 1, height: 1)
        .opacity(0.02) // 完全 0 だと描画スキップされる可能性があるため僅かに残す (黒背景上で不可視)
        .allowsHitTesting(false)
    }
}

// MARK: - フォーマットヘルパー

// (formatDuration / QuizDailyHours.revealRangeLabel は 2026-07-27 の拡張表記統一で死コード化し削除)
// (reportDurationLabel と比較チャート UsageComparisonChart は 2026-09-26 の捏造値撤去で死コード化し削除。
//  実測値は拡張の外に出せないため、本体側の比較チャートは捏造値でしか埋められない)

// MARK: - ローダー (% の2点スワップ)

/// アプリの実アイコン (MonogramMark = 1% モノグラム) と**全く同じジオメトリ**のローダー
/// (2026-07-17 全面刷新)。旧「%の2点が棒を飛び越えて入れ替わる」演出はユーザーFBで
/// 「跳ねる・回る系はダサい」と却下 → 動きを「光」だけに絞る:
/// 静止した 1% モノグラムの上を、斜めの光帯 (シマー) が一定周期で走り抜ける。
/// 光帯はモノグラム形状でマスクされるため、グリフの中だけが順に光る。
/// 高級ブランドのスケルトンローディングと同じ文法で、形は一切動かさない。
/// Reduce Motion 時は静止したモノグラムのみ
private struct MonogramSwapLoader: View {
    let size: CGFloat

    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    @State private var sweep = false
    @State private var breathe = false

    var body: some View {
        ZStack {
            MonogramMark(assembled: true, size: size)
                .opacity(0.9)

            if !reduceMotion {
                // 斜めの光帯。offset をグリフ幅より外→外へ走らせ、repeatForever の
                // 折り返しジャンプはマスク外で起きるため見えない (ポーズ区間も兼ねる)
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .white.opacity(0.9), location: 0.5),
                        .init(color: .clear, location: 1)
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: size * 0.55, height: size * 1.7)
                .rotationEffect(.degrees(24))
                .offset(x: sweep ? size * 1.25 : -size * 1.25)
                .mask(MonogramMark(assembled: true, size: size))
                .allowsHitTesting(false)
            }
        }
        .frame(width: size, height: size)
        // ゆっくり呼吸 (2026-07-17 ユーザーFB「アニメーションつけなくていいの?」への追加。
        // 移動系は使わない原則のまま、スケールの微振動だけ足す)
        .scaleEffect(breathe ? 1.025 : 1.0)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                sweep = true
            }
            withAnimation(.easeInOut(duration: 1.9).repeatForever(autoreverses: true)) {
                breathe = true
            }
        }
    }
}

/// 「解析中」のグロウ文字 (2026-07-17 ユーザー要望)。
/// 同じ文字列をブラー化した下層を重ね、その不透明度だけを呼吸させて白いハローを作る
/// (ブラー半径は固定 = 毎フレームのブラー再計算を避ける。blur 負荷の教訓)。
/// 末尾の3点は解析の進行感として順に点灯する。Reduce Motion 時は静止
private struct GlowingAnalyzingText: View {
    let lang: AppLanguage

    @State private var glow = false
    @State private var litDots = 0

    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    var body: some View {
        ZStack {
            textContent
                .blur(radius: 7)
                .opacity(reduceMotion ? 0.4 : (glow ? 0.95 : 0.25))
            textContent
        }
        .onAppear {
            guard !reduceMotion else { litDots = 3; return }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                glow = true
            }
        }
        .task {
            guard !reduceMotion else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 380_000_000)
                withAnimation(.easeOut(duration: 0.25)) {
                    litDots = (litDots + 1) % 4
                }
            }
        }
    }

    private var textContent: some View {
        HStack(alignment: .center, spacing: 3) {
            Text(lang == .japanese ? "解析中" : "Analyzing") // 文言はユーザー添削待ち
                .font(.system(size: 16, weight: .semibold))

            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .frame(width: 3.5, height: 3.5)
                        .opacity(litDots > i ? 1 : 0.25)
                }
            }
            .padding(.top, 6)   // ベースライン付近に揃える
        }
        .foregroundColor(AppColors.textPrimary)
    }
}

/// フォールバックの単一バー表示 (本人の予想)。棒の高さは固定で、値を表さない。
/// ⚠️ 拡張 (TotalActivityView.singleBar) と同一ジオメトリ厳守 (2026-07-27 実機FB: 拡張と寸法が
/// 食い違うと、プレースホルダが出た時だけ「グラフが縮んでずれる」ように見えた)。拡張側を変えたら追随
private struct SingleUsageBar: View {
    /// 本人が選んだ予想の文言 (例: "4〜6時間")。nil なら値は出さない (枠の高さだけ確保)
    let valueLabel: String?
    let lang: AppLanguage

    private let barHeight: CGFloat = 220

    var body: some View {
        VStack(spacing: 12) {
            // 2026-09-26: 以前はここに捏造値 (自己申告×2.2) を不可視で置いていた。
            // 現在は本人の予想をそのまま出す (見出し「自分の予想」の下)
            Text(valueLabel ?? " ")
                .font(.system(size: 40, weight: .bold))
                .foregroundColor(AppColors.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)
                .opacity(valueLabel == nil ? 0 : 1)

            RoundedRectangle(cornerRadius: 12)
                .fill(AppColors.textPrimary)
                .frame(width: 84, height: barHeight)

            Text(lang == .japanese ? "1日の平均使用時間" : "Daily average")
                .font(.system(size: 13))
                .foregroundColor(AppColors.textTertiary)
        }
    }
}

// MARK: - 使用量トップ3 (スケルトン、実測レポート未描画時のフォールバック)

/// トップ3の1行。以前はここに実在するアプリ名 (YouTube 等) + 捏造した使用時間 + 色付き
/// アイコンタイルを表示していたが、実測レポート (UsageReportExtension) の描画が遅れて
/// これが一瞬でも見えた場合に「本物のデータ」と誤認されるリスクがあった。
/// アプリ名/時間/アイコンの色を一切持たないニュートラルな灰色バーのスケルトンに変更し、
/// レイアウトの footprint (アイコン40x40 / 2行 / バー高6) だけは実データ版と同一に保つ
/// (2026-07 クリーンアップ)
private struct SkeletonTopAppRow: View {
    /// 名前バーの幅比率 (0...1、行の横幅に対する割合)。行ごとに変えて
    /// 不揃いなスケルトンらしさだけ残す
    let nameBarWidthRatio: CGFloat

    private var skeletonColor: Color { AppColors.textTertiary.opacity(0.18) }

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 10)
                .fill(skeletonColor)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(skeletonColor)
                            .frame(width: geo.size.width * nameBarWidthRatio, height: 14)
                    }
                    .frame(height: 14)

                    Spacer(minLength: 12)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(skeletonColor)
                        .frame(width: 34, height: 12)
                }

                Capsule()
                    .fill(skeletonColor)
                    .frame(height: 6)
            }
        }
    }
}
