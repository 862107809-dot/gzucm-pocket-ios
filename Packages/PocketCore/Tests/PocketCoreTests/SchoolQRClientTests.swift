import Foundation
import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import PocketCore

private let qrFixtureID = "qrcodeLogin_synthetic_123456"
private let qrFixtureConfirmation = "http://jw.gzucm.edu.cn/#/qrcodeConfirm/showConfirm?qrcodeId=\(qrFixtureID)"
private let qrProbePath = "/new/student/xsgrkb/getCalendarWeekDatas"

private final class QRClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = ISO8601DateFormatter().date(from: "2026-11-05T08:00:00Z")!
    func date() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; value.addTimeInterval(seconds) }
}

private struct QRMockReply: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var data: Data
    var delay: TimeInterval = 0
    init(_ value: Any, status: Int = 200, headers: [String: String] = [:], delay: TimeInterval = 0) {
        self.status = status; self.headers = headers; self.delay = delay
        self.data = value is String ? Data((value as! String).utf8) : try! JSONSerialization.data(withJSONObject: value)
    }
}

/// Synthetic-only transport. Every request is intercepted, including a mistakenly foreign URL.
private final class QRScript: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var status = "0"
    let override: (@Sendable (URLRequest) -> QRMockReply?)?
    init(override: (@Sendable (URLRequest) -> QRMockReply?)? = nil) { self.override = override }
    func setStatus(_ value: String) { lock.lock(); defer { lock.unlock() }; status = value }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    func reply(_ request: URLRequest) -> QRMockReply {
        lock.lock(); recorded.append(request); let phase = status; lock.unlock()
        if let result = override?(request) { return result }
        switch request.url?.path {
        case "/", "": return QRMockReply("<html>official school login</html>", headers: ["Set-Cookie": "WAF=synthetic-anonymous; Path=/; Secure"])
        case "/new/qrcodeLogin/qrcode": return QRMockReply(["code": 0, "data": Self.json(["qrcodeId": qrFixtureID, "confirmUrl": qrFixtureConfirmation])])
        case "/new/qrcodeLogin/qrcodeStatus": return QRMockReply(["code": 0, "data": Self.json(["scanInfo": Self.json(["status": phase, "url": "/new/finish"])])])
        case "/new/finish": return QRMockReply("finished", headers: ["Set-Cookie": "JSESSIONID=synthetic-root; Path=/; Secure; HttpOnly, JSESSIONID=synthetic-new; Path=/new; Secure; HttpOnly"])
        case qrProbePath: return QRMockReply(["code": 0, "data": []])
        default: return QRMockReply("unexpected synthetic endpoint", status: 500)
        }
    }
    static func json(_ value: Any) -> String { String(data: try! JSONSerialization.data(withJSONObject: value), encoding: .utf8)! }
}

private final class QRMockRegistry: @unchecked Sendable {
    static let shared = QRMockRegistry()
    private let lock = NSLock()
    private var scripts: [String: QRScript] = [:]
    func put(_ script: QRScript, id: String) { lock.lock(); defer { lock.unlock() }; scripts[id] = script }
    func get(_ id: String) -> QRScript? { lock.lock(); defer { lock.unlock() }; return scripts[id] }
    func remove(_ id: String) { lock.lock(); defer { lock.unlock() }; scripts.removeValue(forKey: id) }
}

private final class QRMockProtocol: URLProtocol, @unchecked Sendable {
    private let stateLock = NSLock()
    private var stopped = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-Pocket-Mock-ID"), let script = QRMockRegistry.shared.get(id), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let reply = script.reply(request)
        let deliver: @Sendable () -> Void = { [self] in
            stateLock.lock(); let cancelled = stopped; stateLock.unlock()
            guard !cancelled else { return }
            let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.data)
            client?.urlProtocolDidFinishLoading(self)
        }
        if reply.delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: deliver) }
        else { deliver() }
    }
    override func stopLoading() { stateLock.lock(); stopped = true; stateLock.unlock() }
}

final class SchoolQRClientTests: XCTestCase {
    private func makeClient(_ script: QRScript, clock: QRClock, id: String) -> SchoolQRClient {
        QRMockRegistry.shared.put(script, id: id)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [QRMockProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Pocket-Mock-ID": id]
        return SchoolQRClient(configuration: configuration, now: { clock.date() })
    }
    private func form(_ request: URLRequest) -> [String: String] {
        var bytes = request.httpBody ?? Data()
        if bytes.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
        }
        return Dictionary(uniqueKeysWithValues: String(data: bytes, encoding: .utf8)!.split(separator: "&").map {
            let pair = $0.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (String(pair[0]).removingPercentEncoding!, pair.count > 1 ? String(pair[1]).removingPercentEncoding! : "")
        })
    }
    private func assertSafe(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(error is SchoolClientError || error is CancellationError, file: file, line: line)
        for secret in ["synthetic-root", "synthetic-new", "evil.example", "https://", "qrcodeLogin_"] {
            XCTAssertFalse(error.localizedDescription.contains(secret), file: file, line: line)
        }
    }

    func testStartPrimesOfficialCookiesAndPostsAnEmptyForm() async throws {
        let id = UUID().uuidString; defer { QRMockRegistry.shared.remove(id) }
        let script = QRScript(), clock = QRClock(), client = makeClient(script, clock: clock, id: id)
        let result = try await client.start()
        XCTAssertEqual(result.id, qrFixtureID)
        XCTAssertEqual(result.confirmURL.absoluteString, qrFixtureConfirmation.replacingOccurrences(of: "http:", with: "https:"))
        XCTAssertEqual(result.expiresAt.timeIntervalSince(clock.date()), 300)
        XCTAssertEqual(script.requests.count, 2)
        XCTAssertEqual(script.requests[0].httpMethod, "GET")
        XCTAssertEqual(script.requests[1].httpMethod, "POST")
        XCTAssertEqual(form(script.requests[1]), [:])
        XCTAssertEqual(script.requests[1].value(forHTTPHeaderField: "Cookie"), "WAF=synthetic-anonymous")
        await client.cancel()
    }

    func testNestedWaitingScannedAndDirectObjectResponses() async throws {
        let id = UUID().uuidString; defer { QRMockRegistry.shared.remove(id) }
        let script = QRScript(), clock = QRClock(), client = makeClient(script, clock: clock, id: id)
        _ = try await client.start()
        guard case .waiting = try await client.poll() else { return XCTFail("Expected waiting") }
        script.setStatus("1"); clock.advance(3)
        guard case .scanned = try await client.poll() else { return XCTFail("Expected scanned") }
        XCTAssertEqual(form(script.requests.last!)["qrcodeId"], qrFixtureID)
        await client.cancel()
        let direct = QRScript { request in
            if request.url?.path.hasSuffix("/qrcode") == true { return QRMockReply(["code": 0, "data": ["qrcodeId": qrFixtureID, "confirmUrl": qrFixtureConfirmation]]) }
            if request.url?.path.hasSuffix("/qrcodeStatus") == true { return QRMockReply(["code": "0", "data": ["status": 1, "scanInfo": NSNull()]]) }
            return nil
        }
        let directID = UUID().uuidString; defer { QRMockRegistry.shared.remove(directID) }
        let directClient = makeClient(direct, clock: clock, id: directID)
        _ = try await directClient.start()
        guard case .scanned = try await directClient.poll() else { return XCTFail("Expected direct scanned") }
        await directClient.cancel()
    }

    func testAuthenticationRequiresProtectedProbeAndPreservesCookiePaths() async throws {
        let id = UUID().uuidString; defer { QRMockRegistry.shared.remove(id) }
        let script = QRScript { request in
            request.url?.path == "/new/finish" ? QRMockReply("finished", headers: ["Set-Cookie": "JSESSIONID=synthetic-root; Domain=gzucm.edu.cn; Path=/; Secure; HttpOnly, JSESSIONID=synthetic-new; Path=/new; Secure; HttpOnly"]) : nil
        }
        let clock = QRClock(), client = makeClient(script, clock: clock, id: id)
        script.setStatus("2")
        _ = try await client.start()
        guard case .authenticated(let cookies) = try await client.poll(semesterCode: "202601") else { return XCTFail("Expected authenticated") }
        XCTAssertEqual(Set(cookies.filter { $0.name == "JSESSIONID" }.map(\.path)), ["/", "/new"])
        XCTAssertEqual(cookies.first { $0.value == "synthetic-root" }?.domain, ".gzucm.edu.cn")
        let probe = try XCTUnwrap(script.requests.first { $0.url?.path == qrProbePath })
        XCTAssertEqual(form(probe), ["xnxqdm": "202601", "zc": "", "d1": "2026-07-01 00:00:00", "d2": "2027-08-31 00:00:00"])
        XCTAssertEqual(probe.value(forHTTPHeaderField: "Cookie"), "JSESSIONID=synthetic-new; JSESSIONID=synthetic-root; WAF=synthetic-anonymous")
        XCTAssertTrue(script.requests.allSatisfy { $0.url?.host == "jw.gzucm.edu.cn" && $0.url?.scheme == "https" })
        guard case .expired = try await client.poll() else { return XCTFail("A successful challenge is consumed") }
    }

    func testExpiredChallengeMakesNoFurtherNetworkRequest() async throws {
        let id = UUID().uuidString; defer { QRMockRegistry.shared.remove(id) }
        let script = QRScript(), clock = QRClock(), client = makeClient(script, clock: clock, id: id)
        _ = try await client.start(); clock.advance(300)
        guard case .expired = try await client.poll() else { return XCTFail("Expected expired") }
        XCTAssertEqual(script.requests.count, 2)
    }

    func testInvalidConfirmationURLsAndIDsNeverLeaveTheClient() async throws {
        for url in ["https://evil.example/#/qrcodeConfirm/showConfirm?qrcodeId=\(qrFixtureID)", "https://jw.gzucm.edu.cn:8443/#/qrcodeConfirm/showConfirm?qrcodeId=\(qrFixtureID)", "https://user:secret@jw.gzucm.edu.cn/#/qrcodeConfirm/showConfirm?qrcodeId=\(qrFixtureID)", "https://jw.gzucm.edu.cn/#/qrcodeConfirm/other?qrcodeId=\(qrFixtureID)", "https://jw.gzucm.edu.cn/#/qrcodeConfirm/showConfirm?qrcodeId=other", "https://jw.gzucm.edu.cn/#/qrcodeConfirm/showConfirm?qrcodeId=\(qrFixtureID)&qrcodeId=\(qrFixtureID)"] {
            let id = UUID().uuidString; defer { QRMockRegistry.shared.remove(id) }
            let script = QRScript { request in request.url?.path.hasSuffix("/qrcode") == true ? QRMockReply(["code": 0, "data": ["qrcodeId": qrFixtureID, "confirmUrl": url]]) : nil }
            let client = makeClient(script, clock: QRClock(), id: id)
            do { _ = try await client.start(); XCTFail("Unsafe URL accepted") } catch { assertSafe(error) }
            XCTAssertEqual(script.requests.count, 2)
        }
        let id = UUID().uuidString; defer { QRMockRegistry.shared.remove(id) }
        let script = QRScript { request in request.url?.path.hasSuffix("/qrcode") == true ? QRMockReply(["code": 0, "data": ["qrcodeId": "../bad", "confirmUrl": qrFixtureConfirmation]]) : nil }
        do { _ = try await makeClient(script, clock: QRClock(), id: id).start(); XCTFail("Unsafe ID accepted") } catch { assertSafe(error) }
    }

    func testForeignCompletionURLsAndRedirectsAreNeverRequested() async throws {
        for foreignStatusURL in [false, true] {
            let id = UUID().uuidString; defer { QRMockRegistry.shared.remove(id) }
            let script = QRScript { request in
                if foreignStatusURL && request.url?.path.hasSuffix("/qrcodeStatus") == true { return QRMockReply(["code": 0, "data": ["status": "2", "url": "https://evil.example/steal"]]) }
                if request.url?.path == "/new/finish" { return QRMockReply("", status: 302, headers: ["Location": "https://evil.example/steal"]) }
                return nil
            }
            script.setStatus("2")
            let client = makeClient(script, clock: QRClock(), id: id)
            _ = try await client.start()
            do { _ = try await client.poll(); XCTFail("Foreign destination accepted") } catch { assertSafe(error) }
            XCTAssertTrue(script.requests.allSatisfy { $0.url?.host == "jw.gzucm.edu.cn" })
            XCTAssertFalse(script.requests.contains { $0.url?.path == qrProbePath })
            await client.cancel()
        }
    }

    func testCookieAloneAndMalformedOrUnauthenticatedProbeNeverAuthenticate() async throws {
        for mode in 0..<8 {
            let id = UUID().uuidString; defer { QRMockRegistry.shared.remove(id) }
            let script = QRScript { request in
                if mode == 0 && request.url?.path == "/new/finish" { return QRMockReply("finished") }
                if mode == 5 && request.url?.path == "/new/finish" { return QRMockReply("finished", headers: ["Set-Cookie": "JSESSIONID=synthetic-root; Path=/; Secure; Max-Age=0"]) }
                if mode == 6 && request.url?.path == "/new/finish" { return QRMockReply("finished", headers: ["Set-Cookie": "JSESSIONID=synthetic-root; Path=/unrelated; Secure"]) }
                if mode == 7 && request.url?.path == "/new/finish" { return QRMockReply("finished", headers: ["Set-Cookie": "JSESSIONID=synthetic-root; Domain=evil.example; Path=/; Secure"]) }
                if request.url?.path == qrProbePath {
                    if mode == 1 { return QRMockReply(["code": 0, "data": [:]]) }
                    if mode == 2 { return QRMockReply(["code": -401, "message": "尚未登录 synthetic-root"]) }
                    if mode == 3 { return QRMockReply("<html>login synthetic-root</html>") }
                    if mode == 4 { return QRMockReply(["code": 0, "rows": []]) }
                }
                return nil
            }
            script.setStatus("2")
            let client = makeClient(script, clock: QRClock(), id: id)
            _ = try await client.start()
            do { _ = try await client.poll(); XCTFail("Probe must be verified") } catch { assertSafe(error) }
            XCTAssertTrue(script.requests.contains { $0.url?.path == qrProbePath })
            await client.cancel()
        }
    }

    func testSemesterValidationAndThreeSecondThrottlePrecedeNetwork() async throws {
        let id = UUID().uuidString; defer { QRMockRegistry.shared.remove(id) }
        let script = QRScript(), clock = QRClock(), client = makeClient(script, clock: clock, id: id)
        _ = try await client.start()
        do { _ = try await client.poll(semesterCode: "https://evil.example"); XCTFail("Invalid semester accepted") }
        catch { XCTAssertEqual(error as? SchoolClientError, .invalidSemester) }
        XCTAssertEqual(script.requests.count, 2)
        _ = try await client.poll(); clock.advance(2.99)
        do { _ = try await client.poll(); XCTFail("Early poll accepted") } catch { assertSafe(error) }
        XCTAssertEqual(script.requests.count, 3)
        clock.advance(0.02); _ = try await client.poll()
        XCTAssertEqual(script.requests.count, 4)
        await client.cancel()
    }

    func testSameOriginRedirectsAreLimitedToFour() async throws {
        for tooMany in [false, true] {
            let id = UUID().uuidString; defer { QRMockRegistry.shared.remove(id) }
            let script = QRScript { request in
                if request.url?.path == "/new/finish" { return QRMockReply("", status: 302, headers: ["Location": "/hop/1"]) }
                if let path = request.url?.path, path.hasPrefix("/hop/"), let index = Int(path.split(separator: "/").last!) {
                    if index < (tooMany ? 5 : 4) { return QRMockReply("", status: 302, headers: ["Location": "/hop/\(index + 1)"]) }
                    return QRMockReply("finished", headers: ["Set-Cookie": "JSESSIONID=synthetic-root; Path=/; Secure"])
                }
                return nil
            }
            script.setStatus("2")
            let client = makeClient(script, clock: QRClock(), id: id)
            _ = try await client.start()
            if tooMany {
                do { _ = try await client.poll(); XCTFail("A fifth redirect was accepted") } catch { assertSafe(error) }
                XCTAssertFalse(script.requests.contains { $0.url?.path == "/hop/5" })
            } else {
                guard case .authenticated = try await client.poll() else { return XCTFail("Four valid redirects should succeed") }
            }
            await client.cancel()
        }
    }

    func testCancelInvalidatesAnInflightStart() async throws {
        let id = UUID().uuidString; defer { QRMockRegistry.shared.remove(id) }
        let requested = expectation(description: "QR request started")
        let script = QRScript { request in
            if request.url?.path.hasSuffix("/qrcode") == true {
                requested.fulfill()
                return QRMockReply(["code": 0, "data": ["qrcodeId": qrFixtureID, "confirmUrl": qrFixtureConfirmation]], delay: 0.15)
            }
            return nil
        }
        let client = makeClient(script, clock: QRClock(), id: id)
        let pending = Task { try await client.start() }
        await fulfillment(of: [requested], timeout: 3)
        await client.cancel()
        do { _ = try await pending.value; XCTFail("Cancelled challenge revived") } catch { XCTAssertTrue(error is CancellationError) }
        guard case .expired = try await client.poll() else { return XCTFail("Cancelled client must stay expired") }
    }

    func testCancelDuringProtectedProbeCannotReturnAuthenticatedCookies() async throws {
        let id = UUID().uuidString; defer { QRMockRegistry.shared.remove(id) }
        let requested = expectation(description: "Protected probe started")
        let script = QRScript { request in
            if request.url?.path == qrProbePath { requested.fulfill(); return QRMockReply(["code": 0, "data": []], delay: 0.15) }
            return nil
        }
        script.setStatus("2")
        let client = makeClient(script, clock: QRClock(), id: id)
        _ = try await client.start()
        let pending = Task { try await client.poll() }
        await fulfillment(of: [requested], timeout: 3)
        await client.cancel()
        do { _ = try await pending.value; XCTFail("Cancelled probe returned authentication") } catch { XCTAssertTrue(error is CancellationError) }
        guard case .expired = try await client.poll() else { return XCTFail("Cancelled client must stay expired") }
        _ = try await client.start()
        XCTAssertEqual(script.requests.last?.value(forHTTPHeaderField: "Cookie"), "WAF=synthetic-anonymous", "A new challenge must not inherit authenticated cookies")
        await client.cancel()
    }
}
