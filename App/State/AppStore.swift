import Foundation
import Observation
import WebKit
import UIKit
import ImageIO
import PocketCore

@MainActor @Observable
final class AppStore {
    var selectedTab: PocketTab
    private(set) var campus: Campus
    private(set) var academic: AcademicSnapshot?
    private(set) var power: PowerSnapshot?
    private(set) var powerBalanceHistory: [PowerBalanceRecord] = []
    private(set) var powerNeedsLogin = false
    private(set) var automaticPowerProbe = false
    private(set) var automaticPowerRunID = 0
    var powerAutoSyncEnabled: Bool { UserDefaults.standard.bool(forKey: "autoPowerSync") }
    var powerWasLinked: Bool { UserDefaults.standard.bool(forKey: "powerLinkedOnce") }
    private(set) var hasSession = false
    private(set) var syncing = false
    private(set) var isDemo = false
    private(set) var transitioning = false
    var message: String?
    var selectedWeek = 1
    var selectedDay = 1
    var gradeCategory = 0
    var gradeSearch = ""
    var gradeTerm = "全部学期"
    private(set) var wallpaperData: Data?
    var wallpaperOpacity: Double = UserDefaults.standard.object(forKey: "wallpaperOpacity") as? Double ?? 0.12 {
        didSet { UserDefaults.standard.set(wallpaperOpacity, forKey: "wallpaperOpacity") }
    }
    var semesterOverride: String {
        didSet { UserDefaults.standard.set(semesterOverride, forKey: "semesterOverride") }
    }

    @ObservationIgnored private let client = SchoolClient()
    @ObservationIgnored private var didRestore = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastAutomaticAttempt: Date?
    @ObservationIgnored private var remindersTask: Task<Void, Never>?
    @ObservationIgnored private var powerAlertTask: Task<Void, Never>?
    @ObservationIgnored private var lastAutoPowerAttempt: Date?
    @ObservationIgnored private var powerProbeTimeout: Task<Void, Never>?

    init() {
        campus = Campus(rawValue: UserDefaults.standard.string(forKey: "campus") ?? "") ?? .undergraduate
        selectedTab = PocketTab(rawValue: UserDefaults.standard.string(forKey: "startTab") ?? "") ?? .today
        semesterOverride = UserDefaults.standard.string(forKey: "semesterOverride") ?? ""
        if let cache = LocalCache.load(), cache.campus == campus {
            academic = cache.academic
            power = cache.power
            powerBalanceHistory = cache.powerHistory ?? []
        }
        wallpaperData = try? Data(contentsOf: LocalCache.directory.appending(path: "wallpaper.jpg"))
        resetCalendarSelection()
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--demo") {
            enterDemo()
            if let position = arguments.firstIndex(of: "--tab"), arguments.indices.contains(position + 1), let tab = PocketTab(rawValue: arguments[position + 1]) {
                selectedTab = tab
            }
        }
        #endif
    }

    var currentWeek: Int { academic?.semester.week(of: .now) ?? 0 }
    var termStatus: String {
        guard let semester = academic?.semester else { return "你的校园生活，从这里连接" }
        let week = currentWeek
        return "\(semester.name) · " + (week < 1 ? "学期尚未开始" : week > semester.totalWeeks ? "学期已结束" : "第 \(week) 周")
    }
    var todayCourses: [CourseSession] {
        guard let academic else { return [] }
        let today = SchoolDate.iso(.now)
        return academic.sessions.filter { effectiveDate($0) == today }.sorted { $0.startUnit < $1.startUnit }
    }
    var weekCourses: [CourseSession] {
        academic?.sessions.filter { $0.week == currentWeek } ?? []
    }
    var nextCourse: CourseSession? {
        academic?.sessions.filter { course in
            guard let date = SchoolDate.parse(effectiveDate(course)) ?? courseDate(course) else { return false }
            let parts = course.resolvedStartTime.split(separator: ":").compactMap { Int($0) }
            let valid = parts.count == 2 && (0...23).contains(parts[0]) && (0...59).contains(parts[1])
            let start = valid ? SchoolDate.calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: date) : nil
            return (start ?? date) > .now
        }.sorted { (effectiveDate($0), $0.startUnit) < (effectiveDate($1), $1.startUnit) }.first
    }

    func effectiveDate(_ course: CourseSession) -> String {
        if !course.date.isEmpty { return course.date }
        return courseDate(course).map(SchoolDate.iso) ?? ""
    }
    func courseDate(_ course: CourseSession) -> Date? {
        academic?.semester.date(week: course.week, weekday: course.weekday)
    }

    func restoreSession() async {
        guard !didRestore else { return }
        didRestore = true
        let token = generation
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        guard generation == token, !isDemo else { return }
        await client.setCookies(cookies)
        guard generation == token else { return }
        hasSession = cookies.contains { cookie in
            let target = campus == .undergraduate ? "jw.gzucm.edu.cn" : "yjsglxt.gzucm.edu.cn"
            let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let key = campus == .undergraduate ? "JSESSIONID" : "__LOGINCOOKIE__"
            return (domain == target || domain == "gzucm.edu.cn") && cookie.name == key && !cookie.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (cookie.expiresDate.map { $0 > .now } ?? true)
        }
        await refreshIfNeeded()
    }

    func completeLogin(cookies: [HTTPCookie]) async {
        guard !transitioning else { return }
        transitioning = true
        generation += 1
        remindersTask?.cancel()
        powerAlertTask?.cancel()
        LocalNotifications.clearAll()
        let token = generation
        isDemo = false
        academic = nil
        power = nil
        powerBalanceHistory = []
        cancelPowerProbe()
        LocalCache.remove()
        await client.clearSession()
        guard generation == token else { return }
        await client.setCookies(cookies)
        guard generation == token else { return }
        hasSession = true
        syncing = false
        transitioning = false
        await sync()
    }

    func sync(silently: Bool = false) async {
        guard !isDemo, hasSession else {
            if !silently { message = isDemo ? "当前为演示模式，请先连接学校教务。" : "请先连接学校教务。" }
            return
        }
        guard !syncing else { return }
        syncing = true
        let token = generation
        do {
            var result = try await client.fetchAcademicData(campus: campus, semesterCode: semesterOverride.isEmpty ? nil : semesterOverride)
            guard generation == token else { return }
            if let previous = academic, previous.semester.code == result.semester.code {
                if result.failedSections.contains(.sessions) {
                    result.sessions = previous.sessions
                    result.warnings.append("课表本次未完整返回，继续显示上次缓存的课程。")
                }
                if result.failedSections.contains(.grades) { result.grades = previous.grades }
                if result.failedSections.contains(.levels) { result.levels = previous.levels }
                if result.failedSections.contains(.fitness) { result.fitness = previous.fitness }
                if result.failedSections.contains(.exams) { result.exams = previous.exams }
            }
            academic = result
            resetCalendarSelection()
            persist()
            refreshCourseReminders()
        } catch {
            guard generation == token else { return }
            if !silently { message = error.localizedDescription + (academic == nil ? "" : "\n已保留上次同步的数据。") }
        }
        if generation == token { syncing = false }
    }

    func refreshIfNeeded() async {
        guard !isDemo, hasSession, !syncing else { return }
        if let lastAutomaticAttempt, Date.now.timeIntervalSince(lastAutomaticAttempt) < 4 * 3600 { return }
        guard academic == nil || Date.now.timeIntervalSince(academic!.updatedAt) > 4 * 3600 else { return }
        lastAutomaticAttempt = .now
        await sync(silently: true)
    }

    func acceptPower(_ snapshot: PowerSnapshot) {
        if isDemo { isDemo = false; academic = nil; hasSession = false }
        guard snapshot.balance.isFinite, !snapshot.roomLabel.isEmpty else { return }
        power = snapshot
        let date = SchoolDate.iso(snapshot.updatedAt)
        let record = PowerBalanceRecord(date: date, balance: snapshot.balance, unit: snapshot.unit,
                                        roomLabel: snapshot.roomLabel, recordedAt: snapshot.updatedAt)
        // A room change invalidates the previous room's balance history.
        var records = powerBalanceHistory.filter {
            $0.roomLabel == snapshot.roomLabel && $0.unit == snapshot.unit && $0.date != date
        }
        records.append(record)
        powerBalanceHistory = Array(records.sorted { $0.recordedAt < $1.recordedAt }.suffix(90))
        UserDefaults.standard.set(true, forKey: "powerLinkedOnce")
        if UserDefaults.standard.object(forKey: "autoPowerSync") == nil {
            UserDefaults.standard.set(true, forKey: "autoPowerSync")
        }
        powerNeedsLogin = false
        if automaticPowerProbe && snapshot.isComplete { cancelPowerProbe() }
        persist()
        refreshPowerAlert()
    }

    /// Loads the official electricity page using the app's EXISTING WebKit cookies.
    /// It cannot silently complete new school SSO/MFA challenges.
    func refreshPowerIfNeeded(force: Bool = false) {
        guard !isDemo, !transitioning, (force || powerAutoSyncEnabled),
              powerWasLinked, !automaticPowerProbe else { return }
        if !force {
            if let lastAutoPowerAttempt, Date.now.timeIntervalSince(lastAutoPowerAttempt) < 4 * 3600 { return }
            if let power, Date.now.timeIntervalSince(power.updatedAt) < 4 * 3600 { return }
        }
        powerNeedsLogin = false
        lastAutoPowerAttempt = .now
        automaticPowerRunID += 1
        let run = automaticPowerRunID
        automaticPowerProbe = true
        powerProbeTimeout?.cancel()
        powerProbeTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, self.automaticPowerRunID == run else { return }
            self.cancelPowerProbe()
        }
    }

    func cancelPowerProbe() {
        powerProbeTimeout?.cancel()
        powerProbeTimeout = nil
        automaticPowerProbe = false
    }

    func powerAutoLoginRequired() {
        guard automaticPowerProbe else { return }
        cancelPowerProbe()
        powerNeedsLogin = true
    }

    func powerAutoSettingChanged() {
        if powerAutoSyncEnabled {
            refreshPowerIfNeeded(force: true)
        } else {
            cancelPowerProbe()
        }
    }

    func enterDemo() {
        guard !transitioning else { return }
        generation += 1
        remindersTask?.cancel()
        powerAlertTask?.cancel()
        LocalNotifications.clearAll()
        syncing = false
        isDemo = true
        hasSession = false
        cancelPowerProbe()
        powerNeedsLogin = false
        powerBalanceHistory = []
        academic = DemoData.academic(campus: campus)
        power = DemoData.power()
        resetCalendarSelection()
    }

    func logout() async {
        guard !transitioning else { return }
        transitioning = true
        defer { transitioning = false }
        generation += 1
        remindersTask?.cancel()
        powerAlertTask?.cancel()
        LocalNotifications.clearAll()
        UserDefaults.standard.removeObject(forKey: "lastPowerAlertDay")
        syncing = false
        hasSession = false
        isDemo = false
        academic = nil
        power = nil
        powerBalanceHistory = []
        cancelPowerProbe()
        powerNeedsLogin = false
        lastAutoPowerAttempt = nil
        UserDefaults.standard.removeObject(forKey: "powerLinkedOnce")
        lastAutomaticAttempt = nil
        LocalCache.remove()
        saveWallpaper(nil)
        gradeCategory = 0
        gradeSearch = ""
        gradeTerm = "全部学期"
        await client.clearSession()
        await WebsiteDataReset.clear()
    }

    func leaveDemo() async {
        guard !transitioning else { return }
        isDemo = false
        academic = nil
        power = nil
        if let cache = LocalCache.load(), cache.campus == campus {
            academic = cache.academic
            power = cache.power
            powerBalanceHistory = cache.powerHistory ?? []
        }
        didRestore = false
        resetCalendarSelection()
        await restoreSession()
    }

    func refreshCourseReminders() {
        remindersTask?.cancel()
        let snapshot = !isDemo && !transitioning && UserDefaults.standard.bool(forKey: "courseAlerts") ? academic : nil
        remindersTask = Task { await LocalNotifications.updateCourses(snapshot) }
    }

    func refreshPowerAlert() {
        powerAlertTask?.cancel()
        guard !isDemo, !transitioning, UserDefaults.standard.bool(forKey: "powerAlerts"), let power else {
            LocalNotifications.clearPower(); return
        }
        powerAlertTask = Task { await LocalNotifications.checkPower(power) }
    }

    func saveWallpaper(_ data: Data?) {
        let destination = LocalCache.directory.appending(path: "wallpaper.jpg")
        guard let data else { wallpaperData = nil; try? FileManager.default.removeItem(at: destination); return }
        guard data.count <= 25 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1800, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary),
              let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.8) else {
            message = "无法读取这张图片，请选择小于 25 MB 的照片。"; return
        }
        do {
            try FileManager.default.createDirectory(at: LocalCache.directory, withIntermediateDirectories: true)
            try jpeg.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            var directory = LocalCache.directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            wallpaperData = jpeg
        } catch { message = "课表背景保存失败，请重试。" }
    }

    func changeCampus(_ next: Campus) async {
        guard next != campus else { return }
        await logout()
        campus = next
        semesterOverride = ""
        UserDefaults.standard.set(next.rawValue, forKey: "campus")
    }

    private func resetCalendarSelection() {
        let week = currentWeek
        selectedWeek = min(max(week, 1), academic?.semester.totalWeeks ?? 1)
        selectedDay = (SchoolDate.calendar.component(.weekday, from: .now) + 5) % 7 + 1
    }
    private func persist() {
        guard !isDemo else { return }
        do { try LocalCache.save(CachedAccount(campus: campus, academic: academic,
                                              power: power, powerHistory: powerBalanceHistory)) }
        catch { message = "数据已读取，但本地缓存写入失败。下次打开可能需要重新同步。" }
    }
}

private struct CachedAccount: Codable {
    let campus: Campus
    let academic: AcademicSnapshot?
    let power: PowerSnapshot?
    // Optional to decode older account-v1.json files without migration.
    let powerHistory: [PowerBalanceRecord]?
}

private enum LocalCache {
    static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "GZUCMPocket", directoryHint: .isDirectory)
    }
    static var file: URL { directory.appending(path: "account-v1.json") }
    static func load() -> CachedAccount? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(CachedAccount.self, from: data)
    }
    static func save(_ account: CachedAccount) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        try JSONEncoder().encode(account).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    static func remove() { try? FileManager.default.removeItem(at: file) }
}

private extension WKHTTPCookieStore {
    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in getAllCookies { continuation.resume(returning: $0) } }
    }
}
