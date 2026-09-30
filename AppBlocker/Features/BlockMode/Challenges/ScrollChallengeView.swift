//
//  ScrollChallengeView.swift
//  AppBlocker
//
//  Shared component for the unlock challenges "みんなの進捗を見る" ("See everyone's progress") and
//  "自分で決めた画像を見る" ("See the images you chose").
//
//  🔴 The key part of this screen is the "やっぱり作業を続ける" ("Actually, keep working") button
//  (user idea, 2026-08-29):
//    The current unlock is a choice between "unlock or do nothing", and **"stop" does not exist on
//    the screen**. People only choose the options in front of them. By always showing "stop"
//    while they are forced to watch, the friction becomes **a chance to decide**.
//
//  🔴 Post mode uses the real feed UI as is.
//    This app uses AI moderation to reject anything outside the discipline ethos, so everything that
//    flows by is posts that encourage others. **Reading comments itself fits the purpose**, so
//    likes and comments are not blocked (user decision 2026-08-29).
//

import SwiftUI
import UIKit

struct ScrollChallengeView: View {

    enum Page: Identifiable {
        case post(FeedItem)
        case image(id: String, image: UIImage)

        var id: String {
            switch self {
            case .post(let item):    return "post-\(item.id)"
            case .image(let id, _):  return "image-\(id)"
            }
        }
    }

    let pages: [Page]
    /// How many items must be viewed before unlocking is allowed (given value)
    let requiredCount: Int
    let lang: AppLanguage
    let onCompleted: () -> Void
    /// 🔴 Actually keep working (= stop unlocking and go back to the lock)
    let onKeepWorking: () -> Void

    /// Pages accepted as viewed long enough
    @State private var seen: Set<String> = []
    /// Pages currently more than half visible on screen
    @State private var visibleIds: Set<String> = []
    /// 🔴 Flag that requires a scroll after one item is counted, before counting the next.
    ///    If 2 cards are both over 50% visible from the start, 2 items advance without moving a finger
    ///    (2026-08-29 real device report). The user's diagnosis was correct
    @State private var awaitingScroll = false
    /// Page currently being measured
    @State private var currentId: String?
    /// Displayed meter value (0...1)
    @State private var meterProgress: Double = 0
    @State private var dwellTask: Task<Void, Never>?

    @AppStorage("showOriginal") private var showOriginal = false

    /// Seconds before a page counts as "viewed". ⚠️ Value to tune on a real device
    private static let dwellSeconds: Double = 3.0

    private var ja: Bool { lang == .japanese }

    /// 🔴 Never require more items than the number of pages available.
    ///    Requiring 5 when there are only 3 images makes **unlocking impossible forever**
    ///    (2026-08-29 on a real device, it showed up as "stuck at 2 remaining")
    private var required: Int { max(1, min(requiredCount, pages.count)) }

    private var progress: Int { min(seen.count, required) }
    private var canUnlock: Bool { seen.count >= required }

    private var postItems: [FeedItem] {
        pages.compactMap { if case .post(let item) = $0 { return item } else { return nil } }
    }
    private var isPostMode: Bool { !postItems.isEmpty }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                AppColors.background.ignoresSafeArea()

                if pages.isEmpty {
                    emptyState
                } else if isPostMode {
                    FeedCardListView(
                        items: postItems,
                        recordsViews: false,
                        topContentInset: 40,
                        // 🔴 onAppear/onDisappear was too strict. Moving slightly
                        //    reset the meter (2026-08-29 real device report).
                        //    Changed to "50% visible counts as viewing"
                        onItemVisibilityChanged: { item, isVisible in
                            setVisible("post-\(item.id)", isVisible)
                        }
                    )
                    .onScrollPhaseChange { _, phase in
                        if phase != .idle { handleScroll() }
                    }
                } else {
                    imagePager
                }

                // 🔴 The top header is removed (2026-08-29 user instruction).
                //    The meter is merged into the unlock button at the bottom = one less component
                VStack(spacing: 0) {
                    Spacer()
                    if !pages.isEmpty {
                        bottomControls
                            .padding(.horizontal, 20)
                            .padding(.bottom, 24)
                    }
                }
            }
            // Do not show the black header background (match the look of My page)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .onDisappear { stopMeasuring() }
    }

    // MARK: - Image pager

    /// 🔴 Dropped the vertical pages that snap one at a time (YouTube Shorts style).
    ///    Use a **freely scrolling list of cards**, same as the feed (2026-08-29 user instruction).
    ///    No snap positions, and the aspect ratio matches posts at 4:5
    private var imagePager: some View {
        ScrollView {
            LazyVStack(spacing: 28) {
                ForEach(pages) { page in
                    pageView(page)
                        .id(page.id)
                        // 50% visible counts as "viewing" (same rule as post mode)
                        .onScrollVisibilityChange(threshold: 0.5) { isVisible in
                            setVisible(page.id, isVisible)
                        }
                }
            }
            .padding(.top, 40)
            .padding(.bottom, 140)
        }
        .scrollIndicators(.hidden)
        .onScrollPhaseChange { _, phase in
            if phase != .idle { handleScroll() }
        }
    }

    @ViewBuilder
    private func pageView(_ page: Page) -> some View {
        switch page {
        case .post(let item):
            Color.clear
                .aspectRatio(4.0 / 5.0, contentMode: .fit)
                .overlay { FeedCardMediaView(item: item, lang: lang, showOriginal: showOriginal) }
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .padding(.horizontal, 20)
        case .image(_, let image):
            // Same 4:5 frame as post cards. Other aspect ratios are filled with a blurred copy of the same image
            // (same method as FeedFitBlurImage. The image itself is never cropped)
            Color.clear
                .aspectRatio(4.0 / 5.0, contentMode: .fit)
                .overlay {
                    GeometryReader { geo in
                        ZStack {
                            Image(uiImage: image).resizable().scaledToFill()
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                                .blur(radius: 18)
                                .opacity(0.55)
                                .drawingGroup()
                            Image(uiImage: image).resizable().scaledToFit()
                                .frame(width: geo.size.width, height: geo.size.height)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .padding(.horizontal, 20)
        }
    }

    // MARK: - Dwell time measurement
    //
    // 🔴 The "cancel and restart" approach was fragile (happened often on a real device, 2026-08-29).
    //    Instead, keep the set of visible pages and re-pick the measured page from it.
    //    Leaving a page restarts the count from 0 every time (accumulation removed by user instruction
    //    2026-08-29).

    private func setVisible(_ id: String, _ isVisible: Bool) {
        if isVisible { visibleIds.insert(id) } else { visibleIds.remove(id) }
        syncCurrent()
    }

    /// Among the visible pages, measure "the first one not yet fully viewed"
    private func syncCurrent() {
        // 🔴 Stop counting once the required number is reached. If it keeps counting, the meter fills up
        //    behind the green "ロックを解除する" ("Unlock") button, which looks contradictory
        guard !canUnlock else {
            stopMeasuring()
            currentId = nil
            return
        }
        // Right after one item is counted, do not start counting the next until the finger moves
        guard !awaitingScroll else { return }
        let next = pages.first { visibleIds.contains($0.id) && !seen.contains($0.id) }?.id
        guard next != currentId else { return }

        stopMeasuring()
        currentId = next
        guard let next else {
            meterProgress = 0
            return
        }
        startMeasuring(next)
    }

    private func startMeasuring(_ id: String) {
        // 🔴 Partial viewing is not carried over. Leaving restarts from 0 every time (2026-08-29 user
        // instruction)
        meterProgress = 0

        // 🔴 Update the state only once. Leave the in-between drawing to Core Animation (fixes stutter)
        withAnimation(.linear(duration: Self.dwellSeconds)) { meterProgress = 1 }

        dwellTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Self.dwellSeconds * 1_000_000_000))
            guard !Task.isCancelled, currentId == id else { return }
            seen.insert(id)
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            // Always require a scroll before counting the next
            awaitingScroll = true
            currentId = nil
            // Snapping instantly from full to 0 looks like the progress vanished, so show it briefly before
            // collapsing
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { meterProgress = 0 }
        }
    }

    private func stopMeasuring() {
        dwellTask?.cancel()
        dwellTask = nil
    }

    /// When the finger moves, allow the next measurement
    private func handleScroll() {
        guard awaitingScroll else { return }
        awaitingScroll = false
        syncCurrent()
    }

    // MARK: - Always-visible controls at the bottom

    private var bottomControls: some View {
        VStack(spacing: 10) {
            keepWorkingButton

            unlockButton
        }
    }

    /// 🔴 This is the core. Keep it always tappable.
    ///    On iOS 26, a native Liquid Glass button (the minimum is 18.6, so a branch is needed)
    @ViewBuilder
    private var keepWorkingButton: some View {
        // ⚠️ Wording is waiting for the user's review
        let label = Text(ja ? "やっぱり作業を続ける" : "Actually, keep working")
            .font(.system(size: 15, weight: .bold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)

        // 🔴 With glass, the text blended into the background and was unreadable (2026-08-29 real device
        //    report). This is the button we most want pressed, so readability comes first: back to a solid
        //    fill
        Button(action: onKeepWorking) {
            label
                .foregroundColor(.black)
                .background(Capsule().fill(Color.white))
        }
        .buttonStyle(.plain)
    }

    /// 🔴 The unlock button itself doubles as the meter (user idea 2026-08-29).
    ///    While viewing, the inside of the button fills up, and when full the remaining count goes down
    ///    by 1. No separate meter is needed, so the screen has one less component
    private var unlockButton: some View {
        Button(action: onCompleted) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // The filling part is light aqua green. When everything is filled, the normal green (user
                    // instruction 2026-08-29)
                    Rectangle()
                        .fill(canUnlock ? AppColors.success.opacity(0.85) : Self.fillingGreen)
                        .frame(width: canUnlock ? geo.size.width : geo.size.width * meterProgress)

                    Text(unlockLabel)
                        .font(.system(size: 14, weight: .bold))
                        .monospacedDigit()
                        .foregroundColor(.white)
                        // Add a shadow so it stays readable on the light fill
                        .shadow(color: .black.opacity(0.55), radius: 3, y: 1)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .frame(height: 48)
            .background(glassBackground)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(canUnlock ? 0.4 : 0.15), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!canUnlock)
        .animation(.easeOut(duration: 0.25), value: canUnlock)
    }

    // ⚠️ Wording is waiting for the user's review
    private var unlockLabel: String {
        if canUnlock { return ja ? "ロックを解除する" : "Unlock" }
        let left = required - progress
        if isPostMode {
            return ja ? "残り \(left) 件 ライバルの進捗を見る" : "See \(left) more from your rivals"
        }
        return ja ? "残り \(left) 件 自分の画像を見る" : "See \(left) more of your images"
    }

    /// Color while filling (light aqua green)
    private static let fillingGreen = Color(red: 0.55, green: 0.90, blue: 0.78).opacity(0.45)

    /// 🔴 If the glass is too transparent, the text cannot be read (2026-08-29 real device report).
    ///    Put it on a dark base to keep contrast.
    ///    ⚠️ The behavior of the tab bar and back button ("the background refracts and shows through, and
    ///    it stretches on long press") is only for system components and cannot be reproduced with public
    ///    APIs
    @ViewBuilder
    private var glassBackground: some View {
        ZStack {
            Capsule().fill(Color.black.opacity(0.45))
            if #available(iOS 26.0, *) {
                Capsule().fill(.clear).glassEffect(.regular.interactive(), in: Capsule())
            } else {
                Capsule().fill(.ultraThinMaterial)
            }
        }
    }

    // MARK: - Empty

    /// 🔴 Do not leave the user stuck when there is nothing to show. At least allow unlocking
    private var emptyState: some View {
        VStack(spacing: 16) {
            Text(ja ? "見せるものがありません" : "Nothing to show") // Wording is waiting for the user's review
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
            Button(action: onCompleted) {
                Text(ja ? "ロックを解除する" : "Unlock")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(.ultraThinMaterial))
            }
            .buttonStyle(.plain)
        }
    }
}
