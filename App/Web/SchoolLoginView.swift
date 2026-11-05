import SwiftUI
import WebKit
import CoreImage.CIFilterBuiltins
import PocketCore

@MainActor
struct SchoolLoginView: View {
    let campus: Campus
    let onAuthenticated: ([HTTPCookie]) -> Void
    let onCancel: () -> Void
    @State private var method = 0
    @State private var handingOff = false
    private var previewOnly: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("--login-preview")
        #else
        false
        #endif
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if campus == .undergraduate {
                    PocketChoices(title: "教务登录方式", items: ["微信扫码", "账号密码"], selection: Binding(get: { method }, set: { if !handingOff { method = $0 } }))
                        .disabled(handingOff)
                        .padding(.horizontal, 20)
                } else {
                    Text("研究生系统使用学校账号密码页面，二维码接口暂未接入。")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 20)
                }
                if campus == .undergraduate && method == 0 {
                    SchoolQRContent(previewOnly: previewOnly, onAuthenticated: onAuthenticated, onHandingOff: { handingOff = $0 })
                } else {
                    SchoolPasswordContent(campus: campus, previewOnly: previewOnly, onAuthenticated: onAuthenticated)
                }
            }
            .navigationTitle("连接学校教务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { if !handingOff { onCancel() } }.disabled(handingOff) } }
        }
        .interactiveDismissDisabled(handingOff)
    }
}

@MainActor
private struct SchoolPasswordContent: View {
    @StateObject private var browser: SchoolBrowser
    init(campus: Campus, previewOnly: Bool, onAuthenticated: @escaping ([HTTPCookie]) -> Void) {
        _browser = StateObject(wrappedValue: SchoolBrowser(campus: campus, loadImmediately: !previewOnly, onAuthenticated: onAuthenticated))
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("学校官方账号密码页面", systemImage: "lock.shield").font(.subheadline.weight(.medium))
                    Text(browser.error ?? "在学校网页输入学号、密码和验证码，App 不读取或保存密码。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button { browser.reload() } label: { Image(systemName: "arrow.clockwise").frame(width: 44, height: 44) }
                    .accessibilityLabel("重新加载学校登录")
            }.padding(.horizontal, 20).padding(.vertical, 10)
            if browser.isLoading { ProgressView().progressViewStyle(.linear) }
            SchoolWebView(browser: browser)
            Text(browser.status).font(.caption).foregroundStyle(.secondary).padding(12)
        }.accessibilityIdentifier("school-password-panel")
            .onDisappear { browser.stop() }
    }
}

@MainActor
private struct SchoolQRContent: View {
    let previewOnly: Bool
    let onAuthenticated: ([HTTPCookie]) -> Void
    let onHandingOff: (Bool) -> Void
    @StateObject private var model = SchoolQRModel()
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("微信扫码连接教务").font(.title2.bold())
                Text("与网页版使用同一学校二维码流程").font(.subheadline).foregroundStyle(.secondary)
                Group {
                    if let image = model.image {
                        Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                            .padding(18).background(.white, in: RoundedRectangle(cornerRadius: 22))
                            .frame(maxWidth: 290).accessibilityLabel("学校教务登录二维码")
                        ShareLink(item: Image(uiImage: image), preview: SharePreview("学校登录二维码", image: Image(uiImage: image))) {
                            Label("保存或分享二维码", systemImage: "square.and.arrow.up")
                        }.buttonStyle(.bordered)
                    } else {
                        RoundedRectangle(cornerRadius: 22).fill(.quaternary)
                            .overlay { if model.busy { ProgressView() } else { Image(systemName: "qrcode").font(.system(size: 74)).foregroundStyle(.secondary) } }
                            .frame(maxWidth: 290, minHeight: 240)
                    }
                }
                Text(model.status).font(.headline).multilineTextAlignment(.center).accessibilityIdentifier("school-qr-status")
                if let error = model.error { Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center) }
                Button(model.image == nil ? "生成学校登录二维码" : "重新生成二维码") {
                    if !previewOnly { model.start(onAuthenticated: onAuthenticated, onHandingOff: onHandingOff) }
                }.buttonStyle(.borderedProminent).disabled(model.busy)
                VStack(alignment: .leading, spacing: 12) {
                    Label("在另一台设备上，用微信扫一扫并在学校页面确认。", systemImage: "qrcode.viewfinder")
                    Label("同一部手机可保存二维码，再到微信扫一扫从相册识别；确认后返回 App。", systemImage: "photo")
                    Label("二维码最多有效 5 分钟。仅在学校确认并验证教务会话后完成登录。", systemImage: "clock")
                }.font(.caption).foregroundStyle(.secondary)
            }.padding(22).frame(maxWidth: 620).frame(maxWidth: .infinity)
        }.accessibilityIdentifier("school-qr-panel")
            .task { model.foreground = scenePhase == .active; if !previewOnly { model.start(onAuthenticated: onAuthenticated, onHandingOff: onHandingOff) } }
            .onChange(of: scenePhase) { _, phase in model.foreground = phase == .active }
            .onDisappear { model.stop() }
    }
}

@MainActor
private final class SchoolQRModel: ObservableObject {
    @Published private(set) var image: UIImage?
    @Published private(set) var status = "请生成二维码，然后在学校页面确认。"
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    var foreground = true
    private let client = SchoolQRClient()
    private var task: Task<Void, Never>?
    private var revision = 0
    private var committingCookies = false

    func stop() {
        guard !committingCookies else { return }
        revision += 1; task?.cancel(); task = nil; image = nil; busy = false
        Task { await client.cancel() }
    }
    func start(onAuthenticated: @escaping ([HTTPCookie]) -> Void, onHandingOff: @escaping (Bool) -> Void) {
        guard !committingCookies else { return }
        revision += 1
        let token = revision
        task?.cancel(); error = nil; image = nil; busy = true; status = "正在向学校申请二维码…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { if committingCookies { committingCookies = false; onHandingOff(false) } }
            do {
                await client.cancel()
                try Task.checkCancellation()
                let challenge = try await client.start()
                guard revision == token else { return }
                let generator = CIFilter.qrCodeGenerator()
                generator.message = Data(challenge.confirmURL.absoluteString.utf8)
                generator.correctionLevel = "M"
                guard let output = generator.outputImage?.transformed(by: CGAffineTransform(scaleX: 9, y: 9)),
                      let cg = CIContext().createCGImage(output, from: output.extent) else { throw SchoolClientError.unavailable("二维码无法显示，请重试。") }
                image = UIImage(cgImage: cg); busy = false; status = "等待微信扫码"
                while revision == token && !Task.isCancelled {
                    try await Task.sleep(for: .seconds(3.2))
                    try Task.checkCancellation()
                    guard Date.now < challenge.expiresAt else { image = nil; status = "二维码已过期，请重新生成。"; await client.cancel(); return }
                    if !foreground { continue }
                    switch try await client.poll() {
                    case .waiting: status = "等待微信扫码"
                    case .scanned: status = "已扫码，请在学校页面确认登录"
                    case .expired: image = nil; status = "二维码已过期，请重新生成。"; return
                    case .authenticated(let cookies):
                        guard revision == token else { return }
                        // Cookie-store writes are asynchronous. Freeze user cancellation
                        // and mode switching for this short, verified local handoff.
                        committingCookies = true; onHandingOff(true)
                        busy = true; status = "教务登录已验证，正在保存本设备会话…"
                        let store = WKWebsiteDataStore.default().httpCookieStore
                        let previous: [HTTPCookie] = await withCheckedContinuation { continuation in
                            store.getAllCookies { continuation.resume(returning: $0) }
                        }
                        for cookie in previous where cookie.name == "JSESSIONID" && ["jw.gzucm.edu.cn", "gzucm.edu.cn"].contains(cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()) {
                            guard revision == token else { return }
                            await store.deleteCookie(cookie)
                        }
                        for cookie in cookies {
                            guard revision == token else { return }
                            await store.setCookie(cookie)
                        }
                        guard revision == token else { return }
                        image = nil; busy = false; status = "学校登录成功"
                        committingCookies = false; onHandingOff(false)
                        onAuthenticated(cookies)
                        return
                    }
                }
            } catch is CancellationError { }
            catch {
                guard revision == token else { return }
                image = nil; busy = false; status = "扫码连接未完成"
                self.error = (error as? SchoolClientError)?.localizedDescription ?? "暂时无法连接学校扫码服务，请稍后重试或使用账号密码。"
                await client.cancel()
            }
        }
    }
}
