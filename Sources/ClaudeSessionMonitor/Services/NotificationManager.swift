import Foundation

class NotificationManager {
    static let shared = NotificationManager()

    /// Deduplicate: don't send the same notification twice
    private var recentNotifications: [String: Date] = [:]
    private let dedupeInterval: TimeInterval = 30  // seconds

    func send(title: String, body: String, sound: String = "Glass") {
        // Deduplicate
        let key = "\(title):\(body)"
        if let last = recentNotifications[key], Date().timeIntervalSince(last) < dedupeInterval {
            return
        }
        recentNotifications[key] = Date()

        // Clean old entries
        let cutoff = Date().addingTimeInterval(-dedupeInterval * 2)
        recentNotifications = recentNotifications.filter { $0.value > cutoff }

        let escaped = escapeForAppleScript(body)
        let escapedTitle = escapeForAppleScript(title)
        let script = """
        display notification "\(escaped)" with title "\(escapedTitle)" sound name "\(sound)"
        """

        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", script]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()
            let _ = Pipe() // avoid pipe deadlock
            task.waitUntilExit()
        }
    }

    // Convenience methods for specific notification types
    func notifyToolWaiting(session: SessionInfo, toolName: String, detail: String) {
        send(
            title: "⏳ \(toolName) 等待确认",
            body: "[\(session.projectShort)] \(detail)",
            sound: "Ping"
        )
    }

    func notifyTaskComplete(session: SessionInfo, summary: String) {
        send(
            title: "✅ 任务完成",
            body: "[\(session.projectShort)] \(summary)",
            sound: "Glass"
        )
    }

    func notifyError(session: SessionInfo, error: String) {
        send(
            title: "❌ 出错",
            body: "[\(session.projectShort)] \(error)",
            sound: "Basso"
        )
    }

    func notifyNewSession(session: SessionInfo) {
        send(
            title: "🆕 新 Claude Session",
            body: "\(session.projectShort): \(session.summary)",
            sound: "Glass"
        )
    }

    private func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
         .replacingOccurrences(of: "\n", with: " ")
    }
}
