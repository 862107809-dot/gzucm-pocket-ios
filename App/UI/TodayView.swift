import SwiftUI
import PocketCore

struct TodayView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openSchoolLogin) private var login
    @Environment(\.openPowerPortal) private var powerPortal
    @State private var selectedCourse: CourseSession?

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    if let academic = store.academic {
                        if !academic.warnings.isEmpty {
                            Label(academic.warnings.joined(separator: "\n"), systemImage: "exclamationmark.circle")
                                .font(.callout).foregroundStyle(PocketTheme.ochre)
                        }
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 20) {
                                agenda.frame(minWidth: 380)
                                overview.frame(width: 290)
                            }
                            VStack(spacing: 24) { agenda; overview }
                        }
                        Text("教务更新于 \(academic.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        welcome
                    }
                }
                .padding(geometry.size.width >= 720 ? 28 : 20)
                .frame(maxWidth: 1100).frame(maxWidth: .infinity)
            }
            .refreshable { await store.sync() }
        }
        .pageCanvas()
        .navigationTitle("今日")
        .sheet(item: $selectedCourse) { CourseDetailView(course: $0) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Date.now.formatted(.dateTime.month(.wide).day().weekday(.wide)))
                .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
            Text(store.todayCourses.isEmpty ? "留一点时间，给自己。" : "新的一天，从容开始。")
                .accessibilityIdentifier("today-header")
                .font(.system(.largeTitle, design: .serif, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Circle().fill(PocketTheme.jade).frame(width: 6, height: 6)
                Text(store.termStatus).font(.subheadline).foregroundStyle(.secondary)
                if store.syncing { ProgressView().controlSize(.small) }
            }
        }
        .padding(.vertical, 8)
    }

    private var agenda: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(title: "今日课程", subtitle: "\(store.todayCourses.count) 门安排")
            if store.todayCourses.isEmpty {
                PocketCard {
                    ContentUnavailableView("今天没有课程安排", systemImage: "cup.and.saucer", description: Text("以已同步的教务课表为准。"))
                }
            } else {
                ForEach(store.todayCourses) { course in
                    Button { selectedCourse = course } label: { CourseRow(course: course) }
                        .buttonStyle(.plain)
                }
            }
            if let next = store.nextCourse {
                PocketCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("下一次上课", systemImage: "arrow.up.right").font(.caption.bold()).foregroundStyle(PocketTheme.jade)
                        Text(next.name).font(.headline)
                        Text("\(next.date)  \(next.resolvedStartTime) · \(next.room.isEmpty ? "地点待定" : next.room)")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionTitle(title: "校园速览")
            PocketCard {
                VStack(alignment: .leading, spacing: 20) {
                    Label("本周学习", systemImage: "books.vertical").font(.subheadline.weight(.medium)).foregroundStyle(PocketTheme.jade)
                    HStack {
                        Metric(value: "\(store.weekCourses.count)", label: "课程安排", unit: "次")
                        Metric(value: "\(store.weekCourses.reduce(0) { $0 + max(1, $1.endUnit - $1.startUnit + 1) })", label: "上课节次", unit: "节")
                    }
                    Button("查看完整课表", systemImage: "arrow.right") { store.selectedTab = .schedule }
                        .font(.subheadline)
                }
            }
            PocketCard {
                VStack(alignment: .leading, spacing: 18) {
                    Label("宿舍电量", systemImage: "bolt.fill").font(.subheadline.weight(.medium)).foregroundStyle(PocketTheme.ochre)
                    if let power = store.power {
                        Metric(value: power.balance.formatted(.number.precision(.fractionLength(2))), label: power.roomLabel.isEmpty ? "剩余电量" : power.roomLabel, unit: power.unit)
                        Text("打开电费页查看更新时间与趋势").font(.caption).foregroundStyle(.secondary)
                        Button("查看电费", systemImage: "arrow.right") { store.selectedTab = .power }
                    } else {
                        Text("连接一卡通，查看宿舍剩余电量。")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Button("连接一卡通", action: powerPortal)
                    }
                }
            }
        }
    }

    private var welcome: some View {
        PocketCard {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: "leaf.circle").font(.system(size: 58, weight: .light)).foregroundStyle(PocketTheme.jade)
                Text("你好，广中医。 ").font(.title.bold())
                Text("课表、成绩与宿舍电费，在这里有序相遇。登录学校教务系统后，即可同步你的校园安排。")
                    .foregroundStyle(.secondary).lineSpacing(5)
                Button("连接学校教务", systemImage: "person.badge.key", action: login)
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Button("先看看演示") { store.enterDemo() }.font(.subheadline)
                Divider()
                Label("非官方客户端 · 数据直连学校", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct CourseRow: View {
    let course: CourseSession
    var body: some View {
        PocketCard {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(course.resolvedStartTime).font(.system(.headline, design: .rounded)).monospacedDigit()
                    Text(course.resolvedEndTime).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .frame(width: 54, alignment: .leading)
                RoundedRectangle(cornerRadius: 2).fill(PocketTheme.courseColor(course.code + course.name)).frame(width: 3)
                VStack(alignment: .leading, spacing: 8) {
                    Text(course.name).font(.headline).foregroundStyle(.primary)
                    if !course.content.isEmpty { Text(course.content).font(.subheadline).foregroundStyle(.secondary) }
                    Text([course.room, course.teachers].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                    Text("第 \(course.startUnit)–\(course.endUnit) 节").font(.caption2).foregroundStyle(PocketTheme.jade)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

struct CourseDetailView: View {
    let course: CourseSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(course.name).font(.title2.bold()).padding(.vertical, 12)
                    LabeledContent("时间", value: "\(course.resolvedStartTime)–\(course.resolvedEndTime)")
                    LabeledContent("日期", value: course.date.isEmpty ? "第 \(course.week) 周 · 星期 \(course.weekday)" : course.date)
                    LabeledContent("节次", value: "\(course.startUnit)–\(course.endUnit)")
                    LabeledContent("地点", value: course.room.isEmpty ? "学校暂未提供" : course.room)
                    LabeledContent("授课教师", value: course.teachers.isEmpty ? "学校暂未提供" : course.teachers)
                }
                if !course.content.isEmpty { Section("上课内容") { Text(course.content).textSelection(.enabled) } }
                if !course.teachingMode.isEmpty { Section("教学模式") { Text(course.teachingMode) } }
                if !course.mergedClasses.isEmpty { Section("合班班级") { Text(course.mergedClasses) } }
            }
            .navigationTitle("课程详情").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
