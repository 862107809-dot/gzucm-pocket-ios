import Foundation
import UserNotifications
import PocketCore

enum LocalNotifications {
    static func requestAccess() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func updateCourses(_ snapshot: AcademicSnapshot?) async {
        let center = UNUserNotificationCenter.current()
        let existing = await center.pendingNotificationRequests()
        guard !Task.isCancelled else { return }
        center.removePendingNotificationRequests(withIdentifiers: existing.filter { $0.identifier.hasPrefix("course-") }.map(\.identifier))
        guard let snapshot else { return }
        let cutoff = Date.now.addingTimeInterval(7 * 86400)
        let upcoming: [(CourseSession, Date)] = snapshot.sessions.compactMap { course in
            let date = SchoolDate.parse(course.date) ?? snapshot.semester.date(week: course.week, weekday: course.weekday)
            let time = course.resolvedStartTime.split(separator: ":").compactMap { Int($0) }
            guard time.count == 2, (0...23).contains(time[0]), (0...59).contains(time[1]),
                  let start = SchoolDate.calendar.date(bySettingHour: time[0], minute: time[1], second: 0, of: date) else { return nil }
            let fire = start.addingTimeInterval(-600)
            return fire > .now && fire < cutoff ? (course, fire) : nil
        }.sorted { $0.1 < $1.1 }
        for (course, fire) in upcoming.prefix(50) {
            guard !Task.isCancelled else { return }
            let content = UNMutableNotificationContent()
            content.title = "10 分钟后上课 · \(course.name)"
            content.body = [course.room, course.content].filter { !$0.isEmpty }.joined(separator: " · ")
            content.sound = .default
            var components = SchoolDate.calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            components.timeZone = SchoolDate.calendar.timeZone
            let request = UNNotificationRequest(identifier: "course-\(course.id)", content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
            try? await center.add(request)
            if Task.isCancelled { center.removePendingNotificationRequests(withIdentifiers: [request.identifier]); return }
        }
    }

    @MainActor static func checkPower(_ power: PowerSnapshot) async {
        let summary = PowerSummary(power)
        let today = SchoolDate.iso(.now)
        guard !Task.isCancelled, power.isComplete, SchoolDate.iso(power.updatedAt) == today, summary.recordCount >= 3,
              let days = summary.days, days < 3,
              UserDefaults.standard.string(forKey: "lastPowerAlertDay") != today else { return }
        let content = UNMutableNotificationContent()
        content.title = "宿舍电量可能不足 3 天"
        content.body = "剩余 \(power.balance.formatted())\(power.unit)，请留意学校一卡通。"
        content.sound = .default
        let request = UNNotificationRequest(identifier: "power-low", content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false))
        if (try? await UNUserNotificationCenter.current().add(request)) != nil {
            if Task.isCancelled { clearPower(); return }
            UserDefaults.standard.set(today, forKey: "lastPowerAlertDay")
        }
    }

    static func clearPower() { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["power-low"]) }
    static func clearAll() { UNUserNotificationCenter.current().removeAllPendingNotificationRequests(); UNUserNotificationCenter.current().removeAllDeliveredNotifications() }
}
