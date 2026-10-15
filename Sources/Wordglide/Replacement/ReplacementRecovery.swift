import Foundation

/// One recoverable operation, held only in memory. It deliberately contains no
/// AX target, selection handle, or paste permission that could be replayed.
struct ReplacementRecovery: Identifiable, Equatable {
    let id: UUID
    let source: String
    let translation: String?
    let targetLanguage: String
    let message: String

    init(source: String, translation: String?, targetLanguage: String, message: String) {
        id = UUID()
        self.source = source
        self.translation = translation.flatMap { TextLogic.clean($0).isEmpty ? nil : $0 }
        self.targetLanguage = targetLanguage
        self.message = message
    }

    var hasTranslation: Bool { translation != nil }
}
