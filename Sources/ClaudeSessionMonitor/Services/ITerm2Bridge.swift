import Foundation

class ITerm2Bridge {
    /// Activate the iTerm2 tab/session that owns the given TTY
    static func activateSession(tty: String) {
        let devTty = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"

        let script = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(devTty)" then
                            select t
                            tell w to select
                            activate
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
            return "not found"
        end tell
        """

        runAppleScript(script)
    }

    /// Send text to the iTerm2 session on the given TTY (types into the terminal)
    static func sendText(tty: String, text: String) {
        let devTty = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "\(devTty)" then
                            tell s to write text "\(escaped)"
                            return "ok"
                        end if
                    end repeat
                end repeat
            end repeat
            return "not found"
        end tell
        """

        runAppleScript(script)
    }

    private static func runAppleScript(_ script: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            let pipe = Pipe()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", script]
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            try? task.run()
            let _ = pipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
        }
    }
}
