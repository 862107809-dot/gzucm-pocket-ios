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
    static let background = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.055, green: 0.09, blue: 0.08, alpha: 1)
            : UIColor(red: 0.97, green: 0.97, blue: 0.94, alpha: 1)
    })
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
            .modifier(PocketContentSurface())
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

struct PocketSpringButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(isEnabled && configuration.isPressed && !reduceMotion ? 1.05 : 1)
            .brightness(isEnabled && configuration.isPressed ? 0.025 : 0)
            .animation(reduceMotion ? nil : .spring(response: 0.29, dampingFraction: 0.66), value: configuration.isPressed)
    }
}

private struct PocketContentSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(reduceTransparency ? AnyShapeStyle(PocketTheme.card) : AnyShapeStyle(.thinMaterial))
                .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.16), lineWidth: 0.7) }
        }
    }
}

private struct PocketGlass: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var radius: CGFloat
    var interactive: Bool
    func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(PocketTheme.card, in: RoundedRectangle(cornerRadius: radius))
        } else if #available(iOS 26.0, macCatalyst 26.0, *) {
            content.glassEffect(.regular.interactive(interactive), in: .rect(cornerRadius: radius))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius))
                .overlay { RoundedRectangle(cornerRadius: radius).strokeBorder(.white.opacity(0.28), lineWidth: 0.7).allowsHitTesting(false) }
        }
    }
}

extension View {
    func pocketGlass(radius: CGFloat = 24, interactive: Bool = false) -> some View { modifier(PocketGlass(radius: radius, interactive: interactive)) }
    func pocketSheet() -> some View {
        presentationBackground(.clear)
            .background { Color.clear.pocketGlass(radius: 28) }
            .presentationDragIndicator(.visible)
    }
    func pageCanvas() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                PocketTheme.background.overlay(alignment: .topTrailing) {
                    RadialGradient(colors: [PocketTheme.jade.opacity(0.12), .clear], center: .topTrailing, startRadius: 0, endRadius: 550)
                }.ignoresSafeArea()
            }
    }
}

/// A native glass selector: drag previews a value, release commits it once.
/// Text stays outside the glass effect, preserving legibility and Dynamic Type.
struct PocketChoices: View {
    let title: String
    let items: [String]
    @Binding var selection: Int
    @State private var preview: Int?
    @GestureState private var dragging = false
    @Namespace private var glassNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        if dynamicType.isAccessibilitySize {
            Picker(title, selection: $selection) {
                ForEach(items.indices, id: \.self) { Text(items[$0]).tag($0) }
            }.pickerStyle(.menu).frame(minHeight: 44)
        } else { control }
    }

    private var control: some View {
        GeometryReader { geometry in
            group {
                ZStack(alignment: .leading) {
                    let width = max(1, (geometry.size.width - 8) / CGFloat(max(1, items.count)))
                    let value = min(max(0, preview ?? selection), max(0, items.count - 1))
                    highlight.frame(width: width, height: 42)
                        .scaleEffect(preview == nil || reduceMotion ? 1 : 1.045)
                        .offset(x: 4 + CGFloat(value) * width)
                        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.78), value: value)
                    HStack(spacing: 0) {
                        ForEach(items.indices, id: \.self) { index in
                            Button { selection = index } label: {
                                Text(items[index]).font(.subheadline.weight(value == index ? .semibold : .regular))
                                    .multilineTextAlignment(.center).frame(maxWidth: .infinity, minHeight: 44)
                                    .foregroundStyle(value == index ? PocketTheme.jade : .secondary)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PocketSpringButtonStyle())
                            .accessibilityAddTraits(selection == index ? .isSelected : [])
                        }
                    }.padding(.horizontal, 4)
                }
                .background(.quaternary.opacity(0.35), in: Capsule())
                .simultaneousGesture(DragGesture(minimumDistance: 8)
                    .updating($dragging) { _, state, _ in state = true }
                    .onChanged { drag in
                        guard abs(drag.translation.width) > abs(drag.translation.height) else { return }
                        preview = index(at: drag.location.x, width: geometry.size.width)
                    }
                    .onEnded { _ in
                        if let preview { selection = preview }
                        preview = nil
                    })
                .onChange(of: selection) { _, _ in preview = nil }
                .onChange(of: dragging) { _, active in if !active { preview = nil } }
            }
        }.frame(height: 48).accessibilityLabel(title)
        .onDisappear { preview = nil }
    }

    @ViewBuilder private var highlight: some View {
        if reduceTransparency {
            Capsule().fill(PocketTheme.card)
        } else if #available(iOS 26.0, macCatalyst 26.0, *) {
            Capsule().fill(.clear)
                .glassEffect(.regular.tint(PocketTheme.jade.opacity(0.12)).interactive(), in: .capsule)
                .glassEffectID("selection", in: glassNamespace)
        } else {
            Capsule().fill(.regularMaterial)
                .overlay { Capsule().strokeBorder(.white.opacity(0.45), lineWidth: 0.8) }
        }
    }

    @ViewBuilder private func group<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if #available(iOS 26.0, macCatalyst 26.0, *) { GlassEffectContainer(spacing: 8) { content() } }
        else { content() }
    }
    private func index(at x: CGFloat, width: CGFloat) -> Int {
        let cell = max(1, (width - 8) / CGFloat(max(1, items.count)))
        return min(max(0, Int((x - 4) / cell)), max(0, items.count - 1))
    }
}

struct PocketPageIntro: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(.largeTitle, design: .serif, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }.padding(.vertical, 8)
    }
}
