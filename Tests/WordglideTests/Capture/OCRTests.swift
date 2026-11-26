import AppKit
import ApplicationServices
import CoreText
import XCTest
@testable import Wordglide

final class OCRTests: XCTestCase {
    private enum ScreenshotFailure: Error { case unavailable }

    @MainActor
    func testFailedScreenshotRetainsTheVerifiedAccessibilityParagraph() async throws {
        let paragraph = CapturedText(text: "This paragraph is available through accessibility.",
                                     bounds: CGRect(x: 10, y: 20, width: 300, height: 48),
                                     method: "系统取词", isPartialParagraph: true)
        let accessible = AccessibleHoverCapture(capture: paragraph, hitTextRange: true)

        for failure in [ScreenshotFailure.unavailable, CaptureError.noScreenPermission] as [Error] {
            let result = try await HoverMonitor.resolveHoverCapture(accessible, recognize: {
                throw failure
            }, refreshAccessibility: { accessible })

            XCTAssertEqual(result?.text, paragraph.text)
            XCTAssertEqual(result?.bounds, paragraph.bounds)
            XCTAssertEqual(result?.isPartialParagraph, true)
        }
    }

    @MainActor
    func testOCRDoesNotFallBackAfterCancellationOrAnUnverifiedTarget() async throws {
        let paragraph = CapturedText(text: "This paragraph must stay private.", bounds: .zero,
                                     method: "系统取词", isPartialParagraph: true)
        let accessible = AccessibleHoverCapture(capture: paragraph, hitTextRange: true)
        let failures: [Error] = [CancellationError(), CaptureError.unverifiedTarget,
                                 CaptureError.protectedText, CaptureError.noAccessibilityPermission]
        for failure in failures {
            do {
                _ = try await HoverMonitor.resolveHoverCapture(accessible, recognize: { throw failure },
                    refreshAccessibility: {
                        XCTFail("This error must not retry accessibility capture.")
                        return accessible
                    })
                XCTFail("Expected the OCR failure to propagate.")
            } catch {
                XCTAssertEqual(error.localizedDescription, failure.localizedDescription)
            }
        }
    }

    @MainActor
    func testFailedScreenshotCannotPublishAnAccessibilityParagraphThatIsNoLongerVerified() async throws {
        let paragraph = CapturedText(text: "This paragraph is no longer under the pointer.",
                                     bounds: .zero, method: "系统取词", isPartialParagraph: true)
        let accessible = AccessibleHoverCapture(capture: paragraph, hitTextRange: true)
        let result = try await HoverMonitor.resolveHoverCapture(accessible, recognize: {
            throw ScreenshotFailure.unavailable
        }, refreshAccessibility: { nil })

        XCTAssertNil(result)
    }

    func testUnsupportedAXDescriptionStillAllowsOCRForVisibleText() {
        let foreignText = CapturedText(text: "今日はとても良い天気です。", bounds: .zero, method: "test")
        let foreignWord = CapturedText(text: "Hola", bounds: .zero, method: "test")
        let englishText = CapturedText(text: "This is visible English text.", bounds: .zero, method: "test")
        XCTAssertTrue(AccessibleHoverCapture(capture: foreignText, hitTextRange: false).allowsOCRFallback)
        XCTAssertFalse(AccessibleHoverCapture(capture: foreignText, hitTextRange: true).allowsOCRFallback)
        XCTAssertTrue(AccessibleHoverCapture(capture: foreignWord, hitTextRange: false).allowsOCRFallback)
        XCTAssertFalse(AccessibleHoverCapture(capture: foreignWord, hitTextRange: true).allowsOCRFallback)
        XCTAssertFalse(AccessibleHoverCapture(capture: englishText, hitTextRange: true).allowsOCRFallback)
    }

    func testMatchedChineseTextBlocksOCRWithoutBlockingEnglishParagraphCompletion() {
        let chinese = CapturedText(text: "已确认 Wordglide 更新到 0.3.3。", bounds: .zero, method: "test", isPartialParagraph: true)
        let english = CapturedText(text: "This English paragraph is incomplete.", bounds: .zero, method: "test", isPartialParagraph: true)
        XCTAssertFalse(AccessibleHoverCapture(capture: chinese, hitTextRange: true).allowsOCRFallback)
        XCTAssertTrue(AccessibleHoverCapture(capture: chinese, hitTextRange: false).allowsOCRFallback)
        XCTAssertTrue(AccessibleHoverCapture(capture: english, hitTextRange: true).allowsOCRFallback)
    }

    func testProtectionCheckAllowsAbsentOptionalAttributes() throws {
        let role = try TextCapture.verifiedUnprotectedRole { name in
            switch name {
            case kAXRoleAttribute: return (.success, "AXImage" as CFString)
            case kAXSubroleAttribute: return (.noValue, nil)
            default: return (.attributeUnsupported, nil)
            }
        }
        XCTAssertEqual(role, "AXImage")
    }

    func testProtectionCheckRejectsUnknownAndProtectedTargets() {
        let reads: [(String, AXError, CFTypeRef?)] = [
            (kAXRoleAttribute, .noValue, nil),
            (kAXRoleAttribute, .success, "AXUnknown" as CFString),
            (kAXSubroleAttribute, .cannotComplete, nil),
            ("AXProtectedContent", .success, "unknown" as CFString),
            ("AXProtectedContent", .success, NSNumber(value: 0)),
            ("AXProtectedContent", .success, kCFBooleanTrue),
            (kAXSubroleAttribute, .success, "AXSecureTextField" as CFString),
        ]
        for (name, status, raw) in reads {
            XCTAssertThrowsError(try TextCapture.verifiedUnprotectedRole { attribute in
                if attribute == name { return (status, raw) }
                if attribute == kAXRoleAttribute { return (.success, "AXImage" as CFString) }
                return (.attributeUnsupported, nil)
            }, "\(name): \(status)")
        }
    }

    func testWindowLookupSkipsOnlyTheWindowServerCursor() throws {
        let point = CGPoint(x: 150, y: 90)
        func entry(id: CGWindowID, frame: CGRect, owner: pid_t = 43, layer: CGWindowLevel = 0) -> [String: Any] {
            [kCGWindowNumber as String: NSNumber(value: id),
             kCGWindowOwnerPID as String: NSNumber(value: owner),
             kCGWindowLayer as String: NSNumber(value: layer),
             kCGWindowAlpha as String: NSNumber(value: 1.0),
             kCGWindowBounds as String: frame.dictionaryRepresentation,
             kCGWindowSharingState as String: NSNumber(value: CGWindowSharingType.readOnly.rawValue)]
        }
        let cursorLayer = CGWindowLevelForKey(.cursorWindow)
        let cursorFrame = CGRect(x: 145, y: 85, width: 25, height: 25)
        let overlayFrame = CGRect(x: 250, y: 50, width: 100, height: 100)
        let cursor = entry(id: 1, frame: cursorFrame, owner: 42, layer: cursorLayer)
        let overlay = entry(id: 2, frame: overlayFrame)
        let source = entry(id: 3, frame: CGRect(x: 100, y: 50, width: 300, height: 200))
        let isWindowServer: (pid_t) -> Bool = { $0 == 42 }
        let result = try XCTUnwrap(TextCapture.windowAtPoint(point, windows: [cursor, overlay, source],
                                                           isWindowServer: isWindowServer))
        XCTAssertEqual(result.window.id, 3)
        XCTAssertEqual(result.occluders, [overlayFrame])

        let otherCover = entry(id: 4, frame: cursorFrame, layer: cursorLayer)
        XCTAssertEqual(TextCapture.windowAtPoint(point, windows: [cursor, otherCover, source],
                                                isWindowServer: isWindowServer)?.window.id, 4)
        let systemCover = entry(id: 5, frame: cursorFrame, owner: 42)
        XCTAssertEqual(TextCapture.windowAtPoint(point, windows: [cursor, systemCover, source],
                                                isWindowServer: isWindowServer)?.window.id, 5)
    }

    func testOCRCropStaysOnHoveredDisplayAndExcludesOccluders() throws {
        let display = CGRect(x: -1200, y: -400, width: 1200, height: 900)
        let window = CGRect(x: -700, y: -200, width: 760, height: 450)
        let point = CGPoint(x: -400, y: 50)
        let rightOverlay = CGRect(x: -325, y: -200, width: 350, height: 450)
        let upperOverlay = CGRect(x: -700, y: -200, width: 375, height: 120)
        let crop = try XCTUnwrap(TextCapture.ocrCrop(at: point, scope: .paragraph, window: window, display: display,
                                                     occluders: [rightOverlay, upperOverlay]))
        XCTAssertEqual(crop, CGRect(x: -700, y: -80, width: 375, height: 330))
        XCTAssertTrue(crop.contains(point))
        XCTAssertTrue(display.contains(crop))
        XCTAssertTrue(window.contains(crop))
        XCTAssertNil(TextCapture.ocrCrop(at: point, scope: .paragraph, window: window, display: display,
                                         occluders: [CGRect(origin: point, size: CGSize(width: 20, height: 20))]))
    }

    /// A 2x bitmap, two distinct lines, and a display left of the main screen.
    /// No screen permission, accessibility permission, or language pack is used.
    private func fixture() throws -> (CGImage, CGRect, CGPoint) {
        let (image, region) = try renderedFixture(size: CGSize(width: 600, height: 200), lines: [
            ("Hello Wordglide translation", 30, 120, 28),
            ("Another separate line", 30, 55, 28),
        ])
        return (image, region, CGPoint(x: -740, y: 168))
    }

    private func renderedFixture(size: CGSize, lines: [(text: String, x: CGFloat, y: CGFloat, fontSize: CGFloat)]) throws -> (CGImage, CGRect) {
        let context = try XCTUnwrap(CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2),
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: 2, y: 2)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        for line in lines {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, line.fontSize, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ]
            context.textPosition = CGPoint(x: line.x, y: line.y)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line.text, attributes: attributes)), context)
        }
        return (try XCTUnwrap(context.makeImage()), CGRect(origin: CGPoint(x: -800, y: 100), size: size))
    }

    func testCurrentLineAndWordAtRetinaScaleOnSecondaryDisplay() async throws {
        let (image, region, point) = try fixture()
        let lineResult = try await TextCapture.recognize(image: image, region: region, at: point, scope: .sentence)
        let line = try XCTUnwrap(lineResult)
        XCTAssertTrue(line.text.hasPrefix("Hello"), "Unexpected OCR line: \(line.text)")
        XCTAssertFalse(line.text.contains("Another"))
        XCTAssertTrue(line.bounds.insetBy(dx: -4, dy: -4).contains(point))
        let wordResult = try await TextCapture.recognize(image: image, region: region, at: point, scope: .word)
        let word = try XCTUnwrap(wordResult)
        XCTAssertEqual(word.text, "Hello")
        XCTAssertTrue(word.bounds.insetBy(dx: -3, dy: -3).contains(point))
    }

    func testParagraphOCRJoinsWrappedRowsAndExcludesAdjacentText() async throws {
        let (image, region) = try renderedFixture(size: CGSize(width: 900, height: 220), lines: [
            ("About", 30, 182, 26),
            ("The first line introduces the translation feature", 30, 145, 20),
            ("and the second line explains why it stays local", 30, 117, 20),
            ("and ends here.", 30, 89, 20),
            ("Read more", 30, 61, 20),
            ("A neighboring column starts here", 525, 145, 20),
            ("and continues separately", 525, 117, 20),
            ("Another paragraph begins below.", 30, 19, 20),
        ])
        let top = CGPoint(x: region.minX + 70, y: region.minY + 67)
        let bottom = CGPoint(x: region.minX + 70, y: region.minY + 123)
        let firstResult = try await TextCapture.recognize(image: image, region: region, at: top, scope: .paragraph)
        let first = try XCTUnwrap(firstResult)
        let lastResult = try await TextCapture.recognize(image: image, region: region, at: bottom, scope: .paragraph)
        let last = try XCTUnwrap(lastResult)
        XCTAssertEqual(first.text, last.text)
        XCTAssertTrue(first.text.hasPrefix("The first line"), first.text)
        XCTAssertTrue(first.text.contains("second line"), first.text)
        XCTAssertTrue(first.text.hasSuffix("and ends here."), first.text)
        XCTAssertFalse(first.isPartialParagraph)
        XCTAssertTrue(first.bounds.insetBy(dx: -4, dy: -4).contains(top))
        XCTAssertTrue(last.bounds.insetBy(dx: -4, dy: -4).contains(bottom))
    }

    func testParagraphOCRMarksTextNearTheCaptureEdgeAsPartial() async throws {
        let (image, region) = try renderedFixture(size: CGSize(width: 500, height: 110), lines: [
            ("The screenshot clips this paragraph", -4, 68, 24),
            ("and the next row shares that edge", -4, 38, 24),
        ])
        let point = CGPoint(x: region.minX + 80, y: region.minY + 33)
        let result = try await TextCapture.recognize(image: image, region: region, at: point, scope: .paragraph)
        let recognized = try XCTUnwrap(result)
        XCTAssertTrue(recognized.isPartialParagraph, "Recognized \(recognized.text) at \(recognized.bounds)")
    }

    func testParagraphOCRKeepsShortWrappedEndingAtTheSameFontSize() async throws {
        let (image, region) = try renderedFixture(size: CGSize(width: 800, height: 180), lines: [
            ("Wordglide works with TextEdit, Safari, Notes, and so", 34, 117, 24),
            ("on.", 34, 83, 24),
            ("A separate paragraph starts below.", 34, 49, 24),
        ])
        let firstPoint = CGPoint(x: region.minX + 45, y: region.minY + 55)
        let lastPoint = CGPoint(x: region.minX + 45, y: region.minY + 91)
        let firstResult = try await TextCapture.recognize(image: image, region: region, at: firstPoint, scope: .paragraph)
        let lastResult = try await TextCapture.recognize(image: image, region: region, at: lastPoint, scope: .paragraph)
        let first = try XCTUnwrap(firstResult)
        let last = try XCTUnwrap(lastResult)
        XCTAssertEqual(first.text, last.text)
        XCTAssertTrue(first.text.hasPrefix("Wordglide works"), first.text)
        XCTAssertTrue(first.text.hasSuffix("and so on."), first.text)
        XCTAssertFalse(first.isPartialParagraph)
        XCTAssertFalse(last.isPartialParagraph)
    }

    func testBlankSpaceDoesNotSelectNearestLine() async throws {
        let (image, region, _) = try fixture()
        let result = try await TextCapture.recognize(image: image, region: region,
            at: CGPoint(x: region.minX + 400, y: region.maxY - 8), scope: .paragraph)
        XCTAssertNil(result)
        let outside = try await TextCapture.recognize(image: image, region: region,
            at: CGPoint(x: region.minX - 1, y: region.minY), scope: .sentence)
        XCTAssertNil(outside)
    }

    func testNonEnglishRowDoesNotStartAnEnglishOCRHoverInAnyScope() async throws {
        for text in ["我已确认更新源提供 0.3.3。从 Wordglide 菜单栏检查更新。",
                     "今天我們在 Wordglide 確認更新版本 0.3.3。",
                     "今日は日本語の更新案内を Wordglide で確認しています。"] {
            let (image, region) = try renderedFixture(size: CGSize(width: 1050, height: 185), lines: [
                ("Read more about your current installation", 30, 146, 24),
                (text, 30, 105, 24),
                ("English instructions continue below the notice", 30, 64, 24),
            ])
            let point = CGPoint(x: region.minX + 140, y: region.minY + 67)
            for scope in [HoverRecognitionScope.word, .sentence, .paragraph] {
                let result = try await TextCapture.recognize(image: image, region: region, at: point, scope: scope)
                XCTAssertNil(result, "Unexpected English OCR in \(scope): \(result?.text ?? "")")
            }
            let englishPoint = CGPoint(x: point.x, y: point.y - 41)
            let english = try await TextCapture.recognize(image: image, region: region, at: englishPoint, scope: .paragraph)
            XCTAssertEqual(english?.text, "Read more about your current installation")
        }
    }

    func testCancelledOCRDoesNotReturnAResult() async throws {
        let (image, region, point) = try fixture()
        let task = Task { try await TextCapture.recognize(image: image, region: region, at: point, scope: .sentence) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled OCR request must not publish a result")
        } catch is CancellationError { }
        catch { XCTFail("Unexpected cancellation error: \(error)") }
    }

    func testOwnProcessSelectionIsRejectedBeforeAXAccess() async {
        do {
            _ = try await TextCapture.selected(pid: ProcessInfo.processInfo.processIdentifier, fallbackPoint: .zero)
            XCTFail("Own process selection must be rejected")
        } catch CaptureError.ownApplication { }
        catch { XCTFail("Unexpected error: \(error)") }
    }
}
