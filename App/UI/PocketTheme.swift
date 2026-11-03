import SwiftUI
import UIKit

enum PocketTheme {
    static let jade = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.49, green: 0.82, blue: 0.70, alpha: 1)
            : UIColor(red: 0.13, green: 0.43, blue: 0.36, alpha: 1)
    })
    static let ochre = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.95, green: 0.73, blue: 0.37, alpha: 1)
            : UIColor(red: 0.67, green: 0.40, blue: 0.10, alpha: 1)
    })
    static let background = Color(uiColor: .systemGroupedBackground)
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
    static let colors: [Color] = [jade, .indigo, ochre, .teal, .purple, .blue]

    static func courseColor(_ code: String) -> Color {
        let index = code.utf8.reduce(0) { ($0 + Int($1)) % colors.count }
        return colors[index]
    }
}

struct PocketCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content.padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(PocketTheme.card, in: RoundedRectangle(cornerRadius: 24))
    }
}

struct SectionTitle: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.bold())
            Spacer(minLength: 8)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
    }
}

struct Metric: View {
    let value: String
    let label: String
    var unit: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(.title, design: .rounded, weight: .semibold)).monospacedDigit()
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct PocketGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(PocketTheme.card, in: RoundedRectangle(cornerRadius: 24))
        } else if #available(iOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: 24))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
        }
    }
}

extension View {
    func pocketGlass() -> some View { modifier(PocketGlass()) }
    func pageCanvas() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PocketTheme.background)
    }
}
