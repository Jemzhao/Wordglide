import AppKit
import SwiftUI

/// Semantic AppKit colors follow the user's macOS appearance and contrast.
enum AppTheme {
    static let window = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
    static let ink = Color.primary
    static let secondary = Color.secondary
    static let line = Color(nsColor: .separatorColor).opacity(0.5)
    static let accent = Color.accentColor
    static let subtle = Color(nsColor: .quaternaryLabelColor).opacity(0.12)
    static let cornerRadius: CGFloat = 12
}
