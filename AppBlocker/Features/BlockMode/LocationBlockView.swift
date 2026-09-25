//
//  LocationBlockView.swift
//  AppBlocker
//
//  位置情報ベースのロック設定画面（HomeView 内に埋め込まれる Content View）
//  特定の場所に入ったらアプリをロック
//

import SwiftUI
import CoreLocation
import FamilyControls
import MapKit

struct LocationBlockView: View {
    @ObservedObject private var locationManager = LocationManager.shared
    @ObservedObject private var blockingService = BlockingService.shared
    // 2026-07-19 ゲート方針転換: 設定 (場所の追加・編集) は無料、実行 (ON) の瞬間に課金ゲート
    @ObservedObject private var proAccess = ProAccess.shared
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    @State private var showProPaywall = false
    /// 無課金で場所を保存した直後の説明アラート (保存はされている・実行には課金、を一拍で伝える)
    @State private var showLockedSavedAlert = false
    @State private var showAddLocationSheet = false
    @State private var showAppPicker = false
    @State private var appSelection: FamilyActivitySelection = FamilyActivitySelection()
    @State private var showDeleteConfirmation = false
    @State private var locationToDelete: RegisteredLocation?
    /// カードタップで開く編集シートの対象 (2026-07-15 実機FB: 場所も後から編集できるように)
    @State private var editingLocation: RegisteredLocation?

    var body: some View {
        VStack(spacing: 24) {
            // 権限に問題がある時だけ先頭でカード警告 (機能がブロックされるため)
            // B-3: "使用中のみ許可" はバックグラウンドで動作しないため、専用の警告を出す
            // 実機FB第7弾 (2026-07-15): 「位置情報の利用/常に許可」の状態ピルは不要と判断し撤去。
            // 許可は場所追加の瞬間にシステムモーダルで取る方針に変更 (addLocationButton 参照)。
            // authorizationSection は事前催促をやめるため .notDetermined では出さず、
            // denied/restricted (= 一度拒否されて操作が必要) の時のみ出す
            if locationManager.authorizationStatus == .authorizedWhenInUse {
                whenInUseWarningSection
            } else if locationManager.authorizationStatus == .denied
                || locationManager.authorizationStatus == .restricted {
                authorizationSection
            }

            // 場所一覧 + 追加 (モード固有UIを上に)
            registeredLocationsSection
            addLocationButton

            // アプリ選択は最下部 = 他モードと同じ位置 (共通部品)
            AppSelectCard(
                selection: appSelection,
                lang: lang,
                subtitle: lang == .japanese ? "全ての場所で共通" : "Shared across places" // 文言はユーザー添削待ち
            ) {
                showAppPicker = true
            }
        }
        .sheet(isPresented: $showAddLocationSheet) {
            AddLocationView(locationManager: locationManager, onSavedWhileLocked: presentPaywallAfterSheet)
        }
        .sheet(item: $editingLocation) { location in
            AddLocationView(locationManager: locationManager, existing: location, onSavedWhileLocked: presentPaywallAfterSheet)
        }
        .sheet(isPresented: $showProPaywall) {
            ProPaywallView(triggeredBy: .location)
        }
        // FB#11 (2026-07-21): 保存後の説明は alert からカスタムシートに格上げ。文言はユーザー添削待ち
        .sheet(isPresented: $showLockedSavedAlert) {
            LockedSavedNoticeSheet(
                title: lang == .japanese
                    ? "ロックの実行には 1% エリートが必要です"
                    : "Running locks requires 1% Elite",
                message: lang == .japanese
                    ? "登録した場所は保存されています。有効にするには 1% エリートに参加してください。"
                    : "Your place is saved. Join 1% Elite to turn it on.",
                onSeeElite: {
                    // シート同士の presentation 衝突回避 (presentPaywallAfterSheet と同じ理由の遅延)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        showProPaywall = true
                    }
                },
                closeTitle: lang == .japanese ? "閉じる" : "Close",
                ctaTitle: L.blockLockedSeeElite(lang)
            )
        }
        .familyActivityPicker(isPresented: $showAppPicker, selection: $appSelection)
        .onChange(of: appSelection) { _, newValue in
            locationManager.saveSelection(newValue)
        }
        .alert(L.locationDeleteTitle(lang), isPresented: $showDeleteConfirmation) {
            Button(L.postsComposerCancel(lang), role: .cancel) { }
            Button(L.commentsDelete(lang), role: .destructive) {
                if let location = locationToDelete {
                    locationManager.removeLocation(location)
                }
            }
        } message: {
            if let location = locationToDelete {
                Text(L.locationDeleteConfirmMessage(location.name, lang))
            }
        }
        .onAppear {
            // 権限状態を再チェック
            locationManager.refreshAuthorizationStatus()

            // 保存された選択を読み込み
            if let saved = locationManager.loadSelection() {
                appSelection = saved
            }

            // 現在地が登録済みの場所の範囲内かチェック
            locationManager.checkCurrentLocationAgainstAllGeofences()
        }
    }

    /// 追加/編集シートが閉じ切ってから説明アラートを出す (シートとの presentation 衝突回避 —
    /// HomeView の jumpToModeFromSheet と同じ理由の遅延)
    private func presentPaywallAfterSheet() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            showLockedSavedAlert = true
        }
    }

    // MARK: - Section Label (11pt uppercase tracking)

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.2)
            .textCase(.uppercase)
            .foregroundColor(AppColors.textTertiary)
    }

    // MARK: - Authorization Section

    private var authorizationSection: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)
                Text(L.locationPermissionTitle(lang))
                    .font(AppTypography.headline)
                    .foregroundColor(AppColors.textPrimary)
            }

            Text(L.locationPermissionBody(lang))
                .font(AppTypography.caption1)
                .foregroundColor(AppColors.textSecondary)
                .multilineTextAlignment(.center)

            Button(action: {
                locationManager.requestAuthorization()
            }) {
                Text(L.locationPermissionAllow(lang))
                    .font(AppTypography.buttonMedium)
                    .foregroundColor(AppColors.background)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(AppColors.primaryFallback)
                    )
            }
            .buttonStyle(.plain)

            // 設定アプリを開くボタン
            Button(action: {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }) {
                Text(L.locationPermissionOpenSettings(lang))
                    .font(AppTypography.caption1)
                    .foregroundColor(AppColors.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(AppColors.cardBackground)
        )
    }

    // MARK: - When In Use Warning Section (B-3)

    /// "使用中のみ許可" のままだとバックグラウンドでジオフェンスが機能しないための専用警告
    private var whenInUseWarningSection: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)
                Text(L.locationBgWarningTitle(lang))
                    .font(AppTypography.headline)
                    .foregroundColor(AppColors.textPrimary)
            }

            Text(L.locationBgWarningBody(lang))
                .font(AppTypography.caption1)
                .foregroundColor(AppColors.textSecondary)
                .multilineTextAlignment(.center)

            // 設定アプリを開くボタン
            Button(action: {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }) {
                Text(L.locationBgWarningOpenSettings(lang))
                    .font(AppTypography.buttonMedium)
                    .foregroundColor(AppColors.background)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(AppColors.primaryFallback)
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(AppColors.cardBackground)
        )
    }

    // MARK: - Registered Locations Section

    private var registeredLocationsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionLabel(L.locationRegisteredSection(lang))

            if locationManager.registeredLocations.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "mappin.slash")
                        .font(.system(size: 32))
                        .foregroundColor(AppColors.textTertiary)

                    Text(L.locationNoneRegistered(lang))
                        .font(AppTypography.body)
                        .foregroundColor(AppColors.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(AppColors.cardBackground)
                )
            } else {
                ForEach(locationManager.registeredLocations) { location in
                    // 左スワイプ→赤い削除 (確認 alert は既存のものを流用)、タップ→編集シート
                    // (タップは SwipeRevealDelete の onTap で受ける — カード内 Button はスワイプ誤爆する)
                    SwipeRevealDelete(
                        onDelete: {
                            locationToDelete = location
                            showDeleteConfirmation = true
                        },
                        onTap: {
                            editingLocation = location
                        }
                    ) {
                        locationCard(for: location)
                    }
                }
            }
        }
    }

    private func locationCard(for location: RegisteredLocation) -> some View {
        let isActive = locationManager.activeLocationIds.contains(location.id)
        // FB#11: 無課金 かつ OFF (=このカードは実行できない) の時だけ下端ストリップとロック錠を出す
        let isLocked = !proAccess.canAccess(.location) && !location.isEnabled

        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                // タップ (編集) は SwipeRevealDelete 側の onTap で処理する (Button 禁止 — スワイプ誤爆)
                // FB#11改 (2026-07-22 実機FB): 減光は情報部 (アイコン+テキスト) のみ。
                // トグル/ロック錠バッジまで 55% にすると「何のボタンかわからない」暗さになる
                HStack(spacing: 12) {
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 22))
                        .foregroundColor(AppColors.textSecondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(location.name)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(AppColors.textPrimary)

                        HStack(spacing: 6) {
                            if isActive {
                                Circle()
                                    .fill(AppColors.success)
                                    .frame(width: 6, height: 6)
                            }
                            Text(isActive
                                 ? L.locationRadiusHereText(Int(location.radius), lang)
                                 : L.locationRadiusText(Int(location.radius), lang))
                                .font(AppTypography.caption1)
                                .foregroundColor(isActive ? AppColors.textSecondary : AppColors.textTertiary)
                        }
                    }
                }
                .opacity(location.isEnabled ? 1 : 0.55)

                Spacer(minLength: 8)

                // トグル (settle 付き: 圏内で ON にすると即時シールド書き込みが走りフリーズするため、
                // timer と同じ PreparingLockOverlay で操作を封じる — フリーズ調査 2026-07-15)
                if isLocked {
                    // 無課金ゲート: トグルの代わりに「OFFトグル+錠前バッジ」(2026-07-21 FB#11)
                    LockedToggleBadge(action: { showProPaywall = true })
                } else {
                    Toggle("", isOn: Binding(
                        get: { location.isEnabled },
                        set: { newValue in
                            // ONへの切替 = 実行の瞬間の課金ゲート (通常はロック錠表示で到達しないが、
                            // 購読失効直後の残存ON等の保険)
                            if newValue && !proAccess.canAccess(.location) {
                                showProPaywall = true
                            } else {
                                Task { await blockingService.toggleLocationWithSettle(location) }
                            }
                        }
                    ))
                    .labelsHidden()
                    .tint(AppColors.primaryFallback)
                }
            }
            .padding(16)

            if isLocked {
                // FB#11改: CTA色ベタ塗り初版はユーザー却下 → 静音ストリップ (LockedRunStrip 参照)
                LockedRunStrip(lang: lang, action: { showProPaywall = true })
            }
        }
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Add Location Button (CTA 級 — 2026-07-15 実機FB)

    private var addLocationButton: some View {
        VStack(spacing: 8) {
            PrimaryButton(
                lang == .japanese ? "場所を追加" : "Add place", // 文言はユーザー添削待ち
                icon: "plus",
                // .notDetermined はここでシステムの許可モーダルを出す方針 (下記 action 参照) なので
                // isDisabled では弾かない。それ以外の未許可 (denied/restricted) は authorizationSection
                // 側で案内するためここは押させない
                isDisabled: (!locationManager.isAuthorized && locationManager.authorizationStatus != .notDetermined)
                    || !locationManager.canAddLocation
            ) {
                // 事前催促カード廃止・場所追加時に要求 (2026-07-15 実機FB)。
                // .notDetermined ならここで初めてシステムの許可モーダルを出す
                if locationManager.authorizationStatus == .notDetermined {
                    locationManager.requestAuthorization()
                }
                showAddLocationSheet = true
            }

            // B-4: iOS のジオフェンス同時監視上限 (20) に達している場合の注記
            if locationManager.isAuthorized && !locationManager.canAddLocation {
                Text(L.locationLimitNote(lang))
                    .font(AppTypography.caption1)
                    .foregroundColor(AppColors.textTertiary)
            }
        }
    }

    // statusSection は廃止 (2026-07-15 モックv1): 「現在ここ」ドットが各場所カードにあり重複だった
}

// MARK: - Add Location View

struct AddLocationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var locationManager: LocationManager
    /// 編集対象。nil = 新規追加 (2026-07-15 実機FB: カードタップで場所を編集できるように)
    let existing: RegisteredLocation?

    // 2026-07-17: このシートは日本語ハードコードだったため英語対応 (英語なし17件の解消)
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .english }

    @State private var name: String = ""
    /// 追加/編集シートを「保存」で閉じたが無課金で OFF 保存になった場合に親へ通知する
    /// (親がシートの閉じ切りを待ってペイウォールを出す)
    var onSavedWhileLocked: (() -> Void)? = nil

    @State private var radius: Double = 100
    @State private var selectedCoordinate: CLLocationCoordinate2D?
    @State private var showDeleteConfirmation = false
    // 地図の軽量検索 (2026-07-15 実機FB: スワイプで場所を探すのがだるい)。送信時のみ MKLocalSearch
    @State private var searchQuery: String = ""
    @State private var isSearching = false
    @State private var searchFailed = false
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503), // 東京
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    )

    // M12 (2026-07-21 確定): 50m はこの理由で提供しない — iOS のジオフェンスは
    // 半径100m未満だと検知の遅延・取りこぼしが増え信頼性が落ちる (Apple推奨の実用下限は~100m)。
    // LocationManager.loadLocations 側の max(100, radius) クランプ（既存データの引き上げ）は
    // 正当な防衛として維持し、選択肢自体からも 50 を外して二重に矛盾しないようにする
    private let radiusOptions: [Double] = [100, 200, 500, 1000]

    init(locationManager: LocationManager,
         existing: RegisteredLocation? = nil,
         onSavedWhileLocked: (() -> Void)? = nil) {
        self._locationManager = ObservedObject(wrappedValue: locationManager)
        self.existing = existing
        self.onSavedWhileLocked = onSavedWhileLocked

        // 編集モード: 既存の値をプリフィルし、地図も登録地点を中心にする
        if let existing {
            _name = State(initialValue: existing.name)
            _radius = State(initialValue: existing.radius)
            _selectedCoordinate = State(initialValue: existing.coordinate)
            _region = State(initialValue: MKCoordinateRegion(
                center: existing.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
            ))
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppColors.background
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 24) {
                        // 名前入力
                        VStack(alignment: .leading, spacing: 8) {
                            Text(lang == .japanese ? "場所の名前" : "Place name") // 文言はユーザー添削待ち
                                .font(AppTypography.headline)
                                .foregroundColor(AppColors.textSecondary)

                            TextField(lang == .japanese ? "例: カフェ、職場、図書館" : "e.g. Café, office, library", text: $name) // 文言はユーザー添削待ち
                                .font(AppTypography.body)
                                .padding(16)
                                .background(
                                    RoundedRectangle(cornerRadius: 16)
                                        .fill(AppColors.cardBackground)
                                )
                                .foregroundColor(AppColors.textPrimary)
                        }

                        // 地図
                        VStack(alignment: .leading, spacing: 8) {
                            Text(lang == .japanese ? "場所を選択（タップして選択）" : "Pick a spot (tap the map)") // 文言はユーザー添削待ち
                                .font(AppTypography.headline)
                                .foregroundColor(AppColors.textSecondary)

                            MapViewWithPin(
                                region: $region,
                                selectedCoordinate: $selectedCoordinate,
                                radius: radius
                            )
                            .frame(height: 250)
                            .cornerRadius(16)
                            // 地図の上に半透明の検索バー (2026-07-15 実機FB)
                            .overlay(alignment: .top) {
                                mapSearchBar
                                    .padding(10)
                            }

                            if searchFailed {
                                Text(lang == .japanese ? "見つかりませんでした" : "No results found") // 文言はユーザー添削待ち
                                    .font(AppTypography.caption1)
                                    .foregroundColor(AppColors.textSecondary)
                            }

                            // 現在地ボタン
                            Button {
                                if let location = locationManager.currentLocation {
                                    region.center = location.coordinate
                                    selectedCoordinate = location.coordinate
                                } else {
                                    locationManager.requestCurrentLocation()
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "location.fill")
                                    Text(lang == .japanese ? "現在地を使用" : "Use current location") // 文言はユーザー添削待ち
                                }
                                .font(AppTypography.caption1)
                                .foregroundColor(AppColors.textSecondary)
                            }
                        }

                        // 半径選択 (serif廃止 — UI文字はsansに統一、2026-07-15 実機FB)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(lang == .japanese ? "半径: \(Int(radius))m" : "Radius: \(Int(radius))m") // 文言はユーザー添削待ち
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(AppColors.textPrimary)

                            // 均等幅ピル: 固定 padding だと 4 個目 (1000m) が押されて潰れる
                            // (実機FB 2026-07-15) ため、行全体に等分で広げる
                            HStack(spacing: 8) {
                                ForEach(radiusOptions, id: \.self) { option in
                                    Button {
                                        radius = option
                                    } label: {
                                        Text("\(Int(option))m")
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundColor(radius == option ? AppColors.background : AppColors.textSecondary)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 10)
                                            .background(
                                                Capsule()
                                                    .fill(radius == option ? AppColors.primaryFallback : AppColors.cardBackground)
                                            )
                                    }
                                }
                            }
                        }

                        // 追加/保存ボタン
                        Button {
                            saveLocation()
                        } label: {
                            Text(existing == nil
                                 ? (lang == .japanese ? "場所を追加" : "Add place")
                                 : (lang == .japanese ? "保存" : "Save")) // 文言はユーザー添削待ち
                                .font(AppTypography.buttonMedium)
                                .foregroundColor(canAdd ? AppColors.background : AppColors.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                                .background(
                                    RoundedRectangle(cornerRadius: 16)
                                        .fill(canAdd ? AppColors.primaryFallback : AppColors.secondaryBackground)
                                )
                        }
                        .disabled(!canAdd)

                        // 名前が必須なことが伝わらず混乱する (実機FB 2026-07-15) ため、
                        // 無効時は不足しているものを明示する
                        if let hint = missingRequirementHint {
                            Text(hint) // 文言はユーザー添削待ち
                                .font(AppTypography.caption1)
                                .foregroundColor(AppColors.textSecondary)
                                .frame(maxWidth: .infinity)
                                .multilineTextAlignment(.center)
                                .padding(.top, -12)
                        }

                        // 編集モードのみ: 削除 (ミュートした destructive アウトライン、スケジュール編集と同型)
                        if existing != nil {
                            Button {
                                showDeleteConfirmation = true
                            } label: {
                                HStack {
                                    Image(systemName: "trash")
                                        .font(.system(size: 15))
                                    Text(lang == .japanese ? "場所を削除" : "Delete place") // 文言はユーザー添削待ち
                                        .font(AppTypography.buttonMedium)
                                }
                                .foregroundColor(AppColors.error)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(AppColors.error.opacity(0.4), lineWidth: 1)
                                )
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle(existing == nil
                             ? (lang == .japanese ? "場所を追加" : "Add Place")
                             : (lang == .japanese ? "場所を編集" : "Edit Place")) // 文言はユーザー添削待ち
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(lang == .japanese ? "キャンセル" : "Cancel") {
                        dismiss()
                    }
                    .foregroundColor(AppColors.textSecondary)
                }
            }
            .alert(lang == .japanese ? "場所を削除" : "Delete place", isPresented: $showDeleteConfirmation) {
                Button(lang == .japanese ? "キャンセル" : "Cancel", role: .cancel) { }
                Button(lang == .japanese ? "削除" : "Delete", role: .destructive) {
                    if let existing {
                        locationManager.removeLocation(existing)
                    }
                    dismiss()
                }
            } message: {
                Text(lang == .japanese
                     ? "「\(existing?.name ?? name)」を削除しますか？"
                     : "Delete \"\(existing?.name ?? name)\"?") // 文言はユーザー添削待ち
            }
            .onAppear {
                // 現在地を中心にする (新規のみ。編集時は登録地点を中心にしたまま動かさない)
                guard existing == nil else { return }
                if let location = locationManager.currentLocation {
                    region.center = location.coordinate
                }
                locationManager.requestCurrentLocation()
            }
        }
    }

    private var canAdd: Bool {
        !name.isEmpty && selectedCoordinate != nil
    }

    /// 追加ボタンが無効な理由 (両方欠けている時は先に済ませるべき地図選択を案内)
    private var missingRequirementHint: String? {
        if selectedCoordinate == nil {
            return lang == .japanese ? "地図をタップして場所を選んでください" : "Tap the map to pick a spot" // 文言はユーザー添削待ち
        }
        if name.isEmpty {
            return lang == .japanese ? "場所の名前を入力してください" : "Give this place a name" // 文言はユーザー添削待ち
        }
        return nil
    }

    // MARK: - Map Search (軽量: 送信時のみ検索、先頭ヒットへ移動)

    private var mapSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(AppColors.textSecondary)

            TextField(lang == .japanese ? "場所を検索" : "Search places", text: $searchQuery) // 文言はユーザー添削待ち
                .font(.system(size: 13))
                .foregroundColor(AppColors.textPrimary)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .onSubmit { performMapSearch() }

            if isSearching {
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        // 地図の上で沈まないよう不透明寄りに (2026-07-15 実機FB: ultraThin だと透けすぎ)
        .background(Capsule().fill(Color.black.opacity(0.72)))
        .environment(\.colorScheme, .dark)
    }

    private func performMapSearch() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, !isSearching else { return }

        isSearching = true
        searchFailed = false

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = region

        MKLocalSearch(request: request).start { response, _ in
            DispatchQueue.main.async {
                isSearching = false
                guard let item = response?.mapItems.first else {
                    searchFailed = true
                    return
                }
                let coordinate = item.placemark.coordinate
                region = MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
                )
                selectedCoordinate = coordinate
                // 検索ヒットに連動して場所の名前も常に更新する (2026-07-15 実機FB)。
                // ユーザーが直したい場合はこの後で自由に編集できる
                if let itemName = item.name {
                    name = itemName
                }
            }
        }
    }

    private func saveLocation() {
        guard let coordinate = selectedCoordinate else { return }

        // settle 付きラッパー経由 (フリーズ調査 2026-07-15): 追加/編集地点の圏内に居ると
        // 即時シールド書き込みが走るため、PreparingLockOverlay で enforcement 起動レースを避ける
        if let existing {
            // 編集: id は保持したまま更新 (ジオフェンスは updateLocation が再登録する)。
            // H8: 失効ユーザーが座標・半径を自由に変更し続けられる穴があったため、
            // 新規追加と同じ課金ゲートを適用する (ScheduleBlockView の isEnabled ゲートと同型、2026-07-21 監査対応)
            let canRun = ProAccess.shared.canAccess(.location)
            var updated = existing
            updated.name = name
            updated.latitude = coordinate.latitude
            updated.longitude = coordinate.longitude
            updated.radius = radius
            updated.isEnabled = existing.isEnabled && canRun
            Task { await BlockingService.shared.updateLocationWithSettle(updated) }
            // ONだったものが課金失効でOFFに落ちた場合のみ、保存後にペイウォール導線の説明アラートを出す
            if existing.isEnabled && !canRun {
                onSavedWhileLocked?()
            }
        } else {
            // 無課金は必ず OFF で保存 (設定は無料・実行には課金のゲート方針 2026-07-19)。
            // 保存後、親がペイウォールを出して「ONには課金が要る」ことをその場で伝える
            let canRun = ProAccess.shared.canAccess(.location)
            let location = RegisteredLocation(
                name: name,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                radius: radius,
                isEnabled: canRun
            )
            Task { await BlockingService.shared.addLocationWithSettle(location) }
            if !canRun {
                onSavedWhileLocked?()
            }
        }

        dismiss()
    }
}

// MARK: - Map View with Pin

struct MapViewWithPin: UIViewRepresentable {
    @Binding var region: MKCoordinateRegion
    @Binding var selectedCoordinate: CLLocationCoordinate2D?
    let radius: Double

    func makeUIView(context: Context) -> MKMapView {
        let mapView = MKMapView()
        mapView.delegate = context.coordinator
        mapView.showsUserLocation = true

        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        mapView.addGestureRecognizer(tapGesture)

        return mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {
        mapView.setRegion(region, animated: true)

        // 既存のアノテーションとオーバーレイを削除
        mapView.removeAnnotations(mapView.annotations)
        mapView.removeOverlays(mapView.overlays)

        // 選択された座標にピンを追加
        if let coordinate = selectedCoordinate {
            let annotation = MKPointAnnotation()
            annotation.coordinate = coordinate
            mapView.addAnnotation(annotation)

            // 半径の円を追加
            let circle = MKCircle(center: coordinate, radius: radius)
            mapView.addOverlay(circle)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, MKMapViewDelegate {
        var parent: MapViewWithPin

        init(_ parent: MapViewWithPin) {
            self.parent = parent
        }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            let mapView = gesture.view as! MKMapView
            let point = gesture.location(in: mapView)
            let coordinate = mapView.convert(point, toCoordinateFrom: mapView)

            parent.selectedCoordinate = coordinate
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let circle = overlay as? MKCircle {
                let renderer = MKCircleRenderer(circle: circle)
                renderer.fillColor = UIColor.systemBlue.withAlphaComponent(0.2)
                renderer.strokeColor = UIColor.systemBlue
                renderer.lineWidth = 2
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}

#Preview {
    ScrollView {
        LocationBlockView()
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
    }
    .background(AppColors.background)
}
