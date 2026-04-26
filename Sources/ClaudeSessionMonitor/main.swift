import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    let scanner = SessionScanner()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Status bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "⌘"
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 520)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: SessionListView(scanner: scanner)
        )

        // New session notification
        scanner.onNewSession = { session in
            NotificationManager.shared.send(
                title: "新 Claude Session",
                body: "\(session.projectShort): \(session.summary)"
            )
        }

        // Scan on background thread to avoid blocking run loop
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.scanner.scan()
            DispatchQueue.main.async {
                self?.updateBadge()
            }
        }

        // Periodic refresh
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            DispatchQueue.global(qos: .utility).async {
                self?.scanner.scan()
                DispatchQueue.main.async {
                    self?.updateBadge()
                }
            }
        }
    }

    func updateBadge() {
        let active = scanner.sessions.filter(\.isActive).count
        statusItem?.button?.title = active > 0 ? "⌘ \(active)" : "⌘"
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.scanner.scan()
                DispatchQueue.main.async { self?.updateBadge() }
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
