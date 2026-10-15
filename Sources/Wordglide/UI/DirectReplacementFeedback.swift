import AppKit
import SwiftUI
import Combine

@MainActor
final class DirectReplacementFeedback: ObservableObject {
    @Published var message = ""
    @Published var running = false
    @Published var warning = false
    @Published var layoutSize = CGSize(width: 360, height: 84)

    func update(_ text: String, running: Bool, warning: Bool = false) {
        message = text
        self.running = running
        self.warning = warning
    }
}

private struct DirectReplacementFeedbackView: View {
    @ObservedObject var feedback: DirectReplacementFeedback

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            if feedback.running {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: feedback.warning ? "exclamationmark.circle" : "checkmark.circle")
                    .font(.system(size: 17))
                    .foregroundStyle(feedback.warning ? AppTheme.secondary : AppTheme.accent)
            }
            Text(feedback.message)
                .font(.system(size: 12))
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .frame(width: feedback.layoutSize.width, height: feedback.layoutSize.height)
        .foregroundStyle(AppTheme.ink)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(AppTheme.line, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

extension AppDelegate {
    func configureDirectReplacement() {
        let hud = HoverBadgePanel(contentRect: CGRect(x: 0, y: 0, width: 360, height: 84),
                                  styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        hud.title = "Wordglide · 快捷替换状态"
        hud.backgroundColor = .clear
        hud.isOpaque = false
        hud.hasShadow = true
        hud.hidesOnDeactivate = false
        hud.ignoresMouseEvents = true
        hud.isReleasedWhenClosed = false
        hud.level = .floating
        hud.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let container = TransparentPanelContainer(frame: CGRect(x: 0, y: 0, width: 360, height: 84), cornerRadius: 12)
        let hosting = TransparentPanelHostingView(rootView: DirectReplacementFeedbackView(feedback: directFeedback))
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        hosting.layer?.isOpaque = false
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.frame = CGRect(x: 0, y: 0, width: 360, height: 84)
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        hud.contentView = container
        directStatusPanel = hud

        model.cancelDirectReplacement = { [weak self] in self?.directReplacement.cancel() }
        directReplacement.recoveryAvailable = { [weak self] recovery in
            self?.model.retainReplacementRecovery(recovery)
        }
        directReplacement.$isRunning.sink { [weak self] value in
            self?.model.directReplacementRunning = value
        }.store(in: &subscriptions)
        directReplacement.statusChanged = { [weak self] message in
            guard let self else { return }
            model.status = message
            statusItem.button?.toolTip = "Wordglide · " + message
            directFeedback.update(message, running: directReplacement.isRunning)
            if directReplacement.isRunning { directHideTask?.cancel() }
            showDirectFeedback()
        }
        directReplacement.captured = { [weak self] bounds, _ in
            guard let self, bounds.height > 0, !bounds.isInfinite, !bounds.isNull else { return }
            let caretOrSelection = CGRect(origin: bounds.origin, size: CGSize(width: max(1, bounds.width), height: bounds.height))
            directAnchor = TextLogic.cocoaRect(caretOrSelection, desktopTop: monitor.desktopTop)
            showDirectFeedback()
        }
        directReplacement.finished = { [weak self] outcome in
            guard let self else { return }
            directDestinationPID = nil
            switch outcome {
            case .success: directFeedback.warning = false
            case .uncertain, .failure, .cancelled: directFeedback.warning = true
            }
            scheduleDirectFeedbackDismissal()
        }
        model.$directShortcut.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.registerDirectShortcut() }
        }.store(in: &subscriptions)
        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self, directReplacement.isRunning, let expectedPID = directDestinationPID,
                      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.processIdentifier != expectedPID else { return }
                directReplacement.cancel()
            }.store(in: &subscriptions)
    }

    func showDirectFeedback() {
        guard let hud = directStatusPanel else { return }
        let anchor = directAnchor.isEmpty ? ScreenGeometry.pointerAnchor(NSEvent.mouseLocation) : directAnchor
        guard let screen = ScreenGeometry.resolveCurrent(anchor: anchor) else { hud.orderOut(nil); return }
        let safe = ScreenGeometry.safeFrame(visible: screen.visibleFrame)
        guard safe.width >= 240, safe.height >= 64 else { hud.orderOut(nil); return }
        let width = min(360, safe.width)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        let measured = (directFeedback.message as NSString).boundingRect(
            with: CGSize(width: width - 64, height: 10_000), options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 12), .paragraphStyle: paragraph]).height
        let size = CGSize(width: width, height: min(safe.height, max(84, ceil(measured) + 32)))
        if directFeedback.layoutSize != size { directFeedback.layoutSize = size }
        hud.setFrame(TextLogic.panelFrame(anchor: anchor, size: size, visible: screen.visibleFrame), display: true)
        hud.invalidateShadow()
        hud.orderFrontRegardless()
    }

    func scheduleDirectFeedbackDismissal() {
        directHideTask?.cancel()
        directHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, !directReplacement.isRunning else { return }
            directStatusPanel?.orderOut(nil)
        }
    }
}
