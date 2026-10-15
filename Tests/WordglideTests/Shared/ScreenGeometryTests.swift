import AppKit
import XCTest
@testable import Wordglide

/// Deterministic display fixtures only: these checks never query NSScreen,
/// capture the desktop, or require any permission or language pack.
final class ScreenGeometryTests: XCTestCase {
    private let primary = ScreenGeometry(id: 1,
        frame: CGRect(x: 0, y: 0, width: 1_440, height: 900))

    private func assertContained(_ frame: CGRect, in safe: CGRect,
                                 file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(frame.minX, safe.minX - 0.001, file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, safe.minY - 0.001, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxX, safe.maxX + 0.001, file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, safe.maxY + 0.001, file: file, line: line)
    }

    private func metrics(in visible: CGRect, showsSource: Bool = true,
                         loading: Bool = false, choosing: Bool = false,
                         failure: Bool = false, hasMessage: Bool = true) -> CardLayout.Metrics {
        CardLayout.metrics(
            source: String(repeating: "A long original sentence with enough words to wrap. ", count: 100),
            result: String(repeating: "这是一段需要滚动阅读的长译文。", count: 300),
            showsSource: showsSource, loading: loading, choosing: choosing,
            failure: failure, hasMessage: hasMessage, visibleFrame: visible)
    }

    func testCoordinateConversionsRoundTripAboveAndLeftOfPrimaryWithFractionalPoints() {
        let desktopTop: CGFloat = 900
        let fixtures: [(cocoa: CGPoint, quartz: CGPoint)] = [
            (CGPoint(x: 500.25, y: 1_100.75), CGPoint(x: 500.25, y: -200.75)),
            (CGPoint(x: -900.25, y: 1_100.75), CGPoint(x: -900.25, y: -200.75)),
            (CGPoint(x: -900.25, y: -250.75), CGPoint(x: -900.25, y: 1_150.75)),
            (CGPoint(x: 1_800.25, y: 500.75), CGPoint(x: 1_800.25, y: 399.25))
        ]
        for fixture in fixtures {
            let quartz = TextLogic.quartzPoint(fixture.cocoa, desktopTop: desktopTop)
            XCTAssertEqual(quartz, fixture.quartz)
            XCTAssertEqual(TextLogic.quartzPoint(quartz, desktopTop: desktopTop), fixture.cocoa)

            let cocoaRect = CGRect(origin: fixture.cocoa, size: CGSize(width: 40.5, height: 20.25))
            let quartzRect = CGRect(x: fixture.quartz.x, y: fixture.quartz.y - 20.25,
                                    width: 40.5, height: 20.25)
            XCTAssertEqual(TextLogic.cocoaRect(quartzRect, desktopTop: desktopTop), cocoaRect)
            XCTAssertEqual(TextLogic.cocoaRect(cocoaRect, desktopTop: desktopTop), quartzRect)
        }
    }

    func testMenuBarPointerAnchorStaysOnItsDisplayInsteadOfSelectingDisplayAbove() {
        let above = ScreenGeometry(id: 2,
            frame: CGRect(x: 0, y: 900, width: 1_440, height: 900), scale: 2)
        let pointer = CGPoint(x: 500, y: 895)
        let anchor = ScreenGeometry.pointerAnchor(pointer)

        XCTAssertEqual(anchor, CGRect(x: 496, y: 886, width: 8, height: 18))
        XCTAssertEqual(CGPoint(x: anchor.midX, y: anchor.midY), pointer)
        XCTAssertEqual(ScreenGeometry.resolve(screens: [primary, above], anchor: anchor)?.id, primary.id)
        XCTAssertEqual(ScreenGeometry.resolve(screens: [above, primary], point: pointer, anchor: anchor)?.id, primary.id)
    }

    func testExplicitTriggerPointTakesPriorityOverLargerAnchorOverlap() {
        let left = ScreenGeometry(id: 2,
            frame: CGRect(x: -1_200, y: 0, width: 1_200, height: 900), scale: 1.5)
        let anchor = CGRect(x: -50, y: 300, width: 800, height: 40)
        XCTAssertEqual(ScreenGeometry.resolve(screens: [primary, left],
            point: CGPoint(x: -25.25, y: 320.25), anchor: anchor)?.id, left.id)
    }

    func testAnchorWithCenterInDisplayGapUsesLargestIntersection() {
        let left = ScreenGeometry(id: 2,
            frame: CGRect(x: -1_200, y: 0, width: 1_000, height: 900))
        let right = ScreenGeometry(id: 1,
            frame: CGRect(x: 200, y: 0, width: 1_440, height: 900))
        let anchor = CGRect(x: -600, y: 300, width: 900, height: 40)
        let center = CGPoint(x: anchor.midX, y: anchor.midY)

        XCTAssertFalse(left.frame.contains(center))
        XCTAssertFalse(right.frame.contains(center))
        XCTAssertEqual(anchor.intersection(left.frame).width, 400)
        XCTAssertEqual(anchor.intersection(right.frame).width, 100)
        XCTAssertEqual(ScreenGeometry.resolve(screens: [right, left], anchor: anchor)?.id, left.id)
    }

    func testRemovedDisplayAnchorChoosesNearestRemainingDisplayInsteadOfFirstDisplay() {
        let upperLeft = ScreenGeometry(id: 2,
            frame: CGRect(x: -1_500, y: 900, width: 1_200, height: 900))
        // This anchor belonged to a display above upperLeft, now removed.
        let anchor = CGRect(x: -1_400, y: 1_950, width: 20, height: 20)
        let pointer = CGPoint(x: anchor.midX, y: anchor.midY)

        XCTAssertEqual(ScreenGeometry.resolve(screens: [primary, upperLeft], anchor: anchor)?.id, upperLeft.id)
        XCTAssertEqual(ScreenGeometry.resolve(screens: [primary, upperLeft],
            point: pointer, anchor: anchor)?.id, upperLeft.id)
        XCTAssertNil(ScreenGeometry.resolve(screens: [], point: pointer, anchor: anchor))
    }

    func testConstrainedFrameRepairsSeventyPointBottomOverflowOnShortDisplay() {
        let visible = CGRect(x: 1_440, y: 0, width: 900, height: 500)
        let safe = ScreenGeometry.safeFrame(visible: visible)
        let old = CGRect(x: 1_490, y: -58, width: 520, height: 546)
        XCTAssertEqual(safe.minY - old.minY, 70)

        let constrained = ScreenGeometry.constrainedFrame(old, visible: visible)
        XCTAssertEqual(constrained.width, 520)
        XCTAssertEqual(constrained.height, 476)
        assertContained(constrained, in: safe)
    }

    @MainActor
    func testMovingLongCardFromTallToShortDisplayRecomputesContentAndWindowTogether() {
        let tall = CGRect(x: -1_440, y: 0, width: 1_440, height: 1_000)
        let short = CGRect(x: 0, y: -500, width: 900, height: 500)
        let tallMetrics = metrics(in: tall)
        let shortMetrics = metrics(in: short)
        let safe = ScreenGeometry.safeFrame(visible: short)

        XCTAssertTrue(CardLayout.canPresent(in: short))
        XCTAssertGreaterThan(tallMetrics.height, shortMetrics.height)
        XCTAssertGreaterThan(shortMetrics.sourceHeight, 0)
        XCTAssertGreaterThan(shortMetrics.bodyHeight, 0)
        XCTAssertLessThanOrEqual(shortMetrics.height, safe.height)
        // The content itself must fit; limiting only the NSPanel frame would
        // silently clip the footer or the replacement feedback below it.
        let contentHeight = CardLayout.headerHeight + CardLayout.footerHeight
            + CardLayout.bodyVerticalPadding * 2 + CardLayout.sourceGap
            + CardLayout.replacementMessageHeight
            + shortMetrics.sourceHeight + shortMetrics.bodyHeight
        XCTAssertEqual(shortMetrics.height, contentHeight, accuracy: 0.001)

        let size = CGSize(width: shortMetrics.width, height: shortMetrics.height)
        let frame = TextLogic.panelFrame(
            anchor: CGRect(x: 880, y: -490, width: 8, height: 18), size: size, visible: short)
        XCTAssertEqual(frame.size, size)
        assertContained(frame, in: safe)
    }

    @MainActor
    func testNarrowDisplayConstrainsActualContentWidthToFourHundredFiftySixPoints() {
        let visible = CGRect(x: -480, y: 100, width: 480, height: 800)
        let layout = metrics(in: visible)
        XCTAssertEqual(layout.width, 456)
        let size = CGSize(width: layout.width, height: layout.height)
        let frame = TextLogic.panelFrame(
            anchor: CGRect(x: -10, y: 120, width: 8, height: 18), size: size, visible: visible)

        XCTAssertEqual(frame.size, size)
        assertContained(frame, in: ScreenGeometry.safeFrame(visible: visible))
    }

    @MainActor
    func testSupportedMinimumAndEveryCardStateRespectTheSameViewportBudget() {
        XCTAssertEqual(CardLayout.minimumContentSize, CGSize(width: 320, height: 260))
        let visible = CGRect(x: -344, y: -284, width: 344, height: 284)
        XCTAssertTrue(CardLayout.canPresent(in: visible))
        XCTAssertFalse(CardLayout.canPresent(in: CGRect(x: 0, y: 0, width: 343, height: 284)))
        XCTAssertFalse(CardLayout.canPresent(in: CGRect(x: 0, y: 0, width: 344, height: 283)))
        let safe = ScreenGeometry.safeFrame(visible: visible)

        for sourceVisible in [false, true] {
            for state in [(false, false, false), (true, false, false),
                          (false, true, false), (false, false, true)] {
                let layout = metrics(in: visible, showsSource: sourceVisible,
                    loading: state.0, choosing: state.1, failure: state.2)
                XCTAssertLessThanOrEqual(layout.width, safe.width)
                XCTAssertLessThanOrEqual(layout.height, safe.height)
                XCTAssertGreaterThanOrEqual(layout.bodyHeight, 0)
                XCTAssertGreaterThanOrEqual(layout.sourceHeight, 0)
                if !sourceVisible { XCTAssertEqual(layout.sourceHeight, 0) }
            }
        }
    }

    @MainActor
    func testUnsupportedTinyViewportsRemainFiniteAndExplicitlyDeclinePresentation() {
        for visible in [CGRect.zero,
                        CGRect(x: -20.25, y: 900.25, width: 20, height: 20),
                        CGRect(x: -100, y: -100, width: 100, height: 100)] {
            XCTAssertFalse(CardLayout.canPresent(in: visible))
            let safe = ScreenGeometry.safeFrame(visible: visible)
            XCTAssertGreaterThanOrEqual(safe.width, 0)
            XCTAssertGreaterThanOrEqual(safe.height, 0)
            let layout = metrics(in: visible)
            for dimension in [layout.width, layout.height, layout.sourceHeight, layout.bodyHeight] {
                XCTAssertTrue(dimension.isFinite)
                XCTAssertGreaterThanOrEqual(dimension, 0)
            }
            // AppKit refuses these viewports before showing a card. The
            // fallback metrics need to remain finite, not render a footer
            // in an area smaller than the supported fixed controls.
        }
    }
}
