# TaskMiner

A macOS activity tracker that monitors your desktop usage, captures screenshots, and uses AI to summarise your work into high-level tasks and project activities.

Built with Swift, SwiftUI, and the Gemini API.

## How it works

**TaskMiner** runs two components:

1. **Monitor** (CLI) -- a background daemon that watches app switches, window titles, idle state, and periodically captures screenshots with local OCR.
2. **Dashboard** (SwiftUI app) -- a native viewer that displays your activity timeline, screenshots, AI-generated task summaries, and project activity clustering.

Both share a single SQLite database in `~/Library/Application Support/TaskMiner/`.

The AI summarisation is optional. Without a Gemini key everything still works -- you just won't get the task grouping, project activities, day summaries, or chat.

## Requirements

- macOS 14.0 (Sonoma) or later
- Swift 5.9+ / Xcode 15+
- A [Gemini API key](https://aistudio.google.com/apikey) (free tier works fine) -- optional, for AI features

## Installation

### Build from source

```bash
git clone <repo-url> && cd TaskMiner

# Build both targets
swift build -c release

# Binaries are in:
#   .build/release/TaskMiner           (background monitor)
#   .build/release/TaskMinerDashboard  (SwiftUI dashboard)
```

### Grant permissions

The monitor needs two macOS permissions to function. You'll be prompted on first launch, or you can grant them ahead of time:

**System Settings > Privacy & Security > Accessibility**
Add the `TaskMiner` binary (or Terminal.app if running from a shell).

**System Settings > Privacy & Security > Screen Recording**
Same binary. Required for screenshot capture. If not granted, the monitor still tracks app/window activity but can't capture screen content.

## Usage

### Start the monitor

```bash
# Default settings
.build/release/TaskMiner

# With custom options
.build/release/TaskMiner \
  --screenshot-interval 120 \
  --idle-threshold 60 \
  --screenshot-quality 0.8 \
  --debug
```

| Flag | Default | Description |
|---|---|---|
| `--screenshot-interval` | 300 | Seconds between periodic screenshots |
| `--idle-threshold` | 120 | Seconds of inactivity before marking idle |
| `--screenshot-quality` | 0.6 | JPEG compression (0.0 -- 1.0) |
| `--debug` | off | Verbose logging |

The monitor runs in the foreground. Use a launchd plist, `tmux`, or `nohup` to keep it running in the background.

Stop it with `Ctrl+C` -- it handles SIGINT/SIGTERM gracefully.

### Open the dashboard

```bash
.build/release/TaskMinerDashboard
```

Or double-click the binary in Finder.

### Set up the Gemini API key

Three options, in priority order:

1. **Dashboard settings** -- click the gear icon, enter your key. Stored in the macOS Keychain.
2. **Keychain** -- already stored if you used option 1.
3. **Environment variable** -- `export GEMINI_API_KEY=your-key-here`

Get a free key from [Google AI Studio](https://aistudio.google.com/apikey). TaskMiner uses Gemini 2.5 Flash.

## Features

### Activity tracking
- Detects app switches and window title changes
- Tracks active vs idle time (mouse/keyboard/scroll input)
- Periodic screenshots with local OCR (Apple Vision framework)
- Pause/resume monitoring from the dashboard (with timed pause options)

### AI task summaries
- Groups raw activity into high-level tasks (e.g. "Developing auth flow in Xcode")
- Generates a natural-language day summary
- Configurable granularity (low/medium/high) to control task detail level
- Persistent memory -- the AI learns your projects, tools, and patterns across sessions
- Custom instructions to tailor output (e.g. "ignore YouTube, focus on coding")
- Regenerate on demand from the dashboard

### Project activities
- Clusters related tasks into higher-level project groupings using AI
- Persisted to the database -- only regenerated when explicitly requested
- Automatically regenerated when tasks are regenerated
- Fallback to one-project-per-task when AI is unavailable

### Hotlinks
- Clickable links extracted from window titles and OCR text
- Opens documents, websites, repositories, and file paths directly
- AI-extracted relevant URLs included in task data
- Supports VS Code, Terminal, browser, and editor file path patterns

### Chat
- Ask questions about your day's activity in natural language
- Context-aware -- the AI sees your tasks, time ranges, and apps used
- Conversational with multi-turn history

### Dashboard
- Day selector with 30-day history
- Three tabs: task timeline, project activities, and screenshot browser
- Task timeline with expand/collapse, inline editing, swipe-to-delete, and link chips
- Project activity cards with colour-coded bars, app icons, and constituent task drill-down
- Screenshot browser with detail view, metadata sidebar, and bulk delete
- CSV export of tasks
- Light and dark mode with adaptive colour palette

## Data storage

Everything lives in `~/Library/Application Support/TaskMiner/`:

| File | Contents |
|---|---|
| `taskminer.db` | SQLite database (activities, screenshots, tasks, project activities) |
| `screenshots/` | JPEG files organised by date |
| `settings.json` | Custom prompt, granularity, and non-secret preferences |
| `memory.json` | AI-learned facts about your projects and workflows |

The database uses WAL mode so the monitor and dashboard can access it concurrently.

Screenshots older than 7 days are automatically cleaned up by the monitor.

## Project structure

```
Sources/
  TaskMiner/              CLI background monitor
    App/                  Entry point, configuration, app delegate
    Monitoring/           Activity, screenshot, window title, idle detection
    Processing/           OCR engine
    Storage/              Database writes, screenshot file management

  TaskMinerDashboard/     SwiftUI dashboard app
    App/                  App entry point, menu bar controller
    Models/               ProjectActivity, ChatMessage
    ViewModels/           DashboardViewModel, ProjectActivityGenerator
    Views/                All SwiftUI views (timeline, activities, screenshots, chat, settings)
    Theme/                Adaptive colour palette and styling
    Utilities/            Caching, icon resolution, settings manager

  TaskMinerShared/        Shared library (used by both targets)
    Models/               ActivityRecord, ScreenshotRecord, TaskRecord, ProjectActivityRecord
    Storage/              DatabaseReader, TaskWriter, SharedConfiguration
    API/                  GeminiClient
    Processing/           TaskSummarizer, LinkExtractor
    IPC/                  PauseController (file-based IPC)
    Utilities/            Keychain, logging, formatters
```

## License

MIT
