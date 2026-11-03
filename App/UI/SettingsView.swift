import SwiftUI
import PhotosUI
import PocketCore

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("startTab") private var startTab = PocketTab.today.rawValue
    @AppStorage("courseAlerts") private var courseAlerts = false
    @AppStorage("powerAlerts") private var powerAlerts = false
    @State private var photo: PhotosPickerItem?
    @State private var changingCampus = false
    let onLogin: () -> Void

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        Image(systemName: "leaf.circle.fill").font(.largeTitle).foregroundStyle(PocketTheme.jade)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("广中医口袋").font(.headline)
                            Text(store.isDemo ? "正在体验虚构示例" : store.hasSession ? "\(store.campus.title) · 已连接" : "\(store.campus.title) · 尚未连接")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 8)
                    Picker("学段", selection: Binding(get: { store.campus }, set: { next in
                        changingCampus = true
                        Task { await store.changeCampus(next); changingCampus = false }
                    })) {
                        Text("本科生").tag(Campus.undergraduate)
                        Text("研究生").tag(Campus.graduate)
                    }.disabled(changingCampus || store.syncing)
                    Button(store.hasSession ? "重新登录教务" : "登录教务", systemImage: "person.badge.key", action: onLogin)
                    if store.hasSession {
                        Button { Task { await store.sync() } } label: {
                            HStack { Text("同步教务数据"); Spacer(); if store.syncing { ProgressView() } }
                        }.disabled(store.syncing)
                    }
                    if store.academic != nil || store.power != nil || store.hasSession {
                        Button("退出并清除本地数据", role: .destructive) { Task { await store.logout() } }
                    }
                } header: { Text("账户") } footer: {
                    Text("切换学段会退出当前账户并清除缓存。密码只在学校网页输入；课表和成绩保存在本机。")
                }
                Section("使用偏好") {
                    Picker("默认启动页", selection: $startTab) {
                        ForEach(PocketTab.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    TextField(store.campus == .undergraduate ? "学期代码，例如 202601（留空自动）" : "研究生学期代码（留空自动）", text: $store.semesterOverride)
                        .keyboardType(.numberPad)
                    Text("手动学期代码在下次同步时生效。自动选择以学校返回的校历为准。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("提醒") {
                    Toggle("上课前 10 分钟提醒", isOn: $courseAlerts)
                        .onChange(of: courseAlerts) { _, enabled in
                            Task {
                                if enabled, !(await LocalNotifications.requestAccess()) { courseAlerts = false; store.message = "通知尚未获准，请在系统设置中允许通知。" }
                                store.refreshCourseReminders()
                            }
                        }
                    Toggle("电量不足 3 天时提醒", isOn: $powerAlerts)
                        .onChange(of: powerAlerts) { _, enabled in
                            Task {
                                if enabled, !(await LocalNotifications.requestAccess()) { powerAlerts = false; store.message = "通知尚未获准，请在系统设置中允许通知。" }
                                store.refreshPowerAlert()
                            }
                        }
                    Text("上课提醒在同步后安排未来 7 天，最多 50 条。低电量提醒仅在读取最新电费后判断，每日最多一次；关闭 App 不会自动抓取电费。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("课表背景") {
                    PhotosPicker(selection: $photo, matching: .images) { Label("从照片选择背景", systemImage: "photo") }
                    if store.wallpaperData != nil {
                        Slider(value: $store.wallpaperOpacity, in: 0...0.35) { Text("背景不透明度") }
                        Button("移除背景", role: .destructive) { store.saveWallpaper(nil) }
                    }
                }
                Section("关于与隐私") {
                    LabeledContent("版本", value: "0.1.0 · iOS 18+")
                    Text("广州中医药大学非官方客户端，与学校无隶属关系。无广告、无统计 SDK，数据直接连接学校系统。")
                        .font(.subheadline)
                    Link("Android 原项目与 MIT 许可", destination: URL(string: "https://github.com/Hello-Minecraft/gzucm-pocket")!)
                    Text("基于 朱致辉 的开源项目移植，保留原作者 MIT 版权声明。iOS 版本的接口和设备适配仍需学校账户与真机验证。")
                        .font(.caption).foregroundStyle(.secondary)
                    if !store.isDemo { Button("查看演示数据") { store.enterDemo(); dismiss() } }
                    else { Button("退出演示，恢复本地数据") { Task { await store.leaveDemo(); dismiss() } } }
                }
            }
            .disabled(store.transitioning)
            .navigationTitle("设置与账户").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .onChange(of: photo) { _, item in
                Task {
                    if let data = try? await item?.loadTransferable(type: Data.self) { store.saveWallpaper(data) }
                }
            }
        }
    }
}
