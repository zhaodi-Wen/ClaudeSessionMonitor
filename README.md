# Claude Session Monitor

[English](#english) | [中文](#中文)

---

<a name="english"></a>

## English

A lightweight macOS menu bar app to monitor, browse and interact with all your [Claude Code](https://docs.anthropic.com/en/docs/claude-code) sessions — right from the menu bar.

If you use Claude Code in iTerm2 with multiple tabs/sessions open, you know the pain: **which tab is doing what?** This tool solves that.

### Features

| Feature | Description |
|---------|-------------|
| **Menu Bar Resident** | Compact `⌘` icon with active session count badge |
| **Session List** | Browse all sessions with project path, first message summary, last active time and file size |
| **Real-time Chat Preview** | Click any session to view the full conversation in a floating panel (auto-refreshes every 3s) |
| **Full Chat History** | Incremental loading — all messages preserved as long as the panel stays open |
| **In-panel Chat** | Send messages directly from the floating panel — no need to switch to iTerm2 |
| **Tool Call Details** | Rich display of Bash commands, file edits, reads, greps — not just tool names |
| **Confirm / Reject** | Approve or reject Claude's tool calls (Bash, Write, Edit) directly from the panel |
| **Pin to Float** | 📌 Pin the panel into a standalone always-on-top window that persists across app switches |
| **iTerm2 Jump** | One-click to activate the exact iTerm2 tab running that session |
| **Search & Filter** | Search by keyword, filter to show only active sessions |
| **New Session Notification** | macOS notification when a new Claude Code session is created |
| **Launch at Login** | Toggle auto-start from the panel footer |

### Screenshots

**Session List**
```
┌──────────────────────────────────────────────┐
│ ⌘  Claude Sessions     3 active / 8 total 📌 │
│ 🔍 Search...                  [Only Active] │
│──────────────────────────────────────────────│
│ 🟢 ~/project-a          ttys046      just > │
│    Implement auth flow for login...          │
│──────────────────────────────────────────────│
│ 🟢 ~                     ttys038       2m > │
│    Fix the CSS layout bug in...              │
│──────────────────────────────────────────────│
│ ⚪ ~/obsidian-vault                    3d > │
│    Summarize my meeting notes...             │
│──────────────────────────────────────────────│
│ [Refresh]  [Launch at Login]        [Quit]   │
└──────────────────────────────────────────────┘
```

**Session Detail — Chat & Tool Calls**
```
┌──────────────────────────────────────────────┐
│ ← Back    [Jump iTerm2] [Auto-refresh] 📌   │
│ 🟢 ~/project-a            196KB    just now  │
│──────────────────────────────────────────────│
│                          ┌──────────────────┐│
│                          │ 👤 Implement the ││
│                          │ login auth flow  ││
│                          └──────────────────┘│
│ ┌──────────────────────┐                     │
│ │ 🤖 I'll start by... │                     │
│ └──────────────────────┘                     │
│ ┌────────────────────────────────────────┐   │
│ │ 🔧 Bash                               │   │
│ │ // Create auth middleware              │   │
│ │ $ mkdir -p src/auth && touch ...       │   │
│ │ [✅ Allow]  [❌ Reject]                │   │
│ └────────────────────────────────────────┘   │
│ ┌────────────────────────────────────────┐   │
│ │ 🔧 Write → src/auth/middleware.ts      │   │
│ │ import { NextRequest } from 'next/...  │   │
│ │ [✅ Allow]  [❌ Reject]                │   │
│ └────────────────────────────────────────┘   │
│──────────────────────────────────────────────│
│ [💬 Send a message to this session...   ➤ ] │
└──────────────────────────────────────────────┘
```

### How It Works

#### Architecture

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

#### Session Discovery

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

#### Process Matching (Session → Terminal)

The key challenge is mapping a session file to the correct iTerm2 tab. The monitor uses a **birth-time matching** algorithm:

1. **Get all running `claude` processes** with their PID, TTY, CPU%, and elapsed time via `ps`
2. **Get each process's working directory** via `lsof -d cwd` — this maps to the project directory
3. **Compare file creation time with process start time** — when you run `claude`, it creates a new JSONL file within seconds of the process starting. A match within 60 seconds means this process owns this session.

```
Process: PID=99046, TTY=ttys046, started 2026-04-25 17:07:37
Session: a9292d41.jsonl,           created 2026-04-25 17:07:58
                                   → diff = 21s → MATCH ✓
```

#### iTerm2 Integration

Uses AppleScript to interact with iTerm2:

- **Jump to session**: Iterates all iTerm2 windows/tabs/sessions, finds the one matching the TTY (e.g. `/dev/ttys046`), selects it and activates the window
- **Send message**: Uses `write text` to type into the matching iTerm2 session — this sends the text followed by Enter, so Claude Code receives it as input

### Installation

#### Prerequisites

- **macOS 14.0+** (Sonoma or later)
- **Xcode Command Line Tools** (for Swift compiler)
- **iTerm2** (for terminal integration)
- **Claude Code** installed and running

#### Option 1: Build from Source (Recommended)

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
    <string>1.6.0</string>
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

#### Option 2: Download DMG

Download the latest DMG from [Releases](https://github.com/zhaodi-Wen/ClaudeSessionMonitor/releases), open it, and drag `Claude Session Monitor.app` to your Applications folder.

### Usage

#### Basic

1. Launch the app — a `⌘` icon appears in the menu bar
2. Click `⌘` to see all Claude Code sessions
3. Green dot = active session (has a running terminal process)
4. Gray dot = historical session (no running process)

#### View Conversation

1. Click any session row to enter the detail view
2. See the full conversation with chat bubbles (user on right, Claude on left)
3. **Tool calls** are shown with full details: Bash commands, file paths, edit diffs, grep patterns
4. Auto-refreshes every 3 seconds (toggle with the switch)
5. All messages are preserved as long as the panel stays open (incremental loading)
6. Click "Back" to return to the session list

#### Confirm / Reject Tool Calls

When Claude proposes a Bash command, file write, or edit:
1. The tool call is displayed with full command/content in a highlighted block
2. Click **✅ Allow** to approve (sends `y` to the terminal)
3. Click **❌ Reject** to deny (sends `n` to the terminal)
4. No need to switch to iTerm2 just to press `y` or `n`

#### Send Messages

1. In the detail view of an **active** session, use the input field at the bottom
2. Type your message and press Enter (or click the send button)
3. The message is sent directly to the corresponding iTerm2 terminal
4. Watch the conversation update in real-time

#### Pin as Floating Window

1. Click the 📌 **pin button** in the header (available in both list and detail views)
2. The popover detaches into a **standalone floating window**
3. The window stays on top of all other apps — switch apps freely without losing it
4. Drag it anywhere, resize as needed — it persists across Spaces
5. Click 📌 again or close the window to go back to popover mode

#### Jump to iTerm2

1. In the detail view, click **"Jump to iTerm2"** button
2. Or simply click an active session row — it navigates to the detail and you can jump from there
3. iTerm2 will activate and switch to the correct tab

#### Launch at Login

Toggle the "Launch at Login" switch in the panel footer. This creates/removes a LaunchAgent plist at `~/Library/LaunchAgents/com.claude.session-monitor.plist`.

### Project Structure

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

### Technical Notes

- **No Xcode required** — builds with Swift Package Manager (`swift build`)
- **No third-party dependencies** — pure Swift + SwiftUI + AppKit
- **LSUIElement=true** — the app doesn't appear in the Dock, only in the menu bar
- **Read-only access** to Claude Code data — only reads JSONL files, never writes to them
- **Chat via AppleScript** — messages are sent by "typing" into iTerm2, not by modifying Claude's internal state
- **Background scanning** — all file I/O and process queries run on background threads to keep the UI responsive
- **Incremental JSONL reading** — tracks file offset, only reads new data on refresh
- **Pin mode** — uses `NSWindow` with `.floating` level instead of `NSPopover` for persistent display
- Uses `NSPopover` instead of `MenuBarExtra` for reliable menu bar rendering across all launch contexts

### Troubleshooting

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

---

<a name="中文"></a>

## 中文

一个轻量级 macOS 菜单栏应用，用于监控、浏览和交互你所有的 [Claude Code](https://docs.anthropic.com/en/docs/claude-code) 会话。

如果你在 iTerm2 中同时开了多个 Claude Code 会话，你一定有过这个痛点：**哪个 tab 在干什么？** 这个工具就是来解决这个问题的。

### 功能

| 功能 | 说明 |
|------|------|
| **菜单栏常驻** | 紧凑的 `⌘` 图标，显示活跃会话数量 |
| **会话列表** | 浏览所有会话：项目路径、首条消息摘要、最后活跃时间、文件大小 |
| **实时对话预览** | 点击任意会话，在浮窗中查看完整对话内容（每 3 秒自动刷新） |
| **完整聊天历史** | 增量加载 — 浮窗打开期间保留全部消息，不丢失 |
| **浮窗内聊天** | 直接在浮窗中发送消息，无需切换到 iTerm2 |
| **工具调用详情** | 丰富展示 Bash 命令、文件编辑、读取、搜索的完整内容，而非仅显示工具名 |
| **确认 / 拒绝** | 直接在浮窗中审批 Claude 的工具调用（Bash、Write、Edit） |
| **固定悬浮窗** | 📌 将面板固定为独立置顶窗口，切换应用不消失 |
| **跳转 iTerm2** | 一键激活对应的 iTerm2 标签页 |
| **搜索与过滤** | 关键词搜索，筛选仅显示活跃会话 |
| **新会话通知** | 新 Claude Code 会话创建时弹出 macOS 通知 |
| **开机自启** | 在面板底部一键开关 |

### 界面预览

**会话列表**
```
┌──────────────────────────────────────────────┐
│ ⌘  Claude Sessions    3 活跃 / 8 总计    📌 │
│ 🔍 搜索会话...                  [仅活跃] │
│──────────────────────────────────────────────│
│ 🟢 ~/project-a          ttys046    刚刚  > │
│    帮我实现登录页面的认证流程...              │
│──────────────────────────────────────────────│
│ 🟢 ~                     ttys038  2分钟  > │
│    修复 CSS 布局的 bug...                    │
│──────────────────────────────────────────────│
│ ⚪ ~/obsidian-vault                  3天  > │
│    帮我总结一下会议纪要...                    │
│──────────────────────────────────────────────│
│ [刷新]    [开机启动]                 [退出]  │
└──────────────────────────────────────────────┘
```

**会话详情 — 对话与工具调用**
```
┌──────────────────────────────────────────────┐
│ ← 返回  [跳转 iTerm2] [自动刷新]        📌 │
│ 🟢 ~/project-a            196KB       刚刚  │
│──────────────────────────────────────────────│
│                          ┌──────────────────┐│
│                          │ 👤 帮我实现登录  ││
│                          │ 页面的认证流程   ││
│                          └──────────────────┘│
│ ┌──────────────────────┐                     │
│ │ 🤖 好的，我先...     │                     │
│ └──────────────────────┘                     │
│ ┌────────────────────────────────────────┐   │
│ │ 🔧 Bash                               │   │
│ │ // 创建认证中间件目录                   │   │
│ │ $ mkdir -p src/auth && touch ...       │   │
│ │ [✅ 允许]  [❌ 拒绝]                   │   │
│ └────────────────────────────────────────┘   │
│ ┌────────────────────────────────────────┐   │
│ │ 🔧 Write → src/auth/middleware.ts      │   │
│ │ import { NextRequest } from 'next/...  │   │
│ │ [✅ 允许]  [❌ 拒绝]                   │   │
│ └────────────────────────────────────────┘   │
│──────────────────────────────────────────────│
│ [💬 发送消息到此 session...             ➤ ] │
└──────────────────────────────────────────────┘
```

### 工作原理

#### 架构

```
Claude Session Monitor (Swift + SwiftUI + AppKit)
        │
        ├── SessionScanner       ← 扫描 JSONL 文件 + 匹配进程
        │     ├── 读取 ~/.claude-internal/projects/<项目>/<uuid>.jsonl
        │     ├── ps -eo pid,tty,%cpu,etime,command  → 获取活跃 claude 进程
        │     ├── lsof -p <pid> -d cwd              → 获取进程工作目录
        │     └── 文件创建时间 ≈ 进程启动时间 → 精确匹配 session↔TTY
        │
        ├── ITerm2Bridge         ← AppleScript 激活/输入 iTerm2 会话
        ├── NotificationManager  ← 通过 osascript 发送 macOS 通知
        └── LaunchAtLogin        ← ~/Library/LaunchAgents plist 管理
```

#### 会话发现

Claude Code 将对话日志存储为 JSONL（JSON Lines）文件：

```
~/.claude-internal/projects/
  ├── -Users-你的用户名/                     # 项目目录（基于工作目录）
  │   ├── a9292d41-...-4df4b2e4.jsonl       # 会话对话日志
  │   ├── 8a096379-...-05b6327.jsonl
  │   └── ...
  ├── -Users-你的用户名-my-project/
  │   └── ...
  └── ...
```

每个 JSONL 文件包含完整的对话记录：用户消息、助手回复、工具调用等。监控器读取这些文件，提取：
- **首条用户消息** 作为会话摘要
- **文件修改时间** 作为最后活跃时间
- **文件大小** 作为对话长度指标

#### 进程匹配（Session → 终端）

核心挑战是将 session 文件映射到正确的 iTerm2 标签页。监控器使用 **创建时间匹配** 算法：

1. **获取所有运行中的 `claude` 进程**：通过 `ps` 获取 PID、TTY、CPU 使用率和运行时长
2. **获取每个进程的工作目录**：通过 `lsof -d cwd` 获取，用于匹配项目目录
3. **比较文件创建时间和进程启动时间**：当你运行 `claude` 时，它会在进程启动后几秒内创建新的 JSONL 文件。时间差在 60 秒内即视为匹配。

```
进程: PID=99046, TTY=ttys046, 启动于 2026-04-25 17:07:37
会话: a9292d41.jsonl,          创建于 2026-04-25 17:07:58
                               → 时间差 = 21 秒 → 匹配 ✓
```

#### iTerm2 集成

通过 AppleScript 与 iTerm2 交互：

- **跳转会话**：遍历所有 iTerm2 窗口/标签页/会话，找到与 TTY（如 `/dev/ttys046`）匹配的会话，选中并激活窗口
- **发送消息**：使用 `write text` 向匹配的 iTerm2 会话输入文本 — 自动追加回车，Claude Code 会直接接收输入

### 安装

#### 前置要求

- **macOS 14.0+**（Sonoma 或更高版本）
- **Xcode Command Line Tools**（用于 Swift 编译器）
- **iTerm2**（用于终端集成）
- **Claude Code** 已安装并运行

#### 方式一：从源码构建（推荐）

```bash
# 克隆仓库
git clone https://github.com/zhaodi-Wen/ClaudeSessionMonitor.git
cd ClaudeSessionMonitor

# 构建 Release 版本
swift build -c release

# 创建 .app 包
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
    <string>1.6.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
</dict>
</plist>
EOF

# 启动
open "Claude Session Monitor.app"
```

#### 方式二：下载 DMG

从 [Releases](https://github.com/zhaodi-Wen/ClaudeSessionMonitor/releases) 下载最新的 DMG，打开后将 `Claude Session Monitor.app` 拖入 Applications 文件夹。

### 使用说明

#### 基本操作

1. 启动应用 — 菜单栏出现 `⌘` 图标
2. 点击 `⌘` 查看所有 Claude Code 会话
3. 绿色圆点 = 活跃会话（有对应的终端进程在运行）
4. 灰色圆点 = 历史会话（进程已退出）

#### 查看对话

1. 点击任意会话行进入详情页
2. 以气泡样式查看完整对话（用户消息在右，Claude 回复在左）
3. **工具调用**以完整内容展示：Bash 命令、文件路径、编辑 diff、搜索 pattern
4. 每 3 秒自动刷新（可通过开关控制）
5. 浮窗打开期间保留全部消息历史（增量加载）
6. 点击"返回"回到会话列表

#### 确认 / 拒绝工具调用

当 Claude 提出 Bash 命令、文件写入或编辑时：
1. 工具调用以高亮块展示，包含完整的命令/内容
2. 点击 **✅ 允许** 批准执行（向终端发送 `y`）
3. 点击 **❌ 拒绝** 拒绝执行（向终端发送 `n`）
4. 无需切换到 iTerm2 去按 `y` 或 `n`

#### 发送消息

1. 在**活跃会话**的详情页，使用底部输入框
2. 输入消息后按回车（或点击发送按钮）
3. 消息会直接发送到对应的 iTerm2 终端
4. 对话内容会实时更新

#### 固定悬浮窗

1. 点击标题栏的 📌 **固定按钮**（列表页和详情页均可用）
2. 弹窗会脱离菜单栏，变为**独立悬浮窗口**
3. 窗口始终置顶 — 自由切换其他应用不会消失
4. 可拖动到任意位置、调整大小，跨桌面（Space）保持可见
5. 再次点击 📌 或关闭窗口即可恢复为弹窗模式

#### 跳转 iTerm2

1. 在详情页点击 **"跳转 iTerm2"** 按钮
2. iTerm2 会激活并切换到正确的标签页

#### 开机自启

在面板底部切换"开机启动"开关。这会在 `~/Library/LaunchAgents/com.claude.session-monitor.plist` 创建或删除一个 LaunchAgent 配置。

### 项目结构

```
ClaudeSessionMonitor/
├── Package.swift                                    # Swift Package Manager 配置
├── Sources/ClaudeSessionMonitor/
│   ├── main.swift                                   # 入口，AppDelegate，NSStatusBar
│   ├── Models/
│   │   └── SessionInfo.swift                        # 会话数据模型
│   ├── Services/
│   │   ├── SessionScanner.swift                     # 核心：JSONL 扫描 + 进程匹配
│   │   ├── ITerm2Bridge.swift                       # AppleScript iTerm2 集成
│   │   ├── NotificationManager.swift                # macOS 通知（通过 osascript）
│   │   └── LaunchAtLogin.swift                      # LaunchAgent 管理
│   └── Views/
│       └── SessionListView.swift                    # SwiftUI：列表、详情、聊天界面
└── .gitignore
```

### 技术细节

- **无需 Xcode** — 使用 Swift Package Manager (`swift build`) 构建
- **零第三方依赖** — 纯 Swift + SwiftUI + AppKit
- **LSUIElement=true** — 应用不会出现在 Dock 栏，仅在菜单栏显示
- **只读访问** — 只读取 Claude Code 的 JSONL 文件，不会写入任何数据
- **通过 AppleScript 聊天** — 消息通过"输入"到 iTerm2 发送，不修改 Claude 内部状态
- **后台扫描** — 所有文件 I/O 和进程查询在后台线程执行，保证 UI 流畅
- 使用 `NSPopover` 而非 `MenuBarExtra`，确保在各种启动方式下都能可靠渲染菜单栏

### 常见问题

**菜单栏图标没有出现**
- 确保通过 `open "Claude Session Monitor.app"` 启动，不要直接运行二进制文件
- 如果仍然看不到，尝试：右键 .app → 打开

**会话显示"未找到对应的终端进程"**
- 该会话对应的 Claude Code 进程已经退出
- 在 iTerm2 中启动新的 `claude` 会话，10 秒内会被自动检测到

**会话匹配到了错误的终端**
- 如果多个会话在 60 秒内相继创建，可能会出现匹配错误
- 匹配算法依赖文件创建时间与进程启动时间的对比

**"跳转 iTerm2" 不工作**
- 确保使用的是 iTerm2（不是系统自带的 Terminal.app）
- 应用需要辅助功能权限 — 在系统设置 → 隐私与安全 → 辅助功能中授权

---

## License

MIT

## Acknowledgments

Built with the help of [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — yes, the tool was built using itself.

使用 [Claude Code](https://docs.anthropic.com/en/docs/claude-code) 辅助开发 — 没错，这个工具是用它自己构建的。
