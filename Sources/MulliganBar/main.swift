import AppKit
import SwiftUI
import Combine
import UserNotifications
import MulliganCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    let popover = NSPopover()
    var model: AppModel!
    var observation: AnyCancellable?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do { model = try AppModel.makeDefault() } catch {
            let a = NSAlert()
            a.messageText = "Mulligan can't open its vault"
            a.informativeText = "\(error)"
            a.runModal()
            NSApp.terminate(nil)
            return
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 420, height: 580)
        popover.contentViewController = NSHostingController(rootView: PopoverView(model: model))
        model.onAlert = { [weak self] in self?.openPopover() }
        model.start()
        installNotificationDelegate()
        updateIcon()
        observation = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateIcon() }
        }
        if model.needsOnboarding { openPopover() }
    }

    func installNotificationDelegate() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in self.openPopover() }
        completionHandler()
    }

    func updateIcon() {
        guard let button = statusItem?.button else { return }
        let name: String, color: NSColor?
        if !model.alerts.isEmpty { name = "exclamationmark.arrow.triangle.2.circlepath"; color = .systemRed }
        else if model.config.paused { name = "pause.circle"; color = nil }
        else { name = "arrow.uturn.backward.circle"; color = nil }
        var img = NSImage(systemSymbolName: name, accessibilityDescription: "Mulligan")
        if let c = color {
            img = img?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [c]))
            img?.isTemplate = false
        } else { img?.isTemplate = true }
        button.image = img
        button.toolTip = model.alerts.isEmpty ? "Mulligan — undo for your files" : "Mulligan: files just disappeared — click to restore"
    }

    @objc func togglePopover(_ sender: Any?) {
        if popover.isShown { popover.performClose(sender) } else { openPopover() }
    }

    func openPopover() {
        guard let button = statusItem.button, !popover.isShown else { return }
        model.popoverOpen = true
        model.scheduleTimer()
        model.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    func popoverDidClose(_ notification: Notification) {
        model.popoverOpen = false
        model.scheduleTimer()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

if let i = CommandLine.arguments.firstIndex(of: "--render") {
    let dir = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "."
    MainActor.assumeIsolated { RenderScenes.run(outDir: dir) }
    exit(0)
}

if let i = CommandLine.arguments.firstIndex(of: "--make-icon"), CommandLine.arguments.count > i + 1 {
    MainActor.assumeIsolated { IconMaker.run(dir: CommandLine.arguments[i + 1]) }
    exit(0)
}

if CommandLine.arguments.contains("--selftest") {
    exit(MainActor.assumeIsolated { RenderScenes.selftest() })
}

let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
