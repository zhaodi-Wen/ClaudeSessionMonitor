import Foundation

struct SessionInfo: Identifiable, Hashable {
    let id: String          // UUID from filename
    let project: String     // project dir name
    let summary: String     // first user message
    let lastActive: Date    // file mtime
    let fileSize: Int64
    let filePath: String    // full path to JSONL
    var isActive: Bool = false
    var pid: Int32? = nil
    var tty: String? = nil  // e.g. "ttys024"

    var projectShort: String {
        let home = NSUserName()
        let cleaned = project
            .replacingOccurrences(of: "-Users-\(home)-", with: "~/")
            .replacingOccurrences(of: "-Users-\(home)", with: "~")
        return cleaned.isEmpty ? "~" : cleaned
    }

    var timeAgo: String {
        let interval = Date().timeIntervalSince(lastActive)
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60))分钟前" }
        if interval < 86400 { return "\(Int(interval / 3600))小时前" }
        return "\(Int(interval / 86400))天前"
    }

    var devTty: String? {
        guard let tty = tty else { return nil }
        return tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
    }
}
