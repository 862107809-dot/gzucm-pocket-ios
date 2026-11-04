import SwiftUI
import PocketCore
import UIKit

struct ScheduleView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openSchoolLogin) private var login
    @Environment(\.dynamicTypeSize) private var dynamicType
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("compactWeekBoard") private var compactWeekBoard = false
    @State private var selectedCourse: CourseSession?
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
                    weekControls(academic.semester).padding(.horizontal, 20).padding(.vertical, 12)
                    if (geometry.size.width >= 760 || compactWeekBoard) && !dynamicType.isAccessibilitySize {
                        weekBoard(semester: academic.semester, width: geometry.size.width)
                    } else {
                        dayAgenda(semester: academic.semester)
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
                Button { compactWeekBoard.toggle() } label: {
                    Image(systemName: compactWeekBoard ? "list.bullet" : "rectangle.split.3x3")
                }
                .accessibilityLabel(compactWeekBoard ? "切换日课表" : "切换周课表")
            }
        }
        .sheet(item: $selectedCourse) { CourseDetailView(course: $0) }
    }

    private func weekControls(_ semester: Semester) -> some View {
        HStack {
            Button { store.selectedWeek = max(1, store.selectedWeek - 1) } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }
            .disabled(store.selectedWeek <= 1).accessibilityLabel("上一周")
            Spacer(minLength: 4)
            Menu {
                ForEach(1...max(1, semester.totalWeeks), id: \.self) { week in
                    Button("第 \(week) 周") { store.selectedWeek = week }
                }
            } label: {
                VStack(spacing: 4) {
                    Text("第 \(store.selectedWeek) 周").font(.headline)
                    let start = semester.date(week: store.selectedWeek, weekday: 1)
                    let end = semester.date(week: store.selectedWeek, weekday: 7)
                    Text("\(SchoolDate.display(start, template: "MMMd")) – \(SchoolDate.display(end, template: "MMMd"))")
                        .font(.caption).foregroundStyle(Color.secondary)
                }.padding(.vertical, 6)
            }
            .accessibilityIdentifier("schedule-week-control")
            Spacer(minLength: 4)
            Button { store.selectedWeek = min(semester.totalWeeks, store.selectedWeek + 1) } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 44)
            }
            .disabled(store.selectedWeek >= semester.totalWeeks).accessibilityLabel("下一周")
            if store.currentWeek >= 1 && store.currentWeek <= semester.totalWeeks && store.selectedWeek != store.currentWeek {
                Button("本周") { store.selectedWeek = store.currentWeek }.font(.caption.bold()).padding(.trailing, 12)
            }
        }
        .pocketGlass()
    }

    private func dayAgenda(semester: Semester) -> some View {
        @Bindable var store = store
        return VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(1...7, id: \.self) { day in
                        let date = semester.date(week: store.selectedWeek, weekday: day)
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
                        Button { selectedCourse = course } label: { CourseRow(course: course) }.buttonStyle(.plain)
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
                ForEach(1...7, id: \.self) { day in
                    VStack(spacing: 0) {
                        VStack(spacing: 4) {
                            Text("周\(weekdays[day - 1])").font(.caption.bold())
                            Text(SchoolDate.display(semester.date(week: store.selectedWeek, weekday: day), template: "MMMd")).font(.caption2).foregroundStyle(.secondary)
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
                                    .background(PocketTheme.courseColor(course.code + course.name).opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                                .offset(x: CGFloat(placement.lane) * laneWidth, y: CGFloat(max(0, course.startUnit - 1)) * 74 + 2)
                                .accessibilityLabel("\(course.name)，\(course.resolvedStartTime)至\(course.resolvedEndTime)，\(course.room)")
                            }
                        }.frame(width: columnWidth, height: 14 * 74)
                    }
                }
            }.padding(.horizontal, 8).padding(.bottom, 20)
        }
    }

    private func sessions(day: Int) -> [CourseSession] {
        (store.academic?.sessions ?? []).filter { $0.week == store.selectedWeek && $0.weekday == day }
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
