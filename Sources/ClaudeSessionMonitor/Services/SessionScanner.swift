import Foundation

struct ClaudeProcess {
    let pid: Int32
    let tty: String
    let cpuPercent: Double
    let cwd: String
    let projectKey: String
    let startEpoch: TimeInterval  // process start time
}

class SessionScanner: ObservableObject {
    @Published var sessions: [SessionInfo] = []

    private let basePath: String
    private var knownSessionIds: Set<String> = []
    var onNewSession: ((SessionInfo) -> Void)?

    init() {
        self.basePath = NSHomeDirectory() + "/.claude-internal/projects"
    }

    func scan() {
        let fm = FileManager.default
        var results: [SessionInfo] = []
        let activeProcs = getActiveClaudeProcesses()

        guard let projectDirs = try? fm.contentsOfDirectory(atPath: basePath) else {
            updateSessions(results)
            return
        }

        for proj in projectDirs {
            let projPath = basePath + "/" + proj
            guard let files = try? fm.contentsOfDirectory(atPath: projPath) else { continue }

            // Find processes matching this project by CWD
            let matchingProcs = activeProcs.filter { $0.projectKey == proj }

            for file in files where file.hasSuffix(".jsonl") {
                let filePath = projPath + "/" + file
                let sessionId = String(file.dropLast(6))

                guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                      let mtime = attrs[.modificationDate] as? Date,
                      let size = attrs[.size] as? Int64 else { continue }

                if size < 500 { continue }

                // Get file birth time for process matching
                let birthTime: TimeInterval
                if let creationDate = attrs[.creationDate] as? Date {
                    birthTime = creationDate.timeIntervalSince1970
                } else {
                    birthTime = 0
                }

                let summary = extractFirstUserMessage(filePath: filePath)

                var info = SessionInfo(
                    id: sessionId,
                    project: proj,
                    summary: summary,
                    lastActive: mtime,
                    fileSize: size,
                    filePath: filePath
                )

                // Match this session to a process by birth time ≈ process start time
                // (within 60 seconds means this process created this JSONL)
                if birthTime > 0 {
                    var bestProc: ClaudeProcess? = nil
                    var bestDiff = Double.infinity
                    for proc in matchingProcs {
                        let diff = abs(birthTime - proc.startEpoch)
                        if diff < bestDiff {
                            bestDiff = diff
                            bestProc = proc
                        }
                    }
                    if bestDiff < 60, let proc = bestProc {
                        info.isActive = true
                        info.pid = proc.pid
                        info.tty = proc.tty
                    }
                }

                results.append(info)
            }
        }

        results.sort { $0.lastActive > $1.lastActive }

        // Detect new sessions
        let newIds = Set(results.map(\.id))
        let appeared = newIds.subtracting(knownSessionIds)
        if !knownSessionIds.isEmpty {
            for id in appeared {
                if let session = results.first(where: { $0.id == id }) {
                    onNewSession?(session)
                }
            }
        }
        knownSessionIds = newIds

        updateSessions(results)
    }

    /// Read the latest conversation content from a session JSONL
    func readSessionContent(session: SessionInfo, maxMessages: Int = 30) -> [SessionMessage] {
        guard let fh = FileHandle(forReadingAtPath: session.filePath) else { return [] }
        defer { fh.closeFile() }

        // Read the whole file (or last portion for large files)
        let fileSize = fh.seekToEndOfFile()
        let readFrom: UInt64 = fileSize > 200_000 ? fileSize - 200_000 : 0
        fh.seek(toFileOffset: readFrom)
        let data = fh.readDataToEndOfFile()

        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var messages: [SessionMessage] = []

        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let jsonData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }

            let type = obj["type"] as? String ?? ""

            if type == "user" {
                if let content = extractContent(from: obj) {
                    messages.append(SessionMessage(role: .user, text: content))
                }
            } else if type == "assistant" {
                if let content = extractAssistantContent(from: obj) {
                    messages.append(SessionMessage(role: .assistant, text: content))
                }
            }
        }

        // Return last N messages
        if messages.count > maxMessages {
            return Array(messages.suffix(maxMessages))
        }
        return messages
    }

    private func extractContent(from obj: [String: Any]) -> String? {
        guard let message = obj["message"] as? [String: Any] else { return nil }

        var text: String? = nil
        if let content = message["content"] as? String {
            text = content
        } else if let contentArray = message["content"] as? [[String: Any]] {
            var parts: [String] = []
            for block in contentArray {
                if block["type"] as? String == "text",
                   let t = block["text"] as? String {
                    parts.append(t)
                }
            }
            if !parts.isEmpty { text = parts.joined(separator: "\n") }
        }

        guard var raw = text else { return nil }

        // Skip system/command messages
        if raw.hasPrefix("<local-command") || raw.hasPrefix("<command-name") ||
           raw.hasPrefix("<system-reminder") || raw.hasPrefix("<tool_result") ||
           raw.contains("tool_use_id") {
            return nil
        }

        // Clean XML tags
        raw = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return raw.isEmpty ? nil : raw
    }

    private func extractAssistantContent(from obj: [String: Any]) -> String? {
        guard let message = obj["message"] as? [String: Any],
              let contentArray = message["content"] as? [[String: Any]] else { return nil }

        var parts: [String] = []
        for block in contentArray {
            if block["type"] as? String == "text",
               let t = block["text"] as? String {
                parts.append(t)
            } else if block["type"] as? String == "tool_use",
                      let name = block["name"] as? String {
                parts.append("🔧 \(name)")
            }
        }

        let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private func updateSessions(_ results: [SessionInfo]) {
        if Thread.isMainThread {
            self.sessions = results
        } else {
            DispatchQueue.main.async {
                self.sessions = results
            }
        }
    }

    private func extractFirstUserMessage(filePath: String) -> String {
        guard let fh = FileHandle(forReadingAtPath: filePath) else { return "（无法读取）" }
        defer { fh.closeFile() }

        let data = fh.readData(ofLength: 16384)
        guard let text = String(data: data, encoding: .utf8) else { return "（编码错误）" }

        for line in text.components(separatedBy: "\n") {
            guard !line.isEmpty,
                  let jsonData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                  obj["type"] as? String == "user",
                  let message = obj["message"] as? [String: Any] else { continue }

            var textContent: String? = nil
            if let content = message["content"] as? String {
                textContent = content
            } else if let contentArray = message["content"] as? [[String: Any]] {
                for block in contentArray {
                    if block["type"] as? String == "text",
                       let text = block["text"] as? String {
                        textContent = text
                        break
                    }
                }
            }

            guard let raw = textContent else { continue }

            if raw.hasPrefix("<local-command") || raw.hasPrefix("<command-name") ||
               raw.hasPrefix("<system-reminder") || raw.hasPrefix("<tool_result") ||
               raw.contains("tool_use_id") {
                continue
            }

            let cleaned = raw.replacingOccurrences(
                of: "<[^>]+>", with: "", options: .regularExpression
            ).trimmingCharacters(in: .whitespacesAndNewlines)

            if cleaned.isEmpty { continue }

            let maxLen = 80
            return cleaned.count > maxLen ? String(cleaned.prefix(maxLen)) + "..." : cleaned
        }
        return "（新会话）"
    }

    /// Get active claude processes with CWD and start time for matching
    private func getActiveClaudeProcesses() -> [ClaudeProcess] {
        // Step 1: get PIDs, TTYs, elapsed time from ps
        let psTask = Process()
        let psPipe = Pipe()
        psTask.executableURL = URL(fileURLWithPath: "/bin/ps")
        // Use etime (elapsed time) for start time calculation
        psTask.arguments = ["-eo", "pid,tty,%cpu,etime,command"]
        psTask.standardOutput = psPipe
        psTask.standardError = FileHandle.nullDevice

        do { try psTask.run() } catch { return [] }
        let psData = psPipe.fileHandleForReading.readDataToEndOfFile()
        psTask.waitUntilExit()

        guard let psOutput = String(data: psData, encoding: .utf8) else { return [] }

        let now = Date().timeIntervalSince1970
        var candidates: [(pid: Int32, tty: String, cpu: Double, startEpoch: TimeInterval)] = []

        for line in psOutput.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard (trimmed.hasSuffix("/claude") || trimmed.hasSuffix("claude") || trimmed.contains("claude "))
                    && !trimmed.contains("grep")
                    && !trimmed.contains("--output-format")
                    && !trimmed.contains("ClaudeSessionMonitor")
                    && !trimmed.contains("CSMonitor")
                    && !trimmed.contains("claude-internal") else { continue }

            let parts = trimmed.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard parts.count >= 5, let pid = Int32(parts[0]) else { continue }

            let tty = String(parts[1])
            let cpu = Double(parts[2]) ?? 0.0
            let elapsedStr = String(parts[3])
            guard tty != "??" && tty != "-" else { continue }

            let elapsedSecs = parseEtime(elapsedStr)
            let startEpoch = now - elapsedSecs
            candidates.append((pid, tty, cpu, startEpoch))
        }

        // Step 2: get CWD for each candidate using lsof
        var procs: [ClaudeProcess] = []
        for c in candidates {
            let lsofTask = Process()
            let lsofPipe = Pipe()
            lsofTask.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            lsofTask.arguments = ["-a", "-p", "\(c.pid)", "-d", "cwd", "-Fn"]
            lsofTask.standardOutput = lsofPipe
            lsofTask.standardError = FileHandle.nullDevice

            do { try lsofTask.run() } catch { continue }
            let lsofData = lsofPipe.fileHandleForReading.readDataToEndOfFile()
            lsofTask.waitUntilExit()

            let lsofOutput = String(data: lsofData, encoding: .utf8) ?? ""
            var cwd = ""
            for line in lsofOutput.components(separatedBy: "\n") {
                if line.hasPrefix("n") {
                    cwd = String(line.dropFirst())
                    break
                }
            }

            let projectKey = cwdToProjectKey(cwd)

            procs.append(ClaudeProcess(
                pid: c.pid,
                tty: c.tty,
                cpuPercent: c.cpu,
                cwd: cwd,
                projectKey: projectKey,
                startEpoch: c.startEpoch
            ))
        }

        return procs
    }

    /// Parse ps etime format: "DD-HH:MM:SS", "HH:MM:SS", or "MM:SS"
    private func parseEtime(_ etime: String) -> TimeInterval {
        var days = 0.0
        var rest = etime

        if rest.contains("-") {
            let parts = rest.split(separator: "-", maxSplits: 1)
            days = Double(parts[0]) ?? 0
            rest = String(parts[1])
        }

        let timeParts = rest.split(separator: ":").compactMap { Double($0) }
        var secs = days * 86400
        switch timeParts.count {
        case 3: secs += timeParts[0] * 3600 + timeParts[1] * 60 + timeParts[2]
        case 2: secs += timeParts[0] * 60 + timeParts[1]
        case 1: secs += timeParts[0]
        default: break
        }
        return secs
    }

    /// Convert a CWD like "/Users/diwen/foo/bar" to project key like "-Users-diwen-foo-bar"
    private func cwdToProjectKey(_ cwd: String) -> String {
        // Project dirs use format: "-" + path with "/" replaced by "-" and spaces by "-"
        // e.g. /Users/diwen → -Users-diwen
        //      /Users/diwen/Desktop/ai → -Users-diwen-Desktop-ai
        var key = cwd.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        // Ensure leading hyphen (the dirs all start with -)
        if !key.hasPrefix("-") {
            key = "-" + key
        }
        return key
    }
}

struct SessionMessage: Identifiable {
    let id = UUID()
    let role: Role
    let text: String

    enum Role {
        case user
        case assistant
    }
}
