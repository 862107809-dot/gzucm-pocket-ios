import SwiftUI

struct MessagesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openSchoolLogin) private var openSchoolLogin

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            PocketPageIntro(title: "学校消息，及时查看。", subtitle: "通知与消息以学校官方页面为准。")
            if store.hasSession && !store.isDemo {
                Label("学校官方消息页面", systemImage: "building.columns")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(PocketTheme.jade)
                SchoolMessagesPortalView(campus: store.campus)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(PocketTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                ScrollView {
                    ContentUnavailableView {
                        Label(store.isDemo ? "演示模式没有学校消息" : "连接教务，查看学校消息", systemImage: "envelope")
                    } description: {
                        Text(store.isDemo
                             ? "演示模式不会向学校请求消息。连接本人学校账户后，在官方页面查看通知。"
                             : "请先在学校页面完成登录，再查看本人消息与通知。学校要求重新认证时，请再次连接教务。")
                    } actions: {
                        Button("连接学校教务", systemImage: "person.badge.key", action: openSchoolLogin)
                            .buttonStyle(.borderedProminent)
                            .frame(minHeight: 44)
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: 850)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .pageCanvas()
        .navigationTitle("消息")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("连接教务", systemImage: "person.badge.key", action: openSchoolLogin) } }
    }
}
