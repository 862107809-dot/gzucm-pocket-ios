import Foundation

struct PowerDaily: Codable, Hashable, Identifiable, Sendable {
    let date: String
    let usage: Double
    let remain: Double
    var total: Double = 0
    var id: String { date }
}

/// Only display data is cached. The page's tokens and internal room identifiers stay in WebKit.
/// One confirmed balance per school-local calendar day.
 // This is a balance history, not energy usage; top-ups can increase balances.
struct PowerBalanceRecord: Codable, Hashable, Identifiable, Sendable {
    let date: String
    let balance: Double
    let unit: String
    let roomLabel: String
    let recordedAt: Date
    var id: String { date }
}

struct PowerSnapshot: Codable, Hashable, Sendable {
    let balance: Double
    let unit: String
    let roomLabel: String
    let daily: [PowerDaily]
    let updatedAt: Date
    var isComplete: Bool = false

    var isEnergyUnit: Bool {
        let normalized = unit.lowercased().replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "·", with: "")
        return ["度", "度电", "kwh", "千瓦时"].contains(normalized)
    }

    var averageDailyUsage: Double? {
        let values = daily.sorted { $0.date > $1.date }.prefix(7)
        guard !values.isEmpty else { return nil }
        return values.reduce(0) { $0 + $1.usage } / Double(values.count)
    }

    var estimatedDays: Double? {
        guard isEnergyUnit, let averageDailyUsage, averageDailyUsage > 0 else { return nil }
        return max(0, balance) / averageDailyUsage
    }
}

extension PowerSnapshot {
    private enum CodingKeys: String, CodingKey {
        case balance, unit, roomLabel, daily, updatedAt, isComplete
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        balance = try values.decode(Double.self, forKey: .balance)
        unit = try values.decode(String.self, forKey: .unit)
        roomLabel = try values.decode(String.self, forKey: .roomLabel)
        daily = try values.decode([PowerDaily].self, forKey: .daily)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        // Caches saved before the completion marker was introduced are incomplete by default.
        isComplete = try values.decodeIfPresent(Bool.self, forKey: .isComplete) ?? false
    }
}
