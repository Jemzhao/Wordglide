import AppKit
import ApplicationServices
import Darwin

/// An opt-in check that edits only a dedicated child-process NSTextView. It
/// neither requests permission nor synthesizes typing, shortcuts, or clicks.
@MainActor
enum DirectReplacementIntegrationCheck {
    private static let fixtureArgument = "--direct-replacement-fixture"
    private static let directoryPrefix = "Wordglide-DirectReplacement-"

    /// The app entry point should exit with this status after awaiting cleanup.
    static func run() async -> Int32 {
        guard AXIsProcessTrusted() else {
            print("SKIP direct replacement integration: Accessibility permission is not already granted; no permission was requested.")
            return 0
        }
        guard let executable = Bundle.main.executableURL else {
            print("FAIL direct replacement integration: cannot locate the current executable.")
            return 1
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(directoryPrefix + UUID().uuidString, isDirectory: true)
        let process = Process()
        let session = UUID().uuidString
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(24))
        var watchdog: Task<Void, Never>?
        defer {
            watchdog?.cancel()
            stopFixture(process)
            try? FileManager.default.removeItem(at: directory)
        }

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
            try Data(session.utf8).write(to: directory.appendingPathComponent("session"), options: .atomic)
            process.executableURL = executable
            process.arguments = [fixtureArgument, directory.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let childPID = process.processIdentifier
            guard childPID > 0, childPID != ProcessInfo.processInfo.processIdentifier else {
                throw CheckFailure("fixture is not a separate process")
            }

            // The AX operations themselves have bounded per-message timeouts.
            // Killing only our child also releases pending AX calls if a fixture
            // becomes unresponsive, keeping this optional check bounded overall.
            watchdog = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(24)) }
                catch { return }
                stopFixture(process)
            }

            let client = FixtureClient(directory: directory, session: session,
                                       process: process, deadline: deadline)
            _ = try await client.waitForReply(id: 0, maximumWait: .seconds(5))

            let wholeSample = "你好，世界。"
            try await checkScenario(client: client, sample: wholeSample,
                selection: NSRange(location: 2, length: 0), translation: "Hello, world.",
                expected: "Hello, world.", wholeField: true)
            print("PASS direct replacement integration: whole-field capture keeps the caret, one ordinary paste replaces the sample, and undo restores Chinese.")

            let partialSample = "前缀 你好 世界 后缀"
            let partialRange = (partialSample as NSString).range(of: "你好 世界")
            try await checkScenario(client: client, sample: partialSample,
                selection: partialRange, translation: "Hello, world.",
                expected: "前缀 Hello, world. 后缀", wholeField: false)
            print("PASS direct replacement integration: selected text alone is replaced and undo restores the full original sample.")
            print("PASS direct replacement integration: both cross-process AX / paste / undo scenarios passed.")
            return 0
        } catch {
            print("FAIL direct replacement integration: \(error.localizedDescription)")
            return 1
        }
    }

    /// Called before creating the normal app. The child owns its NSApplication
    /// event loop and can touch only the sample NSTextView it creates below.
    static func runFixtureIfRequested() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: fixtureArgument) else { return false }
        guard arguments.indices.contains(index + 1) else { return true }
        let directory = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard directory.deletingLastPathComponent() == temporary,
              directory.lastPathComponent.hasPrefix(directoryPrefix),
              let data = try? Data(contentsOf: directory.appendingPathComponent("session")),
              let session = String(data: data, encoding: .utf8), UUID(uuidString: session) != nil else { return true }

        let app = NSApplication.shared
        let fixture = FixtureController(directory: directory, session: session)
        app.setActivationPolicy(.regular)
        app.delegate = fixture
        withExtendedLifetime(fixture) { app.run() }
        return true
    }

    private static func stopFixture(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        guard pid > 0, pid != ProcessInfo.processInfo.processIdentifier else { return }
        process.terminate()
        // This is our own disposable fixture, never the target of a user action.
        if process.isRunning { _ = Darwin.kill(pid, SIGKILL) }
    }

    private static func checkScenario(client: FixtureClient, sample: String,
                                      selection: NSRange, translation: String,
                                      expected: String, wholeField: Bool) async throws {
        let configured = try await client.command("configure", text: sample, range: selection)
        try require(configured.text == sample && configured.range == selection,
                    "fixture did not establish the requested original and selection")
        try await client.waitForFocus()
        let pid = client.process.processIdentifier
        let capture = try await ReplacementTarget.captureForDirectReplacement(pid: pid)
        try require(capture.target.pid == pid && capture.replacesWholeField == wholeField,
                    "AX capture did not match our fixture or replacement mode")
        let source = wholeField ? sample : (sample as NSString).substring(with: selection)
        try require(capture.text == source, "AX capture returned unexpected source text")
        let afterCapture = try await client.command("snapshot")
        try require(afterCapture.text == sample && afterCapture.range == selection,
                    "capture changed the sample or selected text before translation")
        try await client.waitForFocus()
        let confirmed = try await TextReplacement.perform(capture.target, text: translation,
            stillCurrent: {
                client.process.isRunning && ContinuousClock().now < client.deadline
                    && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            }, releasePanelFocus: {})
        try require(confirmed, "ordinary paste was sent but its result was not confirmed")
        let pasted = try await client.command("snapshot")
        try require(pasted.text == expected, "paste produced an unexpected full value")
        try require(pasted.canUndo, "ordinary paste did not produce an undo record")
        let undone = try await client.command("undo")
        try require(undone.text == sample, "fixture undo did not restore the full original")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw CheckFailure(message) }
    }

    private struct CheckFailure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private struct FixtureCommand: Codable {
        let session: String
        let id: Int
        let operation: String
        let text: String?
        let location: Int?
        let length: Int?
    }

    private struct FixtureReply: Codable {
        let session: String
        let id: Int
        let text: String
        let location: Int
        let length: Int
        let canUndo: Bool
        let error: String?
        var range: NSRange { NSRange(location: location, length: length) }
    }

    @MainActor
    private final class FixtureClient {
        let directory: URL
        let session: String
        let process: Process
        let deadline: ContinuousClock.Instant
        private var nextID = 1

        init(directory: URL, session: String, process: Process, deadline: ContinuousClock.Instant) {
            self.directory = directory
            self.session = session
            self.process = process
            self.deadline = deadline
        }

        func command(_ operation: String, text: String? = nil, range: NSRange? = nil) async throws -> FixtureReply {
            let id = nextID
            nextID += 1
            let command = FixtureCommand(session: session, id: id, operation: operation,
                                         text: text, location: range?.location, length: range?.length)
            let data = try JSONEncoder().encode(command)
            try data.write(to: directory.appendingPathComponent("command.json"), options: .atomic)
            return try await waitForReply(id: id, maximumWait: .seconds(3))
        }

        func waitForReply(id: Int, maximumWait: Duration) async throws -> FixtureReply {
            let clock = ContinuousClock()
            let stepDeadline = min(deadline, clock.now.advanced(by: maximumWait))
            while clock.now < stepDeadline {
                try Task.checkCancellation()
                guard process.isRunning else { throw CheckFailure("fixture exited before replying") }
                if let data = try? Data(contentsOf: directory.appendingPathComponent("reply.json")),
                   let reply = try? JSONDecoder().decode(FixtureReply.self, from: data),
                   reply.session == session, reply.id == id {
                    if let error = reply.error { throw CheckFailure("fixture: " + error) }
                    return reply
                }
                try await Task.sleep(for: .milliseconds(45))
            }
            throw CheckFailure("fixture reply or overall check deadline expired")
        }

        func waitForFocus() async throws {
            let clock = ContinuousClock()
            let stepDeadline = min(deadline, clock.now.advanced(by: .seconds(3)))
            while clock.now < stepDeadline {
                try Task.checkCancellation()
                guard process.isRunning else { throw CheckFailure("fixture exited before activation") }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == process.processIdentifier { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw CheckFailure("fixture did not become the frontmost application")
        }
    }

    @MainActor
    private final class FixtureController: NSObject, NSApplicationDelegate {
        private let directory: URL
        private let session: String
        private var window: NSWindow?
        private var textView: NSTextView?
        private var timer: Timer?
        private var lastCommand = 0
        private let started = Date()

        init(directory: URL, session: String) {
            self.directory = directory
            self.session = session
        }

        func applicationDidFinishLaunching(_ notification: Notification) {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 240),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Wordglide · 替换检查样例"
            window.isReleasedWhenClosed = false
            let scroll = NSScrollView(frame: window.contentView?.bounds ?? .zero)
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            let text = NSTextView(frame: scroll.bounds)
            text.isRichText = false
            text.isEditable = true
            text.isSelectable = true
            text.allowsUndo = true
            text.font = .systemFont(ofSize: 20)
            text.textContainerInset = NSSize(width: 24, height: 24)
            text.autoresizingMask = [.width]
            text.isVerticallyResizable = true
            text.isHorizontallyResizable = false
            text.textContainer?.widthTracksTextView = true
            scroll.documentView = text
            window.contentView?.addSubview(scroll)
            self.window = window
            textView = text
            window.center()
            activate()
            reply(id: 0)
            timer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
        }

        func applicationWillTerminate(_ notification: Notification) { timer?.invalidate() }
        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

        private func activate() {
            guard let window, let textView else { return }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(textView)
            NSApplication.shared.activate(ignoringOtherApps: true)
        }

        private func poll() {
            // An orphaned fixture has its own independent lifetime bound.
            guard Date().timeIntervalSince(started) < 30 else {
                NSApplication.shared.terminate(nil)
                return
            }
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("command.json")),
                  let command = try? JSONDecoder().decode(FixtureCommand.self, from: data),
                  command.session == session, command.id > lastCommand, let textView else { return }
            lastCommand = command.id
            switch command.operation {
            case "configure":
                guard let text = command.text, let location = command.location, let length = command.length,
                      location >= 0, length >= 0, location <= text.utf16.count,
                      length <= text.utf16.count - location,
                      text.utf16.count <= TextLogic.maximumInputLength else {
                    reply(id: command.id, error: "invalid sample")
                    return
                }
                textView.string = text
                textView.setSelectedRange(NSRange(location: location, length: length))
                textView.undoManager?.removeAllActions()
                activate()
                reply(id: command.id)
            case "snapshot":
                reply(id: command.id)
            case "undo":
                guard let manager = textView.undoManager, manager.canUndo else {
                    reply(id: command.id, error: "no undo operation is available")
                    return
                }
                textView.breakUndoCoalescing()
                manager.undo()
                reply(id: command.id)
            default:
                reply(id: command.id, error: "unsupported fixture command")
            }
        }

        private func reply(id: Int, error: String? = nil) {
            guard let textView else { return }
            let range = textView.selectedRange()
            let reply = FixtureReply(session: session, id: id, text: textView.string,
                location: range.location, length: range.length,
                canUndo: textView.undoManager?.canUndo ?? false, error: error)
            if let data = try? JSONEncoder().encode(reply) {
                try? data.write(to: directory.appendingPathComponent("reply.json"), options: .atomic)
            }
        }
    }
}
