import SwiftUI
import Charts
import PocketCore

struct PowerView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.openPowerPortal) private var openPortal

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                PocketPageIntro(title: "为宿舍，留一盏灯。", subtitle: "剩余电量、用电趋势与学校一卡通连接。")
                if !store.isDemo && (store.powerNeedsLogin || !store.powerWasLinked) {
                    PocketCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Label(store.powerNeedsLogin ? "一卡通授权需要更新" : "尚未连接学校一卡通", systemImage: "lock.trianglebadge.exclamationmark")
                                .font(.headline).foregroundStyle(.orange)
                            Text(store.powerNeedsLogin
                                 ? "原会话可能已失效，或学校认证链接已变化。请在学校官方页面重新认证并确认宿舍绑定，已读数据会保留。"
                                 : "尚未保存可复用的一卡通连接。请在学校官方页面完成认证与宿舍绑定后，读取真实电量。")
                                .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button("立即读取电量", systemImage: "bolt.fill", action: readPower)
                                .buttonStyle(.borderedProminent).frame(minHeight: 44)
                                .disabled(store.automaticPowerProbe)
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
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 18) {
                            updateStatus(power.updatedAt).fixedSize(horizontal: true, vertical: false)
                            Spacer()
                            readButton.fixedSize()
                        }
                        VStack(alignment: .leading, spacing: 12) {
                            updateStatus(power.updatedAt)
                            readButton
                        }
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
                        Text("在学校一卡通官方页面完成认证和宿舍绑定后，直接读取真实剩余电量与学校提供的明细。")
                    } actions: {
                        Button("立即读取电量", systemImage: "bolt.fill", action: readPower)
                            .buttonStyle(.borderedProminent).frame(minHeight: 44)
                            .disabled(store.automaticPowerProbe)
                    }.padding(.top, 40)
                }
                Label("教务扫码与一卡通可能需要分别完成学校授权。电量通过已认证的学校网页直接读取；手动读取不受自动更新开关控制。开启自动更新后，App 在前台且间隔满 4 小时时尝试检查。会话失效会保留旧读数，请重新在学校认证；关闭或冻结 App 后不保证后台查询。", systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.padding(20).frame(maxWidth: 850).frame(maxWidth: .infinity)
        }
        .pageCanvas().navigationTitle("电费")
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("学校一卡通", systemImage: "safari", action: openPortal).disabled(store.automaticPowerProbe) } }
        .onAppear {
            if !store.isDemo && store.powerWasLinked { store.refreshPowerIfNeeded() }
        }
    }

    private var readButton: some View {
        Button(store.automaticPowerProbe ? "正在读取电量…" : "立即读取电量", systemImage: "arrow.clockwise", action: readPower)
            .font(.subheadline).frame(minHeight: 44)
            .disabled(store.automaticPowerProbe)
    }

    private func readPower() {
        if store.isDemo || !store.powerWasLinked || store.powerNeedsLogin { openPortal() }
        else { store.readPowerNow() }
    }

    private func updateStatus(_ date: Date) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("更新于 \(date.formatted(date: .abbreviated, time: .shortened))")
            if Date.now.timeIntervalSince(date) > 24 * 3600 {
                Label("这是上次读数，请重新读取电量", systemImage: "clock.badge.exclamationmark")
                    .foregroundStyle(PocketTheme.ochre)
            }
        }.font(.caption).foregroundStyle(.secondary)
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
