import SwiftUI
import PocketCore

enum PocketTab: String, CaseIterable, Identifiable {
    case today, schedule, grades, power
    var id: String { rawValue }
    var title: String {
        switch self {
        case .today: "今日"
        case .schedule: "课表"
        case .grades: "成绩"
        case .power: "电费"
        }
    }
    var icon: String {
        switch self {
        case .today: "sun.horizon"
        case .schedule: "calendar"
        case .grades: "chart.bar.xaxis"
        case .power: "bolt"
        }
    }
}

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false
    @State private var pendingLogin = false
    @State private var showLogin = false
    @State private var showPower = false

    var body: some View {
        @Bindable var store = store
        GeometryReader { geometry in
            Group {
                if geometry.size.width >= 720 {
                    NavigationSplitView {
                        List {
                            Section {
                                VStack(alignment: .leading, spacing: 8) {
                                    Image(systemName: "leaf.circle.fill").font(.largeTitle).foregroundStyle(PocketTheme.jade)
                                    Text("广中医口袋").font(.title2.bold())
                                    Text("把校园，装进口袋").font(.caption).foregroundStyle(.secondary)
                                }.padding(.vertical, 16)
                            }
                            Section {
                                ForEach(PocketTab.allCases) { tab in
                                    Button { store.selectedTab = tab } label: {
                                        Label(tab.title, systemImage: tab.icon)
                                            .foregroundStyle(store.selectedTab == tab ? PocketTheme.jade : .primary)
                                            .padding(.vertical, 7)
                                    }
                                    .listRowBackground(store.selectedTab == tab ? PocketTheme.jade.opacity(0.10) : Color.clear)
                                }
                            }
                            Section {
                                Button { showSettings = true } label: { Label("设置与账户", systemImage: "gearshape") }
                            }
                        }
                        .navigationTitle("校园生活")
                        .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 300)
                    } detail: {
                        NavigationStack { page(store.selectedTab).toolbar { actions } }
                    }
                    .navigationSplitViewStyle(.balanced)
                } else {
                    TabView(selection: $store.selectedTab) {
                        ForEach(PocketTab.allCases) { tab in
                            NavigationStack { page(tab).toolbar { actions } }
                                .tabItem { Label(tab.title, systemImage: tab.icon) }
                                .tag(tab)
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if store.isDemo {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 12) {
                            Label("演示模式 · 数据为虚构示例", systemImage: "sparkles")
                                .accessibilityIdentifier("demo-banner")
                                .fixedSize(horizontal: true, vertical: false)
                            Spacer(minLength: 0)
                            demoLoginButton
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Label("演示模式 · 数据为虚构示例", systemImage: "sparkles")
                                .accessibilityIdentifier("demo-banner")
                                .fixedSize(horizontal: false, vertical: true)
                            demoLoginButton
                        }
                    }
                    .font(.caption).padding(.horizontal, 18).padding(.vertical, 10)
                    .background(PocketTheme.jade.opacity(0.12))
                }
            }
        }
        .sheet(isPresented: $showSettings, onDismiss: {
            if pendingLogin {
                pendingLogin = false
                showLogin = true
            }
        }) {
            SettingsView(onLogin: {
                pendingLogin = true
                showSettings = false
            })
        }
        .sheet(isPresented: $showLogin) {
            SchoolLoginView(campus: store.campus, onAuthenticated: { cookies in
                showLogin = false
                Task { await store.completeLogin(cookies: cookies) }
            }, onCancel: { showLogin = false })
        }
        .sheet(isPresented: $showPower) {
            EcardPortalView(onSnapshot: { snapshot in store.acceptPower(snapshot) }, onClose: { showPower = false })
        }
        .environment(\.openSchoolLogin, { showLogin = true })
        .environment(\.openPowerPortal, { showPower = true })
        .alert("同步提示", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("知道了", role: .cancel) { store.message = nil }
        } message: { Text(store.message ?? "") }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.refreshIfNeeded() } }
        }
    }

    private var demoLoginButton: some View {
        Button("登录") { showLogin = true }
            .fontWeight(.semibold)
            .frame(minWidth: 44, minHeight: 44)
    }

    @ViewBuilder private func page(_ tab: PocketTab) -> some View {
        switch tab {
        case .today: TodayView()
        case .schedule: ScheduleView()
        case .grades: GradesView()
        case .power: PowerView()
        }
    }

    @ToolbarContentBuilder private var actions: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showSettings = true } label: { Image(systemName: "person.crop.circle") }
                .accessibilityLabel("设置与账户")
        }
    }
}

private struct SchoolLoginAction: EnvironmentKey { static let defaultValue: () -> Void = {} }
private struct PowerPortalAction: EnvironmentKey { static let defaultValue: () -> Void = {} }
extension EnvironmentValues {
    var openSchoolLogin: () -> Void {
        get { self[SchoolLoginAction.self] }
        set { self[SchoolLoginAction.self] = newValue }
    }
    var openPowerPortal: () -> Void {
        get { self[PowerPortalAction.self] }
        set { self[PowerPortalAction.self] = newValue }
    }
}
