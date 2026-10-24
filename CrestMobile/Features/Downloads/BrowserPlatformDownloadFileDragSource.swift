import SwiftUI

/// The touch shell's download rows are not file drag sources: a finished file
/// leaves through the row's Share and Save to Files destinations instead.
struct BrowserPlatformDownloadFileDragSource: ViewModifier {
    let download: DownloadState

    func body(content: Content) -> some View {
        content
    }
}
