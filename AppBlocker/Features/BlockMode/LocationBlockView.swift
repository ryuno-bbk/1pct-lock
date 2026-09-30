//
//  LocationBlockView.swift
//  AppBlocker
//
//  Location-based lock settings screen (Content View embedded in HomeView)
//  Locks apps when the user enters a specific place
//

import SwiftUI
import CoreLocation
import FamilyControls
import MapKit

struct LocationBlockView: View {
    @ObservedObject private var locationManager = LocationManager.shared
    @ObservedObject private var blockingService = BlockingService.shared
    // 2026-07-19 gate policy change: settings (adding/editing places) are free, the paywall appears at the
    // moment of running it (ON)
    @ObservedObject private var proAccess = ProAccess.shared
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue

    private var lang: AppLanguage {
        AppLanguage(rawValue: mainLanguageRaw) ?? .english
    }

    @State private var showProPaywall = false
    /// Explanation alert right after a non-paying user saves a place (tells in one beat that it is saved
    /// but running it requires a purchase)
    @State private var showLockedSavedAlert = false
    @State private var showAddLocationSheet = false
    @State private var showAppPicker = false
    @State private var appSelection: FamilyActivitySelection = FamilyActivitySelection()
    @State private var showDeleteConfirmation = false
    @State private var locationToDelete: RegisteredLocation?
    /// Target of the edit sheet opened by tapping a card (2026-07-15 real-device feedback: places should also
    /// be editable later)
    @State private var editingLocation: RegisteredLocation?

    var body: some View {
        VStack(spacing: 24) {
            // Show a warning card at the top only when there is a permission problem (the feature is blocked)
            // B-3: "使用中のみ許可" ("Allow While Using") does not work in the background, so a dedicated warning is shown
            // Real-device feedback round 7 (2026-07-15): the "location use / always allow" status pill was judged
            // unnecessary and removed.
            // Changed the policy to ask for permission with the system modal at the moment a place is added (see
            // addLocationButton).
            // authorizationSection no longer nags in advance, so it is not shown for .notDetermined,
            // only for denied/restricted (= denied once, the user needs to act)
            if locationManager.authorizationStatus == .authorizedWhenInUse {
                whenInUseWarningSection
            } else if locationManager.authorizationStatus == .denied
                || locationManager.authorizationStatus == .restricted {
                authorizationSection
            }

            // Place list + add (mode-specific UI at the top)
            registeredLocationsSection
            addLocationButton

            // App selection is at the bottom = the same position as the other modes (shared component)
            AppSelectCard(
                selection: appSelection,
                lang: lang,
                subtitle: lang == .japanese ? "全ての場所で共通" : "Shared across places" // Copy waiting for user review
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
        // FB#11 (2026-07-21): the post-save explanation was upgraded from an alert to a custom sheet. Copy
        // waiting for user review
        .sheet(isPresented: $showLockedSavedAlert) {
            LockedSavedNoticeSheet(
                title: lang == .japanese
                    ? "ロックの実行には 1% エリートが必要です"
                    : "Running locks requires 1% Elite",
                message: lang == .japanese
                    ? "登録した場所は保存されています。有効にするには 1% エリートに参加してください。"
                    : "Your place is saved. Join 1% Elite to turn it on.",
                onSeeElite: {
                    // Avoid a presentation conflict between sheets (a delay for the same reason as presentPaywallAfterSheet)
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
            // Recheck the permission state
            locationManager.refreshAuthorizationStatus()

            // Load the saved selection
            if let saved = locationManager.loadSelection() {
                appSelection = saved
            }

            // Check whether the current location is within the range of a registered place
            locationManager.checkCurrentLocationAgainstAllGeofences()
        }
    }

    /// Show the explanation alert after the add/edit sheet has fully closed (avoids a presentation conflict
    /// with the sheet, a delay for the same reason as jumpToModeFromSheet in HomeView)
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

            // Button that opens the Settings app
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

    /// Dedicated warning because geofences do not work in the background while it stays at
    /// "使用中のみ許可" ("Allow While Using")
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

            // Button that opens the Settings app
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
                    // Swipe left → red delete (reuses the existing confirmation alert), tap → edit sheet
                    // (taps are received by onTap of SwipeRevealDelete, because a Button inside the card fires by mistake
                    // on swipes)
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
        // FB#11: show the bottom strip and the padlock only for non-paying + OFF (= this card cannot run)
        let isLocked = !proAccess.canAccess(.location) && !location.isEnabled

        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                // Taps (edit) are handled by onTap on the SwipeRevealDelete side (no Button, it fires by mistake on swipes)
                // FB#11 revised (2026-07-22 real-device feedback): only the info part (icon + text) is dimmed.
                // Dimming the toggle/padlock badge to 55% too makes it so dark that "you can't tell what the button is"
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

                // Toggle (with settle: turning it ON while inside the area writes the shield immediately and freezes,
                // so input is blocked with the same PreparingLockOverlay as timer. Freeze investigation 2026-07-15)
                if isLocked {
                    // Gate for non-paying users: instead of a toggle, an "OFF toggle + padlock badge" (2026-07-21 FB#11)
                    LockedToggleBadge(action: { showProPaywall = true })
                } else {
                    Toggle("", isOn: Binding(
                        get: { location.isEnabled },
                        set: { newValue in
                            // Switching to ON = the paywall at the moment of running (normally not reachable because the padlock is
                            // shown, but a safety net for things like a leftover ON right after the subscription expired)
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
                // FB#11 revised: the first version with a solid CTA color fill was rejected by the user → a quiet strip
                // (see LockedRunStrip)
                LockedRunStrip(lang: lang, action: { showProPaywall = true })
            }
        }
        .background(AppColors.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Add Location Button (CTA level, 2026-07-15 real-device feedback)

    private var addLocationButton: some View {
        VStack(spacing: 8) {
            PrimaryButton(
                lang == .japanese ? "場所を追加" : "Add place", // Copy waiting for user review
                icon: "plus",
                // .notDetermined is not rejected by isDisabled, because the policy is to show the system permission
                // modal here (see action below). Other unauthorized states (denied/restricted) are guided by
                // authorizationSection, so the button cannot be pressed here
                isDisabled: (!locationManager.isAuthorized && locationManager.authorizationStatus != .notDetermined)
                    || !locationManager.canAddLocation
            ) {
                // Removed the advance nag card, permission is requested when adding a place (2026-07-15 real-device
                // feedback).
                // If .notDetermined, the system permission modal is shown here for the first time
                if locationManager.authorizationStatus == .notDetermined {
                    locationManager.requestAuthorization()
                }
                showAddLocationSheet = true
            }

            // B-4: note shown when the iOS limit on concurrently monitored geofences (20) has been reached
            if locationManager.isAuthorized && !locationManager.canAddLocation {
                Text(L.locationLimitNote(lang))
                    .font(AppTypography.caption1)
                    .foregroundColor(AppColors.textTertiary)
            }
        }
    }

    // statusSection was removed (2026-07-15 mock v1): each place card already has a "you are here" dot, so
    // it was a duplicate
}

// MARK: - Add Location View

struct AddLocationView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var locationManager: LocationManager
    /// Edit target. nil = add new (2026-07-15 real-device feedback: tapping a card should let the user edit
    /// the place)
    let existing: RegisteredLocation?

    // 2026-07-17: this sheet had hardcoded Japanese, so English support was added (fixes 17 strings with
    // no English)
    @AppStorage("mainLanguage") private var mainLanguageRaw = AppLanguage.deviceDefault.rawValue
    private var lang: AppLanguage { AppLanguage(rawValue: mainLanguageRaw) ?? .english }

    @State private var name: String = ""
    /// Notifies the parent when the add/edit sheet was closed with "保存" ("Save") but it was saved as OFF
    /// because the user is not paying
    /// (the parent waits for the sheet to finish closing and then shows the paywall)
    var onSavedWhileLocked: (() -> Void)? = nil

    @State private var radius: Double = 100
    @State private var selectedCoordinate: CLLocationCoordinate2D?
    @State private var showDeleteConfirmation = false
    // Lightweight map search (2026-07-15 real-device feedback: finding a place by swiping is tedious).
    // MKLocalSearch only on submit
    @State private var searchQuery: String = ""
    @State private var isSearching = false
    @State private var searchFailed = false
    @State private var region = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503), // Tokyo
        span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
    )

    // M12 (confirmed 2026-07-21): 50m is not offered for this reason: iOS geofences with a radius under
    // 100m have more detection delay and misses and are less reliable (Apple's recommended practical
    // minimum is ~100m).
    // The max(100, radius) clamp in LocationManager.loadLocations (raising existing data) is kept as a
    // valid defense, and 50 is also removed from the options themselves so the two do not contradict
    private let radiusOptions: [Double] = [100, 200, 500, 1000]

    init(locationManager: LocationManager,
         existing: RegisteredLocation? = nil,
         onSavedWhileLocked: (() -> Void)? = nil) {
        self._locationManager = ObservedObject(wrappedValue: locationManager)
        self.existing = existing
        self.onSavedWhileLocked = onSavedWhileLocked

        // Edit mode: prefill the existing values and center the map on the registered location
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
                        // Name input
                        VStack(alignment: .leading, spacing: 8) {
                            Text(lang == .japanese ? "場所の名前" : "Place name") // Copy waiting for user review
                                .font(AppTypography.headline)
                                .foregroundColor(AppColors.textSecondary)

                            TextField(lang == .japanese ? "例: カフェ、職場、図書館" : "e.g. Café, office, library", text: $name) // Copy waiting for user review
                                .font(AppTypography.body)
                                .padding(16)
                                .background(
                                    RoundedRectangle(cornerRadius: 16)
                                        .fill(AppColors.cardBackground)
                                )
                                .foregroundColor(AppColors.textPrimary)
                        }

                        // Map
                        VStack(alignment: .leading, spacing: 8) {
                            Text(lang == .japanese ? "場所を選択（タップして選択）" : "Pick a spot (tap the map)") // Copy waiting for user review
                                .font(AppTypography.headline)
                                .foregroundColor(AppColors.textSecondary)

                            MapViewWithPin(
                                region: $region,
                                selectedCoordinate: $selectedCoordinate,
                                radius: radius
                            )
                            .frame(height: 250)
                            .cornerRadius(16)
                            // Semi-transparent search bar on top of the map (2026-07-15 real-device feedback)
                            .overlay(alignment: .top) {
                                mapSearchBar
                                    .padding(10)
                            }

                            if searchFailed {
                                Text(lang == .japanese ? "見つかりませんでした" : "No results found") // Copy waiting for user review
                                    .font(AppTypography.caption1)
                                    .foregroundColor(AppColors.textSecondary)
                            }

                            // Current location button
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
                                    Text(lang == .japanese ? "現在地を使用" : "Use current location") // Copy waiting for user review
                                }
                                .font(AppTypography.caption1)
                                .foregroundColor(AppColors.textSecondary)
                            }
                        }

                        // Radius selection (serif removed, UI text unified to sans. 2026-07-15 real-device feedback)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(lang == .japanese ? "半径: \(Int(radius))m" : "Radius: \(Int(radius))m") // Copy waiting for user review
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundColor(AppColors.textPrimary)

                            // Equal-width pills: with fixed padding the 4th one (1000m) gets squeezed
                            // (real-device feedback 2026-07-15), so they are spread evenly across the whole row
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

                        // Add/save button
                        Button {
                            saveLocation()
                        } label: {
                            Text(existing == nil
                                 ? (lang == .japanese ? "場所を追加" : "Add place")
                                 : (lang == .japanese ? "保存" : "Save")) // Copy waiting for user review
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

                        // Users were confused because it was not clear that the name is required (real-device feedback
                        // 2026-07-15), so when disabled, show explicitly what is missing
                        if let hint = missingRequirementHint {
                            Text(hint) // Copy waiting for user review
                                .font(AppTypography.caption1)
                                .foregroundColor(AppColors.textSecondary)
                                .frame(maxWidth: .infinity)
                                .multilineTextAlignment(.center)
                                .padding(.top, -12)
                        }

                        // Edit mode only: delete (muted destructive outline, same style as schedule editing)
                        if existing != nil {
                            Button {
                                showDeleteConfirmation = true
                            } label: {
                                HStack {
                                    Image(systemName: "trash")
                                        .font(.system(size: 15))
                                    Text(lang == .japanese ? "場所を削除" : "Delete place") // Copy waiting for user review
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
                             : (lang == .japanese ? "場所を編集" : "Edit Place")) // Copy waiting for user review
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
                     : "Delete \"\(existing?.name ?? name)\"?") // Copy waiting for user review
            }
            .onAppear {
                // Center on the current location (new only. When editing, keep the registered location centered)
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

    /// Reason the add button is disabled (if both are missing, guide to the map selection first, since it
    /// should be done first)
    private var missingRequirementHint: String? {
        if selectedCoordinate == nil {
            return lang == .japanese ? "地図をタップして場所を選んでください" : "Tap the map to pick a spot" // Copy waiting for user review
        }
        if name.isEmpty {
            return lang == .japanese ? "場所の名前を入力してください" : "Give this place a name" // Copy waiting for user review
        }
        return nil
    }

    // MARK: - Map Search (lightweight: searches only on submit, moves to the first hit)

    private var mapSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(AppColors.textSecondary)

            TextField(lang == .japanese ? "場所を検索" : "Search places", text: $searchQuery) // Copy waiting for user review
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
        // Close to opaque so it does not sink into the map (2026-07-15 real-device feedback: ultraThin was too
        // see-through)
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
                // Always update the place name along with the search hit (2026-07-15 real-device feedback).
                // If the user wants to change it, they can edit it freely afterwards
                if let itemName = item.name {
                    name = itemName
                }
            }
        }
    }

    private func saveLocation() {
        guard let coordinate = selectedCoordinate else { return }

        // Through the wrapper with settle (freeze investigation 2026-07-15): if the user is inside the area of
        // the added/edited place, the shield is written immediately, so PreparingLockOverlay avoids the
        // enforcement startup race
        if let existing {
            // Edit: update while keeping the id (updateLocation re-registers the geofence).
            // H8: there was a hole where an expired user could keep changing coordinates and radius freely,
            // so the same paywall gate as adding new is applied (same pattern as the isEnabled gate in
            // ScheduleBlockView, 2026-07-21 audit fix)
            let canRun = ProAccess.shared.canAccess(.location)
            var updated = existing
            updated.name = name
            updated.latitude = coordinate.latitude
            updated.longitude = coordinate.longitude
            updated.radius = radius
            updated.isEnabled = existing.isEnabled && canRun
            Task { await BlockingService.shared.updateLocationWithSettle(updated) }
            // Only when something that was ON dropped to OFF because the purchase expired, show the explanation
            // alert leading to the paywall after saving
            if existing.isEnabled && !canRun {
                onSavedWhileLocked?()
            }
        } else {
            // Non-paying users always save as OFF (gate policy: settings are free, running requires a purchase,
            // 2026-07-19).
            // After saving, the parent shows the paywall to tell the user right there that "ON requires a purchase"
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

        // Remove existing annotations and overlays
        mapView.removeAnnotations(mapView.annotations)
        mapView.removeOverlays(mapView.overlays)

        // Add a pin at the selected coordinate
        if let coordinate = selectedCoordinate {
            let annotation = MKPointAnnotation()
            annotation.coordinate = coordinate
            mapView.addAnnotation(annotation)

            // Add the radius circle
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
