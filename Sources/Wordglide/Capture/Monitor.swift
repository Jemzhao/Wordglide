// Adapted from Hover Translate, Copyright (c) 2026 Kianzzz.
// Distributed under the MIT License; see ThirdParty/HoverTranslate-LICENSE.
import AppKit
import Combine
import Carbon

@MainActor
final class HoverMonitor {
    struct Candidate {
        let capture: CapturedText
        let badgeRect: CGRect?
        let origin: CGPoint
        var previousPoint: CGPoint
        var approachUntil = Date.distantPast
        let demo: Bool
        let scope: HoverRecognitionScope
        var opened = false
        var enteredCard = false
        var opensDirectly: Bool { badgeRect == nil }
    }

    let model: AppModel
    var visibleCardFrame: (() -> CGRect?)?
    var showBadge: ((CGPoint, CGRect) -> CGRect)?
    var hideBadge: (() -> Void)?
    private var candidate: Candidate?
    private var outsideSince: Date?
    private var timer: Timer?
    private var permissionTimer: Timer?
    private var globalEvents: Any?
    private var localEvents: Any?
    private var menuObservers: [NSObjectProtocol] = []
    private var trackingMenus = Set<ObjectIdentifier>()
    private var menuReturnUntil = Date.distantPast
    private var subscriptions = Set<AnyCancellable>()
    private var started = false
    private var refreshScheduled = false
    private var lastPoint = CGPoint.zero
    private var stableSince = Date()
    private var attempted = false
    private var captureTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var selectionID = UUID()
    private var selectionIsAutomatic = false
    private var typingSession: (pid: pid_t, focus: Task<TextCapture.TypingFocus?, Never>)?
    private var typingTask: Task<Void, Never>?
    private var lastTypedText: String?
    private var activationObserver: NSObjectProtocol?
    private var previousEnabled = false
    private var revision = 0
    private var lastPermissionRefresh = Date.distantPast
    private var previousCaptureAccess = ""

    init(model: AppModel) { self.model = model }
    var desktopTop: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }
    // Read-only diagnostics let core checks verify pause without synthesizing
    // input events or requesting system permissions.
    var isPointerPolling: Bool { timer?.isValid == true }
    var hasGlobalEventMonitor: Bool { globalEvents != nil }
    var isPermissionPolling: Bool { permissionTimer?.isValid == true }
    var isMenuTracking: Bool { !trackingMenus.isEmpty }
    private var canHoverAutomatically: Bool { model.enabled && model.hoverEnabled && model.accessibility }
    private var canTranslateTyping: Bool { model.enabled && model.typingTranslationEnabled && model.accessibility }
    private var typingCardVisible: Bool { model.selectionVisible && model.method == TextCapture.typingMethod }

    func start() {
        guard !started else { return }
        started = true
        previousEnabled = model.enabled
        // @Published emits before its value changes. Reconcile on the next main
        // run-loop turn so a complete presentation/dismissal is visible here.
        model.objectWillChange.sink { [weak self] _ in
            self?.scheduleMonitoringRefresh()
        }.store(in: &subscriptions)
        observeMenus()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cancelTyping()
                if self.typingCardVisible { self.model.dismiss() }
            }
        }
        let permissions = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissionsIfNeeded() }
        }
        permissions.tolerance = 0.5
        permissionTimer = permissions
        RunLoop.main.add(permissions, forMode: .common)
        refreshMonitoring()
    }

    func stop() {
        started = false
        timer?.invalidate(); timer = nil
        permissionTimer?.invalidate(); permissionTimer = nil
        removeEventMonitors()
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        activationObserver = nil
        for observer in menuObservers { NotificationCenter.default.removeObserver(observer) }
        menuObservers.removeAll()
        trackingMenus.removeAll()
        menuReturnUntil = .distantPast
        subscriptions.removeAll()
        captureTask?.cancel(); captureTask = nil
        cancelSelection()
        cancelTyping()
        revision += 1
        clearCandidate()
    }

    private func scheduleMonitoringRefresh() {
        guard started, !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refreshMonitoring()
        }
    }

    /// Pausing removes both the 25 Hz pointer poll and global input monitors.
    /// An explicit manual card/demo temporarily opts into the input it needs.
    private func refreshMonitoring() {
        guard started else { return }
        if previousEnabled != model.enabled {
            previousEnabled = model.enabled
            resetMotion(at: NSEvent.mouseLocation)
            if !model.enabled {
                if selectionIsAutomatic { cancelSelection() }
                model.dismiss(force: true)
            }
        }
        let access = "\(model.accessibility):\(model.screenPermission):\(model.ocrEnabled):\(model.hoverEnabled):\(model.hoverRecognitionScope):\(model.showsTranslationOnHover)"
        if access != previousCaptureAccess {
            previousCaptureAccess = access
            resetMotion(at: NSEvent.mouseLocation)
            // A monitor installed before an Accessibility grant may not have
            // keyboard access. Reinstall once when capability/settings change.
            removeEventMonitors()
        }
        if let current = candidate, !current.demo,
           (!model.enabled || !model.hoverEnabled ||
            (!model.pinned && (!model.accessibility || !matchesHoverSettings(current)))) {
            model.dismiss(force: true)
        }
        if selectionIsAutomatic, (!model.enabled || !model.selectionEnabled) { cancelSelection() }
        if !canTranslateTyping || model.pinned || model.directReplacementRunning {
            cancelTyping()
            if !canTranslateTyping && typingCardVisible { model.dismiss() }
        }
        if model.pinned { hideBadge?() }
        let needsPointer = !model.directReplacementRunning && !isMenuTracking && !model.pinned && !model.selectionVisible &&
            selectionTask == nil && typingTask == nil &&
            (candidate != nil || canHoverAutomatically)
        if needsPointer, timer == nil {
            resetMotion(at: NSEvent.mouseLocation)
            let polling = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            polling.tolerance = 0.008
            timer = polling
            RunLoop.main.add(polling, forMode: .common)
        } else if !needsPointer, timer != nil {
            timer?.invalidate(); timer = nil
            captureTask?.cancel(); captureTask = nil
            revision += 1
        }
        let needsEvents = model.directReplacementRunning || canHoverAutomatically || canTranslateTyping ||
            (model.enabled && model.selectionEnabled && model.accessibility) ||
            candidate != nil || visibleCardFrame?() != nil || selectionTask != nil
        if needsEvents, globalEvents == nil, localEvents == nil { installEventMonitors() }
        else if !needsEvents { removeEventMonitors() }
    }

    private func installEventMonitors() {
        let mask: NSEvent.EventTypeMask = [.leftMouseUp, .leftMouseDown, .rightMouseDown, .scrollWheel, .keyDown]
        globalEvents = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            // AppKit invokes event monitors on the main thread. Handle before
            // the event's action, so a delayed dismissal cannot close a new
            // manual card opened by that same button click.
            MainActor.assumeIsolated { self?.handle(event, local: false) }
        }
        localEvents = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event, local: true) }
            return event
        }
    }

    private func removeEventMonitors() {
        if let globalEvents { NSEvent.removeMonitor(globalEvents) }
        if let localEvents { NSEvent.removeMonitor(localEvents) }
        globalEvents = nil
        localEvents = nil
    }

    private func observeMenus() {
        let center = NotificationCenter.default
        menuObservers.append(center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.started, self.visibleCardFrame?() != nil,
                      let menu = notification.object as? NSMenu else { return }
                self.trackingMenus.insert(ObjectIdentifier(menu))
                self.menuReturnUntil = .distantPast
                self.outsideSince = nil
                self.captureTask?.cancel()
                self.revision += 1
                self.scheduleMonitoringRefresh()
            }
        })
        menuObservers.append(center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, self.started, let menu = notification.object as? NSMenu,
                      self.trackingMenus.remove(ObjectIdentifier(menu)) != nil else { return }
                if self.trackingMenus.isEmpty {
                    // The chosen item can be outside the panel. Allow a brief
                    // return path even when automatic close is set to zero.
                    self.menuReturnUntil = Date().addingTimeInterval(0.4)
                    self.outsideSince = nil
                }
                self.scheduleMonitoringRefresh()
            }
        })
    }

    func handle(_ event: NSEvent, local: Bool) {
        if event.type == .keyDown, model.directShortcut.matches(event: event) { return }
        if model.isReplacing {
            if local, let frame = visibleCardFrame?(), event.window?.frame == frame { return }
            model.invalidatePendingReplacement()
            return
        }
        if model.directReplacementRunning {
            model.cancelDirectReplacement?()
            return
        }
        // NSMenu owns its popup windows, so their events do not have the
        // floating panel's frame. Let AppKit handle menu clicks, arrows and
        // Escape; real input in other processes still dismisses as before.
        if local, isMenuTracking { return }
        if local, event.type == .leftMouseUp, Date() < menuReturnUntil { return }
        if event.type == .keyDown {
            if event.keyCode == UInt16(kVK_Escape) {
                cancelSelection()
                cancelTyping()
                resetMotion(at: NSEvent.mouseLocation)
                model.dismiss(force: true)
                return
            }
            let modifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
            // Carbon owns this shortcut. Its handler may run before or after
            // this monitor, so never invalidate its newly started request.
            if event.keyCode == UInt16(kVK_ANSI_T), modifiers == [.control, .option] { return }
        }
        if local, let frame = visibleCardFrame?(), event.window?.frame == frame {
            return // Copy, tabs, text selection and scrolling remain usable.
        }
        if event.type != .keyDown, model.pointerInCard?() == true { return }
        if !local, event.type == .keyDown, canTranslateTyping, !model.pinned,
           Self.isTypingKey(event.keyCode, modifiers: event.modifierFlags, hasTypingSession: typingSession != nil) {
            cancelSelection()
            resetMotion(at: NSEvent.mouseLocation)
            model.dismiss()
            scheduleTypingTranslation()
            return
        }
        cancelTyping()
        if !local, model.enabled, model.selectionEnabled {
            if event.type == .leftMouseUp {
                readSelection(automatic: true)
                return
            }
            if Self.isSelectAll(event) {
                if !event.isARepeat { readSelection(automatic: true) }
                return
            }
        }
        cancelSelection()
        resetMotion(at: NSEvent.mouseLocation)
        model.dismiss()
    }

    static func isSelectAll(_ event: NSEvent) -> Bool {
        event.type == .keyDown
            && event.modifierFlags.intersection([.control, .option, .shift, .command]) == .command
            && event.charactersIgnoringModifiers?.lowercased() == "a"
    }

    static func isTypingKey(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags, hasTypingSession: Bool) -> Bool {
        guard modifiers.intersection([.command, .control, .function]).isEmpty else { return false }
        switch Int(keyCode) {
        // The two physical ANSI typing ranges are split by Return.
        case kVK_ANSI_A...kVK_ANSI_P, kVK_ANSI_L...kVK_ANSI_Period,
             kVK_Space, kVK_ANSI_Grave, kVK_Delete, kVK_ForwardDelete,
             kVK_ANSI_Keypad0...kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9, kVK_ANSI_KeypadDecimal:
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            return hasTypingSession
        default:
            return false
        }
    }

    private func cancelTyping() {
        typingTask?.cancel()
        typingTask = nil
        typingSession?.focus.cancel()
        typingSession = nil
        lastTypedText = nil
    }

    private func scheduleTypingTranslation() {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier, !IsSecureEventInputEnabled() else {
            cancelTyping()
            return
        }
        if typingSession?.pid != pid {
            cancelTyping()
            typingSession = (pid, Task { try? await TextCapture.focusForTyping(pid: pid) })
        }
        guard let focusTask = typingSession?.focus else { return }
        typingTask?.cancel()
        let screenLayout = ScreenGeometry.current
        typingTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if !Task.isCancelled {
                    self.typingTask = nil
                    self.scheduleMonitoringRefresh()
                }
            }
            guard let focus = await focusTask.value else {
                if !Task.isCancelled { self.typingSession = nil }
                return
            }
            do {
                let capture = try await Self.stableTypedText { try await TextCapture.typedText(in: focus) }
                guard self.canTranslateTyping, !self.model.pinned, !self.isMenuTracking,
                      !self.model.directReplacementRunning, self.selectionTask == nil,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      !IsSecureEventInputEnabled(), ScreenGeometry.current == screenLayout else { return }
                guard let capture else {
                    self.lastTypedText = nil
                    return
                }
                guard self.lastTypedText != capture.text else { return }
                self.lastTypedText = capture.text
                let anchor = capture.bounds.isNull
                    ? ScreenGeometry.pointerAnchor(NSEvent.mouseLocation)
                    : TextLogic.cocoaRect(capture.bounds, desktopTop: screenLayout.first?.frame.maxY ?? 0)
                self.model.present(capture, cocoaAnchor: anchor, selection: true)
            } catch ReplacementError.changed {
                if !Task.isCancelled { self.typingSession = nil; self.lastTypedText = nil }
            } catch { }
        }
        scheduleMonitoringRefresh()
    }

    static func stableTypedText(
        delay: Duration = .milliseconds(650), confirmationDelay: Duration = .milliseconds(150),
        read: () async throws -> CapturedText?
    ) async throws -> CapturedText? {
        try await Task.sleep(for: delay)
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        func readAfterComposition() async throws -> CapturedText? {
            while true {
                try Task.checkCancellation()
                do { return try await read() }
                catch ReplacementError.composing {
                    // Some input methods consume the key that confirms a candidate.
                    guard ContinuousClock.now < deadline else { return nil }
                    try await Task.sleep(for: confirmationDelay)
                }
            }
        }
        let first = try await readAfterComposition()
        guard let first else { return nil }
        try await Task.sleep(for: confirmationDelay)
        let latest = try await readAfterComposition()
        try Task.checkCancellation()
        guard latest?.text == first.text else { return nil }
        return latest
    }

    private func cancelSelection() {
        selectionTask?.cancel()
        selectionTask = nil
        selectionID = UUID()
        selectionIsAutomatic = false
        scheduleMonitoringRefresh()
    }

    private func refreshPermissionsIfNeeded() {
        // No pointer sampling and no repeated TCC queries while another app
        // (including System Settings) is active.
        guard NSApp.isActive, Date().timeIntervalSince(lastPermissionRefresh) >= 2 else { return }
        lastPermissionRefresh = Date()
        model.refreshPermissions()
        refreshMonitoring()
    }

    func cancelPendingRequests() {
        cancelSelection()
        cancelTyping()
        resetMotion(at: NSEvent.mouseLocation)
        clearCandidate()
    }

    func screenParametersDidChange() {
        // resetMotion increments the capture revision; cancelSelection changes
        // its request ID. Even services that finish after cancellation cannot
        // publish geometry from the previous desktop coordinate system.
        model.invalidatePendingReplacement()
        cancelPendingRequests()
        if !model.pinned && !model.selectionVisible { model.dismiss(force: true) }
        scheduleMonitoringRefresh()
    }

    func clearCandidate() {
        if candidate?.opensDirectly == true {
            // A dismissed card should stay closed until the pointer moves again.
            lastPoint = NSEvent.mouseLocation
            attempted = true
        }
        candidate = nil
        outsideSince = nil
        menuReturnUntil = .distantPast
        hideBadge?()
        scheduleMonitoringRefresh()
    }

    func stage(_ capture: CapturedText, sourceRect: CGRect, pointer: CGPoint, demo: Bool = false) {
        guard !model.pinned else { return }
        let opensDirectly = model.showsTranslationOnHover
        let badgeRect: CGRect?
        if opensDirectly {
            hideBadge?()
            badgeRect = nil
        } else {
            guard let rect = showBadge?(pointer, sourceRect), !rect.isEmpty else { return }
            badgeRect = rect
        }
        candidate = Candidate(capture: capture, badgeRect: badgeRect, origin: pointer, previousPoint: pointer,
                              demo: demo, scope: model.hoverRecognitionScope, opened: opensDirectly)
        outsideSince = nil
        if opensDirectly {
            model.present(capture, cocoaAnchor: ScreenGeometry.pointerAnchor(pointer), selection: false)
        } else {
            model.status = "已发现英文 · 将鼠标移到“译”图标查看译文"
        }
        scheduleMonitoringRefresh()
    }

    private func matchesHoverSettings(_ candidate: Candidate) -> Bool {
        candidate.scope == model.hoverRecognitionScope && candidate.opensDirectly == model.showsTranslationOnHover
    }

    private func resetMotion(at point: CGPoint) {
        captureTask?.cancel()
        revision += 1
        lastPoint = point
        stableSince = Date()
        attempted = false
    }

    /// Returns true while a source, its icon, the path to it, or its result is in use.
    func retainCandidate(at point: CGPoint, now: Date = Date()) -> Bool {
        guard var current = candidate else { return false }
        if model.pinned { hideBadge?(); return true }
        if !current.demo && (!canHoverAutomatically || !matchesHoverSettings(current)) {
            model.dismiss(force: true)
            resetMotion(at: point)
            return false
        }
        if current.opened, visibleCardFrame?() != nil, isMenuTracking || now < menuReturnUntil {
            outsideSince = nil
            return true
        }
        if current.opened, let frame = visibleCardFrame?(), frame.contains(point) {
            current.enteredCard = true
            candidate = current
            outsideSince = nil
            return true
        }
        if !current.enteredCard, let badgeRect = current.badgeRect, badgeRect.contains(point) {
            outsideSince = nil
            if !current.opened {
                current.opened = true
                candidate = current
                model.present(current.capture, cocoaAnchor: badgeRect, selection: false)
            }
            return true
        }
        var towardBadge = false
        if !current.opened, let badgeRect = current.badgeRect {
            let movement = hypot(point.x - current.previousPoint.x, point.y - current.previousPoint.y)
            let toward = TextLogic.movingTowardBadge(from: current.previousPoint, to: point, badge: badgeRect)
            if movement >= 0.5 {
                current.previousPoint = point
                current.approachUntil = toward ? now.addingTimeInterval(0.2) : .distantPast
            }
            towardBadge = toward || now < current.approachUntil
        }
        candidate = current
        // Keep a direct card open while the pointer rests on the original hit.
        // The captured source rectangle may cover an entire paragraph.
        let beforeEnteringCard = !current.opened || (current.opensDirectly && !current.enteredCard)
        let inSource = beforeEnteringCard && hypot(point.x - current.origin.x, point.y - current.origin.y) <= 4
        let towardCard: Bool
        if current.opened, !current.enteredCard, let frame = visibleCardFrame?() {
            let origin = current.badgeRect ?? ScreenGeometry.pointerAnchor(current.origin)
            towardCard = TextLogic.hoverTransitContains(point, from: origin, to: frame, towardNearestEdge: current.opensDirectly)
        } else { towardCard = false }
        if inSource || towardBadge || towardCard { outsideSince = nil; return true }
        let leftAt = outsideSince ?? now
        outsideSince = leftAt
        if now.timeIntervalSince(leftAt) < model.closeDelay { return true }
        model.dismiss()
        resetMotion(at: point)
        return false
    }

    private func tick() {
        guard !model.directReplacementRunning else { return }
        guard started, !isMenuTracking, selectionTask == nil, typingTask == nil else { return }
        let point = NSEvent.mouseLocation
        // A deliberate selection is an action toolbar, not a hover preview.
        // Keep it reachable across any gap until an outside click/scroll or close.
        if retainSelection() { return }
        if retainCandidate(at: point) { return }
        guard canHoverAutomatically, !model.pinned else { return }
        if let frame = visibleCardFrame?(), frame.insetBy(dx: -12, dy: -12).contains(point) { return }
        let moved = hypot(point.x - lastPoint.x, point.y - lastPoint.y) > 3
        if moved || NSEvent.pressedMouseButtons != 0 {
            resetMotion(at: point)
            model.dismiss()
            return
        }
        guard !attempted, Date().timeIntervalSince(stableSince) >= model.delay else { return }
        attempted = true
        let token = revision
        let screenLayout = ScreenGeometry.current
        let captureDesktopTop = screenLayout.first?.frame.maxY ?? 0
        let quartz = TextLogic.quartzPoint(point, desktopTop: captureDesktopTop)
        let window = TextCapture.hoveredWindow(at: quartz)
        if window?.pid == ProcessInfo.processInfo.processIdentifier { return }
        let scope = model.hoverRecognitionScope
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard canHoverAutomatically else { return }
                let accessible = try await TextCapture.accessible(at: quartz, scope: scope, window: window)
                guard !Task.isCancelled, screenLayout == ScreenGeometry.current,
                      captureStillCurrent(token: token, point: point, frontPID: frontPID, scope: scope) else { return }
                var capture = accessible?.capture
                if model.ocrEnabled, model.screenPermission, accessible?.allowsOCRFallback ?? true, let window {
                    capture = try await Self.resolveHoverCapture(accessible, recognize: {
                        try await TextCapture.ocr(at: quartz, scope: scope, window: window)
                    }, refreshAccessibility: {
                        guard screenLayout == ScreenGeometry.current,
                              self.captureStillCurrent(token: token, point: point, frontPID: frontPID, scope: scope),
                              TextCapture.hoveredWindow(at: quartz) == window else { return nil }
                        return try await TextCapture.accessible(at: quartz, scope: scope, window: window)
                    })
                }
                guard !Task.isCancelled, screenLayout == ScreenGeometry.current,
                      captureStillCurrent(token: token, point: point, frontPID: frontPID, scope: scope),
                      !IsSecureEventInputEnabled(), TextCapture.hoveredWindow(at: quartz) == window,
                      let capture, TextLogic.hasEnglish(capture.text) else { return }
                stage(capture, sourceRect: TextLogic.cocoaRect(capture.bounds, desktopTop: captureDesktopTop), pointer: point)
            } catch {
                guard !Task.isCancelled, token == revision, scope == model.hoverRecognitionScope,
                      screenLayout == ScreenGeometry.current else { return }
                // Do not OCR or publish changes when the target is our own UI.
                if case CaptureError.ownApplication = error { return }
                model.status = error.localizedDescription
            }
        }
    }

    static func resolveHoverCapture(_ accessible: AccessibleHoverCapture?,
                                    recognize: () async throws -> CapturedText?,
                                    refreshAccessibility: () async throws -> AccessibleHoverCapture?) async throws -> CapturedText? {
        do {
            if let recognized = try await recognize(), TextLogic.hasEnglish(recognized.text) {
                return recognized
            }
            return accessible?.capture
        } catch {
            try Task.checkCancellation()
            guard !(error is CancellationError), let accessible, TextLogic.hasEnglish(accessible.capture.text) else {
                throw error
            }
            if let captureError = error as? CaptureError {
                guard case .noScreenPermission = captureError else { throw captureError }
            }
            // The failed OCR may have suspended while the underlying AX target
            // changed. Use a fresh reading before publishing a fallback.
            return try await refreshAccessibility()?.capture
        }
    }

    private func captureStillCurrent(token: Int, point: CGPoint, frontPID: pid_t?, scope: HoverRecognitionScope) -> Bool {
        let current = NSEvent.mouseLocation
        return !model.directReplacementRunning && token == revision && canHoverAutomatically && !model.pinned &&
            scope == model.hoverRecognitionScope &&
            !model.selectionVisible && selectionTask == nil && NSEvent.pressedMouseButtons == 0 &&
            hypot(point.x - current.x, point.y - current.y) <= 3 &&
            NSWorkspace.shared.frontmostApplication?.processIdentifier == frontPID
    }

    func retainSelection() -> Bool {
        model.selectionVisible && visibleCardFrame?() != nil
    }

    func readSelection(automatic: Bool = false) {
        guard !model.pinned, (!automatic || (model.enabled && model.selectionEnabled)),
              let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        cancelSelection()
        cancelTyping()
        captureTask?.cancel()
        revision += 1
        attempted = true
        model.dismiss()
        let id = UUID()
        selectionID = id
        selectionIsAutomatic = automatic
        let pid = front.processIdentifier
        let screenLayout = ScreenGeometry.current
        let captureDesktopTop = screenLayout.first?.frame.maxY ?? 0
        let point = TextLogic.quartzPoint(NSEvent.mouseLocation, desktopTop: captureDesktopTop)
        selectionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if selectionID == id {
                    selectionTask = nil
                    selectionIsAutomatic = false
                    scheduleMonitoringRefresh()
                }
            }
            @MainActor func isCurrent() -> Bool {
                !Task.isCancelled && selectionID == id && screenLayout == ScreenGeometry.current &&
                    (!automatic || (model.enabled && model.selectionEnabled)) &&
                    NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            }
            guard isCurrent() else { return }
            guard model.accessibility else {
                if !automatic { model.requestAccessibility() }
                attempted = false
                return
            }
            do {
                if automatic {
                    // Let the browser publish its tree while the selection settles.
                    try await TextCapture.prepareAccessibility(pid: pid)
                    try await Task.sleep(for: .milliseconds(180))
                    guard isCurrent() else { return }
                }
                let capture: SelectedCapture
                do {
                    capture = try await TextCapture.selected(pid: pid, fallbackPoint: point)
                } catch CaptureError.selectionNotReady where automatic {
                    // A just-activated web process can publish its selection a
                    // little later. An observed caret or protected field ends the request.
                    try await Task.sleep(for: .milliseconds(180))
                    guard isCurrent() else { return }
                    capture = try await TextCapture.selected(pid: pid, fallbackPoint: point)
                }
                guard isCurrent() else { return }
                let anchor = TextLogic.cocoaRect(capture.text.bounds, desktopTop: captureDesktopTop)
                model.present(capture.text, cocoaAnchor: anchor, selection: true, replacement: capture.replacement)
            } catch {
                guard !Task.isCancelled, selectionID == id, screenLayout == ScreenGeometry.current else { return }
                attempted = false
                stableSince = Date()
                if !automatic { model.status = error.localizedDescription; model.showWindow?() }
            }
        }
        scheduleMonitoringRefresh()
    }
}
