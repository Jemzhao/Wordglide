// Adapted from Hover Translate, Copyright (c) 2026 Kianzzz.
// Distributed under the MIT License; see ThirdParty/HoverTranslate-LICENSE.
import AppKit
import Combine
import Carbon

@MainActor
final class HoverMonitor {
    struct Candidate {
        let capture: CapturedText
        let sourceRect: CGRect
        let badgeRect: CGRect
        let origin: CGPoint
        var previousPoint: CGPoint
        var approachUntil = Date.distantPast
        let demo: Bool
        var opened = false
        var enteredCard = false
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
        for observer in menuObservers { NotificationCenter.default.removeObserver(observer) }
        menuObservers.removeAll()
        trackingMenus.removeAll()
        menuReturnUntil = .distantPast
        subscriptions.removeAll()
        captureTask?.cancel(); captureTask = nil
        cancelSelection()
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
        let access = "\(model.accessibility):\(model.screenPermission):\(model.ocrEnabled):\(model.hoverEnabled):\(model.wordMode)"
        if access != previousCaptureAccess {
            previousCaptureAccess = access
            resetMotion(at: NSEvent.mouseLocation)
            // A monitor installed before an Accessibility grant may not have
            // keyboard access. Reinstall once when capability/settings change.
            removeEventMonitors()
        }
        if let current = candidate, !current.demo, (!model.enabled || !model.hoverEnabled) {
            model.dismiss(force: true)
        }
        if selectionIsAutomatic, (!model.enabled || !model.selectionEnabled) { cancelSelection() }
        let canCapture = model.accessibility || (model.ocrEnabled && model.screenPermission)
        if model.pinned { hideBadge?() }
        let needsPointer = !model.directReplacementRunning && !isMenuTracking && !model.pinned && !model.selectionVisible && selectionTask == nil &&
            (candidate != nil || (model.enabled && model.hoverEnabled && canCapture))
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
        let needsEvents = model.directReplacementRunning || (model.enabled && (model.hoverEnabled || model.selectionEnabled)) ||
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
        // The app's ordinary paste emits key events in the destination. Do not
        // cancel its result check or let those events trigger another capture.
        let isOwnPaste = event.cgEvent?.getIntegerValueField(.eventSourceUserData) == TextReplacement.pasteEventMarker
        if isOwnPaste { return }
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
        if event.type == .leftMouseUp, !local, model.enabled, model.selectionEnabled {
            readSelection(automatic: true)
            return
        }
        cancelSelection()
        resetMotion(at: NSEvent.mouseLocation)
        model.dismiss()
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
        candidate = nil
        outsideSince = nil
        menuReturnUntil = .distantPast
        hideBadge?()
        scheduleMonitoringRefresh()
    }

    func stage(_ capture: CapturedText, sourceRect: CGRect, pointer: CGPoint, demo: Bool = false) {
        guard !model.pinned, let badgeRect = showBadge?(pointer, sourceRect), !badgeRect.isEmpty else { return }
        candidate = Candidate(capture: capture, sourceRect: sourceRect, badgeRect: badgeRect, origin: pointer, previousPoint: pointer, demo: demo)
        outsideSince = nil
        model.status = "已发现英文 · 将鼠标移到“译”图标查看译文"
        scheduleMonitoringRefresh()
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
        if !current.demo && (!model.enabled || !model.hoverEnabled) {
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
        if !current.enteredCard && current.badgeRect.contains(point) {
            outsideSince = nil
            if !current.opened {
                current.opened = true
                candidate = current
                model.present(current.capture, cocoaAnchor: current.badgeRect, selection: false)
            }
            return true
        }
        let movement = hypot(point.x - current.previousPoint.x, point.y - current.previousPoint.y)
        let toward = TextLogic.movingTowardBadge(from: current.previousPoint, to: point, badge: current.badgeRect)
        if movement >= 0.5 {
            current.previousPoint = point
            current.approachUntil = toward ? now.addingTimeInterval(0.2) : .distantPast
        }
        candidate = current
        // The source may be an entire paragraph. Only the initial hover point
        // remains a resting zone; moving elsewhere in that paragraph dismisses.
        let inSource = !current.opened && hypot(point.x - current.origin.x, point.y - current.origin.y) <= 4
        let towardBadge = !current.opened && (toward || now < current.approachUntil)
        let towardCard: Bool
        if current.opened, !current.enteredCard, let frame = visibleCardFrame?() {
            towardCard = TextLogic.hoverTransitContains(point, from: current.badgeRect, to: frame)
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
        guard started, !isMenuTracking else { return }
        let point = NSEvent.mouseLocation
        // A deliberate selection is an action toolbar, not a hover preview.
        // Keep it reachable across any gap until an outside click/scroll or close.
        if retainSelection() { return }
        if retainCandidate(at: point) { return }
        guard model.enabled, !model.pinned else { return }
        if let frame = visibleCardFrame?(), frame.insetBy(dx: -12, dy: -12).contains(point) { return }
        let moved = hypot(point.x - lastPoint.x, point.y - lastPoint.y) > 3
        if moved || NSEvent.pressedMouseButtons != 0 {
            resetMotion(at: point)
            model.dismiss()
            return
        }
        guard model.hoverEnabled, !attempted, Date().timeIntervalSince(stableSince) >= model.delay else { return }
        attempted = true
        guard model.accessibility || (model.ocrEnabled && model.screenPermission) else { return }
        let token = revision
        let screenLayout = ScreenGeometry.current
        let captureDesktopTop = screenLayout.first?.frame.maxY ?? 0
        let quartz = TextLogic.quartzPoint(point, desktopTop: captureDesktopTop)
        if topWindowIsOurs(at: quartz) { return }
        let word = model.wordMode
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                var capture: CapturedText?
                if model.accessibility { capture = try await TextCapture.accessible(at: quartz, word: word) }
                guard !Task.isCancelled, screenLayout == ScreenGeometry.current,
                      captureStillCurrent(token: token, point: point, frontPID: frontPID) else { return }
                if (capture == nil || !TextLogic.hasEnglish(capture!.text)), model.ocrEnabled, model.screenPermission {
                    capture = try await TextCapture.ocr(at: quartz, word: word)
                }
                guard !Task.isCancelled, screenLayout == ScreenGeometry.current,
                      captureStillCurrent(token: token, point: point, frontPID: frontPID),
                      let capture, TextLogic.hasEnglish(capture.text) else { return }
                stage(capture, sourceRect: TextLogic.cocoaRect(capture.bounds, desktopTop: captureDesktopTop), pointer: point)
            } catch {
                guard !Task.isCancelled, token == revision, screenLayout == ScreenGeometry.current else { return }
                // Do not OCR or publish changes when the target is our own UI.
                if case CaptureError.ownApplication = error { return }
                model.status = error.localizedDescription
            }
        }
    }

    private func captureStillCurrent(token: Int, point: CGPoint, frontPID: pid_t?) -> Bool {
        let current = NSEvent.mouseLocation
        return !model.directReplacementRunning && token == revision && model.enabled && model.hoverEnabled && !model.pinned &&
            !model.selectionVisible && selectionTask == nil && NSEvent.pressedMouseButtons == 0 &&
            hypot(point.x - current.x, point.y - current.y) <= 3 &&
            NSWorkspace.shared.frontmostApplication?.processIdentifier == frontPID
    }

    func retainSelection() -> Bool {
        model.selectionVisible && visibleCardFrame?() != nil
    }

    private func topWindowIsOurs(at quartz: CGPoint) -> Bool {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        for window in windows {
            guard (window[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let raw = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: raw as CFDictionary), rect.contains(quartz) else { continue }
            return window[kCGWindowOwnerPID as String] as? pid_t == ProcessInfo.processInfo.processIdentifier
        }
        return false
    }

    func readSelection(automatic: Bool = false) {
        guard !model.pinned, (!automatic || (model.enabled && model.selectionEnabled)),
              let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        cancelSelection()
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
            if automatic { try? await Task.sleep(nanoseconds: 180_000_000) }
            defer {
                if selectionID == id {
                    selectionTask = nil
                    selectionIsAutomatic = false
                    scheduleMonitoringRefresh()
                }
            }
            guard !Task.isCancelled, selectionID == id, screenLayout == ScreenGeometry.current,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            guard model.accessibility else {
                if !automatic { model.requestAccessibility() }
                attempted = false
                return
            }
            do {
                let capture = try await TextCapture.selected(pid: pid, fallbackPoint: point)
                guard !Task.isCancelled, selectionID == id, screenLayout == ScreenGeometry.current,
                      (!automatic || (model.enabled && model.selectionEnabled)),
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
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
