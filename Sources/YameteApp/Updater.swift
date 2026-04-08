#if canImport(YameteCore)
import YameteCore
#endif
import Foundation
import Observation

/// App version info. Updates are delivered through the Mac App Store.
@MainActor @Observable
public final class Updater {
    let currentVersion: String

    init() {
        currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }
}
