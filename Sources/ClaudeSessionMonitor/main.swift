import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var pinnedWindow: NSWindow?
    let scanner = SessionScanner()
    var isPinned = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Status bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "⌘"
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Popover (used when not pinned)
        popover = NSPopover()
        popover.contentSize = NSSize(width: 420, height: 560)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: SessionListView(scanner: scanner, onTogglePin: { [weak self] pinned in
                self?.setPinned(pinned)
            })
        )

        // New session notification
        scanner.onNewSession = { session in
            NotificationManager.shared.notifyNewSession(session: session)
        }

        // Scan on background thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.scanner.scan()
            DispatchQueue.main.async {
                self?.updateBadge()
            }
        }

        // Periodic refresh (scan sessions every 10s)
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            DispatchQueue.global(qos: .utility).async {
                self?.scanner.scan()
                DispatchQueue.main.async {
                    self?.updateBadge()
                }
            }
        }

        // Event monitor (check for tool calls, completion, errors every 5s)
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            DispatchQueue.global(qos: .utility).async {
                self?.scanner.monitorEvents()
            }
        }
    }

    func setPinned(_ pinned: Bool) {
        isPinned = pinned

        if pinned {
            // Detach from popover → create a standalone floating window
            popover.performClose(nil)

            let contentView = SessionListView(scanner: scanner, onTogglePin: { [weak self] p in
                self?.setPinned(p)
            })

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.contentViewController = NSHostingController(rootView: contentView)
            window.title = "Claude Session Monitor"
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.level = .floating  // Always on top
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            // Position near the menu bar icon
            if let buttonFrame = statusItem.button?.window?.frame {
                let x = buttonFrame.origin.x
                let y = buttonFrame.origin.y - 560
                window.setFrameOrigin(NSPoint(x: x, y: y))
            } else {
                window.center()
            }

            window.makeKeyAndOrderFront(nil)
            window.delegate = self
            pinnedWindow = window
        } else {
            // Close floating window, go back to popover mode
            pinnedWindow?.close()
            pinnedWindow = nil
        }
    }

    func updateBadge() {
        let active = scanner.sessions.filter(\.isActive).count
        statusItem?.button?.title = active > 0 ? "⌘ \(active)" : "⌘"
    }

    @objc func togglePopover() {
        // If pinned window is open, bring it to front
        if isPinned, let window = pinnedWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }

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

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        // If user closes the pinned window via red button, unpin
        isPinned = false
        pinnedWindow = nil
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
