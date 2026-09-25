//
//  AuthorizationService.swift
//  AppBlocker
//
//  FamilyControls権限管理サービス
//

import Foundation
import Combine
import FamilyControls

/// FamilyControls認証状態
enum AuthorizationStatus {
    case notDetermined
    case denied
    case approved
}

/// FamilyControls権限管理
final class AuthorizationService: ObservableObject {

    @MainActor static let shared = AuthorizationService()

    @Published private(set) var authorizationStatus: AuthorizationStatus = .notDetermined
    @Published private(set) var isAuthorizing: Bool = false
    @Published var errorMessage: String?

    private let center = AuthorizationCenter.shared

    @MainActor
    private init() {
        checkCurrentStatus()
    }

    // MARK: - Public Methods

    /// 現在の認証状態を確認
    @MainActor
    func checkCurrentStatus() {
        let status = center.authorizationStatus
        if status == .notDetermined {
            authorizationStatus = .notDetermined
        } else if status == .denied {
            authorizationStatus = .denied
        } else if status == .approved {
            authorizationStatus = .approved
        } else {
            authorizationStatus = .notDetermined
        }
    }

    /// FamilyControls権限をリクエスト
    @MainActor
    func requestAuthorization() async {
        guard !isAuthorizing else { return }

        isAuthorizing = true
        errorMessage = nil

        do {
            try await center.requestAuthorization(for: .individual)
            authorizationStatus = .approved
        } catch {
            handleAuthorizationError(error)
        }

        isAuthorizing = false
    }

    /// 認証が完了しているか
    var isAuthorized: Bool {
        authorizationStatus == .approved
    }

    // MARK: - Private Methods

    @MainActor
    private func handleAuthorizationError(_ error: Error) {
        if let familyError = error as? FamilyControlsError {
            switch familyError {
            case .restricted:
                errorMessage = "この端末ではFamilyControlsが制限されています"
                authorizationStatus = .denied
            case .unavailable:
                errorMessage = "FamilyControlsは現在利用できません"
                authorizationStatus = .denied
            case .invalidAccountType:
                errorMessage = "無効なアカウントタイプです"
                authorizationStatus = .denied
            case .invalidArgument:
                errorMessage = "無効な引数です"
                authorizationStatus = .notDetermined
            case .authorizationConflict:
                errorMessage = "認証の競合が発生しました"
                authorizationStatus = .denied
            case .authorizationCanceled:
                errorMessage = "認証がキャンセルされました"
                authorizationStatus = .notDetermined
            case .networkError:
                errorMessage = "ネットワークエラーが発生しました"
                authorizationStatus = .notDetermined
            @unknown default:
                errorMessage = "不明なエラーが発生しました"
                authorizationStatus = .notDetermined
            }
        } else {
            errorMessage = error.localizedDescription
            authorizationStatus = .notDetermined
        }
    }
}
