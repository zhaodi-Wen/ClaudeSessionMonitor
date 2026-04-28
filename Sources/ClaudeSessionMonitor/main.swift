import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var pinnedWindows: [String: NSWindow] = [:]  // sessionId → window
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
        popover.contentSize = NSSize(width: 420, height: 560)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: SessionListView(scanner: scanner, onPinSession: { [weak self] session in
                self?.pinSession(session)
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

    func pinSession(_ session: SessionInfo) {
        // If already pinned, bring to front
        if let existing = pinnedWindows[session.id] {
            existing.makeKeyAndOrderFront(nil)
            return
        }

        // Close popover
        popover.performClose(nil)

        // Create a floating window with just this session's detail
        let detailView = PinnedSessionDetailView(
            session: session,
            scanner: scanner,
            onClose: { [weak self] in
                self?.unpinSession(session.id)
            }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = NSHostingController(rootView: detailView)
        window.title = "\(session.projectShort) — \(String(session.summary.prefix(30)))"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Offset each window slightly so they don't stack exactly
        let offset = CGFloat(pinnedWindows.count) * 30
        if let buttonFrame = statusItem.button?.window?.frame {
            let x = buttonFrame.origin.x + offset
            let y = buttonFrame.origin.y - 560
            window.setFrameOrigin(NSPoint(x: x, y: y))
        } else {
            window.center()
        }

        window.makeKeyAndOrderFront(nil)

        // Use a custom delegate to handle window close
        let closeDelegate = WindowCloseDelegate { [weak self] in
            self?.unpinSession(session.id)
        }
        window.delegate = closeDelegate
        // Keep delegate alive by associating with window
        objc_setAssociatedObject(window, "closeDelegate", closeDelegate, .OBJC_ASSOCIATION_RETAIN)

        pinnedWindows[session.id] = window
    }

    func unpinSession(_ sessionId: String) {
        if let window = pinnedWindows[sessionId] {
            window.delegate = nil
            window.orderOut(nil)
        }
        pinnedWindows.removeValue(forKey: sessionId)
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

/// Handles window close button (red X)
class WindowCloseDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void
    init(onClose: @escaping () -> Void) { self.onClose = onClose }
    func windowWillClose(_ notification: Notification) { onClose() }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
