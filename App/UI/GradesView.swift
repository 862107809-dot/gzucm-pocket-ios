import SwiftUI
import PocketCore

struct GradesView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openSchoolLogin) private var login

    private var grades: [CourseGrade] {
        (store.academic?.grades ?? []).filter { (store.gradeTerm == "全部学期" || $0.term == store.gradeTerm) && (store.gradeSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(store.gradeSearch)) }
    }

    var body: some View {
        @Bindable var store = store
        Group {
            if let academic = store.academic {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        PocketPageIntro(title: "每一步，都算数。", subtitle: "课程、等级考试与体测，保留学校公布的学习记录。")
                        if !academic.failedSections.filter({ $0 != .sessions }).isEmpty {
                            Label("部分数据同步失败；已有记录已保留，可稍后重新同步。", systemImage: "exclamationmark.circle")
                                .font(.caption).foregroundStyle(PocketTheme.ochre)
                        }
                        PocketCard {
                            VStack(alignment: .leading, spacing: 18) {
                                Label("学习足迹", systemImage: "graduationcap").font(.subheadline).foregroundStyle(PocketTheme.jade)
                                    .accessibilityIdentifier("grades-summary")
                                HStack(alignment: .top, spacing: 20) {
                                    if store.campus == .undergraduate {
                                        Metric(value: GradeStatistics.weightedGPA(grades).map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "—", label: "本地加权绩点")
                                    }
                                    Metric(value: GradeStatistics.earnedCredits(grades).formatted(.number.precision(.fractionLength(0...1))), label: "已获学分")
                                    Metric(value: "\(grades.count)", label: "课程记录")
                                }
                                Text(store.campus == .undergraduate ? "本地绩点按及格且有可用绩点的课程学分加权，排除非限选的选修课。仅供参考，以学校认定为准。" : "研究生系统未提供可确认的绩点口径，仅展示课程成绩与学分。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        PocketChoices(title: "成绩分类", items: ["课程", "等级", "体测", "考试"], selection: $store.gradeCategory)
                        if store.gradeCategory == 0 {
                            HStack {
                                Text("课程成绩").font(.title3.bold())
                                Spacer()
                                Menu {
                                    Button("全部学期") { store.gradeTerm = "全部学期" }
                                    ForEach(Array(Set(academic.grades.map(\.term))).sorted().reversed(), id: \.self) { value in
                                        Button(value) { store.gradeTerm = value }
                                    }
                                } label: { Label(store.gradeTerm, systemImage: "line.3.horizontal.decrease").font(.caption) }
                            }
                            if grades.isEmpty { empty("暂无课程成绩") }
                            ForEach(grades) { grade in
                                PocketCard {
                                    HStack(alignment: .top, spacing: 12) {
                                        VStack(alignment: .leading, spacing: 8) {
                                            Text(grade.name).font(.headline)
                                            Text("\(grade.term) · \(grade.credit.formatted()) 学分").font(.caption).foregroundStyle(.secondary)
                                            if !grade.category.isEmpty { Text(grade.category).font(.caption2).foregroundStyle(.secondary) }
                                            if !grade.remark.isEmpty { Text(grade.remark).font(.caption).foregroundStyle(.secondary) }
                                        }
                                        Spacer()
                                        VStack(alignment: .trailing, spacing: 5) {
                                            Text(grade.score.formatted()).font(.system(.title2, design: .rounded, weight: .semibold))
                                            Text(grade.passed ? "及格" : "未及格").font(.caption2)
                                        }.foregroundStyle(grade.passed ? PocketTheme.jade : .red)
                                    }.accessibilityElement(children: .combine)
                                }
                            }
                        } else if store.gradeCategory == 1 {
                            if academic.levels.isEmpty { empty("暂无等级成绩") }
                            ForEach(academic.levels) { grade in
                                PocketCard {
                                    VStack(alignment: .leading, spacing: 12) {
                                        SectionTitle(title: grade.name, subtitle: grade.term)
                                        Text(grade.total.formatted()).font(.system(.largeTitle, design: .rounded, weight: .semibold))
                                        Text([grade.level, grade.date].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                                        ForEach(grade.parts, id: \.label) { part in LabeledContent(part.label, value: part.value).font(.subheadline) }
                                    }
                                }
                            }
                        } else if store.gradeCategory == 2 {
                            if academic.fitness.isEmpty { empty("暂无体测成绩") }
                            ForEach(academic.fitness) { grade in
                                PocketCard {
                                    VStack(alignment: .leading, spacing: 14) {
                                        SectionTitle(title: grade.term, subtitle: grade.level)
                                        Text("总分 \(grade.total)").font(.title2.bold())
                                        ForEach(grade.items, id: \.label) { item in
                                            LabeledContent(item.label, value: [item.value, item.score.isEmpty ? "" : "评分 \(item.score)"].filter { !$0.isEmpty }.joined(separator: " · ")).font(.subheadline)
                                        }
                                    }
                                }
                            }
                        } else {
                            if academic.exams.isEmpty { empty("暂无考试安排") }
                            ForEach(academic.exams) { exam in
                                PocketCard {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text(exam.course).font(.headline)
                                        Label("\(exam.date) \(exam.time)", systemImage: "calendar").font(.subheadline)
                                        Text([exam.room, exam.seat.isEmpty ? "" : "座位 \(exam.seat)", exam.type].filter { !$0.isEmpty }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }.padding(20).frame(maxWidth: 850).frame(maxWidth: .infinity)
                }.refreshable { await store.sync() }
            } else {
                ContentUnavailableView {
                    Label("连接教务，查看学习足迹", systemImage: "chart.bar.doc.horizontal")
                } description: { Text("成绩仅保存在本机，直接来自学校系统。") } actions: {
                    Button("连接教务", action: login).buttonStyle(.borderedProminent)
                }
            }
        }
        .pageCanvas().navigationTitle("成绩")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { Task { await store.sync() } } label: { Image(systemName: "arrow.clockwise") }.disabled(store.syncing || store.isDemo).accessibilityLabel("更新成绩") } }
        .searchable(text: $store.gradeSearch, prompt: "搜索课程名称")
    }
    private func empty(_ title: String) -> some View {
        ContentUnavailableView(title, systemImage: "tray", description: Text("若同步提示部分失败，请重新同步。"))
    }
}
