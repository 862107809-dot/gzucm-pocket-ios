import XCTest

/// Launch and content smoke checks using explicit, fictional demo data.
/// Screenshots are evidence for review, not assertions about glass rendering or fold poses.
@MainActor
final class GZUCMPocketUITests: XCTestCase {
    func testTodayDemo() {
        checkDemo(tab: "today", marker: "today-header")
    }

    func testScheduleWithAccessibilityText() {
        checkDemo(tab: "schedule", marker: "schedule-week-control", arguments: ["--large-text"])
    }

    func testGradesInDarkMode() {
        checkDemo(tab: "grades", marker: "grades-summary", arguments: ["--dark"])
    }

    func testPowerInDarkMode() {
        checkDemo(tab: "power", marker: "power-balance", arguments: ["--dark"])
    }

    private func checkDemo(tab: String, marker: String, arguments: [String] = [], file: StaticString = #filePath, line: UInt = #line) {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--tab", tab, "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] + arguments
        app.launch()
        defer { app.terminate() }
        let banner = app.descendants(matching: .any).matching(identifier: "demo-banner").firstMatch
        let bannerAppeared = banner.waitForExistence(timeout: 15)
        let content = app.descendants(matching: .any).matching(identifier: marker).firstMatch
        let contentAppeared = content.waitForExistence(timeout: 15)
        // Existence alone also passes for clipped or obscured accessibility
        // elements. Wait for the banner and the visible page marker to settle.
        let bannerHittable = waitForHittable(banner)
        let contentHittable = waitForHittable(content)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = ([tab] + arguments.map { $0.replacingOccurrences(of: "--", with: "") }).joined(separator: "-")
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertTrue(bannerAppeared, "Fictional demo banner did not appear", file: file, line: line)
        XCTAssertTrue(contentAppeared, "Demo content missing for \(tab): \(marker)", file: file, line: line)
        XCTAssertTrue(bannerHittable && banner.isHittable, "Fictional demo banner is clipped or obscured on \(tab)", file: file, line: line)
        XCTAssertTrue(contentHittable && content.isHittable, "Demo content is clipped or obscured for \(tab): \(marker)", file: file, line: line)
    }

    private func waitForHittable(_ element: XCUIElement) -> Bool {
        let predicate = NSPredicate(format: "exists == true AND hittable == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        // XCTWaiter reports a timeout without failing early, so a screenshot
        // is retained above even when a visibility assertion will fail.
        return XCTWaiter.wait(for: [expectation], timeout: 8) == .completed
    }
}
