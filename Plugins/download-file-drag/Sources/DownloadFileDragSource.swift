import AppKit
import SwiftUI

/// Lets a finished download's row be dragged out of the sidebar as its file,
/// the way Finder hands a file to another window or app: what travels is the
/// file itself, under its Finder icon and name, so dropping it in a folder
/// copies it and dropping it on an app opens it there.
///
/// A download without a finished file on disk is not a drag source at all;
/// the row stays a plain button.
struct DownloadFileDragSource: ViewModifier {
    let download: DownloadState

    @ViewBuilder
    func body(content: Content) -> some View {
        if let fileURL {
            content
                .onDrag {
                    NSItemProvider(contentsOf: fileURL) ?? NSItemProvider()
                } preview: {
                    DownloadFileDragPreview(fileURL: fileURL)
                }
        } else {
            content
        }
    }

    /// The finished file, where it still stands at its destination.
    private var fileURL: URL? {
        guard download.phase.isComplete,
            let destinationURL = download.destinationURL,
            destinationURL.isFileURL,
            FileManager.default.fileExists(atPath: destinationURL.path)
        else { return nil }
        return destinationURL
    }
}

/// What follows the pointer: the file as Finder shows it.
private struct DownloadFileDragPreview: View {
    let fileURL: URL

    var body: some View {
        HStack(spacing: CrestSpacing.small) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: fileURL.path))
                .resizable()
                .frame(width: 32, height: 32)
            Text(fileURL.lastPathComponent)
                .lineLimit(1)
        }
        .padding(.horizontal, CrestSpacing.medium)
        .padding(.vertical, CrestSpacing.small)
        .background {
            CrestSurfaceLayer(shape: .rect(cornerRadius: CrestRadius.compact, style: .continuous))
        }
    }
}
