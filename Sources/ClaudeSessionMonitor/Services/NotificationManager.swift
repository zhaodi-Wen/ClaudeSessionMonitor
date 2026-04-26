import Foundation

class NotificationManager {
    static let shared = NotificationManager()

    func send(title: String, body: String) {
        // Use osascript for notifications (works without .app bundle)
        let script = """
        display notification "\(escapeForAppleScript(body))" with title "\(escapeForAppleScript(title))" sound name "Glass"
        """

        DispatchQueue.global(qos: .utility).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", script]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            try? task.run()
            task.waitUntilExit()
        }
    }

    private func escapeForAppleScript(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
