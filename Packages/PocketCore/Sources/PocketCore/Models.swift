import Foundation

public enum Campus: String, Codable, CaseIterable, Sendable, Identifiable {
    case undergraduate, graduate
    public var id: String { rawValue }
    public var title: String { self == .undergraduate ? "本科生" : "研究生" }
    public var shortTitle: String { self == .undergraduate ? "本科" : "研究生" }
}

/// All school dates use Guangzhou time, independent of the device's timezone.
public enum SchoolDate {
    public static var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        value.firstWeekday = 2
        return value
    }
    public static func parse(_ value: String) -> Date? {
        let prefix = String(value.prefix(10))
        let fields = prefix.split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[0].count == 4, fields[1].count == 2, fields[2].count == 2,
              let year = Int(fields[0]), let month = Int(fields[1]), let day = Int(fields[2]),
              let result = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              iso(result) == prefix else { return nil }
        return result
    }
    public static func iso(_ date: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
    /// Display school calendar dates in Guangzhou even when the device uses another timezone/calendar.
    /// A per-call formatter keeps this synchronous helper safe across UI and background tasks.
    public static func display(_ date: Date, template: String, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }
    public static func addingDays(_ count: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: count, to: date) ?? date
    }
    public static func weekday(_ date: Date) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7 + 1
    }
    public static func monday(of date: Date) -> Date {
        addingDays(1 - weekday(date), to: calendar.startOfDay(for: date))
    }
}

// Length-prefixing avoids collisions even when a source field contains a separator.
private func stableID(_ fields: [String]) -> String {
    fields.map { "\($0.utf8.count):\($0)" }.joined()
}

public struct Semester: Codable, Hashable, Sendable {
    public var code: String
    public var name: String
    public var firstMonday: String
    public var totalWeeks: Int
    public init(code: String, name: String, firstMonday: String, totalWeeks: Int) {
        self.code = code; self.name = name; self.firstMonday = firstMonday; self.totalWeeks = totalWeeks
    }
    public func week(of date: Date) -> Int {
        guard let start = SchoolDate.parse(firstMonday) else { return 0 }
        let days = SchoolDate.calendar.dateComponents([.day], from: start, to: SchoolDate.calendar.startOfDay(for: date)).day ?? 0
        return days < 0 ? 0 : days / 7 + 1
    }
    public func date(week: Int, weekday: Int) -> Date {
        SchoolDate.addingDays((week - 1) * 7 + weekday - 1, to: SchoolDate.parse(firstMonday) ?? Date(timeIntervalSince1970: 0))
    }
    /// UI weeks run Sunday–Saturday; course records keep their official
    /// Monday-based week. The final visual week retains the last Sunday.
    public func sundayFirstWeek(of date: Date) -> Int {
        let visualWeek = week(of: date) + (SchoolDate.weekday(date) == 7 ? 1 : 0)
        return min(max(visualWeek, 1), max(1, totalWeeks + 1))
    }
    public func sundayFirstDate(week: Int, weekday: Int) -> Date {
        let monday = date(week: week, weekday: 1)
        return SchoolDate.addingDays(weekday == 7 ? -1 : weekday - 1, to: monday)
    }
}

public enum ClassTimes {
    public static let starts = ["08:30", "09:20", "10:20", "11:10", "13:10", "14:00", "14:50", "15:40", "16:30", "17:20", "18:10", "19:00", "19:50", "20:40"]
    public static func start(_ unit: Int) -> String { (1...14).contains(unit) ? starts[unit - 1] : "" }
    public static func end(_ unit: Int) -> String {
        guard let minutes = Self.minutes(start(unit)) else { return "" }
        return String(format: "%02d:%02d", (minutes + 40) / 60, (minutes + 40) % 60)
    }
    public static func minutes(_ time: String) -> Int? {
        let fields = time.split(separator: ":")
        guard fields.count >= 2, let hour = Int(fields[0]), let minute = Int(fields[1]), (0..<24).contains(hour), (0..<60).contains(minute) else { return nil }
        return hour * 60 + minute
    }
}

public struct CourseSession: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var code: String
    public var teachers: String
    public var week: Int
    public var weekday: Int
    public var startUnit: Int
    public var endUnit: Int
    public var startTime: String
    public var endTime: String
    public var room: String
    public var content: String
    public var category: String
    public var teachingMode: String
    public var mergedClasses: String
    public var date: String
    public var campus: Campus
    public var id: String { stableID([campus.rawValue, code, name, String(week), String(weekday), String(startUnit), String(endUnit), date, teachers, room, mergedClasses, content]) }
    public var resolvedStartTime: String { startTime.isEmpty ? ClassTimes.start(startUnit) : startTime }
    public var resolvedEndTime: String { endTime.isEmpty ? ClassTimes.end(endUnit) : endTime }
    public init(name: String, code: String = "", teachers: String = "", week: Int, weekday: Int, startUnit: Int, endUnit: Int, startTime: String = "", endTime: String = "", room: String = "", content: String = "", category: String = "", teachingMode: String = "", mergedClasses: String = "", date: String = "", campus: Campus = .undergraduate) {
        self.name = name; self.code = code; self.teachers = teachers; self.week = week; self.weekday = weekday
        self.startUnit = startUnit; self.endUnit = endUnit; self.startTime = startTime; self.endTime = endTime
        self.room = room; self.content = content; self.category = category; self.teachingMode = teachingMode
        self.mergedClasses = mergedClasses; self.date = date; self.campus = campus
    }
}

public struct CourseGrade: Codable, Hashable, Sendable, Identifiable {
    public var term: String
    public var name: String
    public var score: Double
    public var gpa: Double
    /// False means the school did not return a usable GPA; zero must not stand in for missing data.
    public var gpaAvailable: Bool
    public var credit: Double
    public var category: String
    public var nature: String
    public var remark: String
    public var classify: String
    public var passed: Bool { score >= 60 }
    public var id: String { stableID([term, name, nature, category, String(score), String(credit)]) }
    public init(term: String = "", name: String, score: Double, gpa: Double = 0, credit: Double = 0, category: String = "", nature: String = "", remark: String = "", classify: String = "", gpaAvailable: Bool = true) {
        self.term = term; self.name = name; self.score = score; self.gpa = gpa; self.credit = credit
        self.category = category; self.nature = nature; self.remark = remark; self.classify = classify
        self.gpaAvailable = gpaAvailable
    }
}

public enum GradeStatistics {
    /// Mirrors the upstream definition: passed compulsory/limited-elective courses, weighted by credits.
    /// This is an estimate, not the university's official aggregate.
    public static func counted(category: String) -> Bool {
        if category.contains("限选") { return true }
        return !category.contains("选修") && !category.contains("任选")
    }
    public static func weightedGPA(_ grades: [CourseGrade]) -> Double? {
        let included = grades.filter { $0.passed && $0.credit > 0 && $0.credit.isFinite && $0.gpaAvailable && $0.gpa.isFinite && $0.gpa >= 0 && counted(category: $0.category) }
        let credits = included.reduce(0) { $0 + $1.credit }
        let weighted = included.reduce(0) { $0 + $1.credit * $1.gpa }
        return credits > 0 && credits.isFinite && weighted.isFinite ? weighted / credits : nil
    }
    public static func earnedCredits(_ grades: [CourseGrade]) -> Double {
        grades.filter { $0.passed && $0.credit > 0 && $0.credit.isFinite }.reduce(0) { $0 + $1.credit }
    }
}

public struct GradePart: Codable, Hashable, Sendable, Identifiable {
    public var label: String
    public var value: String
    public var id: String { stableID([label, value]) }
    public init(label: String, value: String) { self.label = label; self.value = value }
}
public struct LevelGrade: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var term: String
    public var total: Double
    public var level: String
    public var date: String
    public var parts: [GradePart]
    public var id: String { stableID([name, term, date, String(total)]) }
    public init(name: String, term: String = "", total: Double, level: String = "", date: String = "", parts: [GradePart] = []) {
        self.name = name; self.term = term; self.total = total; self.level = level; self.date = date; self.parts = parts
    }
}
public struct FitnessItem: Codable, Hashable, Sendable, Identifiable {
    public var label: String
    public var value: String
    public var score: String
    public var id: String { stableID([label, value, score]) }
    public init(label: String, value: String, score: String = "") { self.label = label; self.value = value; self.score = score }
}
public struct FitnessGrade: Codable, Hashable, Sendable, Identifiable {
    public var term: String
    public var total: String
    public var level: String
    public var items: [FitnessItem]
    public var id: String { stableID([term, total, level]) }
    public init(term: String = "", total: String, level: String = "", items: [FitnessItem] = []) {
        self.term = term; self.total = total; self.level = level; self.items = items
    }
}
public struct ExamItem: Codable, Hashable, Sendable, Identifiable {
    public var course: String
    public var date: String
    public var time: String
    public var room: String
    public var seat: String
    public var type: String
    public var id: String { stableID([course, date, time, room, seat, type]) }
    public init(course: String, date: String = "", time: String = "", room: String = "", seat: String = "", type: String = "") {
        self.course = course; self.date = date; self.time = time; self.room = room; self.seat = seat; self.type = type
    }
}
public enum AcademicSection: String, Codable, Hashable, Sendable {
    case sessions, grades, levels, fitness, exams
}

public struct AcademicSnapshot: Codable, Hashable, Sendable {
    public var semester: Semester
    public var sessions: [CourseSession]
    public var grades: [CourseGrade]
    public var levels: [LevelGrade]
    public var fitness: [FitnessGrade]
    public var exams: [ExamItem]
    public var updatedAt: Date
    public var warnings: [String]
    public var failedSections: [AcademicSection]
    public init(semester: Semester, sessions: [CourseSession] = [], grades: [CourseGrade] = [], levels: [LevelGrade] = [], fitness: [FitnessGrade] = [], exams: [ExamItem] = [], updatedAt: Date = Date(), warnings: [String] = [], failedSections: [AcademicSection] = []) {
        self.semester = semester; self.sessions = sessions; self.grades = grades; self.levels = levels
        self.fitness = fitness; self.exams = exams; self.updatedAt = updatedAt; self.warnings = warnings
        self.failedSections = failedSections
    }
}
