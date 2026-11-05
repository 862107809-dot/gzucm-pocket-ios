import SwiftUI
import Charts
import PocketCore

struct PowerView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openPowerPortal) private var openPortal

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if store.powerNeedsLogin {
                    PocketCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("一卡通授权已失效", systemImage: "lock.trianglebadge.exclamationmark")
                                .font(.headline).foregroundStyle(.orange)
                            Text("原有登录会话无法继续使用。请在学校网页中重新认证一次，之后可继续自动读取。")
                                .font(.subheadline).foregroundStyle(.secondary)
                            Button("重新登录一卡通", action: openPortal).buttonStyle(.borderedProminent)
                        }
                    }
                } else if store.automaticPowerProbe {
                    Label("正在通过已登录的学校页面检查电量…", systemImage: "arrow.clockwise")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let power = store.power {
                    let summary = PowerSummary(power)
                    PocketCard {
                        VStack(alignment: .leading, spacing: 22) {
                            Label(power.roomLabel.isEmpty ? "宿舍剩余电量" : power.roomLabel, systemImage: "bolt.fill")
                                .font(.subheadline).foregroundStyle(PocketTheme.ochre)
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(power.balance.formatted(.number.precision(.fractionLength(2))))
                                    .font(.system(size: 60, weight: .medium, design: .rounded)).minimumScaleFactor(0.5).monospacedDigit()
                                Text(power.unit).foregroundStyle(.secondary)
                            }.accessibilityElement(children: .combine).accessibilityIdentifier("power-balance")
                            Divider()
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 25) { metrics(summary) }
                                VStack(alignment: .leading, spacing: 18) { metrics(summary) }
                            }
                            if let days = summary.days, days < 3 {
                                Label("电量可能不足 3 天，请留意充值", systemImage: "exclamationmark.triangle")
                                    .font(.subheadline).foregroundStyle(.orange)
                            }
                            Text("估算使用最近 7 天中 \(summary.recordCount) 天的完整记录；当天记录不计入，结果仅供参考。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("更新于 \(power.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            if Date.now.timeIntervalSince(power.updatedAt) > 24 * 3600 {
                                Label("数据已超过一天，请重新读取", systemImage: "clock.badge.exclamationmark").foregroundStyle(PocketTheme.ochre)
                            }
                        }.font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("自动刷新", systemImage: "arrow.clockwise") {
                            if store.powerNeedsLogin { openPortal() }
                            else { store.refreshPowerIfNeeded(force: true) }
                        }
                        .font(.subheadline)
                    }
                    SectionTitle(title: "用电趋势", subtitle: "最近 \(min(30, power.daily.count)) 条记录")
                    PocketCard {
                        if power.daily.isEmpty {
                            ContentUnavailableView("还没有每日明细", systemImage: "chart.xyaxis.line", description: Text("在一卡通网页中打开用电明细，读取后会在这里显示。"))
                        } else {
                            Chart(Array(power.daily.sorted { $0.date < $1.date }.suffix(30))) { day in
                                if let date = SchoolDate.parse(day.date) {
                                    BarMark(x: .value("日期", date, unit: .day, calendar: SchoolDate.calendar), y: .value("用电量", day.usage))
                                        .foregroundStyle(PocketTheme.jade.gradient).cornerRadius(4)
                                }
                            }
                            .chartYAxisLabel("度")
                            .chartXAxis {
                                AxisMarks(values: .stride(by: .day, count: max(1, min(30, power.daily.count) / 6), calendar: SchoolDate.calendar)) { value in
                                    AxisValueLabel {
                                        if let date = value.as(Date.self) {
                                            Text(SchoolDate.display(date, template: "d"))
                                        }
                                    }
                                    AxisGridLine()
                                }
                            }
                            .environment(\.calendar, SchoolDate.calendar)
                            .environment(\.timeZone, SchoolDate.calendar.timeZone)
                            .frame(height: 210)
                            .accessibilityLabel("每日用电趋势，下方列表提供完整数值")
                        }
                    }
                    if !store.powerBalanceHistory.isEmpty {
                        SectionTitle(title: "每日余额自动记录", subtitle: "同一天保留最近一笔，最多 90 天")
                        PocketCard {
                            VStack(spacing: 14) {
                                ForEach(Array(store.powerBalanceHistory.suffix(14).reversed())) { record in
                                    HStack {
                                        Text(record.recordedAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.subheadline)
                                        Spacer()
                                        Text(record.balance.formatted(.number.precision(.fractionLength(2))))
                                        Text(record.unit).foregroundStyle(.secondary)
                                    }
                                    .font(.subheadline).monospacedDigit()
                                    .accessibilityElement(children: .combine)
                                }
                            }
                        }
                        Text("余额记录不等于每日用电量：充值会增加余额。记录仅保存在此设备。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    SectionTitle(title: "每日明细")
                    PocketCard {
                        VStack(spacing: 16) {
                            HStack { Text("日期"); Spacer(); Text("用电量 / 度"); Text("剩余 / 度").frame(width: 86, alignment: .trailing) }
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(power.daily.sorted { $0.date > $1.date }) { day in
                                HStack {
                                    Text(day.date)
                                    Spacer()
                                    Text(day.usage.formatted(.number.precision(.fractionLength(2))))
                                    Text(day.remain.formatted(.number.precision(.fractionLength(2)))).frame(width: 86, alignment: .trailing)
                                }.font(.subheadline).monospacedDigit().accessibilityElement(children: .combine)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView {
                        Label("宿舍用电，心中有数", systemImage: "bolt.circle")
                    } description: {
                        Text("在学校一卡通网页完成登录与房间绑定后，读取剩余电量和用电明细。")
                    } actions: {
                        Button("连接一卡通", action: openPortal).buttonStyle(.borderedProminent)
                    }.padding(.top, 40)
                }
                Label("首次在学校网页完成一卡通登录和宿舍绑定后，App 前台会尝试复用 WebKit Cookie，每 4 小时检查一次电量。会话失效时需重新进行学校认证；iOS 关闭或冻结 App 后不保证后台查询。", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20).frame(maxWidth: 850).frame(maxWidth: .infinity)
        }
        .pageCanvas().navigationTitle("电费")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("一卡通", systemImage: "safari", action: openPortal) } }
    }

    @ViewBuilder private func metrics(_ summary: PowerSummary) -> some View {
        Metric(value: summary.average.map { $0.formatted(.number.precision(.fractionLength(2))) } ?? "—", label: "近 7 天日均", unit: "度")
        Metric(value: summary.days.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—", label: "预计可用", unit: "天")
    }
}

struct PowerSummary {
    let average: Double?
    let days: Double?
    let recordCount: Int
    init(_ power: PowerSnapshot, now: Date = .now) {
        let today = SchoolDate.calendar.startOfDay(for: now)
        let earliest = SchoolDate.calendar.date(byAdding: .day, value: -7, to: today)!
        let rows = power.daily.filter {
            guard let date = SchoolDate.parse($0.date) else { return false }
            return date >= earliest && date < today && $0.usage >= 0 && $0.usage.isFinite
        }
        recordCount = rows.count
        let sum = rows.reduce(0) { $0 + $1.usage }
        let mean: Double? = rows.isEmpty ? nil : sum / Double(rows.count)
        average = mean
        let electricity = ["度", "kwh", "千瓦时"].contains(power.unit.lowercased())
        if electricity, recordCount >= 3, now.timeIntervalSince(power.updatedAt) < 48 * 3600,
           let mean, mean > 0 { days = max(0, power.balance) / mean } else { days = nil }
    }
}
