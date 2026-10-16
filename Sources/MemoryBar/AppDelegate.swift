import AppKit
import SwiftUI
import MemoryBarCore

/// Menu-bar app delegate. Owns the status item, the panel, the polling model,
/// and the settings window. Memory is an `.accessory` app: no Dock icon, and
/// it never takes the foreground unless a row asks for it.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var settingsWindowController: NSWindowController?
    private var defaultsObserver: NSObjectProtocol?

    private let model = PanelModel()
    private lazy var panel = MenuBarPanelController(model: model)
    /// The menu bar shown while a normal window is open.
    private lazy var settingsMenu = SettingsMenu(showSettings: { [weak self] in self?.openSettings() })

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            // Dark is the house default; light is first-class.
            AppearancePreference.key: AppearancePreference.dark.rawValue,
            PanelModel.pollIntervalKey: 60.0,
        ])
        AppearancePreference.applyCurrent()

        model.onOpenSettings = { [weak self] in
            self?.panel.close()
            self?.openSettings()
        }
        model.onQuit = { NSApp.terminate(nil) }
        model.onSnapshotChange = { [weak self] snapshot in
            self?.updateStatusItem(snapshot)
            self?.publishStatus(snapshot.headline)
        }

        setupStatusItem()
        observeAppearancePreference()
        model.start()
        publishCommands()
        publishStatus(model.snapshot.headline)
    }

    // MARK: - House commands

    /// Tell the rest of the house what Memory can do, per the command
    /// contract in `design-system/docs/app-commands.md`. Written once at
    /// launch; the command set is fixed, so there is nothing to rewrite.
    ///
    /// Off the main thread, because it touches the disk, and a failure is one
    /// log line. A manifest Quick Launch cannot read costs the launcher one
    /// app's rows; it must never cost the menu bar its own function.
    private func publishCommands() {
        DispatchQueue.global(qos: .utility).async {
            AppDelegate.log(CommandManifest.publish())
        }
    }

    /// Rewrite the status document from the snapshot already in hand. Called
    /// at launch and whenever the snapshot changes, which is the only place
    /// Memory learns anything new about the collector: no second poll, and no
    /// second wording for the state.
    private func publishStatus(_ headline: String) {
        DispatchQueue.global(qos: .utility).async {
            AppDelegate.log(CommandManifest.publishStatus(headline: headline))
        }
    }

    /// One line to the system log, never a dialog and never a crash.
    private nonisolated static func log(_ outcome: CommandManifest.Outcome) {
        switch outcome {
        case .wrote:
            break
        case let .skipped(reason):
            NSLog("memory-bar: no command manifest: %@", reason)
        case let .failed(reason):
            NSLog("memory-bar: command manifest write failed: %@", reason)
        }
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        item.button?.target = self
        item.button?.action = #selector(togglePanel)
        updateStatusItem(model.snapshot)
    }

    /// The status item says the same thing the panel header does, in one
    /// glyph: the bookmark from the app icon while collecting, the same
    /// bookmark struck through while paused, and the bookmark in `danger`
    /// (the only case that is not a template image) when a permission the
    /// collector needs is missing.
    private func updateStatusItem(_ snapshot: CollectorSnapshot) {
        guard let button = statusItem?.button else { return }
        let symbol: String
        let description: String
        switch snapshot.health {
        case .paused:
            symbol = "bookmark.slash"
            description = "Memory — paused"
        case .permission:
            symbol = "bookmark"
            description = "Memory — \(snapshot.headline)"
        case .collecting, .stopped, .unknown:
            symbol = "bookmark"
            description = "Memory — \(snapshot.headline)"
        }

        if snapshot.health == .permission {
            // Colour is the exception the house rule allows for status, and it
            // is paired with the word in the panel and in the tooltip here.
            button.image = StatusItemGlyph.image(symbol, description: description, tinted: House.NSColorToken.danger)
        } else {
            button.image = StatusItemGlyph.image(symbol, description: description)
        }
        button.toolTip = description
    }

    @objc private func togglePanel() {
        panel.toggle(relativeTo: statusItem.button)
    }

    // MARK: - Appearance

    private func observeAppearancePreference() {
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { AppearancePreference.applyCurrent() }
        }
    }

    // MARK: - Settings

    @objc private func openSettings() {
        if let controller = settingsWindowController, let window = controller.window {
            controller.showWindow(nil)
            present(window)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Memory"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = House.NSColorToken.surface
        window.appearance = AppearancePreference.current.nsAppearance
        window.setContentSize(NSSize(width: 760, height: 500))
        window.minSize = NSSize(width: 720, height: 460)

        window.isReleasedWhenClosed = false
        window.delegate = self
        let controller = NSWindowController(window: window)
        controller.showWindow(self)
        window.center()
        present(window)
        settingsWindowController = controller
    }

    /// A normal window is up: install the menu bar it needs (Edit for its
    /// text fields, Window for minimise and close) and take the keyboard.
    /// An accessory app cannot activate itself on request alone, so
    /// `AppActivation` asks LaunchServices when the request is refused.
    private func present(_ window: NSWindow) {
        if NSApp.mainMenu == nil { NSApp.mainMenu = settingsMenu.makeMenu() }
        AppActivation.becomeRegularApp(showing: window)
    }
}

extension AppDelegate: NSWindowDelegate {
    /// The last normal window is closing: hand the menu bar back and become
    /// a menu-bar app again.
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === settingsWindowController?.window { settingsWindowController = nil }
        AppActivation.settleAfterClosing(window)
    }
}
