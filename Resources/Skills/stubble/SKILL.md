---
name: stubble
description: Generate beautiful, color-coded visual timesheets from Stubble screen activity data. Use this skill whenever the user asks for a timesheet, daily timeline, activity breakdown, time tracking visualization, "how did I spend my day", "what did I work on", screen time report, or any visual summary of their work activity. Also triggers for requests like "show me my day", "visualize my activity", "time audit", or "work log". This skill requires the Stubble MCP connection to be active.
---

# Stubble

Creates elegant, color-coded timeline visualizations from Stubble screen activity data. The output is a polished React artifact showing how the user spent their time in 10-minute intervals.

## Prerequisites

- **Stubble MCP** must be connected. Use `tool_search` to load Stubble tools if not already available.
- Tools needed: `Stubble:get_activity_log` (primary), `Stubble:query_tasks` (supplementary context)

## Workflow

### Step 1: Determine the date

- Default to today if no date specified
- Accept natural language: "yesterday", "last Monday", "May 15th", etc.
- Format as YYYY-MM-DD for the Stubble API

### Step 2: Fetch data

1. Call `Stubble:get_activity_log` with `date`, `include_idle: true`, `limit: 2000`
2. Optionally call `Stubble:query_tasks` for the same date to get AI-summarized task context

If the activity log result is too large for context, it will be saved to a file. Use `bash_tool` with grep/python to process it.

### Step 3: Process data with the bundled script

Copy the processing script to the working directory and run it:

```bash
cp /path/to/skill/scripts/process_timesheet.py /home/claude/process_timesheet.py
python3 /home/claude/process_timesheet.py <activity_log_json_path> [tasks_json_path] [--date YYYY-MM-DD] [--interval 10] [--timezone-offset 1]
```

Arguments:
- `activity_log_json_path`: Path to the raw Stubble activity log JSON (either the tool result file or a file you save the data to)
- `tasks_json_path` (optional): Path to query_tasks result for richer labels
- `--date`: The date being visualized (for the header)
- `--interval`: Minutes per bucket (default: 10)
- `--timezone-offset`: Hours offset from UTC for display (default: 1 for BST, use 0 for UTC). Determine from user's location context.

The script outputs a JSON file at `/home/claude/timesheet_data.json` with processed buckets.

### Step 4: Generate the React artifact

Read `/home/claude/timesheet_data.json` and create a **React (.jsx) artifact** that renders inline in Claude Desktop / claude.ai.

**IMPORTANT**: Read the frontend-design skill at `/mnt/skills/public/frontend-design/SKILL.md` before generating the artifact to ensure high visual quality.

Create the file at `/mnt/user-data/outputs/timesheet.jsx` following these design requirements:

#### Design Specification

**Aesthetic**: Refined editorial / data-visualization hybrid. Think: FT data journalism meets a premium analytics dashboard. Clean, warm, light theme.

**Color Palette** — Each activity category gets a distinct hue:

| Category | Color | Hex |
|---|---|---|
| Deep Work / Coding | Indigo | `#4f46e5` |
| Research / Reading | Teal | `#0d9488` |
| Communication (Email, Slack, WhatsApp) | Amber | `#d97706` |
| Social Media (X, LinkedIn) | Rose | `#e11d48` |
| Entertainment (Chess, Games, YouTube) | Violet | `#7c3aed` |
| Property / Personal | Emerald | `#059669` |
| Meetings / Calls | Sky | `#0284c7` |
| Idle / AFK | Neutral | `#9ca3af` |
| Other | Stone | `#78716c` |

**Theme**: Light — warm off-white background (`#fafaf8`), white cards, dark text (`#0f172a`).

**Layout**:
- Header with date, total active time, and start/end window
- Category legend with colored dots
- **Stacked bar timeline** in a white card: each 10-minute slot is a column with stacked colored segments. Heights are proportional to seconds (use a fixed max like 160px scaled to the busiest slot). Time labels above, active-minutes below.
- Hover tooltips on each bar showing the top activities for that slot
- Breakdown grid: cards with category name, minutes, percentage bar
- Block detail: compact rows with time, dominant activity label, and active minutes

**Typography**: Google Fonts — `DM Sans` for body, `JetBrains Mono` for data/time labels. Import via `<link>` inside the component.

**React constraints** (artifact environment):
- Default export, functional component with hooks
- Only Tailwind core utility classes or inline styles (inline styles preferred for reliability)
- No localStorage/sessionStorage
- Available libraries: `react` (useState, etc.), `recharts`, `lucide-react`
- Keep it in a single file
- Embed the processed data directly as constants in the component

**Visual Details**:
- Stacked bar segments use `linear-gradient(180deg, ${color}dd 0%, ${color} 100%)` for depth
- Soft rounded corners (8-12px) on cards and bars
- Hover state: subtle scale + shadow on timeline bars
- White card backgrounds with 1px `#e8e8ec` borders
- Section labels in monospace, uppercase, spaced-out tracking
- Bar chart tooltips positioned below the bar on hover

### Step 5: Present the file

Use `present_files` to share the `.jsx` artifact. It will render inline in the Claude conversation. Keep the post-message brief — the user can see the visualization directly.

## Activity Classification Rules

When processing window titles into categories, use this priority order:

1. **Deep Work / Coding**: Terminal, VS Code, Cursor, Xcode, any IDE, Claude Code sessions (window titles containing "claude TMPDIR"), GitHub (when viewing code/PRs)
2. **Research / Reading**: Browser tabs with documentation, blog posts, Hacker News, arXiv, Wikipedia, Google Scholar, product pages being researched
3. **Communication**: Mail, Gmail, Slack, WhatsApp, Telegram, Discord (when chatting), Messages, Zoom, Google Meet, Teams
4. **Social Media**: X/Twitter (Home, Feed, Search), LinkedIn (Feed, Notifications), Reddit browsing, Instagram
5. **Entertainment**: Chess.com, YouTube (unless tutorial), Netflix, Spotify, games
6. **Property / Personal**: Real estate sites, banking, personal finance, shopping
7. **Meetings / Calls**: Zoom, Meet, Teams (when in a meeting), Granola
8. **Idle / AFK**: Idle periods > 2 minutes

When a window title is ambiguous, lean toward the more "productive" category. E.g., YouTube with a tech title → Research; LinkedIn viewing a profile → Research if they're a prospect, Social if browsing feed.

## Important Notes

- The timezone offset should be inferred from the user's location. UK users: use +1 during BST (late March–late October), +0 during GMT.
- If the activity log has > 500 records and lands in a file, always process it via the Python script rather than trying to parse in-context.
- The HTML must be self-contained (inline CSS/JS, only external dependency is Google Fonts CDN).
- Always present the file via `present_files` — the user can't see files in `/mnt/user-data/outputs/` otherwise.
