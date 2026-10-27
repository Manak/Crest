import SwiftUI

/// The bar under the lists button: a hairline track the width of the glyph,
/// filled in the Space's accent as far as the tracked download has got.
struct DownloadsProgressBar: View {
    // MARK: - Static Variables

    static let width: CGFloat = 18
    static let height: CGFloat = 3
    static let bottomInset: CGFloat = 2

    // MARK: - Variables

    let context: CrestPluginCommonListsContext

    // MARK: - Actions - Drawing

    var body: some View {
        if let download = trackedDownload {
            Capsule()
                .fill(CrestColor.subtleBorder)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(context.badgeColor)
                        .frame(width: Self.width * max(min(download.progress, 1), 0))
                }
                .frame(width: Self.width, height: Self.height)
                .padding(.bottom, Self.bottomInset)
                .animation(.default, value: download.progress)
                .accessibilityHidden(true)
                .allowsHitTesting(false)
        }
    }

    /// The first download started that is still running, while the button
    /// opens Downloads; nil hides the bar.
    private var trackedDownload: DownloadState? {
        guard context.chosenSurface == .downloads else { return nil }
        return context.downloads.filter { $0.phase.isLive }.min { $0.createdAt < $1.createdAt }
    }
}
