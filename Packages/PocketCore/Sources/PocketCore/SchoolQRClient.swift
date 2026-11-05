import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct SchoolQRChallenge: Sendable, Equatable {
    public let id: String
    public let confirmURL: URL
    public let expiresAt: Date
}

public enum SchoolQRPoll: Sendable {
    case waiting
    case scanned
    case authenticated([HTTPCookie])
    case expired
}

private final class SchoolQRRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Follow redirects explicitly, after validating each destination.
        completionHandler(nil)
    }
}

/// The school's direct undergraduate QR protocol, isolated from WebKit and persistent storage.
/// Source: the verified native-school flow in GZUCM-Pocket-Web/lib/qr.ts.
public actor SchoolQRClient {
    private static let base = URL(string: "https://jw.gzucm.edu.cn")!
    private static let probePath = "/new/student/xsgrkb/getCalendarWeekDatas"
    private let configuration: URLSessionConfiguration
    private let redirectGuard: SchoolQRRedirectGuard
    private var session: URLSession
    private let now: @Sendable () -> Date
    private var generation = 0
    private var challenge: SchoolQRChallenge?
    private var cookies: [HTTPCookie] = []
    private var lastPoll: Date?
    private var busy = false

    public init(configuration: URLSessionConfiguration = .ephemeral,
                now: @escaping @Sendable () -> Date = { Date() }) {
        // Even an injected configuration cannot enable disk caches or a shared cookie jar.
        let ephemeral = URLSessionConfiguration.ephemeral
        ephemeral.protocolClasses = configuration.protocolClasses
        ephemeral.httpAdditionalHeaders = configuration.httpAdditionalHeaders
        ephemeral.timeoutIntervalForRequest = 15
        ephemeral.timeoutIntervalForResource = 30
        ephemeral.httpMaximumConnectionsPerHost = 1
        ephemeral.requestCachePolicy = .reloadIgnoringLocalCacheData
        ephemeral.urlCache = nil
        ephemeral.httpCookieStorage = nil
        ephemeral.httpShouldSetCookies = false
        let delegate = SchoolQRRedirectGuard()
        self.configuration = ephemeral
        self.redirectGuard = delegate
        self.session = URLSession(configuration: ephemeral, delegate: delegate, delegateQueue: nil)
        self.now = now
    }

    public func cancel() async { reset() }

    public func start() async throws -> SchoolQRChallenge {
        reset()
        let token = generation
        let created = now()
        busy = true
        defer { if token == generation { busy = false } }
        do {
            // The original school flow first primes anonymous/WAF cookies on its login page.
            do { _ = try await exchange(Self.base, form: nil, token: token) }
            catch { try check(token) }
            let data = try await exchange(Self.base.appendingPathComponent("new/qrcodeLogin/qrcode"), form: [:], token: token)
            let root = try Self.schoolObject(data)
            let detail = try Self.object(root["data"])
            guard let id = detail["qrcodeId"] as? String, Self.validID(id),
                  let rawURL = detail["confirmUrl"] as? String else { throw Self.malformed() }
            let result = SchoolQRChallenge(id: id, confirmURL: try Self.confirmURL(rawURL, id: id), expiresAt: created.addingTimeInterval(300))
            try check(token)
            guard now() < result.expiresAt else { throw SchoolClientError.unavailable("二维码已过期，请重新获取。") }
            challenge = result
            return result
        } catch {
            if token == generation { reset() }
            throw error
        }
    }

    /// Call no faster than once every three seconds. A protected session probe is mandatory.
    public func poll(semesterCode: String? = nil) async throws -> SchoolQRPoll {
        guard let active = challenge else { return .expired }
        guard now() < active.expiresAt else { reset(); return .expired }
        guard !busy else { throw SchoolClientError.unavailable("扫码请求正在处理中，请稍后重试。") }
        let code = semesterCode ?? SchoolParser.semesterCode(for: now())
        guard SchoolParser.validSemesterCode(code) else { throw SchoolClientError.invalidSemester }
        if let lastPoll, now().timeIntervalSince(lastPoll) < 3 {
            throw SchoolClientError.unavailable("请稍候三秒再检查扫码状态。")
        }
        let token = generation
        busy = true
        lastPoll = now()
        defer { if token == generation { busy = false } }
        do {
            let raw = try await exchange(Self.base.appendingPathComponent("new/qrcodeLogin/qrcodeStatus"), form: ["qrcodeId": active.id], token: token)
            let root = try Self.schoolObject(raw)
            let detail = try Self.object(root["data"])
            let info: [String: Any]
            if let scanInfo = detail["scanInfo"], !(scanInfo is NSNull) { info = try Self.object(scanInfo) }
            else { info = detail }
            let status = Self.text(info["status"] ?? detail["status"])
            guard now() < active.expiresAt else { reset(); return .expired }
            switch status {
            case "0": return .waiting
            case "1": return .scanned
            case "2":
                guard let target = (info["url"] ?? detail["url"]) as? String, !target.isEmpty, target.count <= 3000 else { throw Self.malformed() }
                _ = try await exchange(Self.schoolURL(target), form: nil, token: token)
                let year = String(code.prefix(4))
                let nextYear = String((Int(year) ?? 0) + 1)
                let probeURL = Self.base.appendingPathComponent(String(Self.probePath.dropFirst()))
                let probeData = try await exchange(probeURL, form: [
                    "xnxqdm": code, "zc": "", "d1": "\(year)-07-01 00:00:00", "d2": "\(nextYear)-08-31 00:00:00"
                ], token: token)
                let probe = try Self.schoolObject(probeData)
                guard probe["data"] is [Any], matchingCookies(probeURL).contains(where: { $0.name == "JSESSIONID" && !$0.value.isEmpty }) else {
                    throw SchoolClientError.unauthorized
                }
                try check(token)
                guard now() < active.expiresAt else { reset(); return .expired }
                let authenticated = unexpiredCookies()
                // Consume the challenge; only the returned cookie copies leave this actor.
                reset()
                return .authenticated(authenticated)
            default: throw Self.malformed()
            }
        } catch {
            if token != generation || Task.isCancelled { throw CancellationError() }
            if (error as? SchoolClientError) == .unauthorized { reset() }
            throw error
        }
    }

    private func reset() {
        generation += 1
        session.invalidateAndCancel()
        session = URLSession(configuration: configuration, delegate: redirectGuard, delegateQueue: nil)
        challenge = nil
        cookies = []
        lastPoll = nil
        busy = false
    }

    private func check(_ token: Int) throws {
        try Task.checkCancellation()
        guard token == generation else { throw CancellationError() }
    }

    private func exchange(_ input: URL, form: [String: String]?, token: Int, redirects: Int = 0) async throws -> Data {
        try check(token)
        guard redirects <= 4 else { throw SchoolClientError.unavailable("学校登录跳转次数过多，请重新获取二维码。") }
        let url = try Self.schoolURL(input.absoluteString)
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("application/json, text/javascript, */*; q=0.01", forHTTPHeaderField: "Accept")
        request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        request.setValue("zh-CN,zh;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue(Self.base.absoluteString + (url.path == Self.probePath ? "/new/student/xsgrkb/main.page" : "/"), forHTTPHeaderField: "Referer")
        let applicable = matchingCookies(url)
        if !applicable.isEmpty { request.setValue(applicable.map { "\($0.name)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie") }
        if let form {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = SchoolClient.formEncoded(form).data(using: .utf8)
        }
        let currentSession = session
        let data: Data
        let response: URLResponse
        do { (data, response) = try await currentSession.data(for: request) }
        catch {
            try check(token)
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw SchoolClientError.unavailable("暂时无法连接学校扫码服务，请稍后重试。")
        }
        try check(token)
        guard let http = response as? HTTPURLResponse, let responseURL = http.url else { throw Self.malformed() }
        _ = try Self.schoolURL(responseURL.absoluteString)
        guard data.count <= 1_048_576, http.expectedContentLength <= 1_048_576 else { throw Self.malformed() }
        try capture(http, url: url)
        if (300...399).contains(http.statusCode) {
            guard let location = http.value(forHTTPHeaderField: "Location"),
                  let target = URL(string: location, relativeTo: url)?.absoluteURL else { throw Self.malformed() }
            return try await exchange(Self.schoolURL(target.absoluteString), form: [307, 308].contains(http.statusCode) ? form : nil, token: token, redirects: redirects + 1)
        }
        if [401, 403].contains(http.statusCode) { throw SchoolClientError.unauthorized }
        guard (200...299).contains(http.statusCode) else { throw SchoolClientError.server(http.statusCode) }
        return data
    }

    private func unexpiredCookies() -> [HTTPCookie] { cookies.filter { $0.expiresDate.map { $0 > now() } ?? true } }
    private func matchingCookies(_ url: URL) -> [HTTPCookie] {
        unexpiredCookies().filter { cookie in
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let host = url.host?.lowercased() ?? ""
            let domainMatches = host == domain || cookie.domain.hasPrefix(".") && host.hasSuffix("." + domain)
            let pathMatches = url.path == cookie.path || url.path.hasPrefix(cookie.path) && (cookie.path.hasSuffix("/") || url.path.dropFirst(cookie.path.count).hasPrefix("/"))
            return domainMatches && pathMatches && (!cookie.isSecure || url.scheme == "https")
        }.sorted { $0.path.count == $1.path.count ? $0.name < $1.name : $0.path.count > $1.path.count }
    }
    private func capture(_ response: HTTPURLResponse, url: URL) throws {
        guard let raw = response.value(forHTTPHeaderField: "Set-Cookie") else { return }
        // An Expires attribute contains a comma; split only before a new cookie name.
        let pattern = ",(?=\\s*[!#$%&'*+\\-.^_`|~0-9A-Za-z]+=)"
        let separated = raw.replacingOccurrences(of: pattern, with: "\n", options: .regularExpression)
        for entry in separated.components(separatedBy: "\n") {
            var attributes: [String: String] = [:]
            for attribute in entry.split(separator: ";").dropFirst() {
                let pair = attribute.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
                attributes[key] = pair.count == 2 ? pair[1].trimmingCharacters(in: .whitespaces) : ""
            }
            let declaredDomain = attributes["domain"]?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if let declaredDomain, !["jw.gzucm.edu.cn", "gzucm.edu.cn"].contains(declaredDomain) { continue }
            for parsed in HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": entry], for: url) {
                var properties = parsed.properties ?? [:]
                // Retain RFC domain cookies even when Domain omitted the legacy leading dot.
                properties[.domain] = declaredDomain.map { "." + $0 } ?? url.host!
                if let rawAge = attributes["max-age"], let seconds = Int(rawAge) {
                    // Max-Age is relative to receipt, including under an injected test clock.
                    properties.removeValue(forKey: .maximumAge)
                    properties[.expires] = now().addingTimeInterval(TimeInterval(seconds))
                }
                guard let cookie = HTTPCookie(properties: properties) else { continue }
                let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                guard ["jw.gzucm.edu.cn", "gzucm.edu.cn"].contains(domain), cookie.path.hasPrefix("/"), cookie.path.count <= 300 else { continue }
                guard !cookie.name.isEmpty, cookie.name.count <= 100, !cookie.value.unicodeScalars.contains(where: { $0.value < 33 || $0.value > 126 || $0 == ";" || $0 == "," }) else { continue }
                if cookie.name.hasPrefix("__Secure-"), !cookie.isSecure { continue }
                if cookie.name.hasPrefix("__Host-"), !cookie.isSecure || declaredDomain != nil || cookie.path != "/" { continue }
                cookies.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
                if !cookie.value.isEmpty, cookie.expiresDate.map({ $0 > now() }) ?? true { cookies.append(cookie) }
            }
        }
        cookies = unexpiredCookies()
        guard cookies.count <= 64 else { throw Self.malformed() }
    }

    private static func malformed() -> SchoolClientError { .malformedResponse("学校二维码") }
    private static func text(_ value: Any?) -> String {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return ""
    }
    private static func object(_ value: Any?) throws -> [String: Any] {
        if let object = value as? [String: Any] { return object }
        if let string = value as? String, let data = string.data(using: .utf8), data.count <= 1_048_576,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return object }
        throw malformed()
    }
    private static func schoolObject(_ data: Data) throws -> [String: Any] {
        if let prefix = String(data: data.prefix(256), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), prefix.hasPrefix("<") { throw SchoolClientError.unauthorized }
        guard let decoded = try? JSONSerialization.jsonObject(with: data) else { throw malformed() }
        let root = try object(decoded)
        let code = text(root["code"])
        let message = text(root["message"] ?? root["msg"])
        if ["-401", "401", "403"].contains(code) || ["尚未登录", "请先登录", "已在别处登录", "会话已失效", "会话已过期"].contains(where: message.contains) { throw SchoolClientError.unauthorized }
        guard code == "0" else { throw SchoolClientError.unavailable("学校未接受本次扫码请求，请重新获取二维码。") }
        return root
    }
    private static func validID(_ value: String) -> Bool { value.range(of: "^qrcodeLogin_[A-Za-z0-9_-]{4,240}$", options: .regularExpression) != nil }
    private static func schoolURL(_ raw: String) throws -> URL {
        guard raw.count <= 3000, let url = URL(string: raw, relativeTo: base)?.absoluteURL,
              url.scheme == "https", url.host?.lowercased() == "jw.gzucm.edu.cn", url.port == nil,
              url.user == nil, url.password == nil else { throw malformed() }
        return url
    }
    private static func confirmURL(_ raw: String, id: String) throws -> URL {
        guard raw.count <= 2048, let url = URL(string: raw, relativeTo: base)?.absoluteURL,
              let host = url.host?.lowercased(), host == "gzucm.edu.cn" || host.hasSuffix(".gzucm.edu.cn"),
              ["https", "http"].contains(url.scheme ?? ""), url.port == nil, url.user == nil, url.password == nil,
              let fragment = url.fragment, let inner = URLComponents(string: base.absoluteString + fragment),
              inner.host == "jw.gzucm.edu.cn", inner.path == "/qrcodeConfirm/showConfirm",
              let ids = inner.queryItems?.filter({ $0.name == "qrcodeId" }), ids.count == 1, ids[0].value == id,
              let result = URL(string: "https://\(host)/#/qrcodeConfirm/showConfirm?qrcodeId=\(id)") else { throw malformed() }
        return result
    }
}
