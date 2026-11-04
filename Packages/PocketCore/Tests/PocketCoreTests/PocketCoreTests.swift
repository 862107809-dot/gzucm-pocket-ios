import Foundation
import XCTest
@testable import PocketCore

final class PocketCoreTests: XCTestCase {
    private let semester = Semester(code: "202601", name: "2026–2027 学年第一学期", firstMonday: "2026-09-07", totalWeeks: 19)
    private func data(_ string: String) -> Data { Data(string.utf8) }
    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    func testUpstreamAnonymizedWeeklyFixtureKeepsDetailedContent() throws {
        let sessions = try SchoolParser.weeklySessions(fixture("week8_sample"), schoolWeek: 8, semester: semester)
        XCTAssertEqual(sessions.count, 3)
        XCTAssertEqual(sessions.first?.content, "性早熟")
        XCTAssertEqual(sessions.first?.resolvedStartTime, "08:30")
        XCTAssertEqual(sessions.last?.date, "2026-10-31")
        XCTAssertEqual(sessions.last?.startUnit, 2)
        XCTAssertEqual(sessions.last?.endUnit, 3)
        XCTAssertTrue(sessions.allSatisfy { $0.week == 8 })
    }
    func testSundayUsesActualDateRatherThanRequestedSchoolWeek() throws {
        let payload = #"{"code":0,"data":[{"kcmc":"测试课","xq":7,"ps":"01","pe":"02","zc":8,"qsrq":"2026-10-25","jxcdmc":" 示例楼101　"}]}"#
        let course = try XCTUnwrap(SchoolParser.weeklySessions(data(payload), schoolWeek: 8, semester: semester).first)
        XCTAssertEqual(course.week, 7)
        XCTAssertEqual(course.weekday, 7)
        XCTAssertEqual(course.room, "示例楼101")
        XCTAssertEqual(SchoolDate.iso(semester.date(week: course.week, weekday: course.weekday)), course.date)
    }
    func testMissingRealDateSundayIsStillAligned() throws {
        let payload = #"{"code":0,"data":[{"kcmc":"测试课","xq":7,"ps":1,"pe":2,"zc":8}]}"#
        let course = try XCTUnwrap(SchoolParser.weeklySessions(data(payload), schoolWeek: 8, semester: semester).first)
        XCTAssertEqual(course.week, 7)
        XCTAssertEqual(course.date, "2026-10-25")
    }
    func testSundayBeforeTermIsExcluded() throws {
        let payload = #"{"code":0,"data":[{"kcmc":"测试课","xq":7,"ps":1,"pe":2,"zc":1,"qsrq":"2026-09-06"}]}"#
        XCTAssertTrue(try SchoolParser.weeklySessions(data(payload), schoolWeek: 1, semester: semester).isEmpty)
    }
    func testLastSundayFromExtraSchoolWeekIsKept() throws {
        let last = semester.date(week: 19, weekday: 7)
        let payload = "{\"code\":0,\"data\":[{\"kcmc\":\"测试课\",\"xq\":7,\"ps\":1,\"pe\":2,\"zc\":20,\"qsrq\":\"\(SchoolDate.iso(last))\"}]}"
        let course = try XCTUnwrap(SchoolParser.weeklySessions(data(payload), schoolWeek: 20, semester: semester).first)
        XCTAssertEqual(course.week, 19)
        XCTAssertEqual(course.date, SchoolDate.iso(last))
    }
    func testWholeSemesterExpandsRoomAndWeeksWithoutLosingSunday() throws {
        let payload = #"{"code":0,"data":[{"kcmc":"测试课","xq":7,"ps":1,"pe":2,"zc":"8,9","jxcdmc2":"示例楼A-8,示例楼B-9"}]}"#
        let sessions = try SchoolParser.semesterSessions(data(payload), semester: semester)
        XCTAssertEqual(sessions.map(\.week), [7, 8])
        XCTAssertEqual(sessions.map(\.room), ["示例楼A", "示例楼B"])
    }
    func testCalendarDerivesMondayFromSundayHeader() throws {
        let result = try SchoolParser.semester(fixture("calendar_sample"), code: "202601")
        XCTAssertEqual(result.firstMonday, "2026-09-07")
        XCTAssertEqual(result.totalWeeks, 19)
        let sunday = try XCTUnwrap(SchoolDate.parse("2026-10-25"))
        XCTAssertEqual(result.week(of: sunday), 7)
    }
    func testInvalidCalendarDoesNotInventDates() {
        XCTAssertThrowsError(try SchoolParser.semester(data(#"{"code":0,"data":[]}"#), code: "202601"))
    }
    func testExpiredJSONIsReportedAsAuthenticationFailure() {
        XCTAssertThrowsError(try SchoolParser.weeklySessions(data(#"{"code": -401,"message":"尚未登录"}"#), schoolWeek: 8, semester: semester)) { error in
            XCTAssertEqual(error as? SchoolClientError, .unauthorized)
        }
    }
    func testMalformedResponseIsNotMistakenForNoCourses() {
        XCTAssertThrowsError(try SchoolParser.weeklySessions(data("<html>登录</html>"), schoolWeek: 8, semester: semester))
        XCTAssertThrowsError(try SchoolParser.weeklySessions(data(#"{"code":0,"data":"error"}"#), schoolWeek: 8, semester: semester))
        XCTAssertThrowsError(try SchoolParser.weeklySessions(data(#"{"code":500,"data":[]}"#), schoolWeek: 8, semester: semester))
        XCTAssertNoThrow(try SchoolParser.weeklySessions(data(#"{"code":0,"data":[]}"#), schoolWeek: 8, semester: semester))
    }
    func testMalformedRowsAreSkippedAndNumericFieldsAccepted() throws {
        let payload = #"{"code":0,"data":[{"kcmc":""},{"kcmc":"坏数据","xq":10,"ps":1},{"kcmc":"有效课","xq":1,"ps":3,"pe":4,"zc":8}]}"#
        let courses = try SchoolParser.weeklySessions(data(payload), schoolWeek: 8, semester: semester)
        XCTAssertEqual(courses.map(\.name), ["有效课"])
        XCTAssertEqual(courses.first?.resolvedStartTime, "10:20")
    }
    func testStableIdentitySurvivesRoundTrip() throws {
        let courses = try SchoolParser.weeklySessions(fixture("week8_sample"), schoolWeek: 8, semester: semester)
        let decoded = try JSONDecoder().decode([CourseSession].self, from: JSONEncoder().encode(courses))
        XCTAssertEqual(decoded.map(\.id), courses.map(\.id))
        XCTAssertEqual(Set(courses.map(\.id)).count, courses.count)
    }
    func testCourseGradesSkipUnpublishedInsteadOfInventingScore() throws {
        let payload = #"{"rows":[{"kcmc":"课程A","zcj":"86","cjjd":3.6,"xf":"2","kcdlmc":"必修"},{"kcmc":"课程B","zcj":"未公布","xf":2}]}"#
        let grades = try SchoolParser.courseGrades(data(payload))
        XCTAssertEqual(grades.count, 1)
        XCTAssertEqual(grades.first?.score, 86)
        XCTAssertEqual(grades.first?.gpa, 3.6)
    }
    func testEstimatedGPAExcludesOptionalAndFailedButIncludesLimitedElective() {
        let grades = [
            CourseGrade(name: "A", score: 80, gpa: 3, credit: 2, category: "必修"),
            CourseGrade(name: "B", score: 90, gpa: 4, credit: 1, category: "限选"),
            CourseGrade(name: "C", score: 100, gpa: 5, credit: 10, category: "公共选修"),
            CourseGrade(name: "D", score: 50, gpa: 0, credit: 2, category: "必修")
        ]
        XCTAssertEqual(GradeStatistics.weightedGPA(grades) ?? 0, 10.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(GradeStatistics.earnedCredits(grades), 13)
        XCTAssertNil(GradeStatistics.weightedGPA([]))
    }
    func testFitnessDoesNotRetainUnrelatedPersonalFields() throws {
        let payload = #"{"rows":[{"xnxqmc":"2026","zf":"85","dj":"良好","sg":"170","fhl":"4200","fhlpf":"90","sfzh":"not-retained","lxdh":"not-retained"}]}"#
        let fitness = try SchoolParser.fitnessGrades(data(payload))
        let text = String(decoding: try JSONEncoder().encode(fitness), as: UTF8.self)
        XCTAssertFalse(text.contains("not-retained"))
        XCTAssertEqual(fitness.first?.items.count, 2)
    }
    func testMissingAndNonfiniteGPAIsNotSubstitutedWithZero() throws {
        let payload = #"{"rows":[{"kcmc":"已知绩点","zcj":90,"cjjd":4,"xf":2},{"kcmc":"缺失绩点","zcj":85,"xf":6},{"kcmc":"无效绩点","zcj":80,"cjjd":"NaN","xf":6}]}"#
        let grades = try SchoolParser.courseGrades(data(payload))
        XCTAssertEqual(grades.map(\.gpaAvailable), [true, false, false])
        XCTAssertEqual(GradeStatistics.weightedGPA(grades), 4)
        XCTAssertEqual(GradeStatistics.earnedCredits(grades), 14)
    }
    func testNumericSentinelsAndExtremeWeekNumbersDoNotBecomeDates() throws {
        let payload = #"{"code":0,"data":[{"kcmc":"测试课","xq":7,"ps":1,"pe":2,"zc":"-9223372036854775808,9223372036854775807,8"}]}"#
        let courses = try SchoolParser.weeklySessions(data(payload), schoolWeek: 8, semester: semester)
        XCTAssertEqual(courses.map(\.week), [7])
        let grid = #"{"rows":[{"jcid":"-9223372036854775808","z1":"坏数据"}]}"#
        XCTAssertTrue(try SchoolParser.graduateSessions(data(grid), requestedWeek: 2).isEmpty)
        let grades = try SchoolParser.courseGrades(data(#"{"rows":[{"kcmc":"未公布","zcj":-1},{"kcmc":"无效","zcj":"Infinity"}]}"#))
        XCTAssertTrue(grades.isEmpty)
        let overflowing = [CourseGrade(name: "A", score: 80, gpa: 1e308, credit: 100)]
        XCTAssertNil(GradeStatistics.weightedGPA(overflowing))
    }
    func testLevelSubscoreZeroIsPreserved() throws {
        let levels = try SchoolParser.levelGrades(data(#"{"rows":[{"kjkcmc":"示例考试","zcj":"400","xm1cj":"0"}]}"#))
        XCTAssertEqual(levels.first?.parts.first?.value, "0")
    }
    func testGraduateSelectedTermAcceptsBooleanAndNumericCodes() throws {
        let terms = try SchoolParser.graduateTerms(data(#"[{"termcode":48,"termname":"2026 秋","selected":true},{"termcode":47,"termname":"2026 春","selected":false}]"#))
        XCTAssertEqual(terms.first?.code, "48")
        XCTAssertEqual(terms.first?.selected, true)
    }
    func testGraduateGridMergesAdjacentUnitsAndKeepsRealDates() throws {
        let sessions = try SchoolParser.graduateSessions(fixture("graduate_week_sample"), requestedWeek: 2)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.name, "医学分子生物学基础")
        XCTAssertEqual(sessions.first?.startUnit, 1)
        XCTAssertEqual(sessions.first?.endUnit, 2)
        XCTAssertEqual(sessions.first?.resolvedEndTime, "10:00")
        XCTAssertEqual(sessions.first?.weekday, 1)
        let inferred = try SchoolParser.graduateSemester(term: GraduateTerm(code: "48", name: "2026 秋"), sessions: sessions)
        XCTAssertEqual(inferred.firstMonday, "2026-09-07")
    }
    func testGraduateDoesNotCombineAcrossLunchOrLoseDifferentRooms() {
        let courses = [
            CourseSession(name: "课程", teachers: "教师甲", week: 2, weekday: 1, startUnit: 1, endUnit: 1, room: "教室A", date: "2026-09-14", campus: .graduate),
            CourseSession(name: "课程", teachers: "教师乙", week: 2, weekday: 1, startUnit: 2, endUnit: 2, room: "教室B", date: "2026-09-14", campus: .graduate),
            CourseSession(name: "课程", week: 2, weekday: 1, startUnit: 6, endUnit: 6, date: "2026-09-14", campus: .graduate)
        ]
        let merged = SchoolParser.mergeGraduateSessions(courses)
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged.first?.room, "教室A / 教室B")
        XCTAssertEqual(merged.first?.teachers, "教师甲 / 教师乙")
    }
    func testGraduateHTMLWithTwoCoursesAndMissingBreakSeparatesTitles() {
        let html = "2026级示例班-课程甲甲<br/>[7-7周] 2026-10-21 教师甲[示例楼101]  2026级示例班-课程乙乙<br/>[7-7周]2026-10-21 教师乙[示例楼102]"
        let sessions = SchoolParser.graduateCell(html, weekday: 3, unit: 6, requestedWeek: 7)
        XCTAssertEqual(sessions.map(\.name), ["课程甲甲", "课程乙乙"])
        XCTAssertEqual(sessions.map(\.room), ["示例楼101", "示例楼102"])
    }
    func testGraduateEmptyDataDoesNotInventTermStart() {
        XCTAssertThrowsError(try SchoolParser.graduateSemester(term: GraduateTerm(code: "48", name: "秋"), sessions: []))
    }
    func testSemesterCodesAndNamesFollowAcademicYear() throws {
        let spring = try XCTUnwrap(SchoolDate.parse("2026-03-01"))
        XCTAssertEqual(SchoolParser.semesterCode(for: spring), "202502")
        XCTAssertEqual(SchoolParser.semesterName("202502"), "2025–2026 学年第二学期")
        XCTAssertEqual(SchoolParser.previousSemesterCode("202601"), "202502")
        XCTAssertFalse(SchoolParser.validSemesterCode("48"))
        XCTAssertTrue(SchoolParser.validSemesterCode("202601"))
    }
    func testDatesRejectImpossibleCalendarValues() {
        XCTAssertNil(SchoolDate.parse("2026-02-30"))
        XCTAssertNil(SchoolDate.parse("not-date"))
        XCTAssertEqual(SchoolDate.parse("2026-10-26 08:30:00").map(SchoolDate.iso), "2026-10-26")
    }
    func testSchoolDateDisplayKeepsMondayAcrossHostTimeZones() throws {
        // XCTest runs this case serially. Restore the process-local default even if an assertion fails.
        let originalTimeZone = NSTimeZone.default
        defer { NSTimeZone.default = originalTimeZone }
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-01T16:00:00Z"))
        let locale = Locale(identifier: "zh_CN")
        for identifier in ["UTC", "America/New_York"] {
            NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: identifier))
            // The same instant is Sunday on these hosts, but Monday midnight at school.
            XCTAssertEqual(SchoolDate.display(instant, template: "MMMd", locale: locale), "11月2日", identifier)
            XCTAssertEqual(SchoolDate.display(instant, template: "d", locale: locale), "2日", identifier)
            XCTAssertEqual(SchoolDate.display(instant, template: "EEEE", locale: locale), "星期一", identifier)
        }
    }
    func testTodayHeaderUsesShanghaiDateAtMidnightBoundary() throws {
        let originalTimeZone = NSTimeZone.default
        defer { NSTimeZone.default = originalTimeZone }
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-02T16:30:00Z"))
        let locale = Locale(identifier: "zh_CN")
        for identifier in ["UTC", "America/New_York"] {
            NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: identifier))
            XCTAssertEqual(SchoolDate.iso(instant), "2026-11-03", identifier)
            XCTAssertEqual(SchoolDate.display(instant, template: "MMMd", locale: locale), "11月3日", identifier)
            XCTAssertEqual(SchoolDate.display(instant, template: "EEEE", locale: locale), "星期二", identifier)
            let header = SchoolDate.display(instant, template: "MMMMdEEEE", locale: locale)
            XCTAssertTrue(header.contains("11月3日") && header.contains("星期二"), header)
        }
    }
    func testSchoolPeriodTimesIncludeFourteenConsecutiveUnits() {
        XCTAssertEqual(ClassTimes.start(5), "13:10")
        XCTAssertEqual(ClassTimes.start(10), "17:20")
        XCTAssertEqual(ClassTimes.end(14), "21:20")
        XCTAssertEqual(ClassTimes.start(0), "")
        XCTAssertNil(ClassTimes.minutes("25:10"))
    }
    func testFormEncodingDoesNotTreatPlusOrAmpersandAsSyntax() {
        XCTAssertEqual(SchoolClient.formEncoded(["room": "A+B&中"]), "room=A%2BB%26%E4%B8%AD")
    }
}
