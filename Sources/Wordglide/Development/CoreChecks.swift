import AppKit
import ApplicationServices

@MainActor
enum CoreChecks {
    static func run() async {
        for failure in TextLogic.coreCheckFailures() { DiagnosticCheck.fail(failure) }
        do {
            try TextCapture.requireExternalElement(AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier))
            DiagnosticCheck.fail("Own AX element was accepted")
        } catch CaptureError.ownApplication { }
        catch { DiagnosticCheck.fail("Unexpected own element error: \(error)") }
        do {
            _ = try await TextCapture.selected(pid: ProcessInfo.processInfo.processIdentifier, fallbackPoint: .zero)
            DiagnosticCheck.fail("Own selection was accepted")
        } catch CaptureError.ownApplication { }
        catch { DiagnosticCheck.fail("Unexpected own selection error: \(error)") }
        let model = AppModel(checkPermissions: false)
        let monitor = HoverMonitor(model: model)
        let source = CGRect(x: 100, y: 300, width: 300, height: 25)
        let pointer = CGPoint(x: 150, y: 310)
        let badge = CGRect(x: 150, y: 270, width: 30, height: 30)
        var opened = 0
        monitor.showBadge = { _, _ in badge }
        model.showCard = { _ in opened += 1 }
        model.clearHover = { [weak monitor] in monitor?.clearCandidate() }
        monitor.stage(CapturedText(text: "Hello", bounds: .zero, method: "test"), sourceRect: source, pointer: pointer, demo: true)
        DiagnosticCheck.require(opened == 0, "Hover must only stage an icon")
        let retainedAfterEntry = monitor.retainCandidate(at: CGPoint(x: 165, y: 285))
        // The hover entry presents a card. Cancel its automatic translation in
        // this same main-actor turn, before any real language work can start.
        model.translate(to: "original")
        DiagnosticCheck.require(retainedAfterEntry && opened == 1, "Icon entry must open")
        DiagnosticCheck.require(monitor.retainCandidate(at: CGPoint(x: 165, y: 285)) && opened == 1, "Do not reopen")
        model.dismiss(force: true)
        model.present(CapturedText(text: "Hello", bounds: .zero, method: "test"), cocoaAnchor: source, selection: true)
        model.translate(to: "original")
        monitor.visibleCardFrame = { source }
        DiagnosticCheck.require(monitor.retainSelection(), "Selection must persist across pointer gaps")
        DiagnosticCheck.require(model.result == "Hello" && model.phase == .result, "Original tab")
        DiagnosticCheck.require(!model.hasReplacementTarget, "Read-only selection must not expose replacement")
        model.dismiss(force: true)
        monitor.stop()
        print("PASS: text/UTF-16, coordinates, layout, self filtering, badge entry, persistent selection, read-only safety")
        exit(0)
    }
}

extension AppDelegate {
    func runWindowCheck() {
        model.enabled = false
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard let window else { DiagnosticCheck.fail("Main window missing") }
            let anchor = CGRect(x: 300, y: 400, width: 160, height: 24)
            DiagnosticCheck.require(statusItem.isVisible, "Menu bar item missing")
            print(model.directShortcutIssue.isEmpty ? "PASS: direct shortcut registered: " + model.directShortcut.symbols : "NOTICE: " + model.directShortcutIssue)
            let fixtures: [(source: String, language: String, result: String, expanded: Bool, selection: Bool)] = [
                ("Good design makes complex things feel simple.", "zh-Hans", "好的设计让复杂的事情变得简单。", false, true),
                ("Good design makes complex things feel simple.", "zh-Hans", String(repeating: "长译文滚动检查。", count: 60), true, false),
                ("好的设计让复杂的事情变得简单。", "en", "Good design makes complex things feel simple.", false, true),
                ("保持好奇，总有更多值得发现。", "en", String(repeating: "Stay curious. There is always more to discover. ", count: 35), true, true),
                ("Hello", "zh-Hans", "你好", true, true),
                ("你好", "en", "Hello", true, true)
            ]
            for cycle in 0..<6 {
                window.setContentSize(cycle.isMultiple(of: 2) ? NSSize(width: 660, height: 520) : NSSize(width: 720, height: 580))
                model.page = ["home", "try", "settings"][cycle % 3]
                let fixture = fixtures[cycle]
                let original = fixture.source
                let target = cycle.isMultiple(of: 2) ? nil : ReplacementTarget(
                    element: AXUIElementCreateApplication(1), pid: 1,
                    edit: SelectionEdit(value: original, selected: original, range: NSRange(location: 0, length: original.utf16.count)))
                model.present(CapturedText(text: original, bounds: .zero, method: "窗口检查"), cocoaAnchor: anchor, selection: fixture.selection, replacement: target)
                model.translate(to: "original")
                model.target = fixture.language
                model.result = fixture.result
                model.phase = .result
                model.sourceExpanded = fixture.expanded
                try? await Task.sleep(nanoseconds: 100_000_000)
                DiagnosticCheck.require(panel.isVisible && panel.frame.width == model.cardWidth && panel.frame.height == model.cardHeight, "Native panel geometry mismatch: visible=\(panel.isVisible), frame=\(panel.frame), expected=\(model.cardWidth)x\(model.cardHeight)")
                DiagnosticCheck.require(!panel.isOpaque && panel.backgroundColor == .clear, "Panel must remain transparent")
                DiagnosticCheck.require(panel.contentView is TransparentPanelContainer && panel.contentView?.isOpaque == false && panel.contentView?.layer?.masksToBounds == true && panel.contentView?.layer?.cornerRadius == 16, "Panel content must clip its complete backing to rounded corners")
                model.dismiss(force: true)
                window.performClose(nil)
                DiagnosticCheck.require(NSApp.isRunning, "Closing the window quit the menu bar app")
                showMain()
            }
            let path = FileManager.default.currentDirectoryPath + "/build/window-check.txt"
            try? "PASS: menu bar item; 6 native English-to-Chinese/Chinese-to-English panel open/resize/close cycles; English/Chinese expanded sources; short/long seeded results; translation/settings; main window close/reopen; application stays running; no translation, paste, or permission requests.\n".write(toFile: path, atomically: true, encoding: .utf8)
            print("PASS: native window cycles")
            NSApp.terminate(nil)
        }
    }
}
