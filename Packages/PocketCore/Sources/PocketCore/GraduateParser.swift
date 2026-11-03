import Foundation

public struct GraduateTerm: Codable, Hashable, Sendable, Identifiable {
    public var code: String
    public var name: String
    public var selected: Bool
    public var id: String { code }
    public init(code: String, name: String, selected: Bool = false) { self.code = code; self.name = name; self.selected = selected }
}

extension SchoolParser {
    public static func graduateTerms(_ data: Data) throws -> [GraduateTerm] {
        guard let array = try json(data, section: "研究生学期") as? [[String: Any]] else { throw SchoolClientError.malformedResponse("研究生学期") }
        return array.compactMap { row in
            guard !row.text("termcode").isEmpty, !row.text("termname").isEmpty else { return nil }
            return GraduateTerm(code: row.text("termcode"), name: row.text("termname"), selected: ["true", "1"].contains(row.text("selected").lowercased()))
        }
    }

    /// The graduate grid's z1...z7 columns are Monday...Sunday; actual dates override inconsistent columns.
    public static func graduateSessions(_ data: Data, requestedWeek: Int) throws -> [CourseSession] {
        let records = try rows(data, section: "研究生课表")
        var sessions: [CourseSession] = []
        for row in records {
            let fallbackUnit = Int(row.text("jcid")).flatMap { (11...24).contains($0) ? $0 - 10 : nil }
            guard let unit = Int(row.text("jcbh")) ?? fallbackUnit, (1...14).contains(unit) else { continue }
            for day in 1...7 {
                sessions += graduateCell(row.text("z\(day)"), weekday: day, unit: unit, requestedWeek: requestedWeek)
            }
        }
        return mergeGraduateSessions(sessions)
    }

    static func graduateCell(_ html: String, weekday: Int, unit: Int, requestedWeek: Int) -> [CourseSession] {
        guard !html.isEmpty,
              let entry = try? NSRegularExpression(pattern: #"\[(\d+)-(\d+)周\]\s*(\d{4}-\d{2}-\d{2})\s+(\S+?)\[([^\]]*)\]"#) else { return [] }
        let broken = html.replacingOccurrences(of: #"<br\s*/?>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"</(?:div|p)>"#, with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        let text = decodeEntities(broken)
        var lines: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let ns = line as NSString
            if let last = entry.matches(in: line, range: NSRange(location: 0, length: ns.length)).last, NSMaxRange(last.range) < ns.length {
                lines.append(ns.substring(to: NSMaxRange(last.range)))
                let tail = ns.substring(from: NSMaxRange(last.range)).trimmingCharacters(in: .whitespaces)
                if !tail.isEmpty { lines.append(tail) }
            } else { lines.append(line) }
        }
        var title = ""
        var sessions: [CourseSession] = []
        for (index, line) in lines.enumerated() {
            let ns = line as NSString
            let matches = entry.matches(in: line, range: NSRange(location: 0, length: ns.length))
            if matches.isEmpty {
                let nextIsEntry: Bool
                if index + 1 < lines.count {
                    let next = lines[index + 1]
                    nextIsEntry = entry.firstMatch(in: next, range: NSRange(location: 0, length: (next as NSString).length)) != nil
                } else { nextIsEntry = false }
                let remarks = ["另行通知", "改期", "停课", "调课", "调至", "见群", "待定", "线上上课", "补课", "放假"]
                if title.isEmpty || (nextIsEntry && line.count >= 4 && !remarks.contains(where: line.contains)) { title = line }
                continue
            }
            let (name, classes) = splitGraduateTitle(title)
            guard !name.isEmpty else { continue }
            for match in matches {
                let dateString = ns.substring(with: match.range(at: 3))
                guard let date = SchoolDate.parse(dateString) else { continue }
                // In single-week responses the requested week is authoritative; field week numbers can be stale.
                sessions.append(CourseSession(name: name, teachers: ns.substring(with: match.range(at: 4)), week: requestedWeek,
                    weekday: SchoolDate.weekday(date), startUnit: unit, endUnit: unit, startTime: ClassTimes.start(unit), endTime: ClassTimes.end(unit),
                    room: ns.substring(with: match.range(at: 5)), mergedClasses: classes, date: dateString, campus: .graduate))
            }
        }
        return sessions
    }
    static func splitGraduateTitle(_ raw: String) -> (String, String) {
        guard raw.hasPrefix("20"), raw.contains("级"), let dash = raw.lastIndex(of: "-"), raw.distance(from: dash, to: raw.endIndex) >= 3 else { return (raw, "") }
        return (String(raw[raw.index(after: dash)...]).trimmingCharacters(in: .whitespaces), String(raw[..<dash]).trimmingCharacters(in: .whitespaces))
    }
    static func decodeEntities(_ value: String) -> String {
        var result = value
        for (from, to) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            result = result.replacingOccurrences(of: from, with: to)
        }
        if let regex = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#) {
            let ns = result as NSString
            for match in regex.matches(in: result, range: NSRange(location: 0, length: ns.length)).reversed() {
                let code = ns.substring(with: match.range(at: 1))
                let number = code.hasPrefix("x") ? UInt32(code.dropFirst(), radix: 16) : UInt32(code)
                if let number, let scalar = UnicodeScalar(number), let range = Range(match.range, in: result) { result.replaceSubrange(range, with: String(scalar)) }
            }
        }
        return result
    }
    public static func mergeGraduateSessions(_ sessions: [CourseSession]) -> [CourseSession] {
        // Date participates in grouping: malformed school rows must not combine separate real days.
        let groups = Dictionary(grouping: sessions) { [$0.name, String($0.week), String($0.weekday), $0.mergedClasses, $0.date] }
        var output: [CourseSession] = []
        for group in groups.values {
            let sorted = group.sorted { $0.startUnit < $1.startUnit }
            var current: CourseSession?
            for session in sorted {
                if var existing = current, session.startUnit <= existing.endUnit + 1 {
                    existing.endUnit = max(existing.endUnit, session.endUnit)
                    existing.endTime = ClassTimes.end(existing.endUnit)
                    existing.teachers = joinedUnique(existing.teachers, session.teachers)
                    existing.room = joinedUnique(existing.room, session.room)
                    current = existing
                } else {
                    if let current { output.append(current) }
                    current = session
                }
            }
            if let current { output.append(current) }
        }
        return sortedUnique(output)
    }
    static func joinedUnique(_ lhs: String, _ rhs: String) -> String {
        var seen = Set<String>()
        return (lhs.components(separatedBy: " / ") + rhs.components(separatedBy: " / ")).filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: " / ")
    }
    public static func graduateSemester(term: GraduateTerm, sessions: [CourseSession]) throws -> Semester {
        var votes: [String: Int] = [:]
        for session in sessions where (1...35).contains(session.week) {
            guard let date = SchoolDate.parse(session.date) else { continue }
            let firstMonday = SchoolDate.addingDays(-(session.week - 1) * 7, to: SchoolDate.monday(of: date))
            votes[SchoolDate.iso(firstMonday), default: 0] += 1
        }
        // No dates means the semester start cannot be inferred; do not fabricate today's date as week one.
        guard let first = votes.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }).first?.key else {
            throw SchoolClientError.unavailable("研究生课表没有可用日期，无法推算教学周。请稍后重试或选择有课程的学期。")
        }
        return Semester(code: term.code, name: term.name, firstMonday: first, totalWeeks: min(35, max(20, sessions.map(\.week).max() ?? 20)))
    }
    public static func graduateGrades(_ data: Data) throws -> [CourseGrade] {
        let root = try object(data, section: "研究生成绩")
        guard root["xwklist"] is [Any] || root["fxwklist"] is [Any] else { throw SchoolClientError.malformedResponse("研究生成绩") }
        var output: [CourseGrade] = []
        for (key, category) in [("xwklist", "学位课"), ("fxwklist", "非学位课")] {
            for row in root[key] as? [[String: Any]] ?? [] {
                let name = row.firstText("kcmc", "kcmc_mc")
                guard !name.isEmpty, let score = row.number("cj") ?? row.number("zpcj"), score >= 0 else { continue }
                let gpa = row.number("jd")
                output.append(CourseGrade(term: row.firstText("xq", "xnxq"), name: name, score: score, gpa: gpa ?? 0, credit: row.number("xf") ?? 0, category: category, nature: row.text("ksxz"), gpaAvailable: gpa.map { $0 >= 0 } ?? false))
            }
        }
        return output
    }
}
