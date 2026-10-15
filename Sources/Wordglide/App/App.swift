// Portions derived from HoverTranslate, Copyright (c) 2026 Kianzzz (MIT).
// See ThirdParty/HoverTranslate-LICENSE.
import AppKit
import SwiftUI
import Combine
import Carbon
import Translation
import ImageIO
import ApplicationServices

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class HoverBadgePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    let model = AppModel()
    let directReplacement = DirectReplacementCoordinator(translator: LocalTranslator())
    let directFeedback = DirectReplacementFeedback()
    var directStatusPanel: HoverBadgePanel?
    var directHotKey: EventHotKeyRef?
    var directHideTask: Task<Void, Never>?
    var directDestinationPID: pid_t?
    var directAnchor = CGRect.zero
    var window: NSWindow!
    var panel: FloatingPanel!
    var badge: HoverBadgePanel!
    var statusItem: NSStatusItem!
    var monitor: HoverMonitor!
    var subscriptions = Set<AnyCancellable>()
    var hotKey: EventHotKeyRef?
    var hotKeyHandler: EventHandlerRef?
    private var keepsCardFooter = false
    private var isApplyingCardGeometry = false
    private var cardLayoutScheduled = false
    private var screenLayoutSnapshot: [ScreenGeometry] = []
    private var updateTerminationTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if CommandLine.arguments.contains("--check-direct-replacement-flow") {
            Task { let result = await DirectReplacementIntegrationCheck.run(); exit(result) }
            return
        }
        if CommandLine.arguments.contains("--export-ui-previews") {
            Task { await UIPreviewExporter.run() }
            return
        }
        createPanel()
        createBadge()
        createStatusItem()
        monitor = HoverMonitor(model: model)
        monitor.visibleCardFrame = { [weak self] in
            guard let panel = self?.panel, panel.isVisible else { return nil }
            return panel.frame
        }
        monitor.showBadge = { [weak self] point, source in self?.showBadge(point, source: source) ?? .zero }
        monitor.hideBadge = { [weak self] in self?.badge.orderOut(nil) }
        monitor.start()
        model.showCard = { [weak self] anchor in
            self?.keepsCardFooter = false
            self?.showCard(anchor)
        }
        model.hideCard = { [weak self] in
            self?.keepsCardFooter = false
            self?.panel.orderOut(nil)
        }
        model.showWindow = { [weak self] in self?.showMain() }
        model.pointerInCard = { [weak self] in self?.panel.isVisible == true && self?.panel.frame.contains(NSEvent.mouseLocation) == true }
        model.stageHover = { [weak self] capture, rect, point, demo in self?.monitor.stage(capture, sourceRect: rect, pointer: point, demo: demo) }
        model.clearHover = { [weak self] in self?.monitor.clearCandidate() }
        model.releasePanelFocus = { [weak self] in self?.panel.resignKey() }
        model.$sourceExpanded.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.resizeCard(keepingFooter: true) }
        }.store(in: &subscriptions)
        model.$target.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.resizeCard() }
        }.store(in: &subscriptions)
        model.$replacementMessage.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.resizeCard() }
        }.store(in: &subscriptions)
        model.$phase.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.resizeCard() }
        }.store(in: &subscriptions)
        model.$result.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.resizeCard() }
        }.store(in: &subscriptions)
        model.$enabled.combineLatest(model.updates.$availableVersion).sink { [weak self] enabled, version in
            let description = version.map { "Wordglide · 发现新版本 \($0)" }
                ?? (enabled ? "Wordglide · 全局翻译已开启" : "Wordglide · 已暂停")
            self?.statusItem?.button?.toolTip = description
            if let image = NSImage(systemSymbolName: version == nil ? "character.bubble" : "arrow.down.circle",
                                   accessibilityDescription: description) {
                image.isTemplate = true
                self?.statusItem?.button?.image = image
            }
            self?.statusItem?.menu?.items.first(where: { $0.action == #selector(AppDelegate.toggle) })?.title = enabled ? "暂停全局翻译" : "开启全局翻译"
        }.store(in: &subscriptions)
        configureDirectReplacement()
        observeScreenChanges()
        registerShortcut()
        model.updates.shouldAllowUpdateInstallation = { [weak self] in
            self.map { !$0.hasWorkInFlight } ?? false
        }
        if !CommandLine.arguments.contains("--check-window-flow") { model.updates.start() }
        DispatchQueue.main.async { self.showMain() }
        if CommandLine.arguments.contains("--check-window-flow") { runWindowCheck() }
    }

    func attachWindow(_ newWindow: NSWindow) {
        guard window !== newWindow else { return }
        window = newWindow
        window.title = "Wordglide"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 660, height: 520)
        window.delegate = self
        window.center()
    }

    func createPanel() {
        panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: CardLayout.minimumWidth, height: 84),
                              styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.title = "Wordglide · 翻译浮窗"
        panel.setAccessibilityRole(.window)
        panel.setAccessibilityLabel("翻译浮窗")
        panel.acceptsMouseMovedEvents = true
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 2)
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = fixedHostingView(TranslationCard(model: model), size: panel.frame.size, cornerRadius: 16)
    }

    func createBadge() {
        badge = HoverBadgePanel(contentRect: CGRect(x: 0, y: 0, width: 30, height: 30),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        badge.title = "Wordglide · 悬停图标"
        badge.setAccessibilityRole(.window)
        badge.setAccessibilityLabel("悬停翻译图标")
        badge.isOpaque = false
        badge.backgroundColor = .clear
        badge.hasShadow = true
        badge.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 1)
        badge.hidesOnDeactivate = false
        badge.isReleasedWhenClosed = false
        badge.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        badge.contentView = fixedHostingView(HoverBadgeView(), size: badge.frame.size)
    }

    // AppKit owns panel geometry; asynchronous SwiftUI measurement must not
    // resize the NSWindow as translation content changes.
    private func fixedHostingView<Content: View>(_ content: Content, size: CGSize, cornerRadius: CGFloat = 0) -> NSView {
        let container = TransparentPanelContainer(frame: CGRect(origin: .zero, size: size), cornerRadius: cornerRadius)
        let hosting = TransparentPanelHostingView(rootView: content)
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        hosting.layer?.isOpaque = false
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        return container
    }

    func showBadge(_ point: CGPoint, source: CGRect = .zero) -> CGRect {
        guard let screen = ScreenGeometry.resolveCurrent(point: point, anchor: source),
              screen.visibleFrame.width >= 42, screen.visibleFrame.height >= 42 else {
            badge.orderOut(nil)
            return .zero
        }
        let rect = TextLogic.badgeFrame(pointer: point, visible: screen.visibleFrame, source: source)
        badge.setFrame(rect, display: true)
        badge.orderFrontRegardless()
        return badge.frame
    }

    func showCard(_ anchor: CGRect) {
        guard let screen = ScreenGeometry.resolveCurrent(anchor: anchor) else {
            model.dismiss(force: true)
            return
        }
        guard prepareCardLayout(on: screen) else { return }
        let frame = TextLogic.panelFrame(anchor: anchor, size: CGSize(width: model.cardWidth, height: model.cardHeight), visible: screen.visibleFrame)
        applyCardFrame(frame)
        panel.orderFrontRegardless()
        if model.method == "文字试用 · 本机翻译" { panel.makeKeyAndOrderFront(nil) }
    }

    func resizeCard(keepingFooter: Bool = false) {
        guard panel.isVisible, !isApplyingCardGeometry else { return }
        let old = panel.frame
        guard let screen = ScreenGeometry.resolveCurrent(anchor: old) else {
            model.dismiss(force: true)
            return
        }
        // The destination display supplies both the SwiftUI content budget and
        // the NSPanel frame. The original text anchor may be on another display
        // after a user has dragged a pinned card.
        guard prepareCardLayout(on: screen) else { return }
        let size = CGSize(width: model.cardWidth, height: model.cardHeight)
        // Keep the source-toggle button under the pointer as its section opens
        // or closes. Otherwise a hover card could shrink away from that click.
        if keepingFooter, panel.frame.contains(NSEvent.mouseLocation) { keepsCardFooter = true }
        if keepsCardFooter {
            applyCardFrame(ScreenGeometry.constrainedFrame(CGRect(origin: old.origin, size: size), visible: screen.visibleFrame))
            return
        }
        if model.selectionVisible {
            let safe = ScreenGeometry.safeFrame(visible: screen.visibleFrame)
            let below = old.maxY <= model.anchor.minY
            let y = below ? old.maxY - model.cardHeight : old.minY
            let x = min(max(old.minX, safe.minX), safe.maxX - model.cardWidth)
            let frame = CGRect(x: x, y: y, width: model.cardWidth, height: model.cardHeight)
            if safe.contains(frame), !frame.intersects(model.anchor) {
                applyCardFrame(frame)
                return
            }
        }
        applyCardFrame(TextLogic.panelFrame(anchor: model.anchor, size: size, visible: screen.visibleFrame))
    }

    private func prepareCardLayout(on screen: ScreenGeometry) -> Bool {
        if model.layoutVisibleFrame != screen.visibleFrame { model.layoutVisibleFrame = screen.visibleFrame }
        guard CardLayout.canPresent(in: screen.visibleFrame) else {
            model.status = "当前屏幕可用空间不足，请调整显示缩放后重试。"
            model.dismiss(force: true)
            return false
        }
        return true
    }

    private func applyCardFrame(_ frame: CGRect) {
        guard panel.frame != frame else { return }
        isApplyingCardGeometry = true
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
        isApplyingCardGeometry = false
    }

    private func observeScreenChanges() {
        screenLayoutSnapshot = ScreenGeometry.current
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                // AppKit posts display changes on the main thread. Invalidate
                // old capture revisions before an awaiting request can resume.
                MainActor.assumeIsolated { self?.screenParametersDidChange() }
            }.store(in: &subscriptions)
    }

    private func screenParametersDidChange() {
        let current = ScreenGeometry.current
        // HDR capability also posts this notification. It does not invalidate
        // coordinates, so only actual geometry/scale changes cancel requests.
        guard current != screenLayoutSnapshot else { return }
        screenLayoutSnapshot = current
        directAnchor = .zero
        directReplacement.cancel()
        monitor.screenParametersDidChange()
        badge.orderOut(nil)
        model.layoutVisibleFrame = nil
        if panel.isVisible {
            keepsCardFooter = true
            resizeCard()
        }
        if directStatusPanel?.isVisible == true { showDirectFeedback() }
    }

    private func scheduleMovedCardLayout(_ notification: Notification) {
        guard let moved = notification.object as? NSWindow, moved === panel,
              panel.isVisible, !isApplyingCardGeometry else { return }
        // User movement establishes a new location; later translation results
        // must not jump back to the display containing the original anchor.
        keepsCardFooter = true
        guard !cardLayoutScheduled else { return }
        cardLayoutScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.cardLayoutScheduled = false
            self.resizeCard()
        }
    }

    func windowDidMove(_ notification: Notification) { scheduleMovedCardLayout(notification) }
    func windowDidChangeScreen(_ notification: Notification) { scheduleMovedCardLayout(notification) }
    func windowDidChangeBackingProperties(_ notification: Notification) { scheduleMovedCardLayout(notification) }

    func showMain() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "character.bubble", accessibilityDescription: "Wordglide") {
            image.isTemplate = true; statusItem.button?.image = image
        }
        statusItem.button?.toolTip = "Wordglide · 已暂停"
        let menu = NSMenu()
        menu.addItem(item("打开 Wordglide", #selector(openMain), ""))
        menu.addItem(.separator())
        menu.addItem(item("开启 / 暂停全局翻译", #selector(toggle), ""))
        menu.addItem(item("翻译选中文字  ⌃⌥T", #selector(selection), ""))
        menu.addItem(item("直接翻译并替换  " + model.directShortcut.symbols, #selector(directReplace), ""))
        menu.addItem(item("翻译剪贴板", #selector(clipboard), ""))
        menu.addItem(item("偏好设置…", #selector(settings), ","))
        menu.addItem(item("检查更新…", #selector(checkForUpdates), ""))
        menu.addItem(.separator())
        menu.addItem(item("退出 Wordglide", #selector(quit), "q"))
        statusItem.menu = menu
    }

    func createMainMenu() {
        let main = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Wordglide")
        applicationMenu.addItem(item("打开 Wordglide", #selector(openMain), ""))
        applicationMenu.addItem(item("偏好设置…", #selector(settings), ","))
        applicationMenu.addItem(item("检查更新…", #selector(checkForUpdates), ""))
        applicationMenu.addItem(.separator())
        let hide = NSMenuItem(title: "隐藏Wordglide", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.target = NSApp
        applicationMenu.addItem(hide)
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(item("退出 Wordglide", #selector(quit), "q"))
        applicationItem.submenu = applicationMenu
        main.addItem(applicationItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        for (title, selector, key) in [("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key))
        }
        editItem.submenu = edit
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self; return item
    }

    func registerShortcut() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let handlerResult = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData -> OSStatus in
            guard let userData, let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                    MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr else { return OSStatus(eventNotHandledErr) }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            let keyID = id.id
            let triggerPID = MainActor.assumeIsolated { NSWorkspace.shared.frontmostApplication?.processIdentifier }
            Task { @MainActor in
                switch keyID {
                case 1: delegate.monitor.readSelection()
                case 2: delegate.beginDirectReplacement(expectedPID: triggerPID)
                default: break
                }
            }
            return noErr
        }, 1, &event, pointer, &hotKeyHandler)
        guard handlerResult == noErr else {
            model.directShortcutIssue = "无法注册全局快捷键，请退出并重新打开 Wordglide。"
            return
        }
        let id = EventHotKeyID(signature: OSType(0x57474C44), id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
        if result != noErr { model.status = "⌃⌥T 快捷键被占用；仍可使用鼠标选区和菜单栏。" }
        registerDirectShortcut()
    }

    func registerDirectShortcut() {
        if let directHotKey { UnregisterEventHotKey(directHotKey) }
        directHotKey = nil
        let shortcut = model.directShortcut
        let id = EventHotKeyID(signature: OSType(0x57474C44), id: 2)
        let result = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), 0, &directHotKey)
        model.directShortcutIssue = result == noErr ? "" : "\(shortcut.displayName) 已被占用或无法注册，请选择其他快捷键。"
        statusItem?.menu?.items.first(where: { $0.action == #selector(AppDelegate.directReplace) })?.title = "直接翻译并替换  " + shortcut.symbols
    }

    @objc func directReplace() {
        beginDirectReplacement(expectedPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
    }

    func beginDirectReplacement(expectedPID: pid_t?) {
        guard !model.isReplacing, !directReplacement.isRunning else { return }
        directAnchor = .zero
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            directFeedback.update("请先点选其他应用中的输入框，再按快捷键。", running: false, warning: true)
            showDirectFeedback()
            scheduleDirectFeedbackDismissal()
            return
        }
        guard front.processIdentifier == expectedPID else {
            model.status = "前台应用已变化，已取消快捷替换。"
            return
        }
        model.refreshPermissions()
        guard model.accessibility else {
            directFeedback.update("请先在 Wordglide 设置中授权辅助功能。", running: false, warning: true)
            model.status = directFeedback.message
            showDirectFeedback()
            scheduleDirectFeedbackDismissal()
            return
        }
        monitor.cancelPendingRequests()
        model.beginRecoveryOperation()
        model.dismiss(force: true)
        directDestinationPID = front.processIdentifier
        directAnchor = ScreenGeometry.pointerAnchor(NSEvent.mouseLocation)
        directReplacement.start(pid: front.processIdentifier, targetLanguage: model.directTargetLanguage)
    }

    @objc func openMain() { showMain() }
    @objc func toggle() { model.toggleEnabled() }
    @objc func selection() { monitor.readSelection() }
    @objc func clipboard() { model.clipboard() }
    @objc func settings() { model.settings() }
    @objc func checkForUpdates() { model.updates.checkForUpdates() }
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(checkForUpdates) else { return true }
        menuItem.title = model.updates.availableVersion.map { "发现新版本 \($0) · 检查更新…" } ?? "检查更新…"
        return model.updates.canCheckForUpdates
    }
    private var hasWorkInFlight: Bool {
        model.isTranslationInFlight || model.isReplacementInFlight || directReplacement.isRunning || model.preparing
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.updates.installationPending, hasWorkInFlight else { return .terminateNow }
        // Sparkle can also install on quit. Finish any posted paste and restore
        // its clipboard before permitting the application's process to exit.
        updateTerminationTimer?.invalidate()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, !self.hasWorkInFlight else { return }
                timer.invalidate()
                self.updateTerminationTimer = nil
                sender.reply(toApplicationShouldTerminate: true)
            }
        }
        updateTerminationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        return .terminateLater
    }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationDidBecomeActive(_ notification: Notification) { model.refreshPermissions(); Task { await model.refreshLanguage() } }
    func applicationWillTerminate(_ notification: Notification) {
        updateTerminationTimer?.invalidate()
        monitor?.stop()
        directReplacement.cancel()
        directHideTask?.cancel()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let directHotKey { UnregisterEventHotKey(directHotKey) }
        if let hotKeyHandler { RemoveEventHandler(hotKeyHandler) }
    }
    func windowWillClose(_ notification: Notification) {
        model.dismiss(force: true)
    }
}

@main
struct Entry {
    @MainActor static func main() {
        if DirectReplacementIntegrationCheck.runFixtureIfRequested() { return }
        let args = CommandLine.arguments
        if args.contains("--self-test") {
            Task { @MainActor in await CoreChecks.run() }
            dispatchMain()
        }
        if args.count == 5, ["--check-image", "--check-word-image"].contains(args[1]), let x = Double(args[3]), let y = Double(args[4]) {
            Task { @MainActor in
                guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: args[2]) as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { print("Cannot read image"); exit(1) }
                do {
                    let region = CGRect(x: 0, y: 0, width: image.width, height: image.height)
                    let result = try await TextCapture.recognize(image: image, region: region, at: CGPoint(x: x, y: y), word: args[1] == "--check-word-image")
                    let data = try JSONSerialization.data(withJSONObject: ["text": result?.text as Any? ?? NSNull()], options: [.sortedKeys])
                    print(String(decoding: data, as: UTF8.self))
                    exit(0)
                } catch { print(error.localizedDescription); exit(1) }
            }
            dispatchMain()
        }
        if CommandLine.arguments.contains("--check-engine") {
            Task { @MainActor in
                let availability = TranslationRuntime.availability()
                let status = await availability.status(from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "zh-Hans"))
                print("English → Chinese language status: \(status)")
                if status == .installed {
                    do {
                        let engine = LocalTranslator()
                        print("English → Chinese: \(try await engine.translate("Good design makes complex things feel simple.", target: "zh-Hans"))")
                        print("Chinese → English: \(try await engine.translate("保持好奇，总有更多值得发现。", target: "en"))")
                    } catch { print("Translation failed: \(error.localizedDescription)"); exit(1) }
                }
                exit(0)
            }
            dispatchMain()
        }
        NativeApp.main()
    }
}

@MainActor
struct NativeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("Wordglide") {
            MainView(model: delegate.model)
                .background(WindowBridge { delegate.attachWindow($0) })
        }
        .defaultSize(width: 720, height: 580)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appSettings) {
                Button("偏好设置…") { delegate.model.settings() }.keyboardShortcut(",")
            }
        }
    }
}

struct WindowBridge: NSViewRepresentable {
    let attach: (NSWindow) -> Void
    func makeNSView(context: Context) -> AttachedView {
        let view = AttachedView()
        view.attach = attach
        return view
    }
    func updateNSView(_ nsView: AttachedView, context: Context) { }
    final class AttachedView: NSView {
        var attach: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { [weak self] in self?.attach?(window) }
        }
    }
}
