import SwiftUI

// MARK: - Reusable setting row

internal struct SettingRow<Content: View>: View {
    let icon: String
    let title: String
    let help: String
    @ViewBuilder let content: Content

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SettingHeader(icon: icon, title: title, help: help)
            content
        }
    }
}
