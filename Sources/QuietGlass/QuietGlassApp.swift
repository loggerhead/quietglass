// Clinton Imaro was here 20/09/2026.

import AppKit
import Combine
import ShieldCore

@main
struct QuietGlassApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private var notch: NotchBarController!
    private var privacySettings: PrivacySettingsController!
    private var headSetup: HeadSetupController!
    private var keyMonitor: Any?
    private var observation: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        QuietGlassIntentBridge.model = model
        if Bundle.main.url(forResource: "Metadata", withExtension: "appintents") != nil {
            QuietGlassShortcuts.updateAppShortcutParameters()
        }
        notch = NotchBarController(model: model)
        privacySettings = PrivacySettingsController(model: model)
        headSetup = HeadSetupController(model: model)
        model.onOpenProtection = { [weak self] in self?.privacySettings.show(.protection) }
        model.onOpenRules = { [weak self] in self?.privacySettings.show(.rules) }
        model.privacy.onPrepareAreaSelection = { [weak self] in
            self?.notch.closeControls()
            self?.privacySettings.hideForAreaSelection()
        }
        model.onOpenPrivacySettings = { [weak self] in self?.showPrivacySettings() }
        model.onOpenNearbySettings = { [weak self] in self?.notch.closeControls(); self?.privacySettings.showNearbyPeople() }
        model.onRequestHeadSetup = { [weak self] in self?.notch.closeControls(); self?.headSetup.show() }
        model.onCancelHeadSetup = { [weak self] in self?.headSetup.close() }
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "QuietGlass")
        item("About QuietGlass", #selector(showAbout), in: applicationMenu)
        applicationMenu.addItem(.separator())
        item("Settings…", #selector(showPrivacySettings), in: applicationMenu, key: ",")
        item("Downloads & Updates…", #selector(showDownloads), in: applicationMenu)
        item("Check for Updates…", #selector(checkForUpdates), in: applicationMenu)
        applicationMenu.addItem(.separator())
        item("Quit QuietGlass", #selector(quit), in: applicationMenu, key: "q")
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        let editItem = NSMenuItem(title: QG("Edit"), action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: QG("Edit"))
        editMenu.addItem(withTitle: QG("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: QG("Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: QG("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: QG("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: QG("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: QG("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        let viewItem = NSMenuItem(title: QG("View"), action: nil, keyEquivalent: "")
        let viewMenu = NSMenu(title: QG("View"))
        let sidebar = item("Toggle Sidebar", #selector(toggleSettingsSidebar), in: viewMenu, key: "s")
        sidebar.keyEquivalentModifierMask = [.command]
        viewMenu.addItem(.separator())
        let fullScreen = NSMenuItem(title: QG("Enter Full Screen"), action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.control, .command]
        viewMenu.addItem(fullScreen)
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)
        let helpItem = NSMenuItem(title: QG("Help"), action: nil, keyEquivalent: "")
        let helpMenu = NSMenu(title: QG("Help"))
        item("QuietGlass Help", #selector(showHelp), in: helpMenu)
        item("Report an Issue…", #selector(reportIssue), in: helpMenu)
        helpItem.submenu = helpMenu
        mainMenu.addItem(helpItem)
        NSApp.helpMenu = helpMenu
        NSApp.mainMenu = mainMenu
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = AppIcon.view.image()
        statusItem.button?.setAccessibilityLabel("QuietGlass")
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        buildMenu(menu)
        observation = model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.statusItem.button?.image = (self.model.protectionCoordinator?.plan.hasProtection == true ? AppIcon.viewOff : .view).image()
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53, self.model.headSetupActive {
                self.headSetup.close()
                return nil
            }
            if event.keyCode == 53, self.model.coverage > 0 || self.model.privacy.wantsProtection {
                self.model.dismissShield()
                return nil
            }
            if event.keyCode == 53 { self.notch.closeControls() }
            return event
        }
        notch.show()
        privacySettings.show()
        if UserDefaults.standard.bool(forKey: "showControlsAfterRelaunch") {
            UserDefaults.standard.removeObject(forKey: "showControlsAfterRelaunch")
            notch.showControls()
        }
        model.updates.checkIfDue()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { buildMenu(menu) }

    func applicationDidResignActive(_ notification: Notification) {
        if NSApp.activationPolicy() == .regular, !privacySettings.isVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func buildMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: QG("QuietGlass · %@", model.status), action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        item("Screen controls", #selector(showProtection), in: menu)
        item("Auto & shortcuts", #selector(showRules), in: menu)
        item("Settings", #selector(showPrivacySettings), in: menu)
        item(notch.isVisible ? "Hide Notch" : "Show Notch", #selector(toggleNotch), in: menu)
        item("Move Notch Down", #selector(resetNotch), in: menu)
        menu.addItem(.separator())
        item("Blur screen now", #selector(togglePrivacy), in: menu)
        item("Select an area", #selector(chooseArea), in: menu, shortcut: model.areaShortcutLabel)
        item("Protect a window", #selector(chooseWindow), in: menu)
        item("Focus", #selector(toggleFocus), in: menu)
        item("Pause", #selector(pauseProtection), in: menu)
        item("Resume", #selector(resumeProtection), in: menu)
        item("Clear all · Escape", #selector(clear), in: menu)
        menu.addItem(.separator())
        item("About QuietGlass", #selector(showAbout), in: menu)
        item("QuietGlass Help", #selector(showHelp), in: menu)
        item("Downloads & Updates…", #selector(showDownloads), in: menu)
        menu.addItem(.separator())
        item("Quit QuietGlass", #selector(quit), in: menu, key: "q")
    }

    @discardableResult private func item(_ title: String, _ action: Selector, in menu: NSMenu,
                                        key: String = "", shortcut: String? = nil) -> NSMenuItem {
        let displayTitle = shortcut.map { QG(title) + "    " + $0 } ?? QG(title)
        let entry = NSMenuItem(title: displayTitle, action: action, keyEquivalent: key)
        entry.target = self
        menu.addItem(entry)
        return entry
    }

    @objc private func showProtection() { notch.closeControls(); privacySettings.show(.protection) }
    @objc private func showRules() { notch.closeControls(); privacySettings.show(.rules) }
    @objc private func chooseWindow() { model.privacy.chooseWindow() }
    @objc private func toggleFocus() { model.setFocus(!model.privacy.focusEnabled) }
    @objc private func pauseProtection() { model.protectionCoordinator?.pause() }
    @objc private func resumeProtection() { model.protectionCoordinator?.resume() }

    @objc private func toggleSettingsSidebar() { privacySettings.toggleSidebar() }
    @objc private func showControls() { notch.showControls() }
    @objc private func showPrivacySettings() { notch.closeControls(); privacySettings.show(.settings) }
    @objc private func togglePrivacy() { model.toggleInstantShield() }
    @objc private func chooseArea() { model.privacy.chooseArea() }
    @objc private func toggleNotch() { notch.toggleVisibility() }
    @objc private func resetNotch() { notch.resetPosition(); notch.show() }
    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: QG("Privacy for what’s on your Mac.\nBuilt by Clinton Imaro · Open source under the MIT License."))
        ])
    }
    @objc private func showHelp() {
        if let guide = Bundle.main.url(forResource: "QuietGlass Help", withExtension: "html") {
            NSWorkspace.shared.open(guide)
        }
    }
    @objc private func showDownloads() { openProjectPage("releases/latest") }
    @objc private func checkForUpdates() { privacySettings.showUpdates(); Task { await model.updates.check() } }
    @objc private func reportIssue() { openProjectPage("issues") }
    private func openProjectPage(_ path: String) {
        guard let url = URL(string: "https://github.com/clintonimaroo/quietglass/\(path)") else { return }
        NSWorkspace.shared.open(url)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { privacySettings.show(); notch.show(); return true }
    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
        notch.shutdown()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    @objc private func clear() { model.dismissShield() }
    @objc private func quit() { NSApplication.shared.terminate(nil) }
}
