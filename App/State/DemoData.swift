import Foundation
import PocketCore

enum DemoData {
    static func academic(campus: Campus) -> AcademicSnapshot {
        let today = SchoolDate.calendar.startOfDay(for: .now)
        let weekday = (SchoolDate.calendar.component(.weekday, from: today) + 5) % 7 + 1
        let monday = SchoolDate.calendar.date(byAdding: .day, value: -(weekday - 1), to: today)!
        let first = SchoolDate.calendar.date(byAdding: .day, value: -7 * 7, to: monday)!
        let year = SchoolDate.calendar.component(.year, from: today)
        let semester = Semester(code: "\(year)01", name: "演示学期（虚构）", firstMonday: SchoolDate.iso(first), totalWeeks: 20)
        let courses = [("中医基础理论", "阴阳学说与临床应用", "教学楼 A201", 1, 2), ("中药学", "解表药 · 辛温解表", "教学楼 B302", 3, 4), ("方剂学", "解表剂的配伍思路", "教学楼 A406", 6, 7)]
        var sessions: [CourseSession] = []
        for week in 1...20 {
            for day in 1...5 {
                for (index, item) in courses.enumerated() where day == weekday || (day + index) % 2 == 0 {
                    sessions.append(CourseSession(name: item.0, code: "demo-\(index)", teachers: "示例教师", week: week, weekday: day, startUnit: item.3, endUnit: item.4, room: item.2, content: item.1, date: SchoolDate.iso(semester.date(week: week, weekday: day)), campus: campus))
                }
            }
        }
        let grades = [CourseGrade(term: "演示学期", name: "中医基础理论", score: 92, gpa: 4.2, credit: 4, category: "专业必修课"), CourseGrade(term: "演示学期", name: "医古文", score: 88, gpa: 3.8, credit: 3, category: "专业必修课"), CourseGrade(term: "演示学期", name: "中药学", score: 90, gpa: 4, credit: 4, category: "专业必修课"), CourseGrade(term: "演示学期", name: "大学英语", score: 86, gpa: 3.6, credit: 2, category: "通识课")]
        return AcademicSnapshot(semester: semester, sessions: sessions, grades: grades, levels: [], fitness: [], exams: [], updatedAt: .now)
    }

    static func power() -> PowerSnapshot {
        let daily = (0..<7).map { offset -> PowerDaily in
            let date = SchoolDate.calendar.date(byAdding: .day, value: offset - 6, to: .now)!
            return PowerDaily(date: SchoolDate.iso(date), usage: [3.2, 2.8, 4.1, 3.6, 2.9, 3.4, 3.1][offset], remain: 48.6 + Double(6 - offset) * 3.3)
        }
        return PowerSnapshot(balance: 48.6, unit: "度", roomLabel: "演示宿舍 · 虚构数据", daily: daily, updatedAt: .now)
    }
}
