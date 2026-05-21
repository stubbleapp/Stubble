---
name: stubble
description: Generate visual timesheets from Stubble screen activity data. Use when the user asks for a timesheet, "how did I spend my day", "what did I work on", activity breakdown, or time tracking visualization. Requires Stubble MCP connection.
---

# Stubble Timesheet

Generates a beautiful HTML timesheet showing:
1. **Timeline** — Visual bar chart of the day
2. **Breakdown** — Time spent per category (Deep Work, Communication, etc.)
3. **What You Worked On** — AI-generated task descriptions from Stubble

## Workflow

### Step 1: Fetch both data sources

You need TWO API calls:

```
# 1. Activity log (for timeline visualization)
Stubble:get_activity_log
  date: "YYYY-MM-DD"
  include_idle: true
  limit: 2000

# 2. Task summaries (for "What You Worked On" section)
Stubble:query_tasks
  date: "YYYY-MM-DD"
  limit: 50
```

Save both results to files:
- `/home/claude/activity_data.json`
- `/home/claude/tasks_data.json`

### Step 2: Run the processing script

```bash
python3 /path/to/skill/scripts/process_timesheet.py \
    --activities /home/claude/activity_data.json \
    --tasks /home/claude/tasks_data.json \
    --date YYYY-MM-DD \
    --timezone-offset 1 \
    --output /mnt/user-data/outputs/timesheet.html
```

**Arguments:**
- `--activities`: Activity log JSON (from get_activity_log)
- `--tasks`: Tasks JSON (from query_tasks) — this has the AI descriptions!
- `--date`: Date being visualized
- `--timezone-offset`: Hours from UTC (UK: +1 BST Mar-Oct, +0 GMT winter)
- `--output`: Where to write the HTML

### Step 3: Present the result

Use `present_files` to share the HTML file.

## What Each Data Source Provides

**get_activity_log** → Timeline + Category Breakdown
- Raw app usage with timestamps
- Used to build the visual timeline bars
- Used to calculate time per category

**query_tasks** → "What You Worked On" Section
- AI-generated task titles and descriptions
- Actual descriptions of what the user was doing
- NOT window titles — real task summaries like:
  - "Implemented OAuth flow for user authentication"
  - "Reviewed PR #142 and left comments on the caching approach"
  - "Researched SwiftUI Charts API for timeline visualization"

## Example Output

The "What You Worked On" section shows task cards:

```
┌─────────────────────────────────────────────────────────────┐
│ 09:12 – 10:45                                        1h 33m │
│ Implemented MCP tools for Stubble                           │
│ Added get_activity_log and query_tasks endpoints to the     │
│ MCP server. Fixed timezone handling and added data          │
│ sanitization for privacy.                                   │
│ ─────────────────────────────────────────────────────────── │
│ Cursor, Terminal, Safari                                    │
└─────────────────────────────────────────────────────────────┘
```

## Notes

- UK timezone: +1 (BST, late March–late October), +0 (GMT, winter)
- If no tasks exist, the section shows a message to run Stubble
- Tasks are sorted chronologically by start time
