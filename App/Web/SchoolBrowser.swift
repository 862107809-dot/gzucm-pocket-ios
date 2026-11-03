import SwiftUI
import WebKit
import PocketCore
import CoreFoundation

/// Both portals share WebKit's app-private data store, including the school's SSO cookies.
/// No script reads login forms, passwords or keyboard input.
@MainActor
struct SchoolLoginView: View {
    @StateObject private var browser: SchoolBrowser
    let onCancel: () -> Void

    init(campus: Campus, onAuthenticated: @escaping ([HTTPCookie]) -> Void, onCancel: @escaping () -> Void) {
        _browser = StateObject(wrappedValue: SchoolBrowser(campus: campus, onAuthenticated: onAuthenticated))
        self.onCancel = onCancel
    }

    var body: some View {
        BrowserChrome(browser: browser, title: "登录学校系统", closeTitle: "取消", onClose: onCancel)
    }
}

@MainActor
struct EcardPortalView: View {
    @StateObject private var browser: SchoolBrowser
    let onClose: () -> Void

    init(onSnapshot: @escaping (PowerSnapshot) -> Void, onClose: @escaping () -> Void) {
        _browser = StateObject(wrappedValue: SchoolBrowser(onSnapshot: onSnapshot))
        self.onClose = onClose
    }

    var body: some View {
        BrowserChrome(browser: browser, title: "校园卡与电费", closeTitle: "完成", onClose: onClose)
    }
}

@MainActor
private struct BrowserChrome: View {
    @ObservedObject var browser: SchoolBrowser
    let title: String
    let closeTitle: String
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(browser.displayHost, systemImage: "lock.shield")
                        .font(.caption.weight(.medium))
                    Text(browser.status).font(.subheadline).foregroundStyle(.secondary)
                    if let error = browser.error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(.thinMaterial)
                if browser.isLoading { ProgressView().progressViewStyle(.linear) }
                SchoolWebView(browser: browser)
                Text("请在学校网页输入账号密码。课表与电费均直接连接学校系统。")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(closeTitle) { browser.stop(); onClose() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { browser.goBack() } label: { Image(systemName: "chevron.backward") }
                        .accessibilityLabel("返回上一页")
                    Button { browser.reload() } label: { Image(systemName: "arrow.clockwise") }
                        .accessibilityLabel("重新加载学校页面")
                }
            }
        }
        .onDisappear { browser.stop() }
    }
}

@MainActor
private struct SchoolWebView: UIViewRepresentable {
    let browser: SchoolBrowser
    func makeUIView(context: Context) -> WKWebView { browser.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@MainActor
private final class SchoolBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published var status = "正在连接学校页面…"
    @Published var error: String?
    @Published var isLoading = false
    @Published var displayHost = "gzucm.edu.cn"
    private(set) var webView: WKWebView!

    private let campus: Campus?
    private let onAuthenticated: (([HTTPCookie]) -> Void)?
    private let onSnapshot: ((PowerSnapshot) -> Void)?
    private var validatingLogin = false
    private var completedLogin = false
    private var stopped = false
    private var navigatedToPower = false
    private var roomKey = ""
    private var currentBalance: (Double, String, String)?
    private var dailyByRoom: [String: [String: PowerDaily]] = [:]
    private var completedRooms: Set<String> = []

    init(campus: Campus, onAuthenticated: @escaping ([HTTPCookie]) -> Void) {
        self.campus = campus
        self.onAuthenticated = onAuthenticated
        self.onSnapshot = nil
        super.init()
        configure()
        let entry = campus == .graduate
            ? "https://yjsglxt.gzucm.edu.cn/gmis5/student/default/index"
            : "https://jw.gzucm.edu.cn/new/ssoLogin"
        webView.load(URLRequest(url: URL(string: entry)!))
    }

    init(onSnapshot: @escaping (PowerSnapshot) -> Void) {
        campus = nil
        onAuthenticated = nil
        self.onSnapshot = onSnapshot
        super.init()
        configure()
        webView.load(URLRequest(url: URL(string: "https://ecard.gzucm.edu.cn/user/powerfee/index")!))
    }

    private func configure() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        if onSnapshot != nil {
            let proxy = WeakPowerMessageHandler(owner: self)
            configuration.userContentController.add(proxy, name: "pocketPower")
            if let sourceURL = Bundle.main.url(forResource: "EcardBridge", withExtension: "js"),
               let source = try? String(contentsOf: sourceURL, encoding: .utf8) {
                configuration.userContentController.addUserScript(
                    WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
                )
            } else {
                error = "电费读取脚本缺失，请检查工程资源配置。"
            }
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = false
    }

    func stop() { stopped = true; webView.stopLoading() }
    func goBack() {
        stopped = false
        if webView.canGoBack { webView.goBack() }
    }
    func reload() {
        stopped = false
        error = nil
        navigatedToPower = false
        webView.reload()
    }

    private static func isSchoolURL(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "gzucm.edu.cn" || host.hasSuffix(".gzucm.edu.cn")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard Self.isSchoolURL(navigationAction.request.url) else {
            // A new page never gets permission to receive the native script bridge.
            if navigationAction.targetFrame?.isMainFrame != false {
                error = "仅在此窗口打开学校的 HTTPS 页面。"
            }
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, Self.isSchoolURL(navigationAction.request.url) {
            webView.load(navigationAction.request)
        }
        return nil
    }

    // The school's room-binding flow can use window.confirm. WKWebView otherwise
    // dismisses that dialog, making its own bind/query buttons appear unresponsive.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        guard let presenter = dialogPresenter() else { completionHandler(); return }
        let alert = UIAlertController(title: "学校网页提示", message: String(message.prefix(1000)), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default) { _ in completionHandler() })
        presenter.present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        guard let presenter = dialogPresenter() else { completionHandler(false); return }
        let alert = UIAlertController(title: "学校网页确认", message: String(message.prefix(1000)), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "确认", style: .default) { _ in completionHandler(true) })
        presenter.present(alert, animated: true)
    }

    private func dialogPresenter() -> UIViewController? {
        guard !stopped, webView.window != nil else { return nil }
        var responder: UIResponder? = webView
        while let current = responder {
            if var controller = current as? UIViewController {
                while let presented = controller.presentedViewController { controller = presented }
                return controller.isBeingDismissed ? nil : controller
            }
            responder = current.next
        }
        return nil
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        isLoading = true
        error = nil
        if let host = webView.url?.host { displayHost = host }
        if onSnapshot == nil { status = "请在学校页面完成登录和验证码。" }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoading = false
        guard !stopped, let url = webView.url else { return }
        displayHost = url.host ?? "gzucm.edu.cn"
        if let campus {
            validateLogin(on: url, campus: campus)
        } else if url.host == "ecard.gzucm.edu.cn" {
            if url.path.hasPrefix("/user/powerfee/") {
                status = currentBalance == nil ? "正在读取余额；可在网页中查询或绑定宿舍。" : "已读取余额，正在同步用电明细。"
                webView.evaluateJavaScript("window.__pocketEcard && window.__pocketEcard.refresh();", completionHandler: nil)
            } else if url.path.hasPrefix("/user/"), !navigatedToPower {
                navigatedToPower = true
                webView.load(URLRequest(url: URL(string: "https://ecard.gzucm.edu.cn/user/powerfee/index")!))
            } else {
                status = "请在学校页面完成校园卡登录。"
            }
        } else {
            status = "请完成学校统一身份认证，随后返回校园卡页面。"
        }
    }

    private func validateLogin(on url: URL, campus: Campus) {
        let host = campus == .graduate ? "yjsglxt.gzucm.edu.cn" : "jw.gzucm.edu.cn"
        let expectedPrefix = campus == .graduate ? "/gmis5/student/" : "/new/"
        guard !completedLogin, !validatingLogin, url.host == host,
              url.path.hasPrefix(expectedPrefix), !url.path.lowercased().contains("login") else { return }
        validatingLogin = true
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self, !self.stopped else { return }
            let relevant = cookies.filter {
                let domain = $0.domain.hasPrefix(".") ? String($0.domain.dropFirst()) : $0.domain
                return host == domain || host.hasSuffix("." + domain)
            }
            let key = campus == .graduate ? "__LOGINCOOKIE__" : "JSESSIONID"
            guard relevant.contains(where: { $0.name == key && !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                self.validatingLogin = false
                return
            }
            self.status = "正在确认学校登录状态…"
            let script: String
            if campus == .graduate {
                script = """
                const response = await fetch('/gmis5/student/default/bindterm', {credentials:'same-origin'});
                if (!response.ok || new URL(response.url).hostname !== 'yjsglxt.gzucm.edu.cn') return false;
                const terms = await response.json();
                return Array.isArray(terms) && terms.some(t => t && t.termcode != null && t.termname);
                """
            } else {
                script = """
                const response = await fetch('/new/student/xsgrkb/getCalendarWeekDatas', {
                  method:'POST', credentials:'same-origin',
                  headers:{'Content-Type':'application/x-www-form-urlencoded; charset=UTF-8','X-Requested-With':'XMLHttpRequest'},
                  body:'xnxqdm=&zc=&d1=&d2='
                });
                if (!response.ok || new URL(response.url).hostname !== 'jw.gzucm.edu.cn') return false;
                const result = await response.json();
                return result && String(result.code) === '0' && Array.isArray(result.data);
                """
            }
            self.webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page) { [weak self] result in
                guard let self, !self.stopped else { return }
                self.validatingLogin = false
                guard self.webView.url?.host == host else { return }
                if case .success(let value) = result, (value as? Bool) == true {
                    self.completedLogin = true
                    self.status = "学校登录已确认。"
                    // A verification request may rotate the session. Hand off the newest cookies.
                    self.webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] latest in
                        guard let self, !self.stopped else { return }
                        self.onAuthenticated?(latest.filter {
                            let domain = $0.domain.hasPrefix(".") ? String($0.domain.dropFirst()) : $0.domain
                            return host == domain || host.hasSuffix("." + domain)
                        })
                    }
                } else {
                    self.status = "尚未确认登录。完成学校验证后，可点右上角重新加载。"
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError failure: Error) {
        handleNavigationError(failure)
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError failure: Error) {
        handleNavigationError(failure)
    }
    private func handleNavigationError(_ failure: Error) {
        isLoading = false
        guard (failure as NSError).code != NSURLErrorCancelled else { return }
        // Do not echo NSError URLs: SSO redirects can contain one-time authentication tickets.
        error = "学校页面暂时无法加载，请检查校园网络或稍后重试。"
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        isLoading = false
        error = "学校页面已暂停，请点重新加载。"
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin
        guard !stopped, onSnapshot != nil, message.frameInfo.isMainFrame,
              origin.protocol == "https", origin.host == "ecard.gzucm.edu.cn",
              origin.port == 0 || origin.port == 443,
              webView.url?.host == "ecard.gzucm.edu.cn",
              let body = message.body as? [String: Any], (body["version"] as? Int) == 1,
              let kind = body["kind"] as? String else { return }
        if kind == "status", let text = body["message"] as? String {
            status = String(text.prefix(140))
            return
        }
        guard let key = body["roomKey"] as? String, key.count <= 200 else { return }
        if kind == "balance", let number = body["balance"] as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite {
            roomKey = key
            completedRooms.remove(key)
            let unit = String((body["unit"] as? String ?? "度").prefix(12))
            let label = String((body["roomLabel"] as? String ?? "宿舍").prefix(100))
            currentBalance = (number.doubleValue, unit, label.isEmpty ? "宿舍" : label)
            emitSnapshot()
        } else if kind == "daily", let rows = body["daily"] as? [[String: Any]], rows.count <= 500 {
            completedRooms.remove(key)
            var dates = dailyByRoom[key] ?? [:]
            for row in rows {
                guard let date = row["date"] as? String, date.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil,
                      let usage = row["usage"] as? NSNumber, let remain = row["remain"] as? NSNumber,
                      usage.doubleValue.isFinite, usage.doubleValue >= 0, remain.doubleValue.isFinite else { continue }
                let total = (row["total"] as? NSNumber)?.doubleValue ?? 0
                dates[date] = PowerDaily(date: date, usage: usage.doubleValue, remain: remain.doubleValue, total: total.isFinite ? total : 0)
            }
            dailyByRoom[key] = dates
            if key == roomKey { emitSnapshot() }
        } else if kind == "complete" {
            completedRooms.insert(key)
            if key == roomKey { emitSnapshot() }
        }
    }

    private func emitSnapshot() {
        guard let (balance, unit, label) = currentBalance else { return }
        let daily = (dailyByRoom[roomKey] ?? [:]).values.sorted { $0.date < $1.date }
        onSnapshot?(PowerSnapshot(balance: balance, unit: unit, roomLabel: label, daily: daily, updatedAt: Date(), isComplete: completedRooms.contains(roomKey)))
        status = daily.isEmpty ? "余额已同步；网页加载明细后会继续更新。" : "余额与 \(daily.count) 天用电明细已同步。"
    }
}

/// WKUserContentController retains handlers. Keep the browser owner weak to break the cycle.
@MainActor
private final class WeakPowerMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: SchoolBrowser?
    init(owner: SchoolBrowser) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        owner?.receive(message)
    }
}

@MainActor
enum WebsiteDataReset {
    static func clear() async {
        let store = WKWebsiteDataStore.default()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                continuation.resume()
            }
        }
    }
}
