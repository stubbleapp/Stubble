# Architecture

Stubble is a native macOS app built with SwiftUI and Swift concurrency. It consists of two processes sharing a SQLite database.

## Process Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                           DAEMON PROCESS                            │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌────────────┐ │
│  │ Activity    │  │ Window      │  │ Idle        │  │ File       │ │
│  │ Monitor     │  │ Title       │  │ Detector    │  │ Activity   │ │
│  │ (NSWorkspace)│  │ Monitor (AX)│  │ (HID/Notif) │  │ (FSEvents) │ │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  └──────┬─────┘ │
│         │                │                │                │       │
│         └────────────────┴────────────────┴────────────────┘       │
│                                  │                                  │
│                                  ▼                                  │
│                   ┌──────────────────────────┐                     │
│                   │    DatabaseManager       │                     │
│                   │    (SQLite + WAL)        │                     │
│                   └──────────────────────────┘                     │
│                                  │                                  │
│                                  ▼                                  │
│                   ┌──────────────────────────┐                     │
│                   │    TaskSummarizer        │───▶ Gemini API      │
│                   │    (every 15 min)        │◀─── (JSON tasks)    │
│                   └──────────────────────────┘                     │
└─────────────────────────────────────────────────────────────────────┘
                                   │
                                   │ file: stubble.db
                                   ▼
┌─────────────────────────────────────────────────────────────────────┐
│                         DASHBOARD PROCESS                           │
│  ┌───────────────────┐                                              │
│  │  DatabaseReader   │◀──── reads tasks, activities, projects       │
│  └─────────┬─────────┘                                              │
│            │                                                        │
│            ▼                                                        │
│  ┌───────────────────┐    ┌───────────────────┐                    │
│  │ DashboardViewModel│───▶│ ChatOverlayView   │                    │
│  │ (SwiftUI)         │    │ (user queries)    │──▶ Gemini API      │
│  └───────────────────┘    └───────────────────┘                    │
└─────────────────────────────────────────────────────────────────────┘
```

## Authentication Flow

```
┌──────────────┐        ┌───────────────┐        ┌──────────────┐
│   Dashboard  │        │   Supabase    │        │   Google     │
│   (macOS)    │        │   Auth        │        │   OAuth      │
└──────┬───────┘        └───────┬───────┘        └──────┬───────┘
       │                        │                       │
       │  1. buildGoogleSignInURL()                     │
       │  (PKCE verifier + challenge)                   │
       │──────────────────────────────────────────────▶│
       │                        │                       │
       │                        │◀──── 2. User auths ───│
       │                        │                       │
       │◀─── 3. Redirect with code ─────────────────────│
       │     (com.stubble://auth-callback)              │
       │                        │                       │
       │  4. exchangeCode(code, verifier)               │
       │───────────────────────▶│                       │
       │                        │                       │
       │◀─── 5. JWT + refresh ──│                       │
       │                        │                       │
       │  6. Store in auth.json │                       │
       │     (0600 perms)       │                       │
       ▼                        │                       │
```

## API Request Flow

### Proxy Mode (Default)

```
┌──────────────────────────────────────────────────────────────────┐
│                    API Requests (Proxy Mode)                      │
│                                                                   │
│   Stubble.app ───▶ Cloudflare Worker ───▶ Gemini API             │
│              (Bearer JWT)        (x-goog-api-key)                 │
│                   │                                               │
│                   ├─ Verify JWT (ES256 via JWKS)                  │
│                   ├─ Check tier (pro vs trial)                    │
│                   ├─ Rate limit (KV per user per day)             │
│                   └─ Forward to Gemini                            │
└──────────────────────────────────────────────────────────────────┘
```

### Direct Mode

```
┌──────────────────────────────────────────────────────────────────┐
│                    API Requests (Direct Mode)                     │
│                                                                   │
│   Stubble.app ─────────────────────────▶ Gemini API              │
│                                    (x-goog-api-key)               │
│                                                                   │
│   GEMINI_API_KEY env var enables direct mode                      │
│   No authentication, no rate limiting, no proxy                   │
└──────────────────────────────────────────────────────────────────┘
```

## Daemon Monitors

The daemon runs several monitors that collect activity data:

| Monitor | Source | Data Collected |
|---------|--------|----------------|
| `ActivityMonitor` | NSWorkspace | App activations, launches, terminates |
| `WindowTitleMonitor` | Accessibility API | Window titles, document paths, browser URLs, focused element roles |
| `IdleDetector` | HID + System Events | Idle/active transitions, sleep/wake, lock/unlock |
| `FileActivityMonitor` | FSEvents | File modifications in watched directories |
| `CalendarMonitor` | EventKit | Calendar events for meeting context |
| `GranolaMeetingMonitor` | File polling | Meeting notes from Granola app |

## Database Schema

SQLite database at `~/Library/Application Support/Stubble/stubble.db`:

| Table | Purpose | Retention |
|-------|---------|-----------|
| `activities` | App usage events | 30 days |
| `screenshots` | Captured screenshots + OCR | Images: 100 latest; OCR: 30 days |
| `tasks` | AI-generated task summaries | Indefinite |
| `project_activities` | AI-clustered projects | Indefinite |
| `file_events` | File system modifications | 30 days |
| `granola_meetings` | Granola meeting data | 90 days |
| `chat_threads` | Chat conversations | Indefinite |
| `chat_messages` | Individual messages | Indefinite |
| `stubs_content` | Persisted day summaries | Indefinite |
| `ocr_digests` | Daily OCR digests | Indefinite |

## Module Structure

```
Sources/
├── TaskMinerShared/          # Shared code (both processes)
│   ├── API/                  # GeminiClient
│   ├── Auth/                 # AuthManager, StubbleAPIConfig
│   ├── Database/             # DatabaseManager, DatabaseReader
│   ├── Models/               # Data models
│   ├── Processing/           # TimelineBuilder, DataSanitizer, OCRDigestBuilder
│   └── Utilities/            # Logger, SettingsManager
│
├── TaskMiner/                # Daemon process
│   ├── Monitoring/           # ActivityMonitor, WindowTitleMonitor, etc.
│   └── AI/                   # TaskSummarizer, ProfileSynthesizer
│
├── TaskMinerDashboard/       # Dashboard process
│   ├── Views/                # SwiftUI views
│   ├── ViewModels/           # DashboardViewModel
│   └── Utilities/            # Theme, Analytics
│
├── TaskMinerMCP/             # MCP server library
│   ├── MCPServer.swift       # JSON-RPC server
│   ├── MCPTools.swift        # Tool implementations
│   └── MCPAuth.swift         # API key authentication
│
└── StubbleMCP/               # MCP CLI entry point
    └── main.swift
```

## Key Components

### GeminiClient

Lightweight Gemini REST client supporting two modes:

- **Proxy mode**: Requests go through Cloudflare Worker with JWT auth
- **Direct mode**: Requests go directly to Gemini with API key header

### TaskSummarizer

Runs every 15 minutes to:

1. Gather activity context from all monitors
2. Build a structured prompt with activities, URLs, files, calendar events
3. Call Gemini to generate tasks, project clusters, and day summary
4. Persist results to database

### UserMemoryStore

Learns about the user over time:

- Structured entries with categories (identity, project, technology, workflow, interest)
- Confidence decay based on age and reinforcement
- Profile synthesis into natural language description
- Max 50 entries with per-category minimums

### TimelineBuilder

Constructs the day timeline view:

1. Consolidate idle records into gap periods
2. Clip gaps to work range
3. Merge tasks and gaps chronologically
4. Insert inferred gaps for large time holes

## MCP Server

Local Model Context Protocol server for AI tool integration:

- JSON-RPC over stdio
- API key authentication
- Rate limiting (60 req/min)
- Data sanitization (secrets redacted)
- Audit logging

Available tools: `query_tasks`, `get_activity_log`, `search_activities`, `get_projects`, `get_timeline`, `get_day_summary`, `get_user_profile`, `get_ocr_digest`
