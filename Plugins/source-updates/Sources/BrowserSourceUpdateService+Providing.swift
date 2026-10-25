import Foundation

extension BrowserSourceUpdateService: BrowserSoftwareUpdateProviding {
    /// Sparkle's "download" is this build's "build".
    var automaticallyDownloadsUpdates: Bool { automaticallyBuildsUpdates }

    var settingsSection: CrestPluginView { CrestPluginView(SourceUpdateSettingsSection(source: self)) }

    func setAutomaticallyDownloadsUpdates(_ isEnabled: Bool) {
        setAutomaticallyBuildsUpdates(isEnabled)
    }
}
