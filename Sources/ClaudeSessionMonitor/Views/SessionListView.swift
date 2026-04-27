import SwiftUI

struct SessionListView: View {
    @ObservedObject var scanner: SessionScanner
    var onTogglePin: ((Bool) -> Void)?
    @State private var searchText = ""
    @State private var showOnlyActive = false
    @State private var selectedSession: SessionInfo? = nil
    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    @State private var isPinned = false

    private var filteredSessions: [SessionInfo] {
        var list = scanner.sessions
        if showOnlyActive {
            list = list.filter { $0.isActive }
        }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            list = list.filter {
                $0.summary.lowercased().contains(q) ||
                $0.projectShort.lowercased().contains(q)
            }
        }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            if let session = selectedSession {
                // Detail view
                SessionDetailView(session: session, scanner: scanner, isPinned: $isPinned, onTogglePin: onTogglePin) {
                    selectedSession = nil
                }
            } else {
                // List view
                sessionListContent
            }
        }
        .frame(width: 420)
    }

    private var sessionListContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "terminal.fill")
                    .foregroundColor(.accentColor)
                Text("Claude Sessions")
                    .font(.headline)
                Spacer()
                let active = scanner.sessions.filter(\.isActive).count
                let total = scanner.sessions.count
                Text("\(active) 活跃 / \(total) 总计")
                    .font(.caption)
                    .foregroundColor(.secondary)

                // Pin button
                Button {
                    isPinned.toggle()
                    onTogglePin?(isPinned)
                } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.caption)
                        .foregroundColor(isPinned ? .accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help(isPinned ? "取消固定" : "固定浮窗")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Search
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.caption)
                TextField("搜索会话...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(.body))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
                Toggle("仅活跃", isOn: $showOnlyActive)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)

            Divider()

            if filteredSessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text(searchText.isEmpty ? "没有找到会话" : "没有匹配的会话")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredSessions) { session in
                            SessionRow(session: session)
                                .onTapGesture {
                                    selectedSession = session
                                }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 420)
            }

            Divider()

            // Footer
            HStack(spacing: 12) {
                Button {
                    DispatchQueue.global(qos: .userInitiated).async {
                        scanner.scan()
                    }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderless)

                Toggle(isOn: $launchAtLoginEnabled) {
                    Label("开机启动", systemImage: "power")
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .onChange(of: launchAtLoginEnabled) { _, newVal in
                    if newVal {
                        let binPath = Bundle.main.executablePath ?? ""
                        LaunchAtLogin.enable(executablePath: binPath)
                    } else {
                        LaunchAtLogin.disable()
                    }
                }

                Spacer()

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("退出", systemImage: "xmark.circle")
                        .foregroundColor(.red)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }
}

// MARK: - Session Row

struct SessionRow: View {
    let session: SessionInfo
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            // Status indicator
            Circle()
                .fill(session.isActive ? Color.green : Color.gray.opacity(0.3))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(session.projectShort)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    Spacer()

                    if session.isActive, let tty = session.tty {
                        Text(tty)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.blue)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(3)
                    }

                    Text(session.timeAgo)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Text(session.summary)
                    .font(.system(.body))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            // Arrow indicator
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.02))
        )
        .padding(.horizontal, 4)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

// MARK: - Session Detail View

struct SessionDetailView: View {
    let session: SessionInfo
    let scanner: SessionScanner
    @Binding var isPinned: Bool
    var onTogglePin: ((Bool) -> Void)?
    let onBack: () -> Void

    @State private var messages: [SessionMessage] = []
    @State private var isLoading = true
    @State private var autoRefresh = true
    @State private var refreshTimer: Timer? = nil
    @State private var inputText = ""
    @State private var isSending = false
    @State private var readOffset: UInt64 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header bar
            HStack(spacing: 8) {
                Button {
                    refreshTimer?.invalidate()
                    onBack()
                } label: {
                    Image(systemName: "chevron.left")
                    Text("返回")
                }
                .buttonStyle(.borderless)

                Spacer()

                // Jump to iTerm2
                if session.isActive, session.tty != nil {
                    Button {
                        if let tty = session.devTty {
                            ITerm2Bridge.activateSession(tty: tty)
                        }
                    } label: {
                        Label("跳转 iTerm2", systemImage: "rectangle.topthird.inset.filled")
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.accentColor)
                }

                // Auto refresh toggle
                Toggle("自动刷新", isOn: $autoRefresh)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .onChange(of: autoRefresh) { _, newVal in
                        if newVal {
                            startRefreshTimer()
                        } else {
                            refreshTimer?.invalidate()
                        }
                    }

                // Pin button
                Button {
                    isPinned.toggle()
                    onTogglePin?(isPinned)
                } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.caption)
                        .foregroundColor(isPinned ? .accentColor : .secondary)
                }
                .buttonStyle(.borderless)
                .help(isPinned ? "取消固定" : "固定浮窗")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            // Session info
            HStack(spacing: 6) {
                Circle()
                    .fill(session.isActive ? Color.green : Color.gray.opacity(0.3))
                    .frame(width: 8, height: 8)
                Text(session.projectShort)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Text(formatSize(session.fileSize))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(session.timeAgo)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 4)

            Divider()

            // Messages
            if isLoading {
                VStack {
                    ProgressView()
                    Text("加载中...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else if messages.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.title2)
                        .foregroundColor(.secondary)
                    Text("没有对话内容")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(messages) { msg in
                                MessageBubble(message: msg, sessionTty: session.devTty)
                                    .id(msg.id)
                            }
                        }
                        .padding(8)
                    }
                    .frame(maxHeight: 450)
                    .onChange(of: messages.count) { _, _ in
                        if let last = messages.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                    .onAppear {
                        if let last = messages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            // Chat input bar
            if session.tty != nil {
                Divider()
                HStack(spacing: 8) {
                    TextField("发送消息到此 session...", text: $inputText)
                        .textFieldStyle(.plain)
                        .font(.system(.body))
                        .onSubmit {
                            sendMessage()
                        }
                        .disabled(isSending)

                    Button {
                        sendMessage()
                    } label: {
                        Image(systemName: isSending ? "hourglass" : "paperplane.fill")
                            .foregroundColor(inputText.isEmpty ? .secondary : .accentColor)
                    }
                    .buttonStyle(.borderless)
                    .disabled(inputText.isEmpty || isSending)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            } else {
                // No TTY - no running process found for this session
                Divider()
                HStack {
                    Image(systemName: "info.circle")
                        .foregroundColor(.secondary)
                    Text("未找到对应的终端进程，无法发送消息")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .onAppear {
            loadMessages()
            if autoRefresh {
                startRefreshTimer()
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
        }
    }

    private func loadMessages() {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = scanner.readSessionContent(session: session, lastOffset: 0)
            DispatchQueue.main.async {
                messages = result.messages
                readOffset = result.newOffset
                isLoading = false
            }
        }
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
            DispatchQueue.global(qos: .utility).async {
                let result = scanner.readSessionContent(session: session, lastOffset: readOffset)
                if !result.messages.isEmpty {
                    DispatchQueue.main.async {
                        messages.append(contentsOf: result.messages)
                        readOffset = result.newOffset
                    }
                }
            }
        }
    }

    private func sendMessage() {
        guard !inputText.isEmpty, let tty = session.devTty else { return }
        let text = inputText
        inputText = ""
        isSending = true

        ITerm2Bridge.sendText(tty: tty, text: text)

        // Brief delay then refresh to see the response coming in
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            isSending = false
        }
    }

    private func formatSize(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024) KB" }
        return String(format: "%.1f MB", Double(bytes) / 1048576.0)
    }
}

// MARK: - Message Bubble

struct MessageBubble: View {
    let message: SessionMessage
    let sessionTty: String?
    @State private var actionTaken: String? = nil  // "allowed" or "rejected"

    var body: some View {
        switch message.role {
        case .user:
            userBubble
        case .assistant:
            assistantBubble
        case .toolCall:
            toolCallBubble
        case .toolResult:
            EmptyView()
        }
    }

    private var userBubble: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 2) {
                Text("👤 You")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(truncated(500))
                    .font(.system(.caption))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.accentColor.opacity(0.15))
                    )
                    .textSelection(.enabled)
            }
        }
    }

    private var assistantBubble: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("🤖 Claude")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(truncated(500))
                    .font(.system(.caption))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.secondary.opacity(0.1))
                    )
                    .textSelection(.enabled)
            }
            Spacer(minLength: 40)
        }
    }

    private var toolCallBubble: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Tool header
            HStack(spacing: 4) {
                Image(systemName: toolIcon)
                    .font(.caption2)
                    .foregroundColor(.orange)
                Text(message.toolCall?.name ?? "Tool")
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .foregroundColor(.orange)
                if let desc = message.toolCall?.description {
                    Text("— \(desc)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }

            // Command/content
            Text(truncated(400))
                .font(.system(.caption, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.textBackgroundColor).opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                )
                .textSelection(.enabled)

            // Confirm / Reject buttons (only for active sessions)
            if sessionTty != nil, message.toolCall?.name == "Bash" ||
               message.toolCall?.name == "Write" || message.toolCall?.name == "Edit" {
                if let action = actionTaken {
                    // Already acted — show status
                    HStack(spacing: 4) {
                        Image(systemName: action == "allowed" ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.caption)
                        Text(action == "allowed" ? "已允许" : "已拒绝")
                            .font(.caption)
                    }
                    .foregroundColor(.secondary)
                    .padding(.leading, 4)
                } else {
                    // Awaiting action
                    HStack(spacing: 12) {
                        Button {
                            if let tty = sessionTty {
                                ITerm2Bridge.sendText(tty: tty, text: "y")
                                actionTaken = "allowed"
                            }
                        } label: {
                            Label("允许", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.green)
                        }
                        .buttonStyle(.borderless)

                        Button {
                            if let tty = sessionTty {
                                ITerm2Bridge.sendText(tty: tty, text: "n")
                                actionTaken = "rejected"
                            }
                        } label: {
                            Label("拒绝", systemImage: "xmark.circle.fill")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.borderless)

                        Spacer()
                    }
                    .padding(.leading, 4)
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    private var toolIcon: String {
        switch message.toolCall?.name {
        case "Bash": return "terminal"
        case "Write": return "doc.badge.plus"
        case "Edit": return "pencil"
        case "Read": return "doc.text"
        case "Grep": return "magnifyingglass"
        case "Glob": return "folder.badge.magnifyingglass"
        case "Agent": return "person.2"
        default: return "wrench"
        }
    }

    private func truncated(_ maxLen: Int) -> String {
        if message.text.count > maxLen {
            return String(message.text.prefix(maxLen)) + "..."
        }
        return message.text
    }
}
