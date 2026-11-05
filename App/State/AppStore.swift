import Foundation
import Observation
import WebKit
import UIKit
import ImageIO
import Security
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
    var powerBridgeSite: String = UserDefaults.standard.string(forKey: "powerBridgeSite") ?? "" {
        didSet { UserDefaults.standard.set(powerBridgeSite, forKey: "powerBridgeSite") }
    }
    private(set) var powerBridgeStatus = "尚未配对"
    private(set) var powerBridgePaired = false
    private(set) var powerBridgeBusy = false
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
    @ObservationIgnored private var powerBridgeBinding: PowerBridgeBinding? = PowerBridgeSecret.load()
    @ObservationIgnored private var powerBridgePushTask: Task<Void, Never>?
    @ObservationIgnored private var powerBridgeLastAttempt: Date?

    init() {
        campus = Campus(rawValue: UserDefaults.standard.string(forKey: "campus") ?? "") ?? .undergraduate
        selectedTab = PocketTab(rawValue: UserDefaults.standard.string(forKey: "startTab") ?? "") ?? .today
        semesterOverride = UserDefaults.standard.string(forKey: "semesterOverride") ?? ""
        if let cache = LocalCache.load(), cache.campus == campus {
            academic = cache.academic
            power = cache.power
            powerBalanceHistory = cache.powerHistory ?? []
        }
        powerBridgePaired = powerBridgeBinding?.site == PowerBridgeNetwork.site(powerBridgeSite)?.absoluteString
        powerBridgeStatus = powerBridgePaired ? "已与网站配对，等待下次电量同步" : "尚未配对"
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
        enqueuePowerBridgePush()
    }

    /// Connect by copying a one-time code from this user's Web page.
    /// The official school session remains in WKWebView; only sanitized
    /// display fields are sent to the explicitly entered HTTPS site.
    func pairPowerBridge(code: String) async {
        guard !powerBridgeBusy else { return }
        guard let base = PowerBridgeNetwork.site(powerBridgeSite) else {
            powerBridgeStatus = "请输入广中医口袋网站的完整 HTTPS 地址（不包含路径）"
            return
        }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard trimmed.range(of: "^[A-Z0-9_-]{12}$", options: .regularExpression) != nil else {
            powerBridgeStatus = "请填写网站生成的 12 位一次性配对码"
            return
        }
        powerBridgeBusy = true
        defer { powerBridgeBusy = false }
        do {
            // Verify the server identifies itself as the intended Web app.
            let info = try await PowerBridgeNetwork.get(base: base, path: "/api/health")
            guard info["app"] as? String == "广中医口袋 Web" else {
                throw PowerBridgeNetwork.Failure.invalidServer
            }
            let result = try await PowerBridgeNetwork.post(
                base: base, path: "/api/power/bridge/claim", body: ["code": trimmed], token: nil
            )
            guard let token = result["token"] as? String,
                  token.range(of: "^[-_A-Za-z0-9]{40,100}$", options: .regularExpression) != nil,
                  PowerBridgeSecret.save(PowerBridgeBinding(token: token, site: base.absoluteString)) else {
                throw PowerBridgeNetwork.Failure.invalidResponse
            }
            powerBridgeBinding = PowerBridgeBinding(token: token, site: base.absoluteString)
            powerBridgePaired = true
            powerBridgeStatus = "网站配对成功。将于下次读取真实电量后同步"
            enqueuePowerBridgePush()
        } catch {
            powerBridgeStatus = "配对失败：\(error.localizedDescription)"
        }
    }

    func forgetPowerBridge() {
        powerBridgePushTask?.cancel()
        powerBridgePushTask = nil
        powerBridgeBinding = nil
        powerBridgePaired = false
        powerBridgeStatus = "已清除本机配对"
        PowerBridgeSecret.clear()
    }

    private func enqueuePowerBridgePush() {
        guard !isDemo, powerBridgePaired, powerBridgeBinding != nil else { return }
        powerBridgePushTask?.cancel()
        powerBridgePushTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, !Task.isCancelled, let snapshot = self.power else { return }
            await self.sendPowerBridge(snapshot)
        }
    }

    private func sendPowerBridge(_ snapshot: PowerSnapshot) async {
        guard !isDemo, !powerBridgeBusy, powerBridgePaired,
              let binding = powerBridgeBinding,
              let base = PowerBridgeNetwork.site(powerBridgeSite),
              binding.site == base.absoluteString,
              ["度", "kWh", "千瓦时", "度电"].contains(snapshot.unit),
              snapshot.balance.isFinite, snapshot.balance >= 0 else { return }
        if let last = powerBridgeLastAttempt, Date.now.timeIntervalSince(last) < 18 { return }
        powerBridgeLastAttempt = .now
        powerBridgeBusy = true
        defer { powerBridgeBusy = false }
        do {
            let days: [[String: Any]] = snapshot.daily.suffix(90).map { row in
                ["date": row.date, "usage": row.usage,
                 "remain": row.remain, "total": row.total]
            }
            let payload: [String: Any] = [
                "power": ["balance": snapshot.balance, "unit": snapshot.unit,
                          "roomLabel": snapshot.roomLabel,
                          "updatedAt": ISO8601DateFormatter().string(from: snapshot.updatedAt)],
                "powerDaily": days,
                "historyStatus": snapshot.isComplete ? "complete" : "partial"
            ]
            _ = try await PowerBridgeNetwork.post(
                base: base, path: "/api/power/bridge/push", body: payload, token: binding.token
            )
            powerBridgeStatus = "已将本次电量和明细同步至网站"
        } catch {
            if case PowerBridgeNetwork.Failure.unauthorized = error {
                forgetPowerBridge()
                powerBridgeStatus = "网站授权已到期，请重新输入配对码"
            } else {
                powerBridgeStatus = "网站暂不可达：本机记录仍安全保留，可下次重试"
            }
        }
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
        powerBridgePushTask?.cancel()
        forgetPowerBridge()
        UserDefaults.standard.removeObject(forKey: "powerBridgeSite")
        powerBridgeSite = ""
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

private struct PowerBridgeBinding: Codable {
    let token: String
    let site: String
}

private enum PowerBridgeSecret {
    private static let service = "GZUCMPocket.power-display-only"
    private static let account = "paired-web-push-token"
    static func load() -> PowerBridgeBinding? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(PowerBridgeBinding.self, from: data)
    }
    @discardableResult static func save(_ binding: PowerBridgeBinding) -> Bool {
        clear()
        guard let data = try? JSONEncoder().encode(binding) else { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }
    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
private enum PowerBridgeNetwork {
    enum Failure: LocalizedError {
        case invalidServer, invalidResponse, unauthorized, rejected(String)
        var errorDescription: String? {
            switch self {
            case .invalidServer: return "此地址不是广中医口袋 Web 服务"
            case .invalidResponse: return "设备配对服务器响应无效"
            case .unauthorized: return "配对授权失效"
            case .rejected(let message): return message
            }
        }
    }
    static func site(_ input: String) -> URL? {
        guard let u = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              u.scheme?.lowercased() == "https", let host = u.host,
              host.contains("."), u.user == nil, u.password == nil, u.port == nil,
              u.query == nil, u.fragment == nil,
              u.path.isEmpty || u.path == "/" else { return nil }
        return URL(string: "https://" + host.lowercased())
    }
    private final class NoRedirect: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
    static func get(base: URL, path: String) async throws -> [String: Any] {
        try await request(base: base, path: path, body: nil, token: nil)
    }
    static func post(base: URL, path: String, body: [String: Any], token: String?) async throws -> [String: Any] {
        try await request(base: base, path: path, body: body, token: token)
    }
    private static func request(base: URL, path: String,
                                body: [String: Any]?, token: String?) async throws -> [String: Any] {
        let url = base.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.timeoutInterval = 18
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 18
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.url?.host == base.host else {
            throw Failure.invalidResponse
        }
        if http.statusCode == 401 { throw Failure.unauthorized }
        guard data.count <= 35000,
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Failure.rejected(String((dict["error"] as? String ?? "同步失败").prefix(150)))
        }
        return dict
    }
}
