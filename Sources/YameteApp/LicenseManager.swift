#if canImport(YameteCore)
import YameteCore
#endif
import Foundation
import Security
import Observation

private let log = AppLog(category: "License")

// MARK: - License state

/// Represents the current license status of the application.
public enum LicenseStatus: Equatable, Sendable {
    case trial(daysRemaining: Int)
    case active(key: String)
    case expired
    case invalid
}

// MARK: - Keychain-based license store

/// Persists license keys securely in the macOS Keychain.
/// UserDefaults is not appropriate for license state — it's trivially editable.
enum LicenseStore {
    private static let service = "com.yamete.license"
    private static let account = "license-key"

    static func loadKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func saveKey(_ key: String) {
        deleteKey()
        let data = Data(key.utf8)
        let attrs: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func deleteKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - License manager

/// Manages license validation, trial period, and activation state.
///
/// Trial period: 7 days from first launch.
/// Activation: license key validated against a server (placeholder — currently accepts any non-empty key).
/// State is persisted in the Keychain (license key) and UserDefaults (trial start date).
@MainActor @Observable
final class LicenseManager {
    private(set) var status: LicenseStatus = .trial(daysRemaining: 7)

    private static let trialStartKey = "licenseTrialStartDate"
    private static let trialDurationDays = 7

    init() {
        status = resolveStatus()
    }

    /// Attempt to activate with a license key.
    /// Currently accepts any non-empty key as valid (server validation is a future addition).
    func activate(key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            status = .invalid
            return false
        }

        // TODO: Validate key against licensing server
        // For now, accept any non-empty key format: XXXX-XXXX-XXXX-XXXX
        let pattern = #"^[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$"#
        guard trimmed.range(of: pattern, options: .regularExpression) != nil else {
            log.warning("entity:License wasInvalidatedBy activity:Activation — invalid format")
            status = .invalid
            return false
        }

        LicenseStore.saveKey(trimmed)
        status = .active(key: trimmed)
        log.info("entity:License wasActivatedBy activity:Activation")
        return true
    }

    /// Deactivate the current license.
    func deactivate() {
        LicenseStore.deleteKey()
        status = resolveStatus()
        log.info("entity:License wasDeactivatedBy activity:Deactivation")
    }

    /// Whether the app is currently usable (trial or active license).
    var isUsable: Bool {
        switch status {
        case .trial(let days): days > 0
        case .active: true
        case .expired, .invalid: false
        }
    }

    // MARK: - Private

    private func resolveStatus() -> LicenseStatus {
        // Check for stored license key first
        if let key = LicenseStore.loadKey() {
            return .active(key: key)
        }

        // Calculate trial status
        let defaults = UserDefaults.standard
        let startDate: Date
        if let stored = defaults.object(forKey: Self.trialStartKey) as? Date {
            startDate = stored
        } else {
            startDate = Date()
            defaults.set(startDate, forKey: Self.trialStartKey)
        }

        let elapsed = Calendar.current.dateComponents([.day], from: startDate, to: Date())
        let daysUsed = elapsed.day ?? 0
        let remaining = max(0, Self.trialDurationDays - daysUsed)

        if remaining > 0 {
            return .trial(daysRemaining: remaining)
        } else {
            return .expired
        }
    }
}
