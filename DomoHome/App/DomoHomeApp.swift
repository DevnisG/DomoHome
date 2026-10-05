import AppKit
import ServiceManagement
import SwiftUI

@main
struct DomoHomeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = HomeController()
    @StateObject private var shortcutManager = GlobalShortcutManager()

    var body: some Scene {
        Window("DomoHome", id: "controlPanel") {
            ContentView(appDelegate: appDelegate)
                .environmentObject(controller)
                .environmentObject(shortcutManager)
        }
        .defaultSize(width: 780, height: 520)
        .windowResizability(.contentSize)
    }
}

@MainActor
final class LoginItemManager: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var hasError = false

    init() {
        refreshStatus()
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            hasError = false
        } catch {
            hasError = true
        }
        refreshStatus()
    }

    private func refreshStatus() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled || status == .requiresApproval
        requiresApproval = status == .requiresApproval
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var isConfigured = false
    private var statusItem: NSStatusItem?
    private weak var controller: HomeController?
    private var openControlPanel: (() -> Void)?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func configure(
        controller: HomeController,
        shortcutManager: GlobalShortcutManager,
        openControlPanel: @escaping () -> Void
    ) {
        self.controller = controller
        self.openControlPanel = openControlPanel
        guard !isConfigured else { return }
        isConfigured = true
        shortcutManager.configure(controller: controller)
        configureStatusItem()
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let controller else { return }
        menu.removeAllItems()

        if !controller.lightGroups.isEmpty {
            menu.addItem(NSMenuItem.sectionHeader(title: L10n.text("Todas las luces")))
            menu.addItem(menuItem(L10n.text("Encender todas"), symbol: "sun.max.fill",
                                  action: #selector(turnAllLightsOn(_:)), enabled: !controller.isBusy))
            menu.addItem(menuItem(L10n.text("Apagar todas"), symbol: "moon.fill",
                                  action: #selector(turnAllLightsOff(_:)), enabled: !controller.isBusy))
            menu.addItem(.separator())
        }

        for (index, group) in controller.lightGroups.enumerated() {
            if index > 0 {
                menu.addItem(.separator())
            }
            menu.addItem(NSMenuItem.sectionHeader(title: group.title))
            menu.addItem(menuItem(
                L10n.text("Alternar"),
                symbol: "sun.max.fill",
                action: #selector(toggleLightGroup(_:)),
                representedObject: group.id,
                enabled: !controller.isBusy
            ))
        }

        if controller.lockConfigurationLoaded {
            if !controller.lightGroups.isEmpty {
                menu.addItem(.separator())
            }
            menu.addItem(NSMenuItem.sectionHeader(title: L10n.text("Cerradura")))
            menu.addItem(menuItem(
                L10n.text("Abrir"),
                symbol: "lock.open.fill",
                action: #selector(unlockDoor(_:)),
                enabled: !controller.isBusy
            ))
        }

        menu.addItem(.separator())
        menu.addItem(menuItem(
            L10n.text("Mostrar"),
            symbol: "house",
            action: #selector(showHome(_:))
        ))
        menu.addItem(menuItem(
            L10n.text("Ajustes"),
            symbol: "slider.horizontal.3",
            action: #selector(showSettings(_:))
        ))
        menu.addItem(menuItem(
            L10n.text("Salir"),
            symbol: "xmark",
            action: #selector(quit(_:))
        ))
    }

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        for entry in menu.items {
            (entry.view as? MenuItemRowView)?.setHighlighted(entry === item)
        }
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(named: NSImage.Name("MenuBarMark"))
                ?? NSImage(systemSymbolName: "house.fill", accessibilityDescription: "DomoHome")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageOnly
            button.toolTip = "DomoHome"
        }

        item.menu = makeActionMenu()
        statusItem = item
    }

    func makeActionMenu() -> NSMenu {
        let menu = NSMenu(title: "DomoHome")
        menu.autoenablesItems = false
        menu.showsStateColumn = false
        menu.delegate = self
        return menu
    }

    private func menuItem(
        _ title: String,
        symbol: String,
        action: Selector,
        representedObject: Any? = nil,
        enabled: Bool = true
    ) -> NSMenuItem {
        let item = ActionMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = representedObject
        item.isEnabled = enabled
        item.view = MenuItemRowView(title: title, symbol: symbol)
        return item
    }

    @objc private func toggleLightGroup(_ sender: NSMenuItem) {
        guard let groupID = sender.representedObject as? String else { return }
        controller?.run(.toggleGroup(groupID))
    }

    @objc private func turnAllLightsOn(_ sender: NSMenuItem) {
        controller?.run(.setAllLights(true))
    }

    @objc private func turnAllLightsOff(_ sender: NSMenuItem) {
        controller?.run(.setAllLights(false))
    }

    @objc private func unlockDoor(_ sender: NSMenuItem) {
        controller?.run(.doorUnlock)
    }

    @objc private func showHome(_ sender: NSMenuItem) {
        controller?.page = .home
        openControlPanel?()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showSettings(_ sender: NSMenuItem) {
        controller?.page = .settings
        openControlPanel?()
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(nil)
    }
}
