import XCTest

/// Launch and content smoke checks using explicit, fictional demo data.
/// Screenshots are evidence for review, not assertions about glass rendering or fold poses.
@MainActor
final class GZUCMPocketUITests: XCTestCase {
    func testTodayDemo() async {
        await checkDemo(tab: "today", marker: "today-header")
    }

    func testNativeLoginOffersQRAndOfficialPasswordModes() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--login-preview", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }
        let qr = app.buttons["教务登录方式-0"]
        let password = app.buttons["教务登录方式-1"]
        XCTAssertTrue(qr.waitForExistence(timeout: 15))
        XCTAssertTrue(password.exists)
        XCTAssertTrue(app.descendants(matching: .any)["school-qr-panel"].exists)
        password.tap()
        XCTAssertTrue(app.descendants(matching: .any)["school-password-panel"].waitForExistence(timeout: 5))
        qr.tap()
        XCTAssertTrue(app.descendants(matching: .any)["school-qr-panel"].waitForExistence(timeout: 5))
    }

    func testScheduleAtDefaultTextSize() async {
        // Capture the everyday appearance separately from the accessibility stress case.
        // The week selector should leave useful space for the course list at default text size.
        await checkDemo(tab: "schedule", marker: "schedule-week-control", maximumMarkerHeight: 100)
    }

    func testScheduleWithAccessibilityText() async {
        await checkDemo(tab: "schedule", marker: "schedule-week-control", arguments: ["--large-text"])
    }

    func testGradesInDarkMode() async {
        await checkDemo(tab: "grades", marker: "grades-summary", arguments: ["--dark"])
    }

    func testPowerInDarkMode() async {
        await checkDemo(tab: "power", marker: "power-balance", arguments: ["--dark"])
    }

    func testMonthScheduleAndCourseDetails() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--tab", "schedule", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }
        let month = app.buttons["课表视图-2"]
        XCTAssertTrue(month.waitForExistence(timeout: 15))
        month.tap()
        let calendar = app.descendants(matching: .any)["schedule-month-calendar"]
        XCTAssertTrue(calendar.waitForExistence(timeout: 5))
        let days = app.buttons.matching(NSPredicate(format: "label MATCHES %@", "[0-9]{4}-[0-9]{2}-[0-9]{2}，[0-9]+ 门课程"))
        XCTAssertGreaterThanOrEqual(days.count, 28)
        let day = days.allElementsBoundByIndex.first { $0.isHittable }
        XCTAssertNotNil(day)
        day?.tap()
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "month-calendar-sunday-first"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Return to daily view so persistence doesn't change later tests.
        app.buttons["日课表"].tap()
    }

    func testSundaySelectionSurvivesPageReentry() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--tab", "schedule", "-scheduleLayout", "0", "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        app.launch()
        defer { app.terminate() }
        let sundays = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", " 周日"))
        XCTAssertTrue(sundays.firstMatch.waitForExistence(timeout: 15))
        let before = sundays.firstMatch.label
        sundays.firstMatch.tap()
        let today = app.tabBars.buttons["今日"].exists ? app.tabBars.buttons["今日"] : app.buttons["今日"].firstMatch
        today.tap()
        let schedule = app.tabBars.buttons["课表"].exists ? app.tabBars.buttons["课表"] : app.buttons["课表"].firstMatch
        schedule.tap()
        XCTAssertTrue(sundays.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(sundays.firstMatch.label, before, "Switching pages must not advance the selected Sunday")
    }

    private func checkDemo(tab: String, marker: String, arguments: [String] = [], maximumMarkerHeight: CGFloat? = nil, file: StaticString = #filePath, line: UInt = #line) async {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--tab", tab, "-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"] + arguments
        app.launch()
        defer { app.terminate() }
        let banners = app.descendants(matching: .any).matching(identifier: "demo-banner")
        let bannerAppeared = banners.firstMatch.waitForExistence(timeout: 15)
        let loginButtons = app.buttons.matching(identifier: "demo-login-button")
        let content = app.descendants(matching: .any).matching(identifier: marker).firstMatch
        let contentAppeared = content.waitForExistence(timeout: 15)
        // ViewThatFits and TabView can expose several passive label candidates.
        // The disclaimer must occupy screen space; the actual login action must
        // have exactly one hittable instance. Do not require a composite Label
        // itself to expose a tap point or blindly select its first candidate.
        let bannerVisible = await waitUntil { hasVisibleDisclaimer(banners, screen: app.frame) }
        let loginHittable = await waitUntil { hittableCount(loginButtons) == 1 }
        let contentHittable = await waitUntil { content.exists && content.isHittable }
        let evidenceName = ([tab] + arguments.map { $0.replacingOccurrences(of: "--", with: "") }).joined(separator: "-")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = evidenceName
        attachment.lifetime = .keepAlways
        add(attachment)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = evidenceName + "-accessibility-hierarchy"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTAssertTrue(bannerAppeared, "Fictional demo banner did not appear", file: file, line: line)
        XCTAssertTrue(contentAppeared, "Demo content missing for \(tab): \(marker)", file: file, line: line)
        XCTAssertTrue(bannerVisible && hasVisibleDisclaimer(banners, screen: app.frame), "Fictional demo disclaimer has no positive frame intersecting the screen on \(tab)", file: file, line: line)
        XCTAssertTrue(loginHittable && hittableCount(loginButtons) == 1, "Expected exactly one visible, unobscured demo login button on \(tab)", file: file, line: line)
        XCTAssertTrue(contentHittable && content.isHittable, "Demo content is clipped or obscured for \(tab): \(marker)", file: file, line: line)
        if let maximumMarkerHeight {
            XCTAssertLessThanOrEqual(content.frame.height, maximumMarkerHeight, "Default-size schedule controls leave too little space for courses", file: file, line: line)
        }
    }

    private func hasVisibleDisclaimer(_ query: XCUIElementQuery, screen: CGRect) -> Bool {
        query.allElementsBoundByIndex.contains { element in
            guard element.exists else { return false }
            let frame = element.frame
            guard !frame.isNull, !frame.isInfinite, frame.width > 0, frame.height > 0 else { return false }
            let intersection = frame.intersection(screen)
            return !intersection.isNull && intersection.width > 0 && intersection.height > 0
        }
    }

    private func hittableCount(_ query: XCUIElementQuery) -> Int {
        query.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }.count
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            do { try await Task.sleep(nanoseconds: 100_000_000) }
            catch { return false }
        }
        return true
    }

}
