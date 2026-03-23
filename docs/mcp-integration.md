# Stubble MCP Integration

Connect AI agents to your Stubble activity data via the Model Context Protocol (MCP).

## Quick Start

### 1. Get Your API Key

```bash
# From the app bundle
/Applications/Stubble.app/Contents/MacOS/stubble-mcp --show-key

# Or if running from source
.build/arm64-apple-macosx/debug/stubble-mcp --show-key
```

### 2. Configure Your AI Agent

**Claude Code** (`~/.claude/mcp.json`):
```json
{
  "mcpServers": {
    "stubble": {
      "command": "/Applications/Stubble.app/Contents/MacOS/stubble-mcp",
      "env": {
        "STUBBLE_MCP_KEY": "sk-stubble-your-key-here"
      }
    }
  }
}
```

**OpenClaw** (add to your MCP config):
```json
{
  "stubble": {
    "command": "/Applications/Stubble.app/Contents/MacOS/stubble-mcp",
    "env": {
      "STUBBLE_MCP_KEY": "sk-stubble-your-key-here"
    }
  }
}
```

### 3. Start Using

Once connected, your AI agent can query your activity data:

- "What did I work on today?"
- "How much time did I spend in Terminal this week?"
- "Show me my project breakdown"
- "What was I doing at 2pm yesterday?"

---

## Available Tools

### query_tasks

Get AI-generated task summaries for a date range.

```json
{
  "name": "query_tasks",
  "arguments": {
    "date": "2026-03-23",
    "limit": 10
  }
}
```

**Parameters:**
| Name | Type | Default | Description |
|------|------|---------|-------------|
| `date` | string | today | Single date (YYYY-MM-DD) |
| `from` | string | - | Start date for range |
| `to` | string | - | End date for range |
| `limit` | integer | 50 | Max results (up to 200) |

**Response:**
```json
{
  "tasks": [
    {
      "title": "Implementing MCP server",
      "description": "Building secure local API for AI agents...",
      "start_time": "2026-03-23T09:00:00Z",
      "end_time": "2026-03-23T10:30:00Z",
      "duration_minutes": 90,
      "apps": ["Terminal", "VS Code"],
      "links": ["/Users/sam/project/src"],
      "websites": ["github.com", "stackoverflow.com"]
    }
  ],
  "count": 1
}
```

---

### get_activity_log

Get raw activity records (app switches, window titles, idle periods). Supports single-date or date-range queries.

```json
{
  "name": "get_activity_log",
  "arguments": {
    "date": "2026-03-23",
    "app": "Chrome",
    "include_idle": false,
    "limit": 100
  }
}
```

**Date range example:**
```json
{
  "name": "get_activity_log",
  "arguments": {
    "from": "2026-03-20",
    "to": "2026-03-23",
    "limit": 500
  }
}
```

**Parameters:**
| Name | Type | Default | Description |
|------|------|---------|-------------|
| `date` | string | today | Single date to query (YYYY-MM-DD) |
| `from` | string | - | Start date for range (YYYY-MM-DD) |
| `to` | string | today | End date for range (YYYY-MM-DD) |
| `app` | string | - | Filter by app name |
| `include_idle` | boolean | true | Include idle periods |
| `limit` | integer | 500 | Max results (up to 2000) |

Note: Use `date` for single-day queries OR `from`/`to` for multi-day ranges. Date range capped at 30 days.

**Response:**
```json
{
  "activities": [
    {
      "timestamp": "2026-03-23T09:15:00Z",
      "app_name": "Google Chrome",
      "window_title": "GitHub - stubble/stubble",
      "browser_domain": "github.com",
      "is_idle": false,
      "duration_seconds": 300
    }
  ],
  "count": 1
}
```

---

### search_activities

Search activities by app name, window title, or content.

```json
{
  "name": "search_activities",
  "arguments": {
    "query": "stubble",
    "include_urls": true
  }
}
```

**Parameters:**
| Name | Type | Default | Description |
|------|------|---------|-------------|
| `query` | string | **required** | Search term |
| `app` | string | - | Filter by app |
| `from` | string | 7 days ago | Start time (ISO8601) |
| `to` | string | now | End time (ISO8601) |
| `include_urls` | boolean | false | Include full URLs (privacy opt-in) |

---

### get_projects

Get project activity summaries with durations and associated tasks.

```json
{
  "name": "get_projects",
  "arguments": {
    "date": "2026-03-23"
  }
}
```

**Response:**
```json
{
  "projects": [
    {
      "name": "Stubble MCP Integration",
      "summary": "Building secure local API for AI agents",
      "duration_minutes": 120,
      "apps": ["Terminal", "VS Code", "Chrome"],
      "tasks": ["Implementing MCP server", "Writing documentation"]
    }
  ],
  "count": 1
}
```

---

### get_timeline

Get the day view timeline showing tasks interleaved with away periods.

```json
{
  "name": "get_timeline",
  "arguments": {
    "date": "2026-03-23"
  }
}
```

**Response:**
```json
{
  "timeline": [
    {
      "type": "task",
      "title": "Morning standup",
      "start_time": "2026-03-23T09:00:00Z",
      "end_time": "2026-03-23T09:15:00Z",
      "duration_minutes": 15,
      "is_first": true,
      "is_last": false
    },
    {
      "type": "away",
      "start_time": "2026-03-23T09:15:00Z",
      "end_time": "2026-03-23T09:25:00Z",
      "duration_minutes": 10
    },
    {
      "type": "task",
      "title": "Code review",
      "start_time": "2026-03-23T09:25:00Z",
      "end_time": "2026-03-23T10:10:00Z",
      "duration_minutes": 45,
      "is_first": false,
      "is_last": true
    }
  ],
  "count": 3
}
```

---

### get_day_summary

Get the AI-generated day summary with focus time and meeting stats.

```json
{
  "name": "get_day_summary",
  "arguments": {
    "date": "2026-03-23"
  }
}
```

**Response:**
```json
{
  "date": "2026-03-23",
  "summary": "Focused day on MCP integration. Built the server, wrote docs, and tested with Claude Code.",
  "focus_time_minutes": 240,
  "meeting_time_minutes": 30,
  "project_count": 2,
  "generated_at": "2026-03-23T18:00:00Z"
}
```

---

### get_user_profile

Get the user's learned profile (role, projects, tech stack, interests).

```json
{
  "name": "get_user_profile",
  "arguments": {}
}
```

**Response:**
```json
{
  "profile": "Software engineer working on Stubble, a macOS productivity app. Primary tech stack: Swift, SwiftUI, SQLite. Interested in AI/ML integration and developer tools."
}
```

---

### get_ocr_digest

Get the daily OCR digest containing extracted URLs, file paths, code symbols, and other structured data from screen captures. Useful for understanding what was visible on screen.

```json
{
  "name": "get_ocr_digest",
  "arguments": {
    "date": "2026-03-23"
  }
}
```

**Parameters:**
| Name | Type | Default | Description |
|------|------|---------|-------------|
| `date` | string | today | Date to query (YYYY-MM-DD) |

**Response:**
```json
{
  "date": "2026-03-23",
  "digest": "## URLs Visited\n- github.com/samattias/stubble\n- stackoverflow.com/questions/...\n\n## Code Symbols\n- MCPTools\n- DatabaseReader\n- ActivityRecord\n\n## File Paths\n- Sources/TaskMinerMCP/MCPTools.swift\n- docs/mcp-integration.md",
  "generated_at": "2026-03-23T18:00:00Z"
}
```

---

## Security & Privacy

### Authentication

Every request requires a valid API key passed via the `STUBBLE_MCP_KEY` environment variable.

```bash
# Generate a new key (invalidates existing connections)
stubble-mcp --rotate-key
```

Keys are stored at `~/.stubble/mcp-key` with 0600 permissions (owner-only).

### Rate Limiting

- **60 requests per minute** per connected client
- Exceeding the limit returns a rate-limited error

### Data Sanitization

All responses are sanitized before returning. The following patterns are redacted:

| Data Type | Example | Replacement |
|-----------|---------|-------------|
| JWT tokens | `eyJhbG...` | `[REDACTED_JWT]` |
| API keys | `sk-...`, `ghp_...` | `[REDACTED_KEY]` |
| Passwords | `password=xxx` | `[REDACTED_CREDENTIAL]` |
| Emails | `user@example.com` | `[REDACTED_EMAIL]` |
| AWS keys | `AKIA...` | `[REDACTED_AWS_KEY]` |

### What's NOT Exposed

- **Screenshots** — Image files are never returned
- **Meeting notes** — Granola meeting data is excluded
- **Full file paths** — Only basenames (opt-in for full)
- **Full URLs** — Only domains by default (opt-in for full)

### Audit Log

Every tool invocation is logged to `~/.stubble/mcp-audit.log`:

```
[2026-03-23T09:42:52Z] tool=query_tasks params={date:"2026-03-23"} rows=3 duration_ms=6
[2026-03-23T09:43:01Z] tool=get_timeline params={date:"2026-03-23"} rows=5 duration_ms=4
```

---

## Troubleshooting

### "Unauthorized" Error

Your API key is invalid or not set.

```bash
# Check your key
stubble-mcp --show-key

# Ensure it matches your agent config
echo $STUBBLE_MCP_KEY
```

### "Rate limited" Error

You've exceeded 60 requests/minute. Wait a moment and retry.

### Empty Results

- Check the date parameter (defaults to today)
- Ensure Stubble daemon is running and collecting data
- Verify the database exists at `~/Library/Application Support/Stubble/stubble.db`

### Connection Issues

1. Verify the binary path exists:
   ```bash
   ls -la /Applications/Stubble.app/Contents/MacOS/stubble-mcp
   ```

2. Test manually:
   ```bash
   echo '{"jsonrpc":"2.0","method":"initialize","id":1,"params":{}}' | stubble-mcp
   ```

---

## Protocol Reference

The MCP server implements JSON-RPC 2.0 over stdio.

### Initialize

```json
{"jsonrpc":"2.0","method":"initialize","id":1,"params":{"protocolVersion":"2024-11-05","clientInfo":{"name":"my-agent","version":"1.0"}}}
```

### List Tools

```json
{"jsonrpc":"2.0","method":"tools/list","id":2}
```

### Call Tool

```json
{"jsonrpc":"2.0","method":"tools/call","id":3,"params":{"name":"query_tasks","arguments":{"date":"2026-03-23"}}}
```

---

## Support

- **Issues**: [github.com/samattias/stubble/issues](https://github.com/samattias/stubble/issues)
- **Website**: [stubble.ai](https://stubble.ai)
