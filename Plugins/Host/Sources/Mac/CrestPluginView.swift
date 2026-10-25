import SwiftUI

/// A view a plugin hands the host where the host cannot name its type, such
/// as a settings section. This is the host's one place that erases a view's
/// type: the few views plugins contribute never sit on a hot path.
struct CrestPluginView: View {
    private let content: AnyView

    init<Content: View>(_ content: Content) {
        self.content = AnyView(content)
    }

    var body: some View {
        content
    }
}
