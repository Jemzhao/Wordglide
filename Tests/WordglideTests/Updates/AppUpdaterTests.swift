import XCTest
@testable import Wordglide

@MainActor
private final class RecordingUpdateClient: AppUpdateClient {
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = true {
        didSet { preferenceWrites += 1; stateChanged?() }
    }
    var lastUpdateCheckDate: Date?
    var stateChanged: (() -> Void)?
    var eventHandler: ((AppUpdateEvent) -> Void)?
    var postponeInstallation: ((@escaping () -> Void) -> Bool)?
    var starts = 0
    var checks = 0
    var preferenceWrites = 0
    var startError: Error?
    func start() throws {
        starts += 1
        if let startError { throw startError }
    }
    func checkForUpdates() { checks += 1 }
}

final class AppUpdaterTests: XCTestCase {
    private func configuration() throws -> UpdateConfiguration {
        try UpdateConfiguration(info: ["CFBundlePackageType": "APPL",
                                       "SUFeedURL": "https://updates.example.org/appcast.xml",
                                       "SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString()],
                                bundleURL: URL(fileURLWithPath: "/Applications/Wordglide.app"))
    }

    @MainActor func testInitializationDoesNotConstructOrStartNetworkClient() throws {
        var constructions = 0
        let client = RecordingUpdateClient()
        let updater = AppUpdater(configuration: .success(try configuration())) { _ in
            constructions += 1
            return client
        }
        XCTAssertTrue(updater.isConfigured)
        XCTAssertFalse(updater.canCheckForUpdates)
        updater.checkForUpdates()
        XCTAssertEqual(constructions, 0)
        XCTAssertEqual(client.starts, 0)
        XCTAssertEqual(client.checks, 0)

        updater.start()
        updater.start()
        XCTAssertEqual(constructions, 1)
        XCTAssertEqual(client.starts, 1)
        XCTAssertTrue(updater.canCheckForUpdates)
        XCTAssertEqual(client.preferenceWrites, 0, "Launch must preserve Sparkle's stored user choice")
    }

    @MainActor func testDisabledOrMissingConfigurationNeverCreatesAnUpdater() throws {
        for (result, enabled) in [(Result<UpdateConfiguration, Error>.success(try configuration()), false),
                                   (.failure(UpdateConfiguration.ConfigurationError.missingFeed), true)] {
            let updater = AppUpdater(configuration: result, enabled: enabled) { _ in
                XCTFail("A disabled updater must not create a network client")
                return RecordingUpdateClient()
            }
            updater.start()
            updater.checkForUpdates()
            XCTAssertFalse(updater.isConfigured)
            XCTAssertFalse(updater.canCheckForUpdates)
            XCTAssertFalse(updater.status.contains("最新"))
        }
    }

    @MainActor func testAutomaticCheckPreferenceBelongsToSparkleAndReflectsChanges() throws {
        let client = RecordingUpdateClient()
        client.automaticallyChecksForUpdates = false
        client.preferenceWrites = 0
        let updater = AppUpdater(configuration: .success(try configuration())) { _ in client }
        updater.start()
        XCTAssertFalse(updater.automaticChecksEnabled)
        XCTAssertEqual(client.preferenceWrites, 0)
        updater.automaticChecksEnabled = true
        XCTAssertTrue(client.automaticallyChecksForUpdates)
        XCTAssertEqual(client.preferenceWrites, 1)
        client.automaticallyChecksForUpdates = false
        XCTAssertFalse(updater.automaticChecksEnabled)
        XCTAssertEqual(client.preferenceWrites, 2, "Observation must not write the preference a second time")
    }

    @MainActor func testAvailabilityAndCheckDateFollowTheClient() throws {
        let client = RecordingUpdateClient()
        let updater = AppUpdater(configuration: .success(try configuration())) { _ in client }
        updater.start()
        updater.checkForUpdates()
        XCTAssertEqual(client.checks, 1)
        client.canCheckForUpdates = false
        client.lastUpdateCheckDate = Date(timeIntervalSince1970: 1_700_000_000)
        client.stateChanged?()
        updater.checkForUpdates()
        XCTAssertEqual(client.checks, 1)
        XCTAssertFalse(updater.canCheckForUpdates)
        XCTAssertEqual(updater.lastCheckDate, client.lastUpdateCheckDate)
    }

    @MainActor func testStartupFailureCanBeRetriedWithoutReplacingClient() throws {
        let client = RecordingUpdateClient()
        client.startError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "启动样例失败"])
        let updater = AppUpdater(configuration: .success(try configuration())) { _ in client }
        updater.start()
        XCTAssertFalse(updater.canCheckForUpdates)
        XCTAssertTrue(updater.status.contains("启动样例失败"))
        client.startError = nil
        updater.start()
        XCTAssertTrue(updater.canCheckForUpdates)
        XCTAssertEqual(client.starts, 2)
    }

    @MainActor func testErrorsAndNoCompatibleUpdateAreNotMisreportedAsLatest() throws {
        let client = RecordingUpdateClient()
        let updater = AppUpdater(configuration: .success(try configuration())) { _ in client }
        updater.start()
        client.eventHandler?(.failed("网络暂时不可用"))
        XCTAssertTrue(updater.status.contains("网络暂时不可用"))
        XCTAssertFalse(updater.status.contains("最新"))
        client.eventHandler?(.noCompatibleUpdate)
        XCTAssertTrue(updater.status.contains("适用于此 Mac"))
        client.eventHandler?(.found(version: "0.9.0"))
        XCTAssertTrue(updater.status.contains("0.9.0"))
    }

    @MainActor func testUpdateInstallationWaitsForCurrentOperationAndResumesExactlyOnce() throws {
        let client = RecordingUpdateClient()
        let updater = AppUpdater(configuration: .success(try configuration())) { _ in client }
        var busy = true
        var installations = 0
        updater.shouldAllowUpdateInstallation = { !busy }
        updater.start()
        let postponed = client.postponeInstallation? { installations += 1 }
        XCTAssertEqual(postponed, true)
        XCTAssertTrue(updater.installationPending)
        updater.resumePendingInstallationIfPossible()
        XCTAssertEqual(installations, 0)
        busy = false
        updater.resumePendingInstallationIfPossible()
        updater.resumePendingInstallationIfPossible()
        XCTAssertEqual(installations, 1)
    }

    @MainActor func testKnownAvailableVersionSurvivesDeferralCancellationAndNetworkFailure() throws {
        let client = RecordingUpdateClient()
        let updater = AppUpdater(configuration: .success(try configuration())) { _ in client }
        updater.start()
        XCTAssertNil(updater.availableVersion)
        client.eventHandler?(.found(version: "0.3.1"))
        XCTAssertEqual(updater.availableVersion, "0.3.1")
        for event in [AppUpdateEvent.dismissed(downloaded: false), .dismissed(downloaded: true),
                      .cancelled, .failed("离线")] {
            client.eventHandler?(event)
            XCTAssertEqual(updater.availableVersion, "0.3.1")
        }
        client.eventHandler?(.noCompatibleUpdate)
        XCTAssertNil(updater.availableVersion)
    }

    @MainActor func testExplicitlySkippingAVersionClearsItsReminder() throws {
        let client = RecordingUpdateClient()
        let updater = AppUpdater(configuration: .success(try configuration())) { _ in client }
        updater.start()
        client.eventHandler?(.found(version: "0.3.1"))
        client.eventHandler?(.skipped)
        XCTAssertNil(updater.availableVersion)
        XCTAssertTrue(updater.status.contains("已跳过"))
    }

    @MainActor func testAbortedInstallDropsPendingRelaunch() throws {
        let client = RecordingUpdateClient()
        let updater = AppUpdater(configuration: .success(try configuration())) { _ in client }
        var busy = true
        var installations = 0
        updater.shouldAllowUpdateInstallation = { !busy }
        updater.start()
        XCTAssertEqual(client.postponeInstallation? { installations += 1 }, true)
        client.eventHandler?(.failed("更新验证失败"))
        busy = false
        updater.resumePendingInstallationIfPossible()
        XCTAssertFalse(updater.installationPending)
        XCTAssertEqual(installations, 0)
    }
}
