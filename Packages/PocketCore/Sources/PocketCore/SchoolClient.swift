import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum SchoolEndpoint {
    public static let undergraduate = URL(string: "https://jw.gzucm.edu.cn")!
    public static let graduate = URL(string: "https://yjsglxt.gzucm.edu.cn")!
    public static let ecard = URL(string: "https://ecard.gzucm.edu.cn")!
}

/// Do not forward an authenticated academic request to another host or an insecure URL.
/// A redirect to CAS is returned to the caller as an expired session.
private final class SchoolRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, let target = request.url,
              original.host == target.host, target.scheme == "https" else { completionHandler(nil); return }
        completionHandler(request)
    }
}

private struct WeekResult: Sendable {
    var week: Int
    var sessions: [CourseSession]
    var failed: Bool
}

private enum SchoolRequestContext {
    @TaskLocal static var sessionGeneration: Int?
}

/// Direct HTTPS client for the school's two separate academic systems.
/// Credentials are entered only in the school's WKWebView page; this actor receives session cookies.
public actor SchoolClient {
    private var session: URLSession
    private let redirectGuard: SchoolRedirectGuard
    private var sessionGeneration = 0
    public init() {
        let guardDelegate = SchoolRedirectGuard()
        self.redirectGuard = guardDelegate
        self.session = Self.makeSession(delegate: guardDelegate)
    }
    private static func makeSession(delegate: SchoolRedirectGuard) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 60
        configuration.httpMaximumConnectionsPerHost = 3
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
    /// Import each cookie with its full domain/path identity; same-name cookies must not overwrite each other.
    public func setCookies(_ cookies: [HTTPCookie]) {
        for cookie in cookies {
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard domain == "gzucm.edu.cn" || domain.hasSuffix(".gzucm.edu.cn") else { continue }
            session.configuration.httpCookieStorage?.setCookie(cookie)
        }
    }
    public func clearSession() {
        sessionGeneration += 1
        let oldSession = session
        let storage = oldSession.configuration.httpCookieStorage
        oldSession.invalidateAndCancel()
        storage?.cookies?.forEach { storage?.deleteCookie($0) }
        session = Self.makeSession(delegate: redirectGuard)
    }
    public func fetchAcademicData(campus: Campus, semesterCode: String? = nil) async throws -> AcademicSnapshot {
        try await SchoolRequestContext.$sessionGeneration.withValue(sessionGeneration) {
            switch campus {
            case .undergraduate: return try await undergraduateData(semesterCode: semesterCode)
            case .graduate: return try await graduateData(semesterCode: semesterCode)
            }
        }
    }
    private func request(base: URL, path: String, form: [String: String]? = nil, referer: String) async throws -> Data {
        try Task.checkCancellation()
        guard SchoolRequestContext.sessionGeneration == sessionGeneration else { throw CancellationError() }
        guard [SchoolEndpoint.undergraduate.host, SchoolEndpoint.graduate.host].contains(base.host), base.scheme == "https",
              path.hasPrefix("/"), !path.hasPrefix("//"), var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw SchoolClientError.unavailable("接口地址不在学校允许的范围内。")
        }
        components.path = path
        guard let url = components.url else { throw SchoolClientError.unavailable("接口地址无效。") }
        var request = URLRequest(url: url)
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
        request.setValue(base.absoluteString + referer, forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        if let form {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Self.formEncoded(form).data(using: .utf8)
        }
        let requestSession = session
        let (data, response) = try await requestSession.data(for: request)
        guard SchoolRequestContext.sessionGeneration == sessionGeneration else { throw CancellationError() }
        guard let http = response as? HTTPURLResponse else { throw SchoolClientError.malformedResponse("服务器") }
        if [301, 302, 303, 307, 308, 401, 403].contains(http.statusCode) { throw SchoolClientError.unauthorized }
        guard (200...299).contains(http.statusCode) else { throw SchoolClientError.server(http.statusCode) }
        guard data.count < 10_000_000 else { throw SchoolClientError.malformedResponse("过大的服务器") }
        // The school often returns HTTP 200 with an HTML login page after expiration.
        if let prefix = String(data: data.prefix(4096), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), prefix.hasPrefix("<") {
            throw SchoolClientError.unauthorized
        }
        _ = try SchoolParser.json(data, section: "学校接口")
        return data
    }
    static func formEncoded(_ form: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return form.keys.sorted().map { key in
            let name = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            let value = (form[key] ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return name + "=" + value
        }.joined(separator: "&")
    }
    private func undergraduateData(semesterCode requestedCode: String?) async throws -> AcademicSnapshot {
        let explicit = requestedCode.flatMap { $0.isEmpty ? nil : $0 }
        let code = explicit ?? SchoolParser.semesterCode()
        guard SchoolParser.validSemesterCode(code) else { throw SchoolClientError.invalidSemester }
        let calendarData = try await request(base: SchoolEndpoint.undergraduate, path: "/new/xlxx/data", form: ["xnxqdm": code], referer: "/new/welcome.page?ui=new")
        let semester = try SchoolParser.semester(calendarData, code: code)
        let results = try await fetchWeeks(semester: semester, graduate: false)
        let failedWeeks = results.filter(\.failed).map(\.week).sorted()
        var warnings: [String] = []
        var sessions = SchoolParser.sortedUnique(results.flatMap(\.sessions))
        if failedWeeks.count == results.count {
            let data = try await undergraduateSchedule(semester: semester, week: nil)
            sessions = try SchoolParser.semesterSessions(data, semester: semester)
            warnings.append("逐周课表暂不可用，当前显示学期总表；部分上课内容可能缺失。")
        } else if !failedWeeks.isEmpty {
            warnings.append("教务第 \(failedWeeks.map(String.init).joined(separator: "、")) 周同步失败，当前课表可能不完整，请重新同步。")
        }
        var snapshot = AcademicSnapshot(semester: semester, sessions: sessions, warnings: warnings)
        if !failedWeeks.isEmpty && failedWeeks.count < results.count { snapshot.failedSections.append(.sessions) }
        // Section failures are visible and never converted into a claim of a completely successful sync.
        do {
            let data = try await request(base: SchoolEndpoint.undergraduate, path: "/new/student/xskccj/kccjDatas", form: ["xnxqdm": "", "source": "kccjlist", "ismax": "1", "page": "1", "rows": "500", "sort": "xnxqdm,kcmc", "order": "desc,asc"], referer: "/new/student/xskccj/main.page")
            snapshot.grades = try SchoolParser.courseGrades(data)
            let sourceRows = try SchoolParser.rows(data, section: "课程成绩")
            if snapshot.grades.count < sourceRows.filter({ !$0.text("kcmc").isEmpty }).count { snapshot.warnings.append("部分课程的成绩为非数字或尚未公布，未计入成绩列表与估算绩点。") }
            if snapshot.grades.contains(where: { !$0.gpaAvailable }) { snapshot.warnings.append("部分课程没有可用绩点，未计入本地加权绩点估算；成绩仍正常显示。") }
            if (try SchoolParser.object(data, section: "课程成绩").number("total") ?? 0) > 500 { snapshot.warnings.append("课程成绩超过 500 条，仅显示学校返回的前 500 条。") }
        } catch { try rethrowCritical(error); snapshot.failedSections.append(.grades); snapshot.warnings.append("课程成绩同步失败，稍后可重新同步。") }
        do {
            let data = try await request(base: SchoolEndpoint.undergraduate, path: "/new/student/xskjcj/datas", form: ["page": "1", "rows": "100", "sort": "xnxqdm", "order": "asc"], referer: "/new/student/xskjcj/xskjcjlist.page")
            snapshot.levels = try SchoolParser.levelGrades(data)
        } catch { try rethrowCritical(error); snapshot.failedSections.append(.levels); snapshot.warnings.append("等级成绩同步失败，稍后可重新同步。") }
        do {
            let data = try await request(base: SchoolEndpoint.undergraduate, path: "/new/student/xstccj/datas", form: ["page": "1", "rows": "100", "sort": "xnxqdm", "order": "asc"], referer: "/new/student/xstccj")
            snapshot.fitness = try SchoolParser.fitnessGrades(data)
        } catch { try rethrowCritical(error); snapshot.failedSections.append(.fitness); snapshot.warnings.append("体测成绩同步失败，稍后可重新同步。") }
        do {
            let data = try await request(base: SchoolEndpoint.undergraduate, path: "/new/student/xsksrw/paginateXsksrw", form: ["xnxqdm": code, "page": "1", "rows": "100", "sort": "zc,xq,jcdm2", "order": "asc"], referer: "/new/student/xsksrw/list.page")
            snapshot.exams = try SchoolParser.exams(data)
        } catch { try rethrowCritical(error); snapshot.failedSections.append(.exams); snapshot.warnings.append("考试安排同步失败，稍后可重新同步。") }
        return snapshot
    }
    private func undergraduateSchedule(semester: Semester, week: Int?) async throws -> Data {
        let start = SchoolDate.addingDays(-1, to: semester.date(week: 1, weekday: 1))
        let end = SchoolDate.addingDays((semester.totalWeeks + 2) * 7, to: start)
        return try await request(base: SchoolEndpoint.undergraduate, path: "/new/student/xsgrkb/getCalendarWeekDatas",
            form: ["xnxqdm": semester.code, "zc": week.map(String.init) ?? "", "d1": SchoolDate.iso(start) + " 00:00:00", "d2": SchoolDate.iso(end) + " 00:00:00"], referer: "/new/student/xsgrkb/main.page")
    }
    private func fetchWeeks(semester: Semester, graduate: Bool) async throws -> [WeekResult] {
        // Include the extra school week for undergraduates: the last app Sunday belongs to the next school week.
        let last = graduate ? semester.totalWeeks : semester.totalWeeks + 1
        var results: [WeekResult] = []
        for first in stride(from: 1, through: last, by: 3) {
            try Task.checkCancellation()
            let batch = Array(first...min(first + 2, last))
            let partial = try await withThrowingTaskGroup(of: WeekResult.self) { group -> [WeekResult] in
                for week in batch {
                    group.addTask {
                        do {
                            let data: Data
                            let sessions: [CourseSession]
                            if graduate {
                                data = try await self.request(base: SchoolEndpoint.graduate, path: "/gmis5/student/pygl/py_kbcx_ew1", form: ["kblx": "xs", "termcode": semester.code, "skksz": String(week), "skjsz": String(week), "xzbj": "", "jh": ""], referer: "/gmis5/student/pygl/xskbcx")
                                sessions = try SchoolParser.graduateSessions(data, requestedWeek: week)
                            } else {
                                data = try await self.undergraduateSchedule(semester: semester, week: week)
                                sessions = try SchoolParser.weeklySessions(data, schoolWeek: week, semester: semester)
                            }
                            return WeekResult(week: week, sessions: sessions, failed: false)
                        } catch {
                            if error is CancellationError { throw error }
                            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
                            if (error as? SchoolClientError) == .unauthorized { throw error }
                            return WeekResult(week: week, sessions: [], failed: true)
                        }
                    }
                }
                var values: [WeekResult] = []
                for try await value in group { values.append(value) }
                return values
            }
            results += partial
        }
        return results
    }
    private func graduateData(semesterCode: String?) async throws -> AcademicSnapshot {
        let data = try await request(base: SchoolEndpoint.graduate, path: "/gmis5/student/default/bindterm", referer: "/gmis5/student/default/index")
        let terms = try SchoolParser.graduateTerms(data)
        let requested = semesterCode.flatMap { $0.isEmpty ? nil : $0 }
        let selected = requested.flatMap { code in terms.first { $0.code == code } } ?? terms.first(where: \.selected) ?? terms.first
        guard let term = selected, requested == nil || term.code == requested else { throw SchoolClientError.invalidSemester }
        // No school calendar endpoint was found upstream; 20 weeks is an explicit bounded assumption.
        let provisional = Semester(code: term.code, name: term.name, firstMonday: "", totalWeeks: 20)
        let results = try await fetchWeeks(semester: provisional, graduate: true)
        let sessions = SchoolParser.sortedUnique(results.flatMap(\.sessions))
        let semester = try SchoolParser.graduateSemester(term: term, sessions: sessions)
        var snapshot = AcademicSnapshot(semester: semester, sessions: sessions)
        let failed = results.filter(\.failed).map(\.week).sorted()
        if !failed.isEmpty { snapshot.failedSections.append(.sessions); snapshot.warnings.append("研究生第 \(failed.map(String.init).joined(separator: "、")) 周同步失败，课表可能不完整。") }
        snapshot.warnings.append("研究生周历由课表日期推算；默认查询 20 周。研究生成绩字段沿用上游实现，需与学校网页核对。")
        do {
            let data = try await request(base: SchoolEndpoint.graduate, path: "/gmis5/student/pygl/xscjcx_list", referer: "/gmis5/student/pygl/xscjcx")
            snapshot.grades = try SchoolParser.graduateGrades(data)
        } catch { try rethrowCritical(error); snapshot.failedSections.append(.grades); snapshot.warnings.append("研究生成绩同步失败，稍后可重新同步。") }
        return snapshot
    }
    private func rethrowCritical(_ error: Error) throws {
        if error is CancellationError { throw error }
        if (error as? URLError)?.code == .cancelled { throw CancellationError() }
        if (error as? SchoolClientError) == .unauthorized { throw error }
    }
}
