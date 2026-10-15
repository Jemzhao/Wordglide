import Combine
import Foundation

@MainActor
enum AppUpdateEvent {
    case found(version: String)
    case noCompatibleUpdate
    case downloading
    case downloaded
    case installing
    case dismissed(downloaded: Bool)
    case cancelled
    case skipped
    case failed(String)
}

/// Tests inject this small boundary instead of starting Sparkle or contacting a server.
@MainActor
protocol AppUpdateClient: AnyObject {
    var canCheckForUpdates: Bool { get }
    var automaticallyChecksForUpdates: Bool { get set }
    var lastUpdateCheckDate: Date? { get }
    var stateChanged: (() -> Void)? { get set }
    var eventHandler: ((AppUpdateEvent) -> Void)? { get set }
    var postponeInstallation: ((@escaping () -> Void) -> Bool)? { get set }
    func start() throws
    func checkForUpdates()
}

@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var status: String
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var isConfigured = false
    @Published private(set) var isStarted = false
    @Published private(set) var lastCheckDate: Date?
    @Published private(set) var availableVersion: String?
    @Published private(set) var installationPending = false
    @Published var automaticChecksEnabled = false {
        didSet {
            guard !synchronizing, isStarted, let client,
                  client.automaticallyChecksForUpdates != automaticChecksEnabled else { return }
            // Sparkle owns the persisted preference. Do not duplicate it in our defaults.
            client.automaticallyChecksForUpdates = automaticChecksEnabled
        }
    }

    var shouldAllowUpdateInstallation: () -> Bool = { true }
    let currentVersion: String
    private var client: (any AppUpdateClient)?
    private let makeClient: (() -> any AppUpdateClient)?
    private var synchronizing = false
    private var pendingInstallation: (() -> Void)?
    private var installationTimer: Timer?

    convenience init(bundle: Bundle = .main, enabled: Bool = true) {
        let info = bundle.infoDictionary ?? [:]
        let configuration = Result { try UpdateConfiguration(info: info, bundleURL: bundle.bundleURL) }
        self.init(configuration: configuration, enabled: enabled,
                  currentVersion: info["CFBundleShortVersionString"] as? String ?? "开发版") { configuration in
            SparkleUpdateClient(bundle: bundle, configuration: configuration)
        }
    }

    init(configuration: Result<UpdateConfiguration, Error>, enabled: Bool = true,
         currentVersion: String = "开发版",
         makeClient: @escaping (UpdateConfiguration) -> any AppUpdateClient) {
        self.currentVersion = currentVersion
        switch configuration {
        case .success(let configuration) where enabled:
            isConfigured = true
            status = "更新服务待启动。"
            self.makeClient = { makeClient(configuration) }
        case .success:
            status = "开发检查模式未启用自动更新。"
            self.makeClient = nil
        case .failure(let error):
            status = error.localizedDescription
            self.makeClient = nil
        }
    }

    /// Called only by the normal app launch path, never by settings, previews or tests.
    func start() {
        guard !isStarted, let makeClient else { return }
        if client == nil {
            let newClient = makeClient()
            newClient.stateChanged = { [weak self] in self?.synchronizeState() }
            newClient.eventHandler = { [weak self] in self?.receive($0) }
            newClient.postponeInstallation = { [weak self] handler in
                self?.postponeInstallationIfNeeded(handler) ?? false
            }
            client = newClient
        }
        guard let client else { return }
        do {
            try client.start()
            isStarted = true
            status = "可检查新版本。"
            synchronizeState()
        } catch {
            status = "更新服务启动失败：\(error.localizedDescription)"
            canCheckForUpdates = false
        }
    }

    func checkForUpdates() {
        guard isStarted, canCheckForUpdates, let client else { return }
        status = "正在检查更新…"
        client.checkForUpdates()
        synchronizeState()
    }

    func resumePendingInstallationIfPossible() {
        guard let handler = pendingInstallation, shouldAllowUpdateInstallation() else { return }
        // Consume the handler before invoking it; callbacks may synchronously reenter us.
        pendingInstallation = nil
        installationTimer?.invalidate()
        installationTimer = nil
        status = "正在安装更新并重新启动…"
        handler()
    }

    private func postponeInstallationIfNeeded(_ handler: @escaping () -> Void) -> Bool {
        installationPending = true
        guard !shouldAllowUpdateInstallation() else { return false }
        pendingInstallation = handler
        status = "正在等待本次翻译或替换完成后安装更新。"
        installationTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumePendingInstallationIfPossible() }
        }
        installationTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        return true
    }

    private func synchronizeState() {
        guard let client else { return }
        synchronizing = true
        automaticChecksEnabled = client.automaticallyChecksForUpdates
        lastCheckDate = client.lastUpdateCheckDate
        canCheckForUpdates = isStarted && client.canCheckForUpdates
        synchronizing = false
    }

    private func receive(_ event: AppUpdateEvent) {
        switch event {
        case .found(let version):
            availableVersion = version
            status = "发现新版本 \(version)。"
        case .noCompatibleUpdate:
            availableVersion = nil
            status = "当前没有适用于此 Mac 的新版本。"
        case .downloading: status = "正在下载更新…"
        case .downloaded: status = "更新已下载，等待安装。"
        case .installing:
            installationPending = true
            status = "更新已准备安装。"
        case .dismissed(let downloaded):
            clearPendingInstallation()
            status = downloaded ? "更新已下载，可稍后检查更新继续安装。" : "已推迟本次更新，可稍后重新检查。"
        case .cancelled:
            clearPendingInstallation()
            status = "本次更新已取消，可稍后重新检查。"
        case .skipped:
            clearPendingInstallation()
            availableVersion = nil
            status = "已跳过此版本，可手动检查更新重新查看。"
        case .failed(let message):
            clearPendingInstallation()
            status = "更新未完成：\(message)"
        }
        synchronizeState()
    }

    private func clearPendingInstallation() {
        pendingInstallation = nil
        installationPending = false
        installationTimer?.invalidate()
        installationTimer = nil
    }

    deinit { installationTimer?.invalidate() }
}
