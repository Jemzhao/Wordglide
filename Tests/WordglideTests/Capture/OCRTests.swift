import AppKit
import CoreText
import XCTest
@testable import Wordglide

final class OCRTests: XCTestCase {
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
