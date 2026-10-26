import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// Lets clicks fall through the SwiftUI label to the status bar button underneath.
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let model = StatsModel()
    private let settings = Settings()
    private let sampler = SystemSampler()
    private let topSampler = TopSampler()
    private var statusItem: NSStatusItem!
    private var statusLabel: NSView?
    private var timer: Timer?
    private var preferencesWindow: NSWindow?
    private var resourcesWindow: NSWindow?
    private lazy var resourceModel = ResourceModel(settings: settings)
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setUpStatusItem()
        setUpMenu()
        _ = resourceModel

        topSampler.onSample = { [weak self] apps, cpuValid in
            self?.model.update(apps: apps, cpuValid: cpuValid)
        }
        model.onQuitRequest = { [weak self] app in
            self?.statusItem.menu?.cancelTracking()
            // Let the menu finish closing before showing a modal alert.
            DispatchQueue.main.async { self?.confirmQuit(app) }
        }

        settings.$refreshInterval
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.scheduleTimer() } }
            .store(in: &cancellables)
        // Columns shown in the bar can change, so the item's width must follow.
        settings.objectWillChange
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatusItemLength() } }
            .store(in: &cancellables)

        refresh()
        scheduleTimer()
        registerLoginItemOnce()
        if CommandLine.arguments.contains("--resources") {
            DispatchQueue.main.async { self.openResources(tab: .cleanup) }
        }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let timer = Timer(timeInterval: settings.refreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // .common keeps values updating while the menu is open (event-tracking run loop mode).
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        let label = PassthroughHostingView(rootView: StatusBarView(model: model, settings: settings))
        label.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
        statusLabel = label
        updateStatusItemLength()
    }

    /// Columns have fixed widths, so the width only changes when columns or the thermometer appear or disappear.
    private func updateStatusItemLength() {
        guard let width = statusLabel?.fittingSize.width, statusItem.length != width else { return }
        statusItem.length = width
    }

    private func setUpMenu() {
        let menu = NSMenu()
        menu.delegate = self

        let panel = NSHostingView(rootView: MenuPanelView(model: model, settings: settings))
        panel.frame.size = panel.fittingSize
        let panelItem = NSMenuItem()
        panelItem.view = panel
        menu.addItem(panelItem)

        menu.addItem(.separator())
        let docker = NSMenuItem(title: String(localized: "Clean Docker…"), action: #selector(openDocker), keyEquivalent: "")
        docker.target = self
        menu.addItem(docker)
        let suggestions = NSMenuItem(title: String(localized: "Free memory…"), action: #selector(openSuggestions), keyEquivalent: "")
        suggestions.target = self
        menu.addItem(suggestions)
        let preferences = NSMenuItem(title: String(localized: "Settings…"), action: #selector(openPreferences), keyEquivalent: ",")
        preferences.target = self
        menu.addItem(preferences)
        let activityMonitor = NSMenuItem(title: String(localized: "Open Activity Monitor"), action: #selector(openActivityMonitor), keyEquivalent: "")
        activityMonitor.target = self
        menu.addItem(activityMonitor)
        menu.addItem(NSMenuItem(title: String(localized: "Quit MacStatsBar"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func refresh() {
        let wasHot = model.snapshot.thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        model.snapshot = sampler.sample(previous: model.snapshot)
        // The thermometer appearing or disappearing is the only per-sample change in the bar's width.
        let isHot = model.snapshot.thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        if isHot != wasHot {
            DispatchQueue.main.async { self.updateStatusItemLength() }
        }
    }

    private func registerLoginItemOnce() {
        let key = "didRegisterLoginItem"
        guard Bundle.main.bundlePath.hasPrefix("/Applications/"),
              !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
            settings.launchAtLogin = true
        } catch {
            NSLog("MacStatsBar: could not register login item: \(error)")
        }
    }

    private func confirmQuit(_ app: AppUsage) {
        // The group's top-level apps; helpers live inside another bundle's Contents/ and quit with it.
        let runningApps = app.pids
            .compactMap(NSRunningApplication.init(processIdentifier:))
            .filter { $0.bundleURL.map { !$0.path.contains(".app/") } ?? false }

        let alert = NSAlert()
        alert.messageText = String(localized: "Quit \(app.name)?")
        let freed = String(localized: "This will free about \(Format.memory(app.memBytes)) of memory.")
        let consequence: String
        if !runningApps.isEmpty {
            consequence = String(localized: "If anything is unsaved, the app will ask before closing.")
        } else if app.pids.count > 1 {
            consequence = String(localized: "Its \(app.pids.count) processes will be terminated without a chance to save open work.")
        } else {
            consequence = String(localized: "The process will be terminated without a chance to save open work.")
        }
        alert.informativeText = freed + " " + consequence
        if let path = app.appPath {
            alert.icon = NSWorkspace.shared.icon(forFile: path)
        }
        alert.addButton(withTitle: String(localized: "Quit")).hasDestructiveAction = true
        alert.addButton(withTitle: String(localized: "Cancel"))

        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if runningApps.isEmpty {
            app.pids.forEach { kill($0, SIGTERM) }
        } else {
            runningApps.forEach { $0.terminate() }
        }
    }

    @objc private func openPreferences() {
        if preferencesWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: PreferencesView(settings: settings)))
            window.title = "MacStatsBar"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            preferencesWindow = window
        }
        NSApp.activate()
        preferencesWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func openActivityMonitor() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }

    @objc private func openDocker() { openResources(tab: .cleanup) }
    @objc private func openSuggestions() { openResources(tab: .suggestions) }

    private func openResources(tab: ResourceTab) {
        resourceModel.selectedTab = tab
        if resourcesWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(
                rootView: ResourceWindowView(model: resourceModel, settings: settings)
            ))
            window.title = String(localized: "MacStatsBar Resources")
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 1040, height: 680))
            window.contentMinSize = NSSize(width: 880, height: 560)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            resourcesWindow = window
        }
        resourceModel.setVisible(true)
        NSApp.activate()
        resourcesWindow?.deminiaturize(nil)
        resourcesWindow?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === resourcesWindow { resourceModel.setVisible(false) }
    }

    func windowDidMiniaturize(_ notification: Notification) {
        if (notification.object as? NSWindow) === resourcesWindow { resourceModel.setVisible(false) }
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        if (notification.object as? NSWindow) === resourcesWindow { resourceModel.setVisible(true) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        resourceModel.shutdown()
        topSampler.stop()
        timer?.invalidate()
    }

    func menuWillOpen(_ menu: NSMenu) {
        topSampler.start()
    }

    func menuDidClose(_ menu: NSMenu) {
        topSampler.stop()
        model.menuDidClose()
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
