import Foundation
import Sparkle

/// Uses Sparkle's standard UI, download verification and installer rather than
/// implementing our own archive extraction or application replacement.
@MainActor
final class SparkleUpdateClient: NSObject, AppUpdateClient, SPUUpdaterDelegate {
    var stateChanged: (() -> Void)?
    var eventHandler: ((AppUpdateEvent) -> Void)?
    var postponeInstallation: ((@escaping () -> Void) -> Bool)?

    private let configuration: UpdateConfiguration
    private let userDriver: SPUStandardUserDriver
    private var updater: SPUUpdater!
    private var observations: [NSKeyValueObservation] = []

    init(bundle: Bundle, configuration: UpdateConfiguration) {
        self.configuration = configuration
        userDriver = SPUStandardUserDriver(hostBundle: bundle, delegate: nil)
        super.init()
        updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle,
                             userDriver: userDriver, delegate: self)
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.stateChanged?() }
            },
            updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.stateChanged?() }
            }
        ]
    }

    var canCheckForUpdates: Bool { updater.canCheckForUpdates }
    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }
    var lastUpdateCheckDate: Date? { updater.lastUpdateCheckDate }

    func start() throws {
        // Privacy remains fixed even if an old preference allowed system profiling.
        updater.sendsSystemProfile = false
        try updater.start()
    }

    func checkForUpdates() { updater.checkForUpdates() }

    func feedURLString(for updater: SPUUpdater) -> String? {
        // Prefer validated bundled metadata to any legacy feed URL in defaults.
        configuration.feedURL.absoluteString
    }

    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        eventHandler?(.found(version: item.displayVersionString))
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        eventHandler?(.noCompatibleUpdate)
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        eventHandler?(.downloading)
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        eventHandler?(.downloaded)
    }

    func userDidCancelDownload(_ updater: SPUUpdater) { eventHandler?(.cancelled) }

    func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
                 forUpdate updateItem: SUAppcastItem, state: SPUUserUpdateState) {
        switch choice {
        case .skip: eventHandler?(.skipped)
        case .dismiss where state.stage != .installing:
            eventHandler?(.dismissed(downloaded: state.stage == .downloaded))
        default: break // Dismissing an installing update keeps its install-on-quit state.
        }
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        eventHandler?(.installing)
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        postponeInstallation?(installHandler) ?? false
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        report(error)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        if let error { report(error) }
        stateChanged?()
    }

    private func report(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == SUSparkleErrorDomain && nsError.code == SUError.noUpdateError.rawValue {
            eventHandler?(.noCompatibleUpdate)
        } else if nsError.domain == SUSparkleErrorDomain && nsError.code == SUError.installationCanceledError.rawValue {
            eventHandler?(.cancelled)
        } else {
            eventHandler?(.failed(error.localizedDescription))
        }
    }
}
