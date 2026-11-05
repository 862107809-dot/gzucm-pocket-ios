import SwiftUI
import PocketCore
import UIKit

struct ScheduleView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openSchoolLogin) private var login
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("scheduleLayout") private var layout = 0
    @State private var month = SchoolDate.calendar.startOfDay(for: .now)
    @State private var monthDay = SchoolDate.calendar.startOfDay(for: .now)
    @State private var selectedCourse: CourseSession?
    @State private var weekEdgeOffset: CGFloat = 0
    @State private var weekEdge: Int = 0
    @State private var weekEdgeTask: Task<Void, Never>?
    private let weekdays = ["一", "二", "三", "四", "五", "六", "日"]

    var body: some View {
        @Bindable var store = store
        GeometryReader { geometry in
            if let academic = store.academic {
                VStack(spacing: 0) {
                    if academic.failedSections.contains(.sessions) {
                        Label("课表同步不完整；有缓存时保留上次数据，请稍后重试。", systemImage: "exclamationmark.circle")
                            .font(.caption).foregroundStyle(PocketTheme.ochre).padding(.horizontal, 20)
                    }
                    PocketChoices(title: "课表视图", items: ["日课表", "周课表", "月课表"], selection: $layout).padding(.horizontal, 20).padding(.top, 8)
                    if layout == 2 {
                        monthAgenda
                    } else {
                    weekControls(academic.semester).padding(.horizontal, 20).padding(.vertical, 12)
                    if layout == 1 && !dynamicType.isAccessibilitySize {
                        weekBoard(semester: academic.semester, width: geometry.size.width)
                    } else {
                        dayAgenda(semester: academic.semester)
                    }
                    }
                }
                .background {
                    if let data = store.wallpaperData, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFill().opacity(store.wallpaperOpacity).clipped()
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("课表还未连接", systemImage: "calendar.badge.plus")
                } description: { Text("登录学校教务系统，同步真实日期、授课内容与教室。") } actions: {
                    Button("连接教务", action: login).buttonStyle(.borderedProminent)
                }
            }
        }
        .pageCanvas().navigationTitle("课表")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("日课表") { layout = 0 }
                    Button("周课表") { layout = 1 }
                    Button("月课表") { layout = 2 }
                } label: { Image(systemName: "calendar.badge.clock") }
                .accessibilityLabel("选择课表视图")
            }
        }
        .sheet(item: $selectedCourse) { CourseDetailView(course: $0) }
    }

    private func weekControls(_ semester: Semester) -> some View {
        let current = semester.sundayFirstWeek(of: .now)
        return HStack {
            Button { stepWeek(-1, limit: semester.totalWeeks + 1) } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }
            .opacity(store.selectedWeek <= 1 ? 0.55 : 1)
            .accessibilityLabel("上一周")
            .accessibilityHint(store.selectedWeek <= 1 ? "已到第一周，轻触可查看边缘提示" : "")
            Spacer(minLength: 4)
            Menu {
                ForEach(1...max(1, semester.totalWeeks + 1), id: \.self) { week in
                    Button(week > semester.totalWeeks ? "学期末周" : "第 \(week) 周") { store.selectedWeek = week }
                }
            } label: {
                VStack(spacing: 4) {
                    Text(store.selectedWeek > semester.totalWeeks ? "学期末周" : "第 \(store.selectedWeek) 周").font(.headline)
                    let start = displayDate(7, semester: semester)
                    let end = displayDate(6, semester: semester)
                    Text("\(SchoolDate.display(start, template: "MMMd")) – \(SchoolDate.display(end, template: "MMMd"))")
                        .font(.caption).foregroundStyle(Color.secondary)
                }.padding(.vertical, 6)
            }
            .accessibilityIdentifier("schedule-week-control")
            Spacer(minLength: 4)
            Button { stepWeek(1, limit: semester.totalWeeks + 1) } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 44)
            }
            .opacity(store.selectedWeek >= semester.totalWeeks + 1 ? 0.55 : 1)
            .accessibilityLabel("下一周")
            .accessibilityHint(store.selectedWeek >= semester.totalWeeks + 1 ? "已到最后一周，轻触可查看边缘提示" : "")
            if store.currentWeek >= 1 && store.currentWeek <= semester.totalWeeks && store.selectedWeek != current {
                Button("本周") { store.selectedWeek = current }.font(.caption.bold()).padding(.trailing, 12)
            }
        }
        .pocketGlass()
        .overlay(alignment: .leading) {
            Capsule().fill(PocketTheme.jade.opacity(0.5))
                .frame(width: 8).blur(radius: 7)
                .opacity(weekEdge == -1 ? 1 : 0)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .trailing) {
            Capsule().fill(PocketTheme.jade.opacity(0.5))
                .frame(width: 8).blur(radius: 7)
                .opacity(weekEdge == 1 ? 1 : 0)
                .allowsHitTesting(false)
        }
        .offset(x: weekEdgeOffset)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.5), trigger: weekEdge)
    }

    private func stepWeek(_ direction: Int, limit: Int) {
        let next = store.selectedWeek + direction
        guard (1...max(1, limit)).contains(next) else {
            weekEdgeTask?.cancel()
            weekEdge = direction
            if !UIAccessibility.isReduceMotionEnabled {
                withAnimation(.easeOut(duration: 0.11)) {
                    weekEdgeOffset = CGFloat(direction) * 7
                }
            }
            weekEdgeTask = Task { @MainActor in
                do { try await Task.sleep(for: .milliseconds(110)) } catch { return }
                withAnimation(.spring(response: 0.32, dampingFraction: 0.57)) {
                    weekEdgeOffset = 0
                }
                do { try await Task.sleep(for: .milliseconds(260)) } catch { return }
                weekEdge = 0
            }
            return
        }
        weekEdgeTask?.cancel()
        weekEdge = 0
        weekEdgeOffset = 0
        store.selectedWeek = next
    }

    private func dayAgenda(semester: Semester) -> some View {
        @Bindable var store = store
        return VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach([7, 1, 2, 3, 4, 5, 6], id: \.self) { day in
                        let date = displayDate(day, semester: semester)
                        Button { store.selectedDay = day } label: {
                            VStack(spacing: 8) {
                                Text("周\(weekdays[day - 1])").font(.caption)
                                Text(SchoolDate.display(date, template: "d")).font(.system(.headline, design: .rounded))
                            }
                            .frame(minWidth: 40, minHeight: 60).padding(5)
                            .foregroundStyle(store.selectedDay == day ? (colorScheme == .dark ? Color.black : Color.white) : Color.primary)
                            .background(store.selectedDay == day ? PocketTheme.jade : PocketTheme.card, in: RoundedRectangle(cornerRadius: 18))
                        }
                        .accessibilityLabel("\(SchoolDate.iso(date)) 周\(weekdays[day - 1])")
                        .accessibilityAddTraits(store.selectedDay == day ? .isSelected : [])
                    }
                }.padding(.horizontal, 20).padding(.vertical, 8)
            }
            ScrollView {
                LazyVStack(spacing: 14) {
                    let courses = sessions(day: store.selectedDay)
                    if courses.isEmpty {
                        ContentUnavailableView("这一天没有课程安排", systemImage: "leaf", description: Text("以已同步的教务课表为准。"))
                    }
                    ForEach(courses) { course in
                        Button { selectedCourse = course } label: { CourseRow(course: course) }.buttonStyle(PocketSpringButtonStyle())
                    }
                }.padding(20).frame(maxWidth: 760).frame(maxWidth: .infinity)
            }.refreshable { await store.sync() }
        }
    }

    private func weekBoard(semester: Semester, width: CGFloat) -> some View {
        let columnWidth = max(112, (width - 68) / 7)
        return ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 4) {
                VStack(spacing: 0) {
                    Text("节").frame(height: 56)
                    ForEach(1...14, id: \.self) { unit in
                        VStack(spacing: 4) {
                            Text("\(unit)").font(.caption.bold())
                            Text(SchoolClock.start(unit)).font(.system(size: 9)).foregroundStyle(.secondary)
                        }.frame(width: 42, height: 74)
                    }
                }
                ForEach([7, 1, 2, 3, 4, 5, 6], id: \.self) { day in
                    VStack(spacing: 0) {
                        VStack(spacing: 4) {
                            Text("周\(weekdays[day - 1])").font(.caption.bold())
                            Text(SchoolDate.display(displayDate(day, semester: semester), template: "MMMd")).font(.caption2).foregroundStyle(.secondary)
                        }.frame(height: 56)
                        ZStack(alignment: .topLeading) {
                            VStack(spacing: 0) {
                                ForEach(1...14, id: \.self) { _ in
                                    Rectangle().fill(PocketTheme.card.opacity(0.65)).frame(height: 73)
                                    Divider().frame(height: 1)
                                }
                            }
                            ForEach(CoursePlacement.arrange(sessions(day: day))) { placement in
                                let course = placement.course
                                let laneWidth = columnWidth / CGFloat(placement.lanes)
                                Button { selectedCourse = course } label: {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(course.name).font(.caption.bold()).lineLimit(3)
                                        Text(course.room.isEmpty ? "地点待定" : course.room).font(.caption2).lineLimit(2)
                                        if !course.content.isEmpty { Text(course.content).font(.caption2).lineLimit(3) }
                                    }
                                    .padding(8).frame(width: max(24, laneWidth - 3), height: CGFloat(max(1, course.endUnit - course.startUnit + 1)) * 74 - 4, alignment: .topLeading)
                                    .foregroundStyle(.primary)
                                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                                    .background(PocketTheme.courseColor(course.code + course.name).opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.25), lineWidth: 0.6) }
                                }
                                .buttonStyle(PocketSpringButtonStyle())
                                .offset(x: CGFloat(placement.lane) * laneWidth, y: CGFloat(max(0, course.startUnit - 1)) * 74 + 2)
                                .accessibilityLabel("\(course.name)，\(course.resolvedStartTime)至\(course.resolvedEndTime)，\(course.room)")
                            }
                        }.frame(width: columnWidth, height: 14 * 74)
                    }
                }
            }.padding(.horizontal, 8).padding(.bottom, 20)
        }
    }

    private func displayDate(_ day: Int, semester: Semester) -> Date {
        semester.sundayFirstDate(week: store.selectedWeek, weekday: day)
    }

    private var monthAgenda: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Button { stepMonth(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }.accessibilityLabel("上个月")
                    Spacer()
                    Text(SchoolDate.display(month, template: "yyyy年MMMM")).font(.headline)
                    Spacer()
                    Button { stepMonth(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }.accessibilityLabel("下个月")
                }.pocketGlass()
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 5) {
                    ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                    ForEach(monthDates, id: \.self) { date in monthCell(date) }
                }.accessibilityIdentifier("schedule-month-calendar")
                SectionTitle(title: SchoolDate.display(monthDay, template: "MMMMd日EEEE"), subtitle: "\(monthCourses(monthDay).count) 门课程")
                if monthCourses(monthDay).isEmpty {
                    ContentUnavailableView("当天暂无课程", systemImage: "leaf", description: Text("以已同步的课表为准。"))
                }
                ForEach(monthCourses(monthDay)) { course in
                    Button { selectedCourse = course } label: { CourseRow(course: course) }.buttonStyle(PocketSpringButtonStyle())
                }
            }.padding(20).frame(maxWidth: 1050).frame(maxWidth: .infinity)
        }.refreshable { await store.sync() }
    }

    private var monthDates: [Date] {
        let calendar = SchoolDate.calendar
        let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month)) ?? month
        let offset = calendar.component(.weekday, from: first) - 1
        let days = calendar.range(of: .day, in: .month, for: first)?.count ?? 31
        let count = ((offset + days + 6) / 7) * 7
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0 - offset, to: first) }
    }
    private func monthCourses(_ date: Date) -> [CourseSession] {
        (store.academic?.sessions ?? []).filter { store.effectiveDate($0) == SchoolDate.iso(date) }
            .sorted { $0.startUnit < $1.startUnit }
    }
    private func stepMonth(_ offset: Int) {
        guard let next = SchoolDate.calendar.date(byAdding: .month, value: offset, to: month),
              let first = SchoolDate.calendar.date(from: SchoolDate.calendar.dateComponents([.year, .month], from: next)) else { return }
        month = first; monthDay = first
    }
    private func monthCell(_ date: Date) -> some View {
        let courses = monthCourses(date)
        let selected = SchoolDate.calendar.isDate(date, inSameDayAs: monthDay)
        let current = SchoolDate.calendar.isDate(date, equalTo: month, toGranularity: .month)
        return Button { monthDay = date } label: {
            VStack(spacing: 4) {
                Text(SchoolDate.display(date, template: "d")).font(.subheadline.weight(selected ? .bold : .regular))
                HStack(spacing: 3) {
                    ForEach(Array(courses.prefix(2).enumerated()), id: \.offset) { _, course in
                        Circle().fill(PocketTheme.courseColor(course.code + course.name)).frame(width: 5, height: 5)
                    }
                    if courses.count > 2 { Text("+\(courses.count - 2)").font(.system(size: 8)) }
                }.frame(height: 10)
            }.frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(current ? Color.primary : Color.secondary)
                .background(selected ? PocketTheme.jade.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? PocketTheme.jade.opacity(0.5) : Color.clear) }
        }.buttonStyle(PocketSpringButtonStyle())
            .accessibilityLabel("\(SchoolDate.iso(date))，\(courses.count) 门课程")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func sessions(day: Int) -> [CourseSession] {
        (store.academic?.sessions ?? []).filter { course in
            guard let semester = store.academic?.semester else { return false }
            return store.effectiveDate(course) == SchoolDate.iso(displayDate(day, semester: semester))
        }
            .sorted { $0.startUnit < $1.startUnit }
    }
}

private struct CoursePlacement: Identifiable {
    let course: CourseSession
    let lane: Int
    var lanes: Int
    var id: String { course.id }

    static func arrange(_ courses: [CourseSession]) -> [Self] {
        var output: [Self] = []
        var group: [Self] = []
        var ends: [Int] = []
        var groupEnd = 0
        func flush() { output.append(contentsOf: group.map { Self(course: $0.course, lane: $0.lane, lanes: ends.count) }) }
        for course in courses.sorted(by: { ($0.startUnit, $0.endUnit) < ($1.startUnit, $1.endUnit) }) {
            if course.startUnit > groupEnd { flush(); group = []; ends = []; groupEnd = 0 }
            let lane = ends.firstIndex(where: { $0 < course.startUnit }) ?? ends.count
            if lane == ends.count { ends.append(course.endUnit) } else { ends[lane] = course.endUnit }
            group.append(Self(course: course, lane: lane, lanes: 1))
            groupEnd = max(groupEnd, course.endUnit)
        }
        flush()
        return output
    }
}

private enum SchoolClock {
    static func start(_ unit: Int) -> String {
        let times = ["08:30", "09:20", "10:20", "11:10", "13:10", "14:00", "14:50", "15:40", "16:30", "17:20", "18:10", "19:00", "19:50", "20:40"]
        return (1...14).contains(unit) ? times[unit - 1] : ""
    }
}
