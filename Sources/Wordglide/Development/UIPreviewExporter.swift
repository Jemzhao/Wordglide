import AppKit
import SwiftUI
import ApplicationServices

/// Renders the application's own views with sample content for visual QA.
/// This reads no screen pixels, requests no permissions, and never pastes text.
@MainActor
enum UIPreviewExporter {
    static func run() async {
        do {
            let destination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("build/ui-previews", isDirectory: true)
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let obsolete = destination.appendingPathComponent("card-replacement-\(suffix).png")
                if FileManager.default.fileExists(atPath: obsolete.path) {
                    try FileManager.default.removeItem(at: obsolete)
                }
                let model = AppModel(checkPermissions: false)
                model.manualText = "Stay curious. There is always more to discover."
                model.languageReady = true
                model.languageStatus = "已就绪 · 离线可用"
                model.status = "准备就绪"
                model.page = "try"
                try await render(MainView(model: model), size: CGSize(width: 720, height: 580), appearance: appearance,
                                 to: destination.appendingPathComponent("main-\(suffix).png"))
                model.retainReplacementRecovery(ReplacementRecovery(
                    source: "请帮我确认会议时间，并在有变化时通知我。",
                    translation: "Please confirm the meeting time and let me know if anything changes.",
                    targetLanguage: "en", message: "输入内容已变化，未替换原文。可以复制译文后自行粘贴。"))
                try await render(MainView(model: model), size: CGSize(width: 720, height: 580), appearance: appearance,
                                 to: destination.appendingPathComponent("main-recovery-\(suffix).png"))
                model.retainReplacementRecovery(ReplacementRecovery(
                    source: "请帮我确认会议时间，并在有变化时通知我。", translation: nil,
                    targetLanguage: "en", message: "翻译等待超过 30 秒，原文未替换。可以重新翻译，再查看或复制结果。"))
                try await render(MainView(model: model), size: CGSize(width: 660, height: 580), appearance: appearance,
                                 to: destination.appendingPathComponent("main-timeout-\(suffix).png"))
                model.dismissReplacementRecovery()
                model.page = "settings"
                try await render(MainView(model: model), size: CGSize(width: 660, height: 580), appearance: appearance,
                                 to: destination.appendingPathComponent("settings-\(suffix).png"))
                try await render(UpdateSettingsView(updater: model.updates).padding(20).background(AppTheme.window),
                                 size: CGSize(width: 520, height: 245), appearance: appearance,
                                 to: destination.appendingPathComponent("updates-\(suffix).png"))
                let original = "Stay curious. There is always more to discover."
                let target = ReplacementTarget(element: AXUIElementCreateApplication(1), pid: 1,
                    edit: SelectionEdit(value: original, selected: original, range: NSRange(location: 0, length: original.utf16.count)))
                model.present(CapturedText(text: original, bounds: .zero, method: "视觉检查"), cocoaAnchor: CGRect(x: 300, y: 400, width: 100, height: 20), selection: true, replacement: target)
                // Keep fixtures deterministic: cancel the automatic translation
                // synchronously, then seed the result without language work.
                model.translate(to: "original")
                model.target = "zh-Hans"
                model.result = "保持好奇。总有更多值得发现。"
                model.phase = .result
                try await render(TranslationCard(model: model), size: CGSize(width: model.cardWidth, height: model.cardHeight), appearance: appearance,
                                 to: destination.appendingPathComponent("card-\(suffix).png"))
                model.sourceExpanded = true
                try await render(TranslationCard(model: model), size: CGSize(width: model.cardWidth, height: model.cardHeight), appearance: appearance,
                                 to: destination.appendingPathComponent("card-expanded-\(suffix).png"))
                model.dismiss(force: true)
                let chinese = "保持好奇，总有更多值得发现。"
                let chineseTarget = ReplacementTarget(element: AXUIElementCreateApplication(1), pid: 1,
                    edit: SelectionEdit(value: chinese, selected: chinese, range: NSRange(location: 0, length: chinese.utf16.count)))
                model.present(CapturedText(text: chinese, bounds: .zero, method: "视觉检查"), cocoaAnchor: .zero,
                              selection: true, replacement: chineseTarget)
                model.translate(to: "original")
                model.target = "en"
                model.result = "Stay curious. There is always more to discover."
                model.phase = .result
                model.sourceExpanded = true
                try await render(TranslationCard(model: model), size: CGSize(width: model.cardWidth, height: model.cardHeight), appearance: appearance,
                                 to: destination.appendingPathComponent("card-chinese-\(suffix).png"))
                model.dismiss(force: true)
                model.present(CapturedText(text: "Hello", bounds: .zero, method: "视觉检查"), cocoaAnchor: .zero, selection: true, replacement: ReplacementTarget(
                    element: AXUIElementCreateApplication(1), pid: 1, edit: SelectionEdit(value: "Hello", selected: "Hello", range: NSRange(location: 0, length: 5))))
                model.translate(to: "original")
                model.target = "zh-Hans"
                model.result = "你好"; model.phase = .result
                try await render(TranslationCard(model: model), size: CGSize(width: model.cardWidth, height: model.cardHeight), appearance: appearance,
                                 to: destination.appendingPathComponent("card-short-\(suffix).png"))
                model.dismiss(force: true)

                // Exercise the real failure path so retry availability follows
                // the same state transition as a deadline in the live app.
                let timedOut = AppModel(checkPermissions: false, translator: PreviewTimeoutTranslator())
                timedOut.present(CapturedText(text: "请帮我确认会议时间。", bounds: .zero, method: "视觉检查"),
                                 cocoaAnchor: .zero, selection: true)
                for _ in 0..<1000 where timedOut.phase != .failure { await Task.yield() }
                guard timedOut.phase == .failure, timedOut.canRetryTranslation else {
                    throw NSError(domain: "Wordglide.UIPreview", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "Timeout preview never reached its retry state"])
                }
                try await render(TranslationCard(model: timedOut), size: CGSize(width: timedOut.cardWidth, height: timedOut.cardHeight), appearance: appearance,
                                 to: destination.appendingPathComponent("card-timeout-\(suffix).png"))
                // Loading is a visual fixture only: no live engine request is
                // left pending while the cancellation control is rendered.
                timedOut.translate(to: "original")
                timedOut.target = "en"
                timedOut.result = ""
                timedOut.phase = .loading
                try await render(TranslationCard(model: timedOut), size: CGSize(width: timedOut.cardWidth, height: timedOut.cardHeight), appearance: appearance,
                                 to: destination.appendingPathComponent("card-loading-\(suffix).png"))
                timedOut.dismiss(force: true)
            }
            print("PASS: rendered native UI previews at \(destination.path)")
            NSApp.terminate(nil)
        } catch {
            DiagnosticCheck.fail("UI preview export failed: \(error)")
        }
    }

    private static func render<Content: View>(_ content: Content, size: CGSize, appearance: NSAppearance.Name, to url: URL) async throws {
        let window = FloatingPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: size)
        window.contentView = hosting
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(160))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
        window.orderOut(nil)
    }
}

@MainActor
private struct PreviewTimeoutTranslator: TranslationService {
    func translate(_ text: String, target: String) async throws -> String {
        throw TranslationIssue.timedOut
    }
}
