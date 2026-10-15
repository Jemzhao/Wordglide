// Portions derived from HoverTranslate, Copyright (c) 2026 Kianzzz (MIT).
// See ThirdParty/HoverTranslate-LICENSE.
import AppKit
import SwiftUI
import Translation
import ApplicationServices

enum CardPhase { case choose, loading, result, failure }
@MainActor
final class AppModel: ObservableObject {
    let updates: AppUpdater
    @Published var page = "try"
    @Published var enabled = false
    @Published var hoverEnabled = true { didSet { if persistSettings { UserDefaults.standard.set(hoverEnabled, forKey: "hoverEnabled") } } }
    @Published var selectionEnabled = true { didSet { if persistSettings { UserDefaults.standard.set(selectionEnabled, forKey: "selectionEnabled") } } }
    @Published var ocrEnabled = true { didSet { if persistSettings { UserDefaults.standard.set(ocrEnabled, forKey: "ocrEnabled") } } }
    @Published var delay = 0.6 { didSet { if persistSettings { UserDefaults.standard.set(delay, forKey: "hoverDelay") } } }
    @Published var closeDelay = 0.0 { didSet { if persistSettings { UserDefaults.standard.set(closeDelay, forKey: "closeDelay") } } }
    @Published var wordMode = false { didSet { if persistSettings { UserDefaults.standard.set(wordMode, forKey: "wordMode") } } }
    @Published var accessibility = false
    @Published var screenPermission = false
    @Published var languageStatus = "检查中"
    @Published var languageReady = false
    @Published var preparationConfig: TranslationSession.Configuration?
    @Published var preparationMessage = ""
    @Published var preparing = false
    @Published var directShortcut = DirectReplacementShortcut.controlReturn {
        didSet { if persistSettings { UserDefaults.standard.set(directShortcut.rawValue, forKey: "directShortcut") } }
    }
    @Published var directTargetLanguage = "auto" {
        didSet { if persistSettings { UserDefaults.standard.set(directTargetLanguage, forKey: "directTargetLanguage") } }
    }
    @Published var directShortcutIssue = ""
    @Published var directReplacementRunning = false
    var cancelDirectReplacement: (() -> Void)?
    @Published var source = ""
    @Published var result = ""
    @Published var method = ""
    @Published var target = "zh-Hans"
    @Published var phase: CardPhase = .choose
    @Published var pinned = false
    @Published var copied = false
    @Published var sourceExpanded = false
    @Published var status = "准备就绪"
    @Published var manualText = "Good design makes complex things feel simple."
    @Published private(set) var replacementRecovery: ReplacementRecovery?
    var recoveryPasteboard: NSPasteboard = .general
    private var retryAllowed = false
    private var recoveryOperationID = UUID()
    @Published private(set) var isReplacing = false
    @Published private(set) var isTranslationInFlight = false
    @Published private var replacementTransactions = 0
    var isReplacementInFlight: Bool { replacementTransactions > 0 }
    @Published private(set) var replacementMessage = ""
    @Published private var replacementTarget: ReplacementTarget?
    private var replacementTask: Task<Void, Never>?
    private var replacementID = UUID()
    var replacementPerformer: (ReplacementTarget, String, @escaping () -> Bool, @escaping () -> Void) async throws -> Bool = {
        destination, output, current, releaseFocus in
        try await TextReplacement.perform(destination, text: output, stillCurrent: current, releasePanelFocus: releaseFocus)
    }
    private let translator: any TranslationService
    private var translationTask: Task<Void, Never>?
    private var requestID = UUID()
    private var preparationReverse = false
    private var persistSettings = true
    var showCard: ((CGRect) -> Void)?
    var hideCard: (() -> Void)?
    var showWindow: (() -> Void)?
    var pointerInCard: (() -> Bool)?
    var stageHover: ((CapturedText, CGRect, CGPoint, Bool) -> Void)?
    var clearHover: (() -> Void)?
    var releasePanelFocus: (() -> Void)?
    var anchor = CGRect.zero
    private(set) var selectionVisible = false

    var hasReplacementTarget: Bool { selectionVisible && replacementTarget != nil }
    var showsReplacementControls: Bool { hasReplacementTarget || !replacementMessage.isEmpty }
    var canReplaceSelection: Bool {
        guard hasReplacementTarget, !isReplacing, phase == .result, target != "original",
              let replacementTarget, replacementTarget.attempt.isValid, !result.isEmpty else { return false }
        return result != replacementTarget.edit.selected
    }

    func replaceSelection() {
        guard canReplaceSelection, let destination = replacementTarget else { return }
        let output = result
        let original = source
        let outputLanguage = target
        let recoveryOperation = UUID()
        recoveryOperationID = recoveryOperation
        let id = UUID()
        replacementID = id
        isReplacing = true
        replacementTransactions += 1
        replacementMessage = ""
        replacementTask = Task { [weak self] in
            guard let self else { return }
            // Confirmation and clipboard restoration can outlive dismissal.
            // Keep update installation waiting until the transaction really ends.
            defer { replacementTransactions -= 1 }
            do {
                // Strictly validate the original selection; never reselect a stale span.
                let verified = try await replacementPerformer(destination, output,
                    { self.replacementID == id && destination.attempt.isValid },
                    { self.releasePanelFocus?() })
                guard !Task.isCancelled, replacementID == id else {
                    guard recoveryOperationID == recoveryOperation else { return }
                    status = verified ? "上一次替换已确认完成 · 可在原输入框按 ⌘Z 撤销" : "上一次替换结果无法确认，请检查原输入框；未重复粘贴。"
                    if !verified {
                        retainReplacementRecovery(ReplacementRecovery(source: original, translation: output,
                            targetLanguage: outputLanguage, message: status))
                    }
                    return
                }
                guard verified else {
                    replacementTarget = nil
                    isReplacing = false
                    replacementMessage = "无法确认替换结果，请检查输入框；未重复替换。"
                    retainReplacementRecovery(ReplacementRecovery(source: original, translation: output,
                        targetLanguage: outputLanguage, message: replacementMessage))
                    return
                }
                dismiss(force: true)
                status = "已替换选中文字 · 可在原输入框按 ⌘Z 撤销"
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled, replacementID == id else { return }
                replacementTarget = nil
                isReplacing = false
                replacementMessage = error.localizedDescription
                retainReplacementRecovery(ReplacementRecovery(source: original, translation: output,
                    targetLanguage: outputLanguage, message: replacementMessage))
            }
        }
    }

    /// Invalidate submission without discarding confirmation of a paste that may
    /// already have been sent. The shared gate is also visible to the AX queue.
    func invalidatePendingReplacement() {
        guard isReplacing else { return }
        replacementTarget?.attempt.invalidate()
    }

    private func clearReplacement() {
        replacementTarget?.attempt.invalidate()
        replacementTask?.cancel()
        replacementTask = nil
        replacementID = UUID()
        replacementTarget = nil
        isReplacing = false
        replacementMessage = ""
    }

    init(checkPermissions: Bool = true, translator: (any TranslationService)? = nil) {
        updates = AppUpdater(enabled: checkPermissions)
        self.translator = translator ?? LocalTranslator()
        persistSettings = checkPermissions
        let d = UserDefaults.standard
        if let value = d.string(forKey: "directShortcut"), let shortcut = DirectReplacementShortcut(rawValue: value) { directShortcut = shortcut }
        if let value = d.string(forKey: "directTargetLanguage"), ["auto", "en", "zh-Hans"].contains(value) { directTargetLanguage = value }
        if d.object(forKey: "hoverDelay") != nil { delay = min(1.5, max(0.3, d.double(forKey: "hoverDelay"))) }
        if d.object(forKey: "closeDelay") != nil { closeDelay = min(1, max(0, d.double(forKey: "closeDelay"))) }
        if d.object(forKey: "hoverEnabled") != nil { hoverEnabled = d.bool(forKey: "hoverEnabled") }
        if d.object(forKey: "selectionEnabled") != nil { selectionEnabled = d.bool(forKey: "selectionEnabled") }
        if d.object(forKey: "ocrEnabled") != nil { ocrEnabled = d.bool(forKey: "ocrEnabled") }
        wordMode = d.bool(forKey: "wordMode")
        if checkPermissions {
            enabled = d.bool(forKey: "globalEnabled")
            refreshPermissions()
            if enabled { updatePermissionStatus() }
        }
        if checkPermissions { Task { await refreshLanguage() } }
    }

    func refreshPermissions() {
        applyPermissions(accessibility: AXIsProcessTrusted(), screen: CGPreflightScreenCaptureAccess())
    }

    func recheckPermissions() {
        refreshPermissions()
        status = accessibility ? "系统取词权限已生效" : "当前版本的取词权限尚未生效 · 请确认添加的是当前Wordglide应用"
    }

    @Published var layoutVisibleFrame: CGRect?
    private var cardMetrics: CardLayout.Metrics {
        let visible = layoutVisibleFrame ?? ScreenGeometry.resolveCurrent(anchor: anchor)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 900, height: 900)
        return CardLayout.metrics(source: source, result: phase == .result || phase == .failure ? result : "",
                                  showsSource: showsCardSource, loading: phase == .loading, choosing: phase == .choose,
                                  failure: phase == .failure, hasMessage: !replacementMessage.isEmpty, visibleFrame: visible)
    }
    var cardWidth: CGFloat { cardMetrics.width }
    var showsCardSource: Bool { sourceExpanded && target != "original" && !source.isEmpty }
    var sourceBodyHeight: CGFloat { cardMetrics.sourceHeight }
    var cardBodyHeight: CGFloat { cardMetrics.bodyHeight }
    var cardHeight: CGFloat { cardMetrics.height }

    func toggleSourceExpanded() { sourceExpanded.toggle() }

    func applyPermissions(accessibility trusted: Bool, screen allowed: Bool) {
        let changed = accessibility != trusted || screenPermission != allowed
        // Equal @Published assignments still invalidate SwiftUI layout.
        if accessibility != trusted { accessibility = trusted }
        if screenPermission != allowed { screenPermission = allowed }
        if enabled, changed { updatePermissionStatus() }
    }

    func refreshLanguage() async {
        let availability = TranslationRuntime.availability()
        let forward = await availability.status(from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "zh-Hans"))
        let reverse = await availability.status(from: Locale.Language(identifier: "zh-Hans"), to: Locale.Language(identifier: "en"))
        languageReady = forward == .installed && reverse == .installed
        languageStatus = languageReady ? "已就绪 · 离线可用" : (forward == .unsupported || reverse == .unsupported ? "当前系统不支持" : "需要准备语言包")
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openPrivacy("Accessibility")
    }

    func requestScreen() {
        page = "settings"
        _ = CGRequestScreenCaptureAccess()
        openPrivacy("ScreenCapture")
    }

    var applicationPath: String { Bundle.main.bundleURL.path }

    func revealApplication() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    func copyApplicationPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(applicationPath, forType: .string)
        status = "已复制Wordglide应用路径 · 在添加窗口按 ⇧⌘G 后粘贴"
    }

    func openPrivacy(_ section: String) {
        let current = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_" + section
        if let url = URL(string: current), NSWorkspace.shared.open(url) { return }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_" + section) { NSWorkspace.shared.open(url) }
    }

    func prepareLanguage() {
        preparing = true
        preparationMessage = "请在系统弹窗中确认下载；准备期间保持此窗口打开。"
        preparationReverse = false
        let config = TranslationRuntime.configuration()
        if preparationConfig == config { preparationConfig?.invalidate() } else { preparationConfig = config }
    }

    func languagePreparationFinished(error: Error? = nil) async {
        if let error {
            preparationMessage = "准备失败：" + error.localizedDescription
            preparing = false
            await refreshLanguage()
            return
        }
        if !preparationReverse {
            preparationReverse = true
            preparationMessage = "正在确认中文 → 英文语言包…"
            preparationConfig = TranslationRuntime.configuration(source: "zh-Hans", target: "en")
            return
        }
        await refreshLanguage()
        preparationMessage = languageReady ? "中英文语言包已就绪，可以开始翻译。" : "语言包仍未就绪，请重试。"
        preparing = false
    }

    func toggleEnabled() {
        enabled.toggle()
        if persistSettings { UserDefaults.standard.set(enabled, forKey: "globalEnabled") }
        if !enabled { dismiss(force: true) }
        refreshPermissions()
        updatePermissionStatus()
        if enabled && !accessibility { settings() }
    }

    private func updatePermissionStatus() {
        if !enabled { status = "全局翻译已暂停" }
        else if !accessibility { status = "请在隐私权限页开启“Wordglide”（设备控制与数据访问 / 辅助功能）" }
        else if ocrEnabled && !screenPermission { status = "覆盖范围受限 · 系统选项和图片需要识图授权，请打开偏好设置" }
        else { status = "等待英文悬停 · 移到“译”图标查看译文" }
    }

    func present(_ capture: CapturedText, cocoaAnchor: CGRect, selection: Bool, replacement: ReplacementTarget? = nil) {
        guard !pinned else { return }
        beginRecoveryOperation()
        clearReplacement()
        if selection { clearHover?() }
        selectionVisible = selection
        replacementTarget = selection ? replacement : nil
        translationTask?.cancel()
        requestID = UUID()
        sourceExpanded = false
        source = capture.text
        method = capture.method
        anchor = cocoaAnchor
        result = ""
        copied = false
        pinned = false
        let automaticTarget = TextLogic.language(of: source) == "zh-Hans" ? "en" : "zh-Hans"
        phase = .loading
        target = automaticTarget
        let presentationID = requestID
        showCard?(anchor)
        guard requestID == presentationID else { return }
        translate(to: automaticTarget)
    }

    func translate(to language: String) {
        guard !isReplacing else { return }
        translationTask?.cancel()
        let id = UUID()
        requestID = id
        isTranslationInFlight = false
        target = language
        copied = false
        retryAllowed = false
        if language == "original" { result = source; phase = .result; return }
        let input = source
        let recoveryOperation = recoveryOperationID
        let recoveryToResolve = replacementRecovery.flatMap { recovery in
            !recovery.hasTranslation && recovery.source == input && recovery.targetLanguage == language ? recovery.id : nil
        }
        result = ""
        phase = .loading
        isTranslationInFlight = true
        translationTask = Task { [weak self] in
            guard let self else { return }
            defer { if requestID == id { isTranslationInFlight = false } }
            do {
                try Task.checkCancellation()
                let output = try await translator.translate(input, target: language)
                guard !Task.isCancelled, requestID == id else { return }
                result = output; phase = .result; status = "翻译完成"
                if let recoveryToResolve, replacementRecovery?.id == recoveryToResolve {
                    retainReplacementRecovery(ReplacementRecovery(source: input, translation: output,
                        targetLanguage: language, message: "重新翻译已完成，可复制译文；尚未替换原输入框。"))
                }
            } catch is CancellationError {
                // Pointer movement and language changes intentionally cancel old requests.
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
                result = error.localizedDescription; phase = .failure; status = "翻译未完成"
                retryAllowed = (error as? TranslationIssue).map {
                    switch $0 {
                    case .languagePack, .tooLong, .unsupported: return false
                    default: return true
                    }
                } ?? true
                if case TranslationIssue.timedOut = error, recoveryOperationID == recoveryOperation {
                    retainReplacementRecovery(ReplacementRecovery(source: input, translation: nil,
                        targetLanguage: language, message: error.localizedDescription))
                }
            }
        }
    }

    func dismiss(force: Bool = false) {
        guard force || !pinned else { return }
        clearReplacement()
        selectionVisible = false
        translationTask?.cancel()
        requestID = UUID()
        isTranslationInFlight = false
        retryAllowed = false
        pinned = false
        hideCard?()
        clearHover?()
    }

    var canRetryTranslation: Bool {
        phase == .failure && retryAllowed && !source.isEmpty && ["en", "zh-Hans"].contains(target)
    }

    func retryTranslation() {
        guard canRetryTranslation else { return }
        // A retry is a fresh translation only. Any captured edit target may now
        // be stale and must never become available for a later replacement.
        clearReplacement()
        translate(to: target)
    }

    func cancelTranslation() {
        guard phase == .loading else { return }
        translationTask?.cancel()
        translationTask = nil
        requestID = UUID()
        isTranslationInFlight = false
        result = "已取消翻译，可以重试。"
        phase = .failure
        status = "已取消翻译"
        retryAllowed = true
        clearReplacement()
    }

    func retainReplacementRecovery(_ recovery: ReplacementRecovery) {
        recoveryOperationID = UUID()
        replacementRecovery = recovery
    }

    @discardableResult
    func beginRecoveryOperation() -> UUID {
        recoveryOperationID = UUID()
        return recoveryOperationID
    }

    func dismissReplacementRecovery() {
        beginRecoveryOperation()
        replacementRecovery = nil
    }

    func copyRecoveredTranslation() {
        guard let text = replacementRecovery?.translation else { return }
        recoveryPasteboard.clearContents()
        if recoveryPasteboard.setString(text, forType: .string) {
            status = "已复制保留的译文"
        } else {
            status = "复制未完成，请重试或在浮窗中选中译文复制。"
        }
    }

    func showRecoveredTranslation() {
        guard let recovery = replacementRecovery, let output = recovery.translation else { return }
        beginRecoveryOperation()
        dismiss(force: true)
        source = recovery.source
        result = output
        target = recovery.targetLanguage
        method = "本次保留的译文"
        selectionVisible = true
        sourceExpanded = false
        copied = false
        phase = .result
        anchor = ScreenGeometry.pointerAnchor(NSEvent.mouseLocation)
        showCard?(anchor)
    }

    func retryRecoveredTranslation() {
        guard let recovery = replacementRecovery, !recovery.hasTranslation else { return }
        beginRecoveryOperation()
        dismiss(force: true)
        source = recovery.source
        target = recovery.targetLanguage
        method = "重新翻译 · 仅查看与复制"
        selectionVisible = true
        sourceExpanded = false
        copied = false
        phase = .loading
        result = ""
        anchor = ScreenGeometry.pointerAnchor(NSEvent.mouseLocation)
        let presentationID = requestID
        showCard?(anchor)
        guard requestID == presentationID else { return }
        translate(to: recovery.targetLanguage)
    }

    func copyResult() {
        let text = phase == .result ? result : source
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
    }

    func clipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !TextLogic.clean(text).isEmpty else {
            status = "剪贴板中没有文字"; showWindow?(); return
        }
        guard text.count <= TextLogic.maximumInputLength else {
            status = TranslationIssue.tooLong.localizedDescription
            showWindow?()
            return
        }
        let mouse = NSEvent.mouseLocation
        dismiss(force: true)
        present(CapturedText(text: TextLogic.clean(text), bounds: .zero, method: "剪贴板 · 手动触发"),
                cocoaAnchor: ScreenGeometry.pointerAnchor(mouse), selection: true)
    }

    func manualTranslate() {
        let text = TextLogic.clean(manualText)
        guard !text.isEmpty else { return }
        guard text.count <= TextLogic.maximumInputLength else {
            status = TranslationIssue.tooLong.localizedDescription
            return
        }
        let rect = NSApp.keyWindow.map { CGRect(x: $0.frame.midX - 200, y: $0.frame.midY + 80, width: 400, height: 30) }
            ?? ScreenGeometry.pointerAnchor(NSEvent.mouseLocation, size: CGSize(width: 20, height: 20))
        dismiss(force: true)
        present(CapturedText(text: text, bounds: .zero, method: "文字试用 · 本机翻译"), cocoaAnchor: rect, selection: true)
    }

    func settings() { page = "settings"; showWindow?() }

    func preview(_ english: String, bounds: CGRect) {
        guard !pinned else { return }
        dismiss(force: true)
        stageHover?(CapturedText(text: english, bounds: .zero, method: "本机翻译 · 交互试用"), bounds, NSEvent.mouseLocation, true)
    }
}
