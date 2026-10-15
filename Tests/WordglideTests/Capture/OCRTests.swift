import AppKit
import CoreText
import XCTest
@testable import Wordglide

final class OCRTests: XCTestCase {
    /// A 2x bitmap, two distinct lines, and a display left of the main screen.
    /// No screen permission, accessibility permission, or language pack is used.
    private func fixture() throws -> (CGImage, CGRect, CGPoint) {
        let context = try XCTUnwrap(CGContext(data: nil, width: 1_200, height: 400,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: 2, y: 2)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 600, height: 200))
        let font = CTFontCreateWithName("Helvetica" as CFString, 28, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ]
        context.textPosition = CGPoint(x: 30, y: 120)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Hello Wordglide translation", attributes: attributes)), context)
        context.textPosition = CGPoint(x: 30, y: 55)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Another separate line", attributes: attributes)), context)
        let region = CGRect(x: -800, y: 100, width: 600, height: 200)
        return (try XCTUnwrap(context.makeImage()), region, CGPoint(x: -740, y: 168))
    }

    func testCurrentLineAndWordAtRetinaScaleOnSecondaryDisplay() async throws {
        let (image, region, point) = try fixture()
        let lineResult = try await TextCapture.recognize(image: image, region: region, at: point, word: false)
        let line = try XCTUnwrap(lineResult)
        XCTAssertTrue(line.text.hasPrefix("Hello"), "Unexpected OCR line: \(line.text)")
        XCTAssertFalse(line.text.contains("Another"))
        XCTAssertTrue(line.bounds.insetBy(dx: -4, dy: -4).contains(point))
        let wordResult = try await TextCapture.recognize(image: image, region: region, at: point, word: true)
        let word = try XCTUnwrap(wordResult)
        XCTAssertEqual(word.text, "Hello")
        XCTAssertTrue(word.bounds.insetBy(dx: -3, dy: -3).contains(point))
    }

    func testBlankSpaceDoesNotSelectNearestLine() async throws {
        let (image, region, _) = try fixture()
        let result = try await TextCapture.recognize(image: image, region: region,
            at: CGPoint(x: region.minX + 400, y: region.maxY - 8), word: false)
        XCTAssertNil(result)
        let outside = try await TextCapture.recognize(image: image, region: region,
            at: CGPoint(x: region.minX - 1, y: region.minY), word: false)
        XCTAssertNil(outside)
    }

    func testCancelledOCRDoesNotReturnAResult() async throws {
        let (image, region, point) = try fixture()
        let task = Task { try await TextCapture.recognize(image: image, region: region, at: point, word: false) }
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
