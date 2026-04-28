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

    // Background event monitoring
    private var monitorOffsets: [String: UInt64] = [:]  // sessionId → file offset
    private var lastAssistantTime: [String: Date] = [:]  // sessionId → last assistant message time
    private var pendingToolCalls: Set<String> = []       // sessionId that has pending tool call

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
            var usedProcPids: Set<Int32> = []

            // Collect all sessions for this project
            var projSessionIndices: [(idx: Int, birthTime: TimeInterval, mtime: Date)] = []

            for file in files where file.hasSuffix(".jsonl") {
                let filePath = projPath + "/" + file
                let sessionId = String(file.dropLast(6))

                guard let attrs = try? fm.attributesOfItem(atPath: filePath),
                      let mtime = attrs[.modificationDate] as? Date,
                      let size = attrs[.size] as? Int64 else { continue }

                if size < 500 { continue }

                let birthTime: TimeInterval
                if let creationDate = attrs[.creationDate] as? Date {
                    birthTime = creationDate.timeIntervalSince1970
                } else {
                    birthTime = 0
                }

                let summary = extractFirstUserMessage(filePath: filePath)

                let info = SessionInfo(
                    id: sessionId,
                    project: proj,
                    summary: summary,
                    lastActive: mtime,
                    fileSize: size,
                    filePath: filePath
                )

                let idx = results.count
                results.append(info)
                projSessionIndices.append((idx: idx, birthTime: birthTime, mtime: mtime))
            }

            // Pass 1: Match by birth time ≈ process start time (within 60s)
            for s in projSessionIndices {
                guard s.birthTime > 0 else { continue }
                var bestProc: ClaudeProcess? = nil
                var bestDiff = Double.infinity
                for proc in matchingProcs where !usedProcPids.contains(proc.pid) {
                    let diff = abs(s.birthTime - proc.startEpoch)
                    if diff < bestDiff {
                        bestDiff = diff
                        bestProc = proc
                    }
                }
                if bestDiff < 60, let proc = bestProc {
                    results[s.idx].isActive = true
                    results[s.idx].pid = proc.pid
                    results[s.idx].tty = proc.tty
                    usedProcPids.insert(proc.pid)
                }
            }

            // Pass 2: Fallback — match unmatched sessions (recently modified) to unmatched processes
            // Sort unmatched sessions by mtime desc, unmatched procs by start time desc
            let unmatchedSessions = projSessionIndices
                .filter { !results[$0.idx].isActive }
                .sorted { $0.mtime > $1.mtime }

            let unmatchedProcs = matchingProcs
                .filter { !usedProcPids.contains($0.pid) }
                .sorted { $0.startEpoch > $1.startEpoch }

            for (i, s) in unmatchedSessions.enumerated() {
                // Only match sessions modified in the last 5 minutes (likely active)
                guard s.mtime.timeIntervalSinceNow > -300 else { continue }
                if i < unmatchedProcs.count {
                    results[s.idx].isActive = true
                    results[s.idx].pid = unmatchedProcs[i].pid
                    results[s.idx].tty = unmatchedProcs[i].tty
                }
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

    /// Monitor active sessions for events and send notifications
    func monitorEvents() {
        let activeSessions = sessions.filter { $0.isActive }

        for session in activeSessions {
            let offset = monitorOffsets[session.id] ?? {
                // First time: start from current end of file to avoid old notifications
                let fm = FileManager.default
                if let attrs = try? fm.attributesOfItem(atPath: session.filePath),
                   let size = attrs[.size] as? UInt64 {
                    monitorOffsets[session.id] = size
                    return size
                }
                return UInt64(0)
            }()

            guard let fh = FileHandle(forReadingAtPath: session.filePath) else { continue }
            defer { fh.closeFile() }

            let fileSize = fh.seekToEndOfFile()
            if offset >= fileSize {
                // No new data — check for task completion
                // If we had a recent assistant message and no new activity for 15+ seconds
                if let lastTime = lastAssistantTime[session.id],
                   Date().timeIntervalSince(lastTime) > 15,
                   !pendingToolCalls.contains(session.id) {
                    NotificationManager.shared.notifyTaskComplete(
                        session: session,
                        summary: String(session.summary.prefix(60))
                    )
                    lastAssistantTime.removeValue(forKey: session.id)
                }
                continue
            }

            // Read new data
            fh.seek(toFileOffset: offset)
            let data = fh.readDataToEndOfFile()
            monitorOffsets[session.id] = fileSize

            guard let text = String(data: data, encoding: .utf8) else { continue }

            for line in text.components(separatedBy: "\n") {
                guard !line.isEmpty,
                      let jsonData = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else { continue }

                let type = obj["type"] as? String ?? ""

                if type == "assistant" {
                    lastAssistantTime[session.id] = Date()
                    pendingToolCalls.remove(session.id)

                    // Check for tool calls that need confirmation
                    if let message = obj["message"] as? [String: Any],
                       let content = message["content"] as? [[String: Any]] {
                        for block in content {
                            if block["type"] as? String == "tool_use",
                               let name = block["name"] as? String,
                               let input = block["input"] as? [String: Any] {

                                if name == "Bash" || name == "Write" || name == "Edit" {
                                    pendingToolCalls.insert(session.id)
                                    let detail: String
                                    if name == "Bash" {
                                        let cmd = (input["command"] as? String) ?? ""
                                        detail = "$ \(String(cmd.prefix(80)))"
                                    } else {
                                        let path = (input["file_path"] as? String) ?? ""
                                        detail = "\(name) → \(path)"
                                    }
                                    NotificationManager.shared.notifyToolWaiting(
                                        session: session,
                                        toolName: name,
                                        detail: detail
                                    )
                                }
                            }
                        }
                    }

                    // Check for error keywords in assistant text
                    if let message = obj["message"] as? [String: Any],
                       let content = message["content"] as? [[String: Any]] {
                        for block in content {
                            if block["type"] as? String == "text",
                               let text = block["text"] as? String {
                                let lower = text.lowercased()
                                if lower.contains("error:") || lower.contains("failed") ||
                                   lower.contains("exception") || lower.contains("panic") ||
                                   lower.contains("fatal") {
                                    let snippet = String(text.prefix(100))
                                    NotificationManager.shared.notifyError(
                                        session: session,
                                        error: snippet
                                    )
                                }
                            }
                        }
                    }
                }

                // User message means the tool call was answered
                if type == "user" {
                    pendingToolCalls.remove(session.id)
                    lastAssistantTime.removeValue(forKey: session.id)
                }
            }
        }

        // Clean up stale entries for sessions no longer active
        let activeIds = Set(activeSessions.map(\.id))
        monitorOffsets = monitorOffsets.filter { activeIds.contains($0.key) }
        lastAssistantTime = lastAssistantTime.filter { activeIds.contains($0.key) }
        pendingToolCalls = pendingToolCalls.filter { activeIds.contains($0) }
    }

    /// Read the full conversation content from a session JSONL
    /// Uses incremental reading: pass lastOffset to only read new data
    func readSessionContent(session: SessionInfo, lastOffset: UInt64 = 0) -> (messages: [SessionMessage], newOffset: UInt64) {
        guard let fh = FileHandle(forReadingAtPath: session.filePath) else { return ([], 0) }
        defer { fh.closeFile() }

        let fileSize = fh.seekToEndOfFile()

        // If no new data, return empty
        if lastOffset >= fileSize {
            return ([], lastOffset)
        }

        // Seek to where we left off
        fh.seek(toFileOffset: lastOffset)
        let data = fh.readDataToEndOfFile()

        guard let text = String(data: data, encoding: .utf8) else { return ([], lastOffset) }

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
                let extracted = extractAssistantMessages(from: obj)
                messages.append(contentsOf: extracted)
            }
        }

        return (messages, fileSize)
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

    private func extractAssistantMessages(from obj: [String: Any]) -> [SessionMessage] {
        guard let message = obj["message"] as? [String: Any],
              let contentArray = message["content"] as? [[String: Any]] else { return [] }

        var results: [SessionMessage] = []
        var textParts: [String] = []

        for block in contentArray {
            let blockType = block["type"] as? String ?? ""

            if blockType == "text", let t = block["text"] as? String {
                let cleaned = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    textParts.append(cleaned)
                }
            } else if blockType == "tool_use", let name = block["name"] as? String {
                // Flush any accumulated text first
                if !textParts.isEmpty {
                    results.append(SessionMessage(role: .assistant, text: textParts.joined(separator: "\n")))
                    textParts.removeAll()
                }

                let input = block["input"] as? [String: Any] ?? [:]
                let toolCall = parseToolCall(name: name, input: input)

                let displayText = formatToolCall(name: name, toolCall: toolCall)
                results.append(SessionMessage(role: .toolCall, text: displayText, toolCall: toolCall))
            }
        }

        // Flush remaining text
        if !textParts.isEmpty {
            results.append(SessionMessage(role: .assistant, text: textParts.joined(separator: "\n")))
        }

        return results
    }

    private func parseToolCall(name: String, input: [String: Any]) -> ToolCallInfo {
        switch name {
        case "Bash":
            return ToolCallInfo(
                name: name,
                command: input["command"] as? String,
                description: input["description"] as? String,
                filePath: nil,
                detail: nil
            )
        case "Write":
            let content = input["content"] as? String
            let preview = content.map { String($0.prefix(200)) }
            return ToolCallInfo(
                name: name,
                command: nil,
                description: nil,
                filePath: input["file_path"] as? String,
                detail: preview
            )
        case "Edit":
            let oldStr = input["old_string"] as? String
            let newStr = input["new_string"] as? String
            var detail = ""
            if let o = oldStr { detail += "- \(String(o.prefix(100)))\n" }
            if let n = newStr { detail += "+ \(String(n.prefix(100)))" }
            return ToolCallInfo(
                name: name,
                command: nil,
                description: nil,
                filePath: input["file_path"] as? String,
                detail: detail.isEmpty ? nil : detail
            )
        case "Read":
            return ToolCallInfo(
                name: name,
                command: nil,
                description: nil,
                filePath: input["file_path"] as? String,
                detail: nil
            )
        case "Grep":
            return ToolCallInfo(
                name: name,
                command: nil,
                description: "pattern: \(input["pattern"] as? String ?? "")",
                filePath: input["path"] as? String,
                detail: nil
            )
        case "Glob":
            return ToolCallInfo(
                name: name,
                command: nil,
                description: "pattern: \(input["pattern"] as? String ?? "")",
                filePath: input["path"] as? String,
                detail: nil
            )
        default:
            // Agent, AskUserQuestion, TaskCreate, etc.
            let desc = input["description"] as? String ?? input["subject"] as? String
            let prompt = input["prompt"] as? String
            return ToolCallInfo(
                name: name,
                command: nil,
                description: desc,
                filePath: nil,
                detail: prompt.map { String($0.prefix(150)) }
            )
        }
    }

    private func formatToolCall(name: String, toolCall: ToolCallInfo) -> String {
        var parts: [String] = []

        switch name {
        case "Bash":
            parts.append("$ \(toolCall.command ?? "(empty)")")
            if let desc = toolCall.description {
                parts.insert("// \(desc)", at: 0)
            }
        case "Write":
            parts.append("Write → \(toolCall.filePath ?? "?")")
            if let d = toolCall.detail { parts.append(d + "...") }
        case "Edit":
            parts.append("Edit → \(toolCall.filePath ?? "?")")
            if let d = toolCall.detail { parts.append(d) }
        case "Read":
            parts.append("Read → \(toolCall.filePath ?? "?")")
        case "Grep":
            parts.append("Grep \(toolCall.description ?? "")")
            if let p = toolCall.filePath { parts.append("in \(p)") }
        case "Glob":
            parts.append("Glob \(toolCall.description ?? "")")
        default:
            parts.append(name)
            if let desc = toolCall.description { parts.append(desc) }
            if let d = toolCall.detail { parts.append(d) }
        }

        return parts.joined(separator: "\n")
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
    let toolCall: ToolCallInfo?

    init(role: Role, text: String, toolCall: ToolCallInfo? = nil) {
        self.role = role
        self.text = text
        self.toolCall = toolCall
    }

    enum Role {
        case user
        case assistant
        case toolCall    // a tool invocation by assistant
        case toolResult  // result returned to assistant
    }
}

struct ToolCallInfo {
    let name: String        // e.g. "Bash", "Write", "Edit", "Read"
    let command: String?    // for Bash: the command string
    let description: String? // human-readable description
    let filePath: String?   // for Write/Edit/Read: the file path
    let detail: String?     // additional info (edit content, etc.)
}
