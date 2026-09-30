//
//  LocationManager.swift
//  AppBlocker
//
//  Location-based lock management service
//  Uses geofencing to lock apps at specific places
//

import Foundation
import CoreLocation
import ManagedSettings
import FamilyControls
import Combine

/// A registered place
struct RegisteredLocation: Codable, Identifiable {
    let id: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    var radius: Double // meters
    var isEnabled: Bool

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(id: UUID = UUID(), name: String, latitude: Double, longitude: Double, radius: Double = 100, isEnabled: Bool = true) {
        self.id = id
        self.name = name
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.isEnabled = isEnabled
    }
}

/// Location lock management service
final class LocationManager: NSObject, ObservableObject {

    @MainActor static let shared = LocationManager()

    private let locationManager = CLLocationManager()
    private let store = ManagedSettingsStore(named: .init(AppGroupConstants.Stores.location))
    private let appGroupID = AppGroupConstants.identifier

    // MARK: - Published Properties

    /// List of registered places
    @Published var registeredLocations: [RegisteredLocation] = []

    /// Current location
    @Published var currentLocation: CLLocation?

    /// Location permission status
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    /// Places currently locked (the user is inside the geofence)
    @Published var activeLocationIds: Set<UUID> = []

    /// Whether the Shield is applied
    @Published var isShieldActive: Bool = false

    /// Debug info
    @Published var debugInfo: String = ""

    /// Whether a region evaluation is in progress (public so the spinner shown right after the toggle
    /// stays until the evaluation finishes. pendingGeofenceEvaluation stays true while waiting for a retry)
    @Published private(set) var isEvaluatingRegion = false

    // MARK: - Private Properties

    private let locationsKey = AppGroupConstants.Keys.registeredLocations
    private let selectionKey = AppGroupConstants.Keys.locationSelection

    /// Waiting for a fix from requestLocation() (B-5: flag-driven, to remove the race of a fixed wait)
    private var pendingGeofenceEvaluation = false

    /// Retry count for region evaluation (up to 3 times until a reliable fix arrives. Removes silent failures)
    private var evaluationRetryCount = 0
    private let maxEvaluationRetries = 3

    // MARK: - Init

    @MainActor
    private override init() {
        super.init()

        locationManager.delegate = self
        // B-6: 100m accuracy is enough for geofence checks. kCLLocationAccuracyBest uses a lot of battery
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters

        // Geofencing is managed by the system, so
        // no background update setup is needed (it works automatically after permission is granted)

        // Load saved places
        loadLocations()

        // Update permission status
        authorizationStatus = locationManager.authorizationStatus

        // B-2: If there are zero registered places (or all are disabled), clear unconditionally, regardless
        // of permission status, so a Shield from the previous process does not survive even if it is still in
        // the store. Same when permission is not Always: we cannot receive exit events and have no way to
        // unlock, so we always clear at launch to prevent stuck-on (added in the Fable review)
        if registeredLocations.filter({ $0.isEnabled }).isEmpty || !isAuthorized {
            removeShield()
        }

        // B-8: Do not register geofences while permission is still undetermined (.notDetermined etc.).
        // Registration once Always permission is confirmed is left to locationManagerDidChangeAuthorization
        if isAuthorized {
            registerAllGeofences()
        }
    }

    // MARK: - Authorization

    /// Request location permission
    func requestAuthorization() {
        // Re-check the current status
        let currentStatus = locationManager.authorizationStatus
        print("📍 Current authorization status: \(currentStatus.rawValue)")

        if currentStatus == .notDetermined {
            locationManager.requestAlwaysAuthorization()
        } else if currentStatus == .authorizedWhenInUse {
            // Request an upgrade from When In Use to Always
            locationManager.requestAlwaysAuthorization()
        } else {
            // If already granted/denied, update the status
            refreshAuthorizationStatus()
        }
    }

    /// Re-check the permission status
    func refreshAuthorizationStatus() {
        let status = locationManager.authorizationStatus
        DispatchQueue.main.async { [weak self] in
            self?.authorizationStatus = status
            print("📍 Authorization status refreshed: \(status.rawValue)")

            // B-3: Register geofences only for Always (WhenInUse does not work in the background, so it is excluded)
            if status == .authorizedAlways {
                self?.registerAllGeofences()
            }
        }
    }

    /// Whether permission is granted
    /// B-3: WhenInUse cannot receive geofence events in the background, so it is not treated as authorized
    var isAuthorized: Bool {
        locationManager.authorizationStatus == .authorizedAlways
    }

    // MARK: - Location Management

    /// Get the current location
    func requestCurrentLocation() {
        locationManager.requestLocation()
    }

    /// Whether the number of enabled places is below the iOS limit for concurrently monitored geofences
    /// (20) (B-4)
    var canAddLocation: Bool {
        registeredLocations.filter(\.isEnabled).count < 20
    }

    /// Register a place
    func addLocation(_ location: RegisteredLocation) {
        // B-4: iOS limits the regions CLLocationManager can monitor at the same time to 20
        guard canAddLocation else {
            debugInfo = "⚠️ これ以上場所を追加できません（iOS 制限で最大20箇所）"
            print("⚠️ Cannot add location: 20-region monitoring limit reached")
            return
        }

        registeredLocations.append(location)
        saveLocations()
        registerGeofence(for: location)

        // Check whether the current location is inside this place's range
        checkIfInsideLocation(location)

        debugInfo = "📍 場所を追加: \(location.name)"
        print("📍 Added location: \(location.name) at \(location.latitude), \(location.longitude)")
    }

    /// Delete a place
    func removeLocation(_ location: RegisteredLocation) {
        registeredLocations.removeAll { $0.id == location.id }
        saveLocations()
        unregisterGeofence(for: location)

        // Also remove it from the active list
        activeLocationIds.remove(location.id)
        syncShield()

        debugInfo = "🗑️ 場所を削除: \(location.name)"
        print("🗑️ Removed location: \(location.name)")
    }

    /// Update a place
    func updateLocation(_ location: RegisteredLocation) {
        if let index = registeredLocations.firstIndex(where: { $0.id == location.id }) {
            // Unregister the old geofence
            unregisterGeofence(for: registeredLocations[index])

            // Update
            registeredLocations[index] = location
            saveLocations()

            // Register the new geofence
            if location.isEnabled {
                registerGeofence(for: location)
            }

            debugInfo = "✏️ 場所を更新: \(location.name)"
        }
    }

    /// Toggle a place enabled/disabled
    func toggleLocation(_ location: RegisteredLocation) {
        var updated = location
        updated.isEnabled = !location.isEnabled

        // B-4: Check the limit only when enabling (disabling is always allowed)
        if updated.isEnabled && !canAddLocation {
            debugInfo = "⚠️ これ以上有効化できません（iOS 制限で最大20箇所）"
            print("⚠️ Cannot enable location: 20-region monitoring limit reached")
            return
        }

        updateLocation(updated)

        // When turned off, unlock this place
        if !updated.isEnabled {
            activeLocationIds.remove(location.id)
            syncShield()
            debugInfo = "⏸️ 監視を停止: \(location.name)"
            print("⏸️ Monitoring paused for: \(location.name)")
        } else {
            // When turned on, check whether the current location is inside this place's range
            checkIfInsideLocation(updated)
            debugInfo = "▶️ 監視を開始: \(location.name)"
            print("▶️ Monitoring started for: \(location.name)")
        }
    }

    // MARK: - Geofencing

    /// Register a geofence
    private func registerGeofence(for location: RegisteredLocation) {
        guard location.isEnabled else { return }

        let region = CLCircularRegion(
            center: location.coordinate,
            radius: location.radius,
            identifier: location.id.uuidString
        )
        region.notifyOnEntry = true
        region.notifyOnExit = true

        locationManager.startMonitoring(for: region)

        // If you are already inside the region when calling startMonitoring, didEnterRegion does not fire
        // (CoreLocation behavior). The initial inside state is decided via requestState → didDetermineState
        // (2026-08-09: the root cause of the bug "saving a place for the first time and turning it ON while
        // inside does not start the lock")
        locationManager.requestState(for: region)

        print("🔔 Registered geofence: \(location.name) (radius: \(location.radius)m)")
    }

    /// Unregister a geofence
    private func unregisterGeofence(for location: RegisteredLocation) {
        let region = CLCircularRegion(
            center: location.coordinate,
            radius: location.radius,
            identifier: location.id.uuidString
        )
        locationManager.stopMonitoring(for: region)

        print("🔕 Unregistered geofence: \(location.name)")
    }

    /// Re-register all geofences
    private func registerAllGeofences() {
        // Clear existing geofences
        for region in locationManager.monitoredRegions {
            locationManager.stopMonitoring(for: region)
        }

        // Register geofences for enabled places
        for location in registeredLocations where location.isEnabled {
            registerGeofence(for: location)
        }

        // Check whether the current location is inside any registered place
        checkCurrentLocationAgainstAllGeofences()
    }

    /// Request a current location fix and evaluate all enabled places as soon as it arrives (B-5/B-6).
    /// If there is already a fix from the last 60 seconds, evaluate immediately with it and skip
    /// requestLocation() (saves battery + removes the race caused by a fixed asyncAfter wait).
    private func requestGeofenceEvaluation() {
        // Even within 60 seconds, a coarse fix (accuracy > 100m) just gets rejected by the accuracy gate in
        // evaluateRegions, so accuracy is also part of the condition for using the cache. Because this was not
        // checked, a recent coarse fix sent us into the sync path and it ended there silently
        if let current = currentLocation,
           Date().timeIntervalSince(current.timestamp) < 60,
           current.horizontalAccuracy >= 0, current.horizontalAccuracy <= 100 {
            if evaluateRegions(with: current) {
                // A successful evaluation satisfies the pending request, so treat the leftovers of the earlier chain
                // as resolved too (if left alone, the earlier pending stays and the spinner does not go away for up to
                // 15 seconds)
                pendingGeofenceEvaluation = false
                isEvaluatingRegion = false
                evaluationRetryCount = 0
            }
        } else {
            evaluationRetryCount = 0
            pendingGeofenceEvaluation = true
            isEvaluatingRegion = true
            locationManager.requestLocation()
        }
    }

    /// Re-request when a reliable fix could not be obtained. requestLocation() delivers only once, so
    /// before this we silently gave up here, causing the silent failure "inside the area but the lock does
    /// not start" (happens with high probability right after first granting permission / indoor cold start
    /// = the real cause of the bug confirmed on a real device)
    private func scheduleEvaluationRetry() {
        guard evaluationRetryCount < maxEvaluationRetries else {
            pendingGeofenceEvaluation = false
            isEvaluatingRegion = false
            print("⚠️ Geofence evaluation gave up after \(maxEvaluationRetries) retries")
            return
        }
        evaluationRetryCount += 1
        pendingGeofenceEvaluation = true
        isEvaluatingRegion = true
        let delay = 2.0 * Double(evaluationRetryCount)   // 2s, 4s, 6s (wait for GPS warm-up)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.pendingGeofenceEvaluation else { return }
            self.locationManager.requestLocation()
        }
    }

    /// Check whether the current location is inside a specific place (requests an evaluation of all regions)
    private func checkIfInsideLocation(_ location: RegisteredLocation) {
        guard location.isEnabled else { return }
        requestGeofenceEvaluation()
    }

    /// Check whether the current location is inside any registered place (requests an evaluation of all
    /// regions)
    func checkCurrentLocationAgainstAllGeofences() {
        guard isAuthorized else { return }
        requestGeofenceEvaluation()
    }

    /// Based on the given location, evaluate presence in every enabled place and apply it to the Shield (B-5).
    /// Return value: true = evaluation ran / false = skipped due to low accuracy (the caller re-requests)
    private func evaluateRegions(with location: CLLocation) -> Bool {
        // M13: horizontalAccuracy < 0 (invalid fix) or > 100 (coarse fix with too much error) causes
        // false ON/OFF near the boundary, so skip the evaluation itself and keep the previous state
        // (2026-07-21 audit fix)
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 100 else {
            print("📍 Skipping region evaluation: unreliable fix (accuracy: \(location.horizontalAccuracy)m)")
            return false
        }

        for loc in registeredLocations where loc.isEnabled {
            let locationCenter = CLLocation(latitude: loc.latitude, longitude: loc.longitude)
            let distance = location.distance(from: locationCenter)

            // M13: Use asymmetric thresholds for enter/exit to suppress chattering.
            // enter is distance <= radius; exit only when clearly outside: distance > radius + measured error.
            // In the middle band (radius < distance <= radius + accuracy) keep the previous state as is
            if distance <= loc.radius {
                if !activeLocationIds.contains(loc.id) {
                    // Audit :881 fix: a session started by a manual evaluation records its start time, same as didEnterRegion
                    // (without this, a lock started by a manual evaluation was never counted in the total lock time)
                    if AppGroupStorage.shared.isProBlockingEntitled() {
                        saveLocationActiveStartIfAbsent(regionId: loc.id)
                    }
                    print("📍 Currently inside: \(loc.name) (distance: \(Int(distance))m)")
                }
                activeLocationIds.insert(loc.id)
            } else if distance > loc.radius + location.horizontalAccuracy {
                // Close the session once being outside is confirmed (enqueueLocationSession is a no-op
                // if there is no start time key, so it is idempotent)
                if activeLocationIds.contains(loc.id) {
                    enqueueLocationSession(regionId: loc.id)
                }
                activeLocationIds.remove(loc.id)
            }
        }

        // B-2: Always do an idempotent reconcile at the end (the foundInside guard was removed)
        syncShield()
        return true
    }

    // MARK: - Shield Management

    /// Reconcile the Shield state with the actual state in the store (idempotent) (B-2)
    /// Instead of a flag diff (isShieldActive), always compare "the state it should be in" with "the actual
    /// state in the store" and correct it. Even right after a cold launch (initial value isShieldActive=false),
    /// a Shield left in the store by the previous process is reliably removed.
    private func syncShield() {
        // C1: While a purchase expiry is confirmed by a fresh fetch, do not run location blocking
        // (geofence registration and place settings stay: when the mirror goes back to true, enter/exit events
        // bring it back automatically)
        let desired = !activeLocationIds.isEmpty && AppGroupStorage.shared.isProBlockingEntitled()
        let actuallyApplied = store.shield.applications != nil || store.shield.applicationCategories != nil

        if desired && !actuallyApplied {
            isShieldActive = applyShield()
        } else if !desired && actuallyApplied {
            removeShield()
        } else {
            // Already in the desired state → only sync the flag to the actual store state
            isShieldActive = actuallyApplied
        }
    }

    /// Apply the Shield. Returns true only if it was applied
    @discardableResult
    func applyShield() -> Bool {
        // C1: Do not write while expiry is confirmed (parity with the schedule side)
        guard AppGroupStorage.shared.isProBlockingEntitled() else {
            print("⚠️ applyShield: Pro entitlement lapsed - Location shield not applied")
            return false
        }

        // If Screen Time permission is revoked/not approved, writing to the store is not enforced.
        // To prevent "active in appearance only", return false early (parity with schedule-side A-5, added in
        // the Fable review)
        guard AuthorizationCenter.shared.authorizationStatus == .approved else {
            print("⚠️ applyShield: Family Controls not approved - Location shield not applied")
            return false
        }

        guard let selection = loadSelection() else {
            debugInfo = "⚠️ アプリが選択されていません"
            print("⚠️ No apps selected for location block")
            return false
        }

        guard !selection.applicationTokens.isEmpty || !selection.categoryTokens.isEmpty else {
            // There is a selection but the tokens are empty → not applied, so do not claim isShieldActive
            debugInfo = "⚠️ アプリが選択されていません"
            print("⚠️ Selection has no tokens")
            return false
        }

        // Categories and individual apps can be combined (union). The old "categories first" branch
        // was a hole where individual apps were not blocked when both were selected (2026-07-16 Fable review)
        store.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
        store.shield.applicationCategories = selection.categoryTokens.isEmpty ? nil : .specific(selection.categoryTokens)

        let locationNames = activeLocationIds.compactMap { id in
            registeredLocations.first { $0.id == id }?.name
        }.joined(separator: ", ")

        debugInfo = "🔒 ロック中: \(locationNames)"
        print("🔒 Shield applied for locations: \(locationNames)")
        return true
    }

    /// Remove the Shield
    func removeShield() {
        store.shield.applications = nil
        store.shield.applicationCategories = nil

        isShieldActive = false
        debugInfo = "🔓 ロック解除"
        print("🔓 Shield removed")
    }

    // MARK: - App Selection

    /// In-memory cache to avoid running the heavy PropertyListDecoder decode on the main thread on every
    /// applyShield (freeze investigation 2026-07-15: the decode was running in the same tick as the toggle)
    private var cachedSelection: FamilyActivitySelection?

    /// Save the app selection
    func saveSelection(_ selection: FamilyActivitySelection) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }

        cachedSelection = selection

        do {
            let data = try PropertyListEncoder().encode(selection)
            defaults.set(data, forKey: selectionKey)
            defaults.synchronize()
            print("💾 Saved location block selection")
        } catch {
            print("❌ Failed to save selection: \(error)")
        }
    }

    /// Load the app selection (decode only the first time, then use the in-memory cache)
    func loadSelection() -> FamilyActivitySelection? {
        if let cachedSelection {
            return cachedSelection
        }

        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: selectionKey) else {
            return nil
        }

        do {
            let decoded = try PropertyListDecoder().decode(FamilyActivitySelection.self, from: data)
            cachedSelection = decoded
            return decoded
        } catch {
            print("❌ Failed to load selection: \(error)")
            return nil
        }
    }

    // MARK: - Persistence

    /// Save places
    private func saveLocations() {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }

        do {
            let data = try JSONEncoder().encode(registeredLocations)
            defaults.set(data, forKey: locationsKey)
            defaults.synchronize()
        } catch {
            print("❌ Failed to save locations: \(error)")
        }
    }

    /// Load places
    private func loadLocations() {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: locationsKey) else {
            return
        }

        do {
            var loaded = try JSONDecoder().decode([RegisteredLocation].self, from: data)
            // B-7: A radius of 50m or less causes geofence flapping, so existing data under 100m is also raised
            for i in loaded.indices {
                loaded[i].radius = max(100, loaded[i].radius)
            }
            registeredLocations = loaded
            print("📍 Loaded \(registeredLocations.count) locations")
        } catch {
            print("❌ Failed to load locations: \(error)")
        }
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationManager: CLLocationManagerDelegate {

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.authorizationStatus = manager.authorizationStatus

            switch manager.authorizationStatus {
            case .authorizedAlways:
                self.registerAllGeofences()
            case .denied, .restricted, .authorizedWhenInUse:
                // If permission is revoked (or downgraded from Always → WhenInUse), exit events
                // can no longer be received in the background, and there is no way to unlock.
                // To prevent stuck-on (permanent blocking), clean up the Shield right here
                // (M11: a WhenInUse downgrade is treated the same as denied/restricted, 2026-07-21 audit fix)
                self.activeLocationIds.removeAll()
                self.syncShield()
            default:
                break
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.currentLocation = location

            // B-5: Evaluate when the fix arrives, not after a fixed asyncAfter wait
            if self.pendingGeofenceEvaluation {
                // Drop fixes that are too old (over 30s). requestLocation() delivers only once, so
                // just "waiting for the next update" left pending hanging and it failed silently
                if Date().timeIntervalSince(location.timestamp) < 30 {
                    if self.evaluateRegions(with: location) {
                        self.pendingGeofenceEvaluation = false
                        self.isEvaluatingRegion = false
                        self.evaluationRetryCount = 0
                    } else {
                        self.scheduleEvaluationRetry()   // Not accurate enough → re-request (before, this failed silently)
                    }
                } else {
                    self.scheduleEvaluationRetry()       // Old fix → re-request (before, it waited forever and hung)
                }
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("❌ Location error: \(error.localizedDescription)")

        // If pending is left alone after failing to get a fix, the region evaluation never finishes (silent
        // failure), so re-request
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.pendingGeofenceEvaluation else { return }
            self.scheduleEvaluationRetry()
        }
    }

    // Entered a geofence
    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let circularRegion = region as? CLCircularRegion,
              let uuid = UUID(uuidString: circularRegion.identifier) else {
            return
        }

        // C1: While expiry is confirmed we are not blocking, so do not record a session start either (prevents
        // inflating total lock time)
        if AppGroupStorage.shared.isProBlockingEntitled() {
            saveLocationActiveStart(regionId: uuid)
        }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.activeLocationIds.insert(uuid)

            if let location = self.registeredLocations.first(where: { $0.id == uuid }) {
                self.debugInfo = "📍 \(location.name) に入りました"
                print("📍 Entered: \(location.name)")
            }

            self.syncShield()
        }
    }

    // Exited a geofence
    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard let circularRegion = region as? CLCircularRegion,
              let uuid = UUID(uuidString: circularRegion.identifier) else {
            return
        }

        // Enqueue as a completed session
        enqueueLocationSession(regionId: uuid)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            self.activeLocationIds.remove(uuid)

            if let location = self.registeredLocations.first(where: { $0.id == uuid }) {
                self.debugInfo = "📍 \(location.name) を出ました"
                print("📍 Exited: \(location.name)")
            }

            self.syncShield()
        }
    }

    // Right after returning from startMonitoring, monitoring is not active yet, and there are many reports
    // that an immediate requestState returns .unknown. Request again from this callback, where monitoring
    // is confirmed started, to double it up (the didDetermineState side is idempotent on every path, so
    // duplicates are safe)
    func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        manager.requestState(for: region)
    }

    // Response to requestState(for:). If you are already inside the region when calling startMonitoring,
    // didEnterRegion does not fire (CoreLocation behavior), so the initial inside state right after
    // registration is decided here. It is also called alongside didEnter/didExit on boundary transitions, so
    // all handling is idempotent (insert/remove use a Set, session keys have an existence check)
    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard let circularRegion = region as? CLCircularRegion,
              let uuid = UUID(uuidString: circularRegion.identifier) else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Ignore late callbacks for places that are already unmonitored/disabled
            guard let location = self.registeredLocations.first(where: { $0.id == uuid }),
                  location.isEnabled else { return }

            switch state {
            case .inside:
                // Do nothing if already tracking. registerAllGeofences sends up to 20 regions' worth at once,
                // so do not run syncShield (ManagedSettingsStore read = main
                // thread IO) in the no-op case
                guard !self.activeLocationIds.contains(uuid) else { return }
                // This can fire together with didEnterRegion, so do not overwrite the start time of an ongoing session
                // (overwriting resets the start time to now on every restart or app return, and stats are lost)
                if AppGroupStorage.shared.isProBlockingEntitled() {
                    self.saveLocationActiveStartIfAbsent(regionId: uuid)
                }
                self.activeLocationIds.insert(uuid)
                self.debugInfo = "📍 \(location.name) の圏内にいます"
                self.syncShield()
            case .outside:
                // Correct only while tracking (= a missed exit is suspected). A .outside for a place we are not
                // tracking is a normal response that comes 20 in a row on every launch, so do nothing
                guard self.activeLocationIds.contains(uuid) else { return }
                self.enqueueLocationSession(regionId: uuid)
                self.activeLocationIds.remove(uuid)
                self.syncShield()
            case .unknown:
                break  // Our own evaluation chain (requestGeofenceEvaluation) is running as a fallback
            @unknown default:
                break
            }
        }
    }

    // MARK: - Session Recording (total time aggregation)

    private func saveLocationActiveStart(regionId: UUID) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        let key = AppGroupConstants.Keys.locationActiveStartPrefix + regionId.uuidString
        defaults.set(Date().timeIntervalSince1970, forKey: key)
    }

    /// A variant that does not overwrite the start time of an ongoing session.
    /// didDetermineState .inside / evaluateRegions are also called to "re-confirm an ongoing session"
    /// (after a process restart activeLocationIds is empty, so the contains guard does not work), so
    /// do not touch the key if it already exists. didEnterRegion (a true new entry; the preceding didExitRegion
    /// has deleted the key) keeps using the unconditional version as before: after a missed exit, a re-entry
    /// with the old key would overcount several days, so an unconditional overwrite is correct there
    private func saveLocationActiveStartIfAbsent(regionId: UUID) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        let key = AppGroupConstants.Keys.locationActiveStartPrefix + regionId.uuidString
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: key)
    }

    private func enqueueLocationSession(regionId: UUID) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        let key = AppGroupConstants.Keys.locationActiveStartPrefix + regionId.uuidString
        guard let startTs = defaults.object(forKey: key) as? TimeInterval else { return }

        BlockSessionTracker.enqueueSession(
            mode: "location",
            startedAt: Date(timeIntervalSince1970: startTs),
            endedAt: Date(),
            status: "completed"
        )
        defaults.removeObject(forKey: key)
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        // B-4: Do not silence geofence registration failures; reflect them in debugInfo
        DispatchQueue.main.async { [weak self] in
            self?.debugInfo = "⚠️ ジオフェンス登録失敗: \(error.localizedDescription)"
        }
        print("❌ Geofence monitoring failed: \(error.localizedDescription)")
    }
}
