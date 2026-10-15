import XCTest
@testable import Wordglide

final class UpdateConfigurationTests: XCTestCase {
    private let applicationURL = URL(fileURLWithPath: "/Applications/Wordglide.app")
    private var validInfo: [String: Any] {
        ["CFBundlePackageType": "APPL", "SUFeedURL": "https://updates.example.org/appcast.xml",
         "SUPublicEDKey": Data(repeating: 7, count: 32).base64EncodedString()]
    }

    func testValidPublicReleaseConfiguration() throws {
        let configuration = try UpdateConfiguration(info: validInfo, bundleURL: applicationURL)
        XCTAssertEqual(configuration.feedURL.absoluteString, "https://updates.example.org/appcast.xml")
        XCTAssertEqual(Data(base64Encoded: configuration.publicKey)?.count, 32)
    }

    func testMissingFeedAndSigningKeyRemainUnconfigured() {
        for key in ["SUFeedURL", "SUPublicEDKey"] {
            var info = validInfo
            info.removeValue(forKey: key)
            XCTAssertThrowsError(try UpdateConfiguration(info: info, bundleURL: applicationURL))
            info[key] = ""
            XCTAssertThrowsError(try UpdateConfiguration(info: info, bundleURL: applicationURL))
        }
    }

    func testRejectsInsecureOrMalformedFeedURLs() {
        for feed in ["http://updates.example.org/appcast.xml", "file:///tmp/appcast.xml", "/appcast.xml",
                     "https:///appcast.xml", "https://user:secret@example.org/appcast.xml",
                     "https://example.org/appcast.xml#fragment", "https://example.org/a b.xml",
                     " https://example.org/appcast.xml"] {
            var info = validInfo
            info["SUFeedURL"] = feed
            XCTAssertThrowsError(try UpdateConfiguration(info: info, bundleURL: applicationURL), feed)
        }
    }

    func testRejectsWrongLengthOrMalformedEd25519Keys() {
        for key in ["not-a-key", Data(repeating: 1, count: 31).base64EncodedString(),
                    Data(repeating: 1, count: 33).base64EncodedString()] {
            var info = validInfo
            info["SUPublicEDKey"] = key
            XCTAssertThrowsError(try UpdateConfiguration(info: info, bundleURL: applicationURL))
        }
    }

    func testCommandLineExecutablesAndTestBundlesCannotSelfUpdate() {
        for url in [URL(fileURLWithPath: "/tmp/Wordglide"), URL(fileURLWithPath: "/tmp/WordglideTests.xctest")] {
            XCTAssertThrowsError(try UpdateConfiguration(info: validInfo, bundleURL: url))
        }
        var info = validInfo
        info["CFBundlePackageType"] = "BNDL"
        XCTAssertThrowsError(try UpdateConfiguration(info: info, bundleURL: applicationURL))
    }
}
