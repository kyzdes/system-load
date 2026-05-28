import AppKit
import ServiceManagement

extension Notification.Name {
    /// Posted by SettingsStore whenever a user-facing setting changes.
    static let settingsDidChange = Notification.Name("Settings.didChange")
}

// MARK: - Settings store

/// UserDefaults-backed preferences plus the system login-item state.
///
/// "Launch at login" is NOT stored here — it lives in the system via
/// `SMAppService` (the user can also toggle it from System Settings), so it is
/// always read straight from `SMAppService.mainApp.status`.
final class SettingsStore {
    private enum Key {
        static let refreshInterval = "refreshInterval"
        static let showCPU = "showCPU"
        static let showRAM = "showRAM"
        static let useTextLabels = "useTextLabels"
    }

    /// Allowed refresh intervals in seconds. Order matches the popup in the UI.
    static let intervalChoices = [1, 2, 3, 5, 10]

    private let defaults = UserDefaults.standard

    init() {
        defaults.register(defaults: [
            Key.refreshInterval: 2,
            Key.showCPU: true,
            Key.showRAM: true,
            Key.useTextLabels: false,
        ])
    }

    var refreshInterval: Int {
        get {
            let v = defaults.integer(forKey: Key.refreshInterval)
            return Self.intervalChoices.contains(v) ? v : 2
        }
        set { defaults.set(newValue, forKey: Key.refreshInterval) }
    }

    var showCPU: Bool {
        get { defaults.bool(forKey: Key.showCPU) }
        set { defaults.set(newValue, forKey: Key.showCPU) }
    }

    var showRAM: Bool {
        get { defaults.bool(forKey: Key.showRAM) }
        set { defaults.set(newValue, forKey: Key.showRAM) }
    }

    var useTextLabels: Bool {
        get { defaults.bool(forKey: Key.useTextLabels) }
        set { defaults.set(newValue, forKey: Key.useTextLabels) }
    }

    // MARK: Launch at login (system state)

    /// True when the app is registered to launch at login. `.requiresApproval`
    /// (registered, awaiting the user's OK in System Settings) also counts as on.
    var launchAtLogin: Bool {
        switch SMAppService.mainApp.status {
        case .enabled, .requiresApproval: return true
        default: return false
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// Notify observers (the AppDelegate) so they re-apply settings immediately.
    func notifyChanged() {
        NotificationCenter.default.post(name: .settingsDidChange, object: nil)
    }
}

// MARK: - Settings window

final class SettingsWindowController: NSWindowController {
    private let settings: SettingsStore
    private let updater: Updater

    private var launchAtLoginCheckbox: NSButton!
    private var intervalPopup: NSPopUpButton!
    private var showCPUCheckbox: NSButton!
    private var showRAMCheckbox: NSButton!
    private var textLabelsCheckbox: NSButton!
    private var autoUpdateCheckbox: NSButton!

    init(settings: SettingsStore, updater: Updater) {
        self.settings = settings
        self.updater = updater
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false)
        window.title = "System Load Settings"
        // Reuse a single instance: without this AppKit releases the window on
        // close and reopening a retained controller crashes (use-after-free).
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Layout

    private func buildUI() {
        guard let window = window else { return }
        let content = NSView()
        window.contentView = content

        launchAtLoginCheckbox = makeCheckbox("Launch at login", #selector(toggleLaunchAtLogin))

        intervalPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        intervalPopup.addItems(withTitles: SettingsStore.intervalChoices.map {
            "\($0) second\($0 == 1 ? "" : "s")"
        })
        intervalPopup.target = self
        intervalPopup.action = #selector(changeInterval)
        let intervalRow = NSStackView(views: [makeLabel("Refresh interval:"), intervalPopup])
        intervalRow.orientation = .horizontal
        intervalRow.alignment = .centerY
        intervalRow.spacing = 8

        let menuBarHeader = makeHeader("Menu bar")
        showCPUCheckbox = makeCheckbox("Show CPU", #selector(toggleShowCPU))
        showRAMCheckbox = makeCheckbox("Show RAM", #selector(toggleShowRAM))
        textLabelsCheckbox = makeCheckbox("Use text labels instead of icons", #selector(toggleTextLabels))

        let updateHeader = makeHeader("Software Update")
        autoUpdateCheckbox = makeCheckbox("Automatically check for updates", #selector(toggleAutoUpdate))
        let checkNowButton = NSButton(title: "Check for Updates…", target: self, action: #selector(checkForUpdatesNow))
        checkNowButton.bezelStyle = .rounded
        let versionLabel = makeLabel(versionString())
        versionLabel.textColor = .secondaryLabelColor
        versionLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

        let stack = NSStackView(views: [
            launchAtLoginCheckbox,
            intervalRow,
            menuBarHeader,
            showCPUCheckbox,
            showRAMCheckbox,
            textLabelsCheckbox,
            updateHeader,
            autoUpdateCheckbox,
            checkNowButton,
            versionLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.setCustomSpacing(20, after: intervalRow)        // gap before "Menu bar"
        stack.setCustomSpacing(20, after: textLabelsCheckbox) // gap before "Software Update"
        stack.setCustomSpacing(6, after: checkNowButton)      // version sits close under the button
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        let inset: CGFloat = 20
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -inset),
        ])

        syncFromSettings()
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
        window.center()
    }

    private func makeCheckbox(_ title: String, _ action: Selector) -> NSButton {
        NSButton(checkboxWithTitle: title, target: self, action: action)
    }

    private func makeLabel(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func makeHeader(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        return label
    }

    // MARK: State sync

    /// Mirror the stored settings (and live login-item status) into the controls.
    /// Re-run on every show because the login item may have changed in System Settings.
    private func syncFromSettings() {
        launchAtLoginCheckbox.state = settings.launchAtLogin ? .on : .off
        if let idx = SettingsStore.intervalChoices.firstIndex(of: settings.refreshInterval) {
            intervalPopup.selectItem(at: idx)
        }
        showCPUCheckbox.state = settings.showCPU ? .on : .off
        showRAMCheckbox.state = settings.showRAM ? .on : .off
        textLabelsCheckbox.state = settings.useTextLabels ? .on : .off
        autoUpdateCheckbox.state = updater.automaticallyChecksForUpdates ? .on : .off
    }

    private func versionString() -> String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "System Load \(short) (\(build))"
    }

    override func showWindow(_ sender: Any?) {
        syncFromSettings()
        super.showWindow(sender)
    }

    // MARK: Actions

    @objc private func toggleLaunchAtLogin() {
        let desired = launchAtLoginCheckbox.state == .on
        do {
            try settings.setLaunchAtLogin(desired)
            // register() may leave the status as .requiresApproval — that is a
            // success, so keep the checkbox reflecting the user's choice.
        } catch {
            launchAtLoginCheckbox.state = settings.launchAtLogin ? .on : .off
            presentLaunchError(error, wasEnabling: desired)
        }
    }

    @objc private func changeInterval() {
        let idx = intervalPopup.indexOfSelectedItem
        guard SettingsStore.intervalChoices.indices.contains(idx) else { return }
        settings.refreshInterval = SettingsStore.intervalChoices[idx]
        settings.notifyChanged()
    }

    @objc private func toggleShowCPU() {
        // Keep at least one of CPU/RAM visible — revert the last uncheck.
        if showCPUCheckbox.state == .off && showRAMCheckbox.state == .off {
            showCPUCheckbox.state = .on
            NSSound.beep()
            return
        }
        settings.showCPU = showCPUCheckbox.state == .on
        settings.notifyChanged()
    }

    @objc private func toggleShowRAM() {
        if showRAMCheckbox.state == .off && showCPUCheckbox.state == .off {
            showRAMCheckbox.state = .on
            NSSound.beep()
            return
        }
        settings.showRAM = showRAMCheckbox.state == .on
        settings.notifyChanged()
    }

    @objc private func toggleTextLabels() {
        settings.useTextLabels = textLabelsCheckbox.state == .on
        settings.notifyChanged()
    }

    @objc private func toggleAutoUpdate() {
        updater.automaticallyChecksForUpdates = autoUpdateCheckbox.state == .on
    }

    @objc private func checkForUpdatesNow() {
        updater.checkForUpdates()
    }

    private func presentLaunchError(_ error: Error, wasEnabling: Bool) {
        let alert = NSAlert()
        alert.messageText = wasEnabling
            ? "Couldn’t enable launch at login"
            : "Couldn’t disable launch at login"
        alert.informativeText = error.localizedDescription
            + "\n\nLaunch at login works when the app runs from a stable location "
            + "such as /Applications — not from a build folder."
        alert.alertStyle = .warning
        if let window = window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
