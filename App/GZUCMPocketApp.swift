import SwiftUI
import PocketCore

@main
struct GZUCMPocketApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .tint(PocketTheme.jade)
                .modifier(VerificationAppearance())
                .task { if !store.isDemo { await store.restoreSession() } }
        }
    }
}

/// Explicit debug-only launch switches let CI use synthetic data without school credentials.
private struct VerificationAppearance: ViewModifier {
    @ViewBuilder func body(content: Content) -> some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--large-text") {
            content.dynamicTypeSize(.accessibility3).preferredColorScheme(testColorScheme)
        } else {
            content.preferredColorScheme(testColorScheme)
        }
        #else
        content
        #endif
    }
    private var testColorScheme: ColorScheme? {
        ProcessInfo.processInfo.arguments.contains("--dark") ? .dark : nil
    }
}
