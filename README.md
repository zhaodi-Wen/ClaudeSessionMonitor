# Claude Session Monitor

A lightweight macOS menu bar app to monitor, browse and interact with all your [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions — right from the menu bar.

If you use Claude Code in iTerm2 with multiple tabs/sessions open, you know the pain: **which tab is doing what?** This tool solves that.

## Features

| Feature | Description |
|---------|-------------|
| **Menu Bar Resident** | Compact `⌘` icon with active session count badge |
| **Session List** | Browse all sessions with project path, first message summary, last active time and file size |
| **Real-time Chat Preview** | Click any session to view the full conversation in a floating panel (auto-refreshes every 3s) |
| **In-panel Chat** | Send messages directly from the floating panel — no need to switch to iTerm2 |
| **iTerm2 Jump** | One-click to activate the exact iTerm2 tab running that session |
| **Search & Filter** | Search by keyword, filter to show only active sessions |
| **New Session Notification** | macOS notification when a new Claude Code session is created |
| **Launch at Login** | Toggle auto-start from the panel footer |

## Screenshots

```
┌──────────────────────────────────────────┐
│ ⌘  Claude Sessions          3 active / 8 │
│ 🔍 Search...              [Only Active] │
│──────────────────────────────────────────│
│ 🟢 ~/project-a          ttys046   just  │
│    Implement auth flow for login...   >  │
│──────────────────────────────────────────│
│ 🟢 ~                     ttys038   2m   │
│    Fix the CSS layout bug in...       >  │
│──────────────────────────────────────────│
│ ⚪ ~/obsidian-vault                  3d  │
│    Summarize my meeting notes...      >  │
│──────────────────────────────────────────│
│ [Refresh]  [Launch at Login]    [Quit]   │
└──────────────────────────────────────────┘
```

## How It Works

### Architecture

```
Claude Session Monitor (Swift + SwiftUI + AppKit)
        │
        ├── SessionScanner       ← scans JSONL files + matches processes
        │     ├── reads ~/.claude-internal/projects/<project>/<uuid>.jsonl
        │     ├── ps -eo pid,tty,%cpu,etime,command  → active claude processes
        │     ├── lsof -p <pid> -d cwd              → process working directory
        │     └── file birthtime ≈ process start time → precise session↔TTY matching
        │
        ├── ITerm2Bridge         ← AppleScript to activate/type into iTerm2 sessions
        ├── NotificationManager  ← macOS notifications via osascript
        └── LaunchAtLogin        ← ~/Library/LaunchAgents plist management
```

### Session Discovery

Claude Code stores conversation logs as JSONL (JSON Lines) files:

```
~/.claude-internal/projects/
  ├── -Users-you/                          # project directory (CWD-based)
  │   ├── a9292d41-...-4df4b2e4.jsonl      # session conversation log
  │   ├── 8a096379-...-05b6327.jsonl
  │   └── ...
  ├── -Users-you-my-project/
  │   └── ...
  └── ...
```

Each JSONL file contains the full conversation: user messages, assistant responses, tool calls, etc. The monitor reads these files to extract:
- **First user message** as the session summary
- **File modification time** as last active time
- **File size** as conversation length indicator

### Process Matching (Session → Terminal)

The key challenge is mapping a session file to the correct iTerm2 tab. The monitor uses a **birth-time matching** algorithm:

1. **Get all running `claude` processes** with their PID, TTY, CPU%, and elapsed time via `ps`
2. **Get each process's working directory** via `lsof -d cwd` — this maps to the project directory
3. **Compare file creation time with process start time** — when you run `claude`, it creates a new JSONL file within seconds of the process starting. A match within 60 seconds means this process owns this session.

```
Process: PID=99046, TTY=ttys046, started 2026-04-25 17:07:37
Session: a9292d41.jsonl,           created 2026-04-25 17:07:58
                                   → diff = 21s → MATCH ✓
```

### iTerm2 Integration

Uses AppleScript to interact with iTerm2:

- **Jump to session**: Iterates all iTerm2 windows/tabs/sessions, finds the one matching the TTY (e.g. `/dev/ttys046`), selects it and activates the window
- **Send message**: Uses `write text` to type into the matching iTerm2 session — this sends the text followed by Enter, so Claude Code receives it as input

## Installation

### Prerequisites

- **macOS 14.0+** (Sonoma or later)
- **Xcode Command Line Tools** (for Swift compiler)
- **iTerm2** (for terminal integration)
- **Claude Code** installed and running

### Option 1: Build from Source (Recommended)

```bash
# Clone
git clone https://github.com/zhaodi-Wen/ClaudeSessionMonitor.git
cd ClaudeSessionMonitor

# Build release binary
swift build -c release

# Create .app bundle
mkdir -p "Claude Session Monitor.app/Contents/MacOS"
cp .build/release/ClaudeSessionMonitor "Claude Session Monitor.app/Contents/MacOS/"

cat > "Claude Session Monitor.app/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ClaudeSessionMonitor</string>
    <key>CFBundleIdentifier</key>
    <string>com.claude.session-monitor</string>
    <key>CFBundleName</key>
    <string>Claude Session Monitor</string>
    <key>CFBundleVersion</key>
    <string>1.4.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
</dict>
</plist>
EOF

# Launch
open "Claude Session Monitor.app"
```

### Option 2: Download DMG

Download the latest DMG from [Releases](https://github.com/zhaodi-Wen/ClaudeSessionMonitor/releases), open it, and drag `Claude Session Monitor.app` to your Applications folder.

## Usage

### Basic

1. Launch the app — a `⌘` icon appears in the menu bar
2. Click `⌘` to see all Claude Code sessions
3. Green dot = active session (has a running terminal process)
4. Gray dot = historical session (no running process)

### View Conversation

1. Click any session row to enter the detail view
2. See the full conversation with chat bubbles (user on right, Claude on left)
3. Auto-refreshes every 3 seconds (toggle with the switch)
4. Click "Back" to return to the session list

### Send Messages

1. In the detail view of an **active** session, use the input field at the bottom
2. Type your message and press Enter (or click the send button)
3. The message is sent directly to the corresponding iTerm2 terminal
4. Watch the conversation update in real-time

### Jump to iTerm2

1. In the detail view, click **"Jump to iTerm2"** button
2. Or simply click an active session row — it navigates to the detail and you can jump from there
3. iTerm2 will activate and switch to the correct tab

### Launch at Login

Toggle the "Launch at Login" switch in the panel footer. This creates/removes a LaunchAgent plist at `~/Library/LaunchAgents/com.claude.session-monitor.plist`.

## Project Structure

```
ClaudeSessionMonitor/
├── Package.swift                                    # Swift Package Manager config
├── Sources/ClaudeSessionMonitor/
│   ├── main.swift                                   # Entry point, AppDelegate, NSStatusBar
│   ├── Models/
│   │   └── SessionInfo.swift                        # Session data model
│   ├── Services/
│   │   ├── SessionScanner.swift                     # Core: JSONL scanning + process matching
│   │   ├── ITerm2Bridge.swift                       # AppleScript iTerm2 integration
│   │   ├── NotificationManager.swift                # macOS notification via osascript
│   │   └── LaunchAtLogin.swift                      # LaunchAgent management
│   └── Views/
│       └── SessionListView.swift                    # SwiftUI: list, detail, chat UI
└── .gitignore
```

## Technical Notes

- **No Xcode required** — builds with Swift Package Manager (`swift build`)
- **No third-party dependencies** — pure Swift + SwiftUI + AppKit
- **LSUIElement=true** — the app doesn't appear in the Dock, only in the menu bar
- **Read-only access** to Claude Code data — only reads JSONL files, never writes to them
- **Chat via AppleScript** — messages are sent by "typing" into iTerm2, not by modifying Claude's internal state
- **Background scanning** — all file I/O and process queries run on background threads to keep the UI responsive
- Uses `NSPopover` instead of `MenuBarExtra` for reliable menu bar rendering across all launch contexts

## Troubleshooting

**Menu bar icon doesn't appear**
- Make sure to launch via `open "Claude Session Monitor.app"`, not by running the binary directly
- If still not visible, try: right-click the .app → Open

**Sessions show "No terminal process found"**
- The Claude Code process for this session is no longer running
- Start a new `claude` session in iTerm2, it will be detected within 10 seconds

**Wrong session matched to terminal**
- This can happen if multiple sessions were created within 60 seconds of each other
- The matching algorithm uses file creation time vs process start time

**"Jump to iTerm2" doesn't work**
- Ensure iTerm2 is running (not Terminal.app)
- The app needs Accessibility permissions — grant them in System Settings → Privacy & Security → Accessibility

## License

MIT

## Acknowledgments

Built with the help of [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — yes, the tool was built using itself.
