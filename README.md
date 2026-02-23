# Stubble

A macOS activity tracker that monitors your desktop usage, captures screenshots, and uses AI to summarise your work into high-level tasks and project activities.

Built with Swift, SwiftUI, and the Gemini API.

## How it works

**Stubble** runs two components:

1. **Monitor** (daemon) -- a background process that watches app switches, window titles, idle state, and periodically captures screenshots with local OCR.
2. **Dashboard** (SwiftUI app) -- a native viewer that displays your activity timeline, screenshots, AI-generated task summaries, and project activity clustering.

Both share a single SQLite database in `~/Library/Application Support/Stubble/`.

The AI summarisation is optional. Without a Gemini key everything still works -- you just won't get the task grouping, project activities, day summaries, or chat.

## Requirements

- macOS 14.0 (Sonoma) or later
- A [Gemini API key](https://aistudio.google.com/apikey) (free tier works fine) -- optional, for AI features

## Installation

Download the latest release from [GitHub Releases](https://github.com/samattias/stubble-releases/releases) and move `Stubble.app` to your Applications folder.

On first launch, the setup wizard will guide you through granting permissions and entering your API key.

### Build from source

```bash
git clone <repo-url> && cd Stubble

# Build both targets
swift build -c release

# Create the .app bundle
bash scripts/build-app.sh 1.0.0

# Run
open build/Stubble.app
```

### Grant permissions

Stubble needs two macOS permissions to function. The setup wizard will walk you through this, or you can grant them ahead of time:

**System Settings > Privacy & Security > Accessibility**
Add `Stubble.app`. Required for reading window titles.

**System Settings > Privacy & Security > Screen Recording**
Add `Stubble.app`. Required for screenshot capture. If not granted, the monitor still tracks app/window activity but can't capture screen content.

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

Everything lives in `~/Library/Application Support/Stubble/`:

| File | Contents |
|---|---|
| `stubble.db` | SQLite database (activities, screenshots, tasks, project activities) |
| `screenshots/` | JPEG files organised by date |
| `settings.json` | Gemini API key, custom prompt, granularity, and preferences |
| `memory.json` | AI-learned facts about your projects and workflows |

The database uses WAL mode so the monitor and dashboard can access it concurrently.

Screenshots older than 7 days are automatically cleaned up by the monitor.

## Privacy

- **All data stays on your machine.** Screenshots, OCR text, and activity logs are stored locally.
- **Screenshots are never uploaded.** Only window titles and OCR text are sent to Google Gemini for summarisation (if you provide an API key).
- **No analytics or telemetry.** Stubble makes no network requests except to the Gemini API and Sparkle update feed.

## License

MIT
