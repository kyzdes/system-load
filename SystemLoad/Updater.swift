import AppKit
import Sparkle

/// Thin wrapper around Sparkle's standard updater for this AppKit menu-bar app.
///
/// The controller is created with `startingUpdater: false` so it exists (and can
/// back the "Check for Updates…" menu item) the moment the app launches, while
/// the actual `start()` — which touches XPC + the keychain — is deferred until
/// just after launch by the caller.
final class Updater {
    let controller: SPUStandardUpdaterController

    init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: nil)
    }

    func start() {
        do {
            try controller.updater.start()
        } catch {
            NSLog("Sparkle failed to start: \(error)")
        }
    }

    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }
}
