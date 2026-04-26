import Foundation

class LaunchAtLogin {
    private static let plistName = "com.claude.session-monitor"
    private static var plistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(plistName).plist"
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistPath)
    }

    static func enable(executablePath: String) {
        let plist: [String: Any] = [
            "Label": plistName,
            "ProgramArguments": [executablePath],
            "RunAtLoad": true,
            "KeepAlive": false,
            "StandardOutPath": "/tmp/claude-session-monitor.log",
            "StandardErrorPath": "/tmp/claude-session-monitor.log"
        ]

        let dir = NSHomeDirectory() + "/Library/LaunchAgents"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let data = try? PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        FileManager.default.createFile(atPath: plistPath, contents: data)

        // Load immediately
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["load", plistPath]
        try? task.run()
        task.waitUntilExit()
    }

    static func disable() {
        // Unload
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["unload", plistPath]
        try? task.run()
        task.waitUntilExit()

        try? FileManager.default.removeItem(atPath: plistPath)
    }
}
