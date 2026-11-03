import Foundation

public enum SchoolClientError: Error, LocalizedError, Sendable, Equatable {
    case unauthorized
    case invalidSemester
    case malformedResponse(String)
    case server(Int)
    case unavailable(String)
    public var errorDescription: String? {
        switch self {
        case .unauthorized: return "学校登录已失效，请重新登录。"
        case .invalidSemester: return "学期代码不正确，请检查设置。"
        case .malformedResponse(let section): return "无法识别\(section)响应，学校接口可能已变化。"
        case .server(let code): return "学校服务器返回 HTTP \(code)，请稍后重试。"
        case .unavailable(let reason): return reason
        }
    }
}

extension Dictionary where Key == String, Value == Any {
    func text(_ key: String) -> String {
        if let value = self[key] as? String { return value.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{200B}\u{FEFF}"))) }
        if let value = self[key] as? NSNumber { return value.stringValue }
        return ""
    }
    func number(_ key: String) -> Double? {
        guard let value = Double(text(key)), value.isFinite else { return nil }
        return value
    }
    func firstText(_ keys: String...) -> String {
        keys.lazy.map { self.text($0) }.first { !$0.isEmpty } ?? ""
    }
}

/// Parsing is independent of the transport and never retains complete raw school responses.
public enum SchoolParser {
    static func json(_ data: Data, section: String) throws -> Any {
        let value: Any
        do { value = try JSONSerialization.jsonObject(with: data) }
        catch { throw SchoolClientError.malformedResponse(section) }
        if let object = value as? [String: Any] {
            if object.text("code") == "-401" || object.text("message").contains("尚未登录") || object.text("message").contains("已在别处登录") {
                throw SchoolClientError.unauthorized
            }
            let code = object.text("code")
            if !code.isEmpty && code != "0" && code != "200" {
                throw SchoolClientError.unavailable("学校接口未返回成功状态，请稍后重试。")
            }
        }
        return value
    }
    static func object(_ data: Data, section: String) throws -> [String: Any] {
        guard let object = try json(data, section: section) as? [String: Any] else { throw SchoolClientError.malformedResponse(section) }
        return object
    }
    static func rows(_ data: Data, key: String = "rows", section: String) throws -> [[String: Any]] {
        let root = try object(data, section: section)
        guard let array = root[key] as? [Any] else { throw SchoolClientError.malformedResponse(section) }
        return array.compactMap { $0 as? [String: Any] }
    }
    public static func semesterCode(for date: Date = Date()) -> String {
        let year = SchoolDate.calendar.component(.year, from: date)
        let month = SchoolDate.calendar.component(.month, from: date)
        return month >= 8 ? "\(year)01" : "\(year - 1)02"
    }
    public static func validSemesterCode(_ code: String) -> Bool {
        guard code.count == 6, let year = Int(code.prefix(4)), (1990...2100).contains(year) else { return false }
        return code.hasSuffix("01") || code.hasSuffix("02")
    }
    public static func previousSemesterCode(_ code: String) -> String {
        guard validSemesterCode(code), let year = Int(code.prefix(4)) else { return code }
        return code.hasSuffix("01") ? "\(year - 1)02" : "\(year)01"
    }
    public static func semesterName(_ code: String) -> String {
        guard let year = Int(code.prefix(4)) else { return code }
        return code.hasSuffix("01") ? "\(year)–\(year + 1) 学年第一学期" : "\(year)–\(year + 1) 学年第二学期"
    }
    public static func semester(_ data: Data, code: String) throws -> Semester {
        let root = try object(data, section: "教学校历")
        guard let groups = root["data"] as? [Any] else { throw SchoolClientError.malformedResponse("教学校历") }
        var firstMonday: Date?
        var maxWeek = 0
        func visit(_ value: Any) {
            guard let array = value as? [Any] else { return }
            if let head = array.first as? [String: Any], head.text("type") == "zc", let week = Int(head.text("value")), (1...35).contains(week) {
                maxWeek = max(maxWeek, week)
                if week == 1, firstMonday == nil {
                    let days = array.dropFirst().compactMap { $0 as? [String: Any] }.filter { $0.text("type") == "day" }
                    if let sunday = days.first.flatMap({ SchoolDate.parse($0.text("fullText")) }) {
                        firstMonday = SchoolDate.addingDays(1, to: sunday)
                    }
                }
            } else { array.forEach(visit) }
        }
        visit(groups)
        guard let firstMonday, SchoolDate.weekday(firstMonday) == 1, maxWeek > 0 else { throw SchoolClientError.malformedResponse("教学校历") }
        return Semester(code: code, name: semesterName(code), firstMonday: SchoolDate.iso(firstMonday), totalWeeks: maxWeek)
    }
    static func room(_ row: [String: Any], schoolWeek: Int) -> String {
        if !row.text("jxcdmc").isEmpty { return row.text("jxcdmc") }
        let tokens = row.text("jxcdmc2").split(separator: ",").map(String.init)
        let matched = tokens.first { $0.hasSuffix("-\(schoolWeek)") }
        if let value = matched ?? tokens.first, let dash = value.lastIndex(of: "-") { return String(value[..<dash]).trimmingCharacters(in: .whitespaces) }
        return row.text("cdmc")
    }
    public static func weeklySessions(_ data: Data, schoolWeek: Int, semester: Semester) throws -> [CourseSession] {
        try parseUndergraduate(data, schoolWeek: schoolWeek, semester: semester, wholeSemester: false)
    }
    public static func semesterSessions(_ data: Data, semester: Semester) throws -> [CourseSession] {
        try parseUndergraduate(data, schoolWeek: 1, semester: semester, wholeSemester: true)
    }
    private static func parseUndergraduate(_ data: Data, schoolWeek: Int, semester: Semester, wholeSemester: Bool) throws -> [CourseSession] {
        let records = try rows(data, key: "data", section: "课表")
        var sessions: [CourseSession] = []
        for row in records {
            let name = row.text("kcmc")
            guard !name.isEmpty, let sourceDay = Int(row.text("xq")), (1...7).contains(sourceDay),
                  let start = Int(row.text("ps")), (1...14).contains(start) else { continue }
            let end = min(14, max(start, Int(row.text("pe")) ?? start))
            let realDate = SchoolDate.parse(row.text("qsrq"))
            let weekday = realDate.map(SchoolDate.weekday) ?? sourceDay
            let weeks: [(app: Int, school: Int)]
            if let realDate {
                weeks = [(semester.week(of: realDate), schoolWeek)]
            } else {
                var sourceWeeks = row.text("zc").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                if wholeSemester && sourceWeeks.isEmpty {
                    sourceWeeks = row.text("jxcdmc2").split(separator: ",").compactMap { Int($0.split(separator: "-").last ?? "") }
                }
                if sourceWeeks.isEmpty && !wholeSemester { sourceWeeks = [schoolWeek] }
                weeks = sourceWeeks.filter { (1...semester.totalWeeks + 1).contains($0) }.map { ($0 - (weekday == 7 ? 1 : 0), $0) }
            }
            for pair in weeks where (1...semester.totalWeeks).contains(pair.app) {
                let date = realDate.map(SchoolDate.iso) ?? SchoolDate.iso(semester.date(week: pair.app, weekday: weekday))
                sessions.append(CourseSession(name: name, code: row.text("kcdm"), teachers: row.text("teaxms"), week: pair.app, weekday: weekday, startUnit: start, endUnit: end,
                    startTime: String(row.text("qssj").prefix(5)), endTime: String(row.text("jssj").prefix(5)), room: room(row, schoolWeek: pair.school),
                    content: row.text("sknrjj"), category: row.text("jxhjmc"), teachingMode: row.firstText("jxmsmc", "jxxsmc"), mergedClasses: row.text("jxbmc"), date: date))
            }
        }
        return sortedUnique(sessions)
    }
    static func sortedUnique(_ sessions: [CourseSession]) -> [CourseSession] {
        var ids = Set<String>()
        return sessions.filter { ids.insert($0.id).inserted }.sorted {
            if $0.week != $1.week { return $0.week < $1.week }
            if $0.weekday != $1.weekday { return $0.weekday < $1.weekday }
            if $0.startUnit != $1.startUnit { return $0.startUnit < $1.startUnit }
            return $0.id < $1.id
        }
    }
    public static func courseGrades(_ data: Data) throws -> [CourseGrade] {
        try rows(data, section: "课程成绩").compactMap { row in
            guard !row.text("kcmc").isEmpty, let score = row.number("zcj"), score >= 0 else { return nil }
            let gpa = row.number("cjjd")
            return CourseGrade(term: row.text("xnxqmc"), name: row.text("kcmc"), score: score, gpa: row.number("cjjd") ?? 0, credit: row.number("xf") ?? 0,
                category: row.text("kcdlmc"), nature: row.text("ksxzmc"), remark: row.text("bz"), classify: row.text("kcflmc"), gpaAvailable: gpa.map { $0 >= 0 } ?? false)
        }
    }
    public static func levelGrades(_ data: Data) throws -> [LevelGrade] {
        try rows(data, section: "等级成绩").compactMap { row in
            guard !row.text("kjkcmc").isEmpty else { return nil }
            let labels = ["听力", "阅读", "写作", "翻译", "其他"]
            let parts = (1...5).compactMap { index -> GradePart? in
                let value = row.text("xm\(index)cj")
                return value.isEmpty ? nil : GradePart(label: labels[index - 1], value: value)
            }
            return LevelGrade(name: row.text("kjkcmc"), term: row.text("xnxqmc"), total: row.number("zcj") ?? 0, level: row.text("djmc"), date: row.text("kssj"), parts: parts)
        }
    }
    public static func fitnessGrades(_ data: Data) throws -> [FitnessGrade] {
        try rows(data, section: "体测成绩").map { row in
            let keys = [("身高", "sg", ""), ("体重", "tz", "tzpf"), ("肺活量", "fhl", "fhlpf"), ("50 米", "wsm", "wsmpf"), ("坐位体前屈", "zwtqq", "zwtqqpf"), ("立定跳远", "ldty", "ldtypf"), ("引体/仰卧", "ytxsorywqz", "ytxsorywqzpf"), ("800/1000 米", "yqmorbbm", "yqmorbbmpf")]
            let items = keys.compactMap { label, value, score -> FitnessItem? in
                row.text(value).isEmpty ? nil : FitnessItem(label: label, value: row.text(value), score: row.text(score))
            }
            return FitnessGrade(term: row.text("xnxqmc"), total: row.text("zf"), level: row.text("dj"), items: items)
        }
    }
    public static func exams(_ data: Data) throws -> [ExamItem] {
        try rows(data, section: "考试安排").compactMap { row in
            guard !row.text("kcmc").isEmpty else { return nil }
            return ExamItem(course: row.text("kcmc"), date: row.firstText("rq", "ksrq"), time: row.firstText("kssj", "jcdm2"), room: row.firstText("cdmc", "jxcdmc"), seat: row.text("zwh"), type: row.firstText("ksxzmc", "kslxmc"))
        }
    }
}
