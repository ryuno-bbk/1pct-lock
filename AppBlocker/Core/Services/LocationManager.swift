//
//  LocationManager.swift
//  AppBlocker
//
//  位置情報ベースのロック管理サービス
//  ジオフェンシングを使用して特定の場所でアプリをロック
//

import Foundation
import CoreLocation
import ManagedSettings
import FamilyControls
import Combine

/// 登録された場所
struct RegisteredLocation: Codable, Identifiable {
    let id: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    var radius: Double // メートル
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

/// 位置情報ロック管理サービス
final class LocationManager: NSObject, ObservableObject {

    @MainActor static let shared = LocationManager()

    private let locationManager = CLLocationManager()
    private let store = ManagedSettingsStore(named: .init(AppGroupConstants.Stores.location))
    private let appGroupID = AppGroupConstants.identifier

    // MARK: - Published Properties

    /// 登録された場所のリスト
    @Published var registeredLocations: [RegisteredLocation] = []

    /// 現在地
    @Published var currentLocation: CLLocation?

    /// 位置情報の権限状態
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    /// 現在ロック中の場所（ジオフェンス内にいる）
    @Published var activeLocationIds: Set<UUID> = []

    /// シールドが適用されているか
    @Published var isShieldActive: Bool = false

    /// デバッグ情報
    @Published var debugInfo: String = ""

    /// 在圏評価が進行中か (トグル直後のスピナー表示を評価完了まで維持するために公開。
    /// pendingGeofenceEvaluation はリトライ待ち中も true のまま維持される)
    @Published private(set) var isEvaluatingRegion = false

    // MARK: - Private Properties

    private let locationsKey = AppGroupConstants.Keys.registeredLocations
    private let selectionKey = AppGroupConstants.Keys.locationSelection

    /// requestLocation() の fix 到着待ち（B-5: 固定待ちのレースを解消するためのフラグ駆動）
    private var pendingGeofenceEvaluation = false

    /// 在圏評価の再試行回数 (信頼できる fix が取れるまで最大3回。無音失敗の撤廃)
    private var evaluationRetryCount = 0
    private let maxEvaluationRetries = 3

    // MARK: - Init

    @MainActor
    private override init() {
        super.init()

        locationManager.delegate = self
        // B-6: ジオフェンス判定には 100m 精度で十分。kCLLocationAccuracyBest はバッテリー消費が大きい
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters

        // ジオフェンシングはシステムが管理するため、
        // バックグラウンド更新の設定は不要（権限許可後に自動で動作）

        // 保存された場所を読み込み
        loadLocations()

        // 権限状態を更新
        authorizationStatus = locationManager.authorizationStatus

        // B-2: 登録場所がゼロ (または全て無効) なら、前回プロセスのシールドが
        // store に残っていても生き残らないよう、権限状態に関わらず無条件でクリアする。
        // 権限が Always でない場合も同様: exit イベントを受け取れず解除の術がないため、
        // stuck-on を防ぐ目的で起動時に必ずクリアする (Fable レビュー追加)
        if registeredLocations.filter({ $0.isEnabled }).isEmpty || !isAuthorized {
            removeShield()
        }

        // B-8: 権限が未確定（.notDetermined 等）のままジオフェンスを登録しない。
        // Always 権限が確定した時点の登録は locationManagerDidChangeAuthorization に任せる
        if isAuthorized {
            registerAllGeofences()
        }
    }

    // MARK: - Authorization

    /// 位置情報の権限をリクエスト
    func requestAuthorization() {
        // 現在の状態を再チェック
        let currentStatus = locationManager.authorizationStatus
        print("📍 Current authorization status: \(currentStatus.rawValue)")

        if currentStatus == .notDetermined {
            locationManager.requestAlwaysAuthorization()
        } else if currentStatus == .authorizedWhenInUse {
            // When In Use から Always に昇格をリクエスト
            locationManager.requestAlwaysAuthorization()
        } else {
            // 既に許可/拒否されている場合は状態を更新
            refreshAuthorizationStatus()
        }
    }

    /// 権限状態を再チェック
    func refreshAuthorizationStatus() {
        let status = locationManager.authorizationStatus
        DispatchQueue.main.async { [weak self] in
            self?.authorizationStatus = status
            print("📍 Authorization status refreshed: \(status.rawValue)")

            // B-3: Always のみジオフェンスを登録（WhenInUse はバックグラウンドで機能しないため対象外）
            if status == .authorizedAlways {
                self?.registerAllGeofences()
            }
        }
    }

    /// 権限が許可されているか
    /// B-3: WhenInUse はバックグラウンドでジオフェンスイベントを受け取れないため、認可扱いにしない
    var isAuthorized: Bool {
        locationManager.authorizationStatus == .authorizedAlways
    }

    // MARK: - Location Management

    /// 現在地を取得
    func requestCurrentLocation() {
        locationManager.requestLocation()
    }

    /// 有効な場所が iOS のジオフェンス同時監視上限（20）未満か（B-4）
    var canAddLocation: Bool {
        registeredLocations.filter(\.isEnabled).count < 20
    }

    /// 場所を登録
    func addLocation(_ location: RegisteredLocation) {
        // B-4: iOS は CLLocationManager が同時監視できるリージョンを 20 個に制限している
        guard canAddLocation else {
            debugInfo = "⚠️ これ以上場所を追加できません（iOS 制限で最大20箇所）"
            print("⚠️ Cannot add location: 20-region monitoring limit reached")
            return
        }

        registeredLocations.append(location)
        saveLocations()
        registerGeofence(for: location)

        // 現在地がこの場所の範囲内かチェック
        checkIfInsideLocation(location)

        debugInfo = "📍 場所を追加: \(location.name)"
        print("📍 Added location: \(location.name) at \(location.latitude), \(location.longitude)")
    }

    /// 場所を削除
    func removeLocation(_ location: RegisteredLocation) {
        registeredLocations.removeAll { $0.id == location.id }
        saveLocations()
        unregisterGeofence(for: location)

        // アクティブリストからも削除
        activeLocationIds.remove(location.id)
        syncShield()

        debugInfo = "🗑️ 場所を削除: \(location.name)"
        print("🗑️ Removed location: \(location.name)")
    }

    /// 場所を更新
    func updateLocation(_ location: RegisteredLocation) {
        if let index = registeredLocations.firstIndex(where: { $0.id == location.id }) {
            // 古いジオフェンスを解除
            unregisterGeofence(for: registeredLocations[index])

            // 更新
            registeredLocations[index] = location
            saveLocations()

            // 新しいジオフェンスを登録
            if location.isEnabled {
                registerGeofence(for: location)
            }

            debugInfo = "✏️ 場所を更新: \(location.name)"
        }
    }

    /// 場所の有効/無効を切り替え
    func toggleLocation(_ location: RegisteredLocation) {
        var updated = location
        updated.isEnabled = !location.isEnabled

        // B-4: 有効化しようとしている場合のみ上限チェック（無効化は常に許可）
        if updated.isEnabled && !canAddLocation {
            debugInfo = "⚠️ これ以上有効化できません（iOS 制限で最大20箇所）"
            print("⚠️ Cannot enable location: 20-region monitoring limit reached")
            return
        }

        updateLocation(updated)

        // オフにした場合、この場所のロックを解除
        if !updated.isEnabled {
            activeLocationIds.remove(location.id)
            syncShield()
            debugInfo = "⏸️ 監視を停止: \(location.name)"
            print("⏸️ Monitoring paused for: \(location.name)")
        } else {
            // オンにした場合、現在地がこの場所の範囲内かチェック
            checkIfInsideLocation(updated)
            debugInfo = "▶️ 監視を開始: \(location.name)"
            print("▶️ Monitoring started for: \(location.name)")
        }
    }

    // MARK: - Geofencing

    /// ジオフェンスを登録
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

        // 既に圏内にいる状態で startMonitoring しても didEnterRegion は発火しない (CoreLocation 仕様)。
        // 初回の在圏は requestState → didDetermineState で判定する
        // (2026-08-09: 「初めて場所を保存して圏内でONにしてもロックが始まらない」バグの本丸)
        locationManager.requestState(for: region)

        print("🔔 Registered geofence: \(location.name) (radius: \(location.radius)m)")
    }

    /// ジオフェンスを解除
    private func unregisterGeofence(for location: RegisteredLocation) {
        let region = CLCircularRegion(
            center: location.coordinate,
            radius: location.radius,
            identifier: location.id.uuidString
        )
        locationManager.stopMonitoring(for: region)

        print("🔕 Unregistered geofence: \(location.name)")
    }

    /// すべてのジオフェンスを再登録
    private func registerAllGeofences() {
        // 既存のジオフェンスをクリア
        for region in locationManager.monitoredRegions {
            locationManager.stopMonitoring(for: region)
        }

        // 有効な場所のジオフェンスを登録
        for location in registeredLocations where location.isEnabled {
            registerGeofence(for: location)
        }

        // 現在地が登録済みの場所の範囲内かチェック
        checkCurrentLocationAgainstAllGeofences()
    }

    /// 現在地の fix を要求し、取得次第すべての有効な場所を評価する（B-5/B-6）。
    /// 直近60秒以内の fix が既にあればそれを使って即時評価し、requestLocation() をスキップする
    /// （バッテリー節約 + 固定 asyncAfter 待ちによるレースの解消）。
    private func requestGeofenceEvaluation() {
        // 60秒以内でも粗い fix (accuracy > 100m) は evaluateRegions の精度ゲートで弾かれるだけなので、
        // キャッシュ採用の条件に精度も入れる。ここを見ていなかったため、直近に粗い fix があると
        // 同期パスに入ってそのまま無音で終わっていた
        if let current = currentLocation,
           Date().timeIntervalSince(current.timestamp) < 60,
           current.horizontalAccuracy >= 0, current.horizontalAccuracy <= 100 {
            if evaluateRegions(with: current) {
                // 評価成功は pending の要求を満たすので、先行チェーンの残骸ごと解決扱いにする
                // (放置すると先行の pending が残り続けてスピナーが最長15秒消えない)
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

    /// 信頼できる fix が取れなかった時の再要求。requestLocation() は1回しか配送しないため、
    /// 従来はここで黙って諦めて「圏内にいるのにロックが始まらない」無音失敗になっていた
    /// (初回権限許可直後・屋内のコールドスタートで高確率で発生 = 実機で確認されたバグの真因)
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
        let delay = 2.0 * Double(evaluationRetryCount)   // 2s, 4s, 6s (GPS ウォームアップ待ち)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.pendingGeofenceEvaluation else { return }
            self.locationManager.requestLocation()
        }
    }

    /// 現在地が特定の場所の範囲内かチェック（全リージョン評価をリクエスト）
    private func checkIfInsideLocation(_ location: RegisteredLocation) {
        guard location.isEnabled else { return }
        requestGeofenceEvaluation()
    }

    /// 現在地がすべての登録済み場所の範囲内かチェック（全リージョン評価をリクエスト）
    func checkCurrentLocationAgainstAllGeofences() {
        guard isAuthorized else { return }
        requestGeofenceEvaluation()
    }

    /// 指定した位置情報を元に、全ての有効な場所への滞在を評価してシールドに反映する（B-5）。
    /// 戻り値: true = 評価を実行した / false = 精度不足でスキップした（呼び出し側で再要求する）
    private func evaluateRegions(with location: CLLocation) -> Bool {
        // M13: horizontalAccuracy < 0 (無効な fix) または > 100 (誤差が大きすぎる粗い fix) は
        // 境界付近での誤ON/誤OFFの原因になるため、評価自体をスキップして前回状態を維持する
        // (2026-07-21 監査対応)
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 100 else {
            print("📍 Skipping region evaluation: unreliable fix (accuracy: \(location.horizontalAccuracy)m)")
            return false
        }

        for loc in registeredLocations where loc.isEnabled {
            let locationCenter = CLLocation(latitude: loc.latitude, longitude: loc.longitude)
            let distance = location.distance(from: locationCenter)

            // M13: enter/exit を非対称閾値にしてチャタリングを抑制。
            // enter は distance <= radius、exit は distance > radius + 実測誤差 が確実に外れた時のみ。
            // 中間帯 (radius < distance <= radius + accuracy) は前回状態をそのまま保持する
            if distance <= loc.radius {
                if !activeLocationIds.contains(loc.id) {
                    // 監査 :881 対応: 手動評価で始まるセッションも didEnterRegion と同様に開始時刻を記録する
                    // (これが無いと手動評価で始まったロックが累計ロック時間に一切入らなかった)
                    if AppGroupStorage.shared.isProBlockingEntitled() {
                        saveLocationActiveStartIfAbsent(regionId: loc.id)
                    }
                    print("📍 Currently inside: \(loc.name) (distance: \(Int(distance))m)")
                }
                activeLocationIds.insert(loc.id)
            } else if distance > loc.radius + location.horizontalAccuracy {
                // 圏外が確定したらセッションを閉じる (enqueueLocationSession は開始時刻キーが
                // 無ければ no-op なので冪等)
                if activeLocationIds.contains(loc.id) {
                    enqueueLocationSession(regionId: loc.id)
                }
                activeLocationIds.remove(loc.id)
            }
        }

        // B-2: 末尾で必ず冪等リコンサイルを行う（foundInside ガードは撤去）
        syncShield()
        return true
    }

    // MARK: - Shield Management

    /// シールド状態を store の実状態とリコンサイル（冪等）（B-2）
    /// フラグ差分 (isShieldActive) でなく、常に「あるべき状態」と「store の実状態」を突き合わせて是正する。
    /// コールドローンチ直後 (isShieldActive=false の初期値) でも、
    /// 前回プロセスのシールドが store に残っていれば確実に除去できる。
    private func syncShield() {
        // C1: 課金失効が新鮮なフェッチで確定している間は位置遮断を実行しない
        // (ジオフェンス登録と場所設定は残す — ミラーが true に戻れば enter/exit イベントで自動復活)
        let desired = !activeLocationIds.isEmpty && AppGroupStorage.shared.isProBlockingEntitled()
        let actuallyApplied = store.shield.applications != nil || store.shield.applicationCategories != nil

        if desired && !actuallyApplied {
            isShieldActive = applyShield()
        } else if !desired && actuallyApplied {
            removeShield()
        } else {
            // 既に望ましい状態 → フラグだけ実際の store 状態に同期
            isShieldActive = actuallyApplied
        }
    }

    /// シールドを適用。適用できた場合のみ true を返す
    @discardableResult
    func applyShield() -> Bool {
        // C1: 失効確定中は書き込まない (schedule 側とのパリティ)
        guard AppGroupStorage.shared.isProBlockingEntitled() else {
            print("⚠️ applyShield: Pro entitlement lapsed - Location shield not applied")
            return false
        }

        // Screen Time 権限が失効/未承認の場合、store に書いても enforcement されない。
        // 「見た目だけ active」を防ぐため false で早期 return (schedule 側 A-5 とのパリティ、Fable レビュー追加)
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
            // 選択はあるがトークンが空 → 適用できていないので isShieldActive を主張しない
            debugInfo = "⚠️ アプリが選択されていません"
            print("⚠️ Selection has no tokens")
            return false
        }

        // カテゴリと個別アプリは併用可能 (和集合)。旧「カテゴリ優先」分岐は
        // 両方選んだ時に個別アプリが遮断されない穴だった (2026-07-16 Fableレビュー)
        store.shield.applications = selection.applicationTokens.isEmpty ? nil : selection.applicationTokens
        store.shield.applicationCategories = selection.categoryTokens.isEmpty ? nil : .specific(selection.categoryTokens)

        let locationNames = activeLocationIds.compactMap { id in
            registeredLocations.first { $0.id == id }?.name
        }.joined(separator: ", ")

        debugInfo = "🔒 ロック中: \(locationNames)"
        print("🔒 Shield applied for locations: \(locationNames)")
        return true
    }

    /// シールドを解除
    func removeShield() {
        store.shield.applications = nil
        store.shield.applicationCategories = nil

        isShieldActive = false
        debugInfo = "🔓 ロック解除"
        print("🔓 Shield removed")
    }

    // MARK: - App Selection

    /// applyShield のたびに PropertyListDecoder の重いデコードがメインスレッドで走るのを避ける
    /// メモリキャッシュ (フリーズ調査 2026-07-15: デコードがトグルの同一ティックに乗っていた)
    private var cachedSelection: FamilyActivitySelection?

    /// アプリ選択を保存
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

    /// アプリ選択を読み込み (初回のみデコードし、以後はメモリキャッシュ)
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

    /// 場所を保存
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

    /// 場所を読み込み
    private func loadLocations() {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: locationsKey) else {
            return
        }

        do {
            var loaded = try JSONDecoder().decode([RegisteredLocation].self, from: data)
            // B-7: 50m 以下の半径はジオフェンスのフラッピング源になるため、既存データも 100m 未満は引き上げる
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
                // 権限を切られたら（あるいは Always → WhenInUse に降格されたら）exit イベントを
                // バックグラウンドで受け取れなくなり、解除する術がなくなる。
                // stuck-on (永久ブロック) を防ぐため、この場でシールドを掃除する
                // (M11: WhenInUse 降格時も denied/restricted と同様に扱う, 2026-07-21 監査対応)
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

            // B-5: 固定 asyncAfter 待ちでなく、fix の到着駆動で評価する
            if self.pendingGeofenceEvaluation {
                // 古すぎる fix（30s 超）は捨てる。requestLocation() は1回しか配送しないため、
                // 「次の更新を待つ」だけだと pending が宙吊りになって無音失敗していた
                if Date().timeIntervalSince(location.timestamp) < 30 {
                    if self.evaluateRegions(with: location) {
                        self.pendingGeofenceEvaluation = false
                        self.isEvaluatingRegion = false
                        self.evaluationRetryCount = 0
                    } else {
                        self.scheduleEvaluationRetry()   // 精度不足 → 再要求 (従来は無音失敗)
                    }
                } else {
                    self.scheduleEvaluationRetry()       // 古い fix → 再要求 (従来は永遠に待って宙吊り)
                }
            }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("❌ Location error: \(error.localizedDescription)")

        // fix 取得に失敗したまま pending を放置すると在圏評価が永久に終わらない (無音失敗) ため再要求する
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.pendingGeofenceEvaluation else { return }
            self.scheduleEvaluationRetry()
        }
    }

    // ジオフェンスに入った
    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let circularRegion = region as? CLCircularRegion,
              let uuid = UUID(uuidString: circularRegion.identifier) else {
            return
        }

        // C1: 失効確定中は遮断していないため、セッション開始も記録しない (累計ロック時間の水増し防止)
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

    // ジオフェンスから出た
    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard let circularRegion = region as? CLCircularRegion,
              let uuid = UUID(uuidString: circularRegion.identifier) else {
            return
        }

        // セッション完了として enqueue
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

    // startMonitoring から戻った瞬間は監視がまだ有効化されておらず、直後の requestState が
    // .unknown を返す報告が多い。監視開始が確定したこのコールバックからも要求して二重化する
    // (didDetermineState 側は全経路冪等なので重複しても安全)
    func locationManager(_ manager: CLLocationManager, didStartMonitoringFor region: CLRegion) {
        manager.requestState(for: region)
    }

    // requestState(for:) への応答。既に圏内にいる状態で startMonitoring しても
    // didEnterRegion は発火しない (CoreLocation 仕様) ため、登録直後の初期在圏は
    // これで判定する。境界遷移時にも didEnter/didExit と並行して呼ばれるので、
    // 処理はすべて冪等にする (insert/remove は Set、session キーは存在チェック付き)
    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard let circularRegion = region as? CLCircularRegion,
              let uuid = UUID(uuidString: circularRegion.identifier) else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // 監視解除済み/無効化済みの場所への遅延コールバックは無視
            guard let location = self.registeredLocations.first(where: { $0.id == uuid }),
                  location.isEnabled else { return }

            switch state {
            case .inside:
                // 既に追跡中なら何もしない。registerAllGeofences で最大20リージョンぶん一斉に
                // 飛んでくるため、no-op ケースで syncShield (ManagedSettingsStore 読み = メイン
                // スレッド IO) を回さない
                guard !self.activeLocationIds.contains(uuid) else { return }
                // didEnterRegion と重複発火しうるので、進行中セッションの開始時刻は上書きしない
                // (上書きすると再起動やアプリ復帰のたびに開始時刻が now にリセットされ統計が欠ける)
                if AppGroupStorage.shared.isProBlockingEntitled() {
                    self.saveLocationActiveStartIfAbsent(regionId: uuid)
                }
                self.activeLocationIds.insert(uuid)
                self.debugInfo = "📍 \(location.name) の圏内にいます"
                self.syncShield()
            case .outside:
                // 追跡中 (= exit 取りこぼしの疑い) の時だけ是正する。追跡していない場所への
                // .outside は毎起動20連で飛んでくる正常応答なので何もしない
                guard self.activeLocationIds.contains(uuid) else { return }
                self.enqueueLocationSession(regionId: uuid)
                self.activeLocationIds.remove(uuid)
                self.syncShield()
            case .unknown:
                break  // 自前評価チェーン (requestGeofenceEvaluation) がフォールバックとして走っている
            @unknown default:
                break
            }
        }
    }

    // MARK: - Session Recording (累計時間集計)

    private func saveLocationActiveStart(regionId: UUID) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        let key = AppGroupConstants.Keys.locationActiveStartPrefix + regionId.uuidString
        defaults.set(Date().timeIntervalSince1970, forKey: key)
    }

    /// 進行中セッションの開始時刻を上書きしないための変種。
    /// didDetermineState .inside / evaluateRegions は「継続中セッションの再確認」でも呼ばれる
    /// (プロセス再起動後は activeLocationIds が空で contains ガードが機能しない) ため、
    /// 既にキーがある場合は触らない。didEnterRegion (真の新規入圏。直前の didExitRegion が
    /// キーを消している) は従来どおり無条件版を使う — exit 取りこぼし後の再入圏で
    /// 古いキーのまま数日ぶんが過大計上されるのを防ぐため、無条件上書きが正しい
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
        // B-4: ジオフェンス登録失敗を沈黙させず debugInfo に反映する
        DispatchQueue.main.async { [weak self] in
            self?.debugInfo = "⚠️ ジオフェンス登録失敗: \(error.localizedDescription)"
        }
        print("❌ Geofence monitoring failed: \(error.localizedDescription)")
    }
}
