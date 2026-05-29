import SwiftUI

/// Wrap any SwiftUI root view with `.localizationAware()` so it
/// re-renders when `LocalizationCache` finishes filling missing
/// strings via the LLM. Without this, a view that displayed an
/// English-fallback string on first paint (before the LLM
/// returned the translation) would keep showing English forever
/// even after the cache fills.
///
/// The modifier listens for `LocalizationCache.didUpdateNotification`
/// and bumps an internal state, which SwiftUI uses as a signal to
/// recompute the body. Cheap — only runs when new translations
/// land.
extension View {
    func localizationAware() -> some View {
        modifier(LocalizationRefreshModifier())
    }
}

private struct LocalizationRefreshModifier: ViewModifier {
    @State private var refreshToken: Int = 0

    func body(content: Content) -> some View {
        content
            // `id` flip is the surest way to force SwiftUI to
            // tear down and rebuild the subtree so newly-cached
            // localizations propagate. The cost is the brief
            // animation flicker that comes with re-identifying a
            // view — acceptable for the rare cache-update event.
            .id(refreshToken)
            .onReceive(NotificationCenter.default.publisher(
                for: LocalizationCache.didUpdateNotification
            )) { _ in
                refreshToken &+= 1
            }
    }
}
