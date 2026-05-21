#!/usr/bin/env python3
"""
Process Stubble data and generate a complete HTML timesheet visualization.

Usage:
    python3 process_timesheet.py --activities <activity_log.json> --tasks <tasks.json> [--date YYYY-MM-DD] [--timezone-offset 1] [--output /path/to/output.html]

    --activities: Raw activity log for timeline visualization (from get_activity_log)
    --tasks: AI-generated task summaries for "What You Worked On" section (from query_tasks)

Output:
    Writes a self-contained HTML file with the timesheet visualization.
"""

import json
import argparse
import html
from datetime import datetime, timedelta, timezone
from collections import defaultdict
from pathlib import Path


# ── Category classification ──────────────────────────────────────────────────

CATEGORIES = {
    "deep_work":      {"label": "Deep Work",      "color": "#2563eb", "priority": 1},
    "research":       {"label": "Research",       "color": "#0d9488", "priority": 2},
    "communication":  {"label": "Communication",  "color": "#ea580c", "priority": 3},
    "social_media":   {"label": "Social Media",   "color": "#f43f5e", "priority": 4},
    "entertainment":  {"label": "Entertainment",  "color": "#7c3aed", "priority": 5},
    "personal":       {"label": "Personal",       "color": "#16a34a", "priority": 6},
    "meetings":       {"label": "Meetings",       "color": "#0284c7", "priority": 7},
    "idle":           {"label": "Idle",           "color": "#e5e7eb", "priority": 8},
    "other":          {"label": "Other",          "color": "#9ca3af", "priority": 9},
}


def classify_activity(app_name: str, window_title: str, duration: int) -> str:
    """Classify an activity record into a category."""
    app = app_name.replace("\u200e", "").strip().lower()
    title = window_title.lower() if window_title else ""

    if app == "idle" and duration > 120:
        return "idle"

    # Deep work: IDEs, terminals, Claude
    if app in ("terminal",):
        return "deep_work"
    if app in ("code", "visual studio code", "cursor", "xcode", "intellij", "pycharm", "webstorm", "neovim", "vim"):
        return "deep_work"
    if app == "claude":
        return "deep_work"

    # Communication
    if app in ("mail", "gmail", "outlook"):
        return "communication"
    if "whatsapp" in app:
        return "communication"
    if app in ("slack", "telegram", "messages", "signal"):
        return "communication"

    # Meetings
    if app in ("zoom", "zoom.us") and "meeting" in title:
        return "meetings"
    if "google meet" in title or "meet.google.com" in title:
        return "meetings"
    if app in ("granola",):
        return "meetings"

    # Browser
    if app in ("google chrome", "safari", "firefox", "arc", "brave", "edge"):
        return classify_browser(title)

    if app == "stubble":
        return "deep_work"

    return "other"


def classify_browser(title: str) -> str:
    """Classify browser window titles."""
    t = title.lower()

    if any(s in t for s in ["chess.com", "netflix", "disney+", "twitch", "spotify"]):
        return "entertainment"
    if "youtube" in t:
        if any(s in t for s in ["tutorial", "talk", "conference", "code", "programming", "claude", "ai "]):
            return "research"
        return "entertainment"

    if any(s in t for s in ["home / x", "search / x", "/ x -", "reddit.com", "instagram", "facebook.com"]):
        return "social_media"
    if "linkedin" in t:
        if "feed" in t or "notification" in t:
            return "social_media"
        return "research"

    if any(s in t for s in ["slack", "gmail", "mail.google", "discord"]):
        return "communication"

    if "github.com" in t:
        return "deep_work"
    if any(s in t for s in ["claude.ai", "chatgpt", "vercel", "netlify", "notion", "figma", "linear"]):
        return "deep_work"

    if any(s in t for s in ["hacker news", "ycombinator", "arxiv", "wikipedia", "blog", "docs.", "documentation"]):
        return "research"

    if any(s in t for s in ["amazon", "ebay", "bank", "rightmove", "zoopla"]):
        return "personal"

    if "meet.google" in t or "zoom" in t:
        return "meetings"

    return "other"


# ── Data loading ─────────────────────────────────────────────────────────────

def load_json_data(path: str, key: str) -> list:
    """Load data from a Stubble tool result file."""
    with open(path) as f:
        raw = json.load(f)

    # Handle MCP tool result wrapper format
    if isinstance(raw, list) and len(raw) > 0 and "text" in raw[0]:
        data = json.loads(raw[0]["text"])
        return data.get(key, [])
    elif isinstance(raw, dict) and key in raw:
        return raw[key]
    elif isinstance(raw, list):
        return raw
    else:
        return []


def process_timeline(activities: list, interval_minutes: int, tz_offset_hours: int) -> dict:
    """Process raw activities into timeline buckets."""
    tz = timezone(timedelta(hours=tz_offset_hours))

    # Find activity range (skip long idle periods)
    timestamps = []
    for a in activities:
        ts = datetime.fromisoformat(a["timestamp"].replace("Z", "+00:00"))
        app = a.get("app_name", "").replace("\u200e", "")
        dur = a.get("duration_seconds", 0)
        if app == "Idle" and dur > 3600:
            continue
        timestamps.append(ts)

    if not timestamps:
        return {"buckets": [], "summary": [], "meta": {}}

    first_ts = min(timestamps)
    last_ts = max(timestamps)

    # Align to interval boundaries
    first_local = first_ts.astimezone(tz)
    start_minute = (first_local.minute // interval_minutes) * interval_minutes
    bucket_start = first_local.replace(minute=start_minute, second=0, microsecond=0)

    last_local = last_ts.astimezone(tz)
    end_minute = ((last_local.minute // interval_minutes) + 1) * interval_minutes
    if end_minute >= 60:
        bucket_end = (last_local + timedelta(hours=1)).replace(minute=end_minute - 60, second=0, microsecond=0)
    else:
        bucket_end = last_local.replace(minute=end_minute, second=0, microsecond=0)

    # Build buckets
    current = bucket_start
    bucket_list = []

    while current < bucket_end:
        next_bucket = current + timedelta(minutes=interval_minutes)
        current_utc = current.astimezone(timezone.utc)
        next_utc = next_bucket.astimezone(timezone.utc)

        category_seconds = defaultdict(float)

        for a in activities:
            ts = datetime.fromisoformat(a["timestamp"].replace("Z", "+00:00"))
            dur = max(a.get("duration_seconds", 0), 1)
            a_end = ts + timedelta(seconds=dur)

            overlap_start = max(ts, current_utc)
            overlap_end = min(a_end, next_utc)
            if overlap_start >= overlap_end:
                continue

            overlap_secs = (overlap_end - overlap_start).total_seconds()
            app = a.get("app_name", "").replace("\u200e", "")
            title = a.get("window_title", "")
            cat = classify_activity(app, title, dur)
            category_seconds[cat] += overlap_secs

        total_active = sum(v for k, v in category_seconds.items() if k != "idle")
        dominant = max(category_seconds, key=lambda k: category_seconds[k]) if category_seconds else "idle"

        time_str = current.strftime("%H:%M")
        show_label = current.minute == 0

        bucket_list.append({
            "time": time_str,
            "show_label": show_label,
            "categories": dict(category_seconds),
            "dominant": dominant,
            "active_seconds": round(total_active),
        })

        current = next_bucket

    # Summary by category
    total_by_cat = defaultdict(float)
    for b in bucket_list:
        for cat, secs in b["categories"].items():
            total_by_cat[cat] += secs

    grand_total = sum(total_by_cat.values())
    summary_list = []
    for cat_id, secs in sorted(total_by_cat.items(), key=lambda x: -x[1]):
        if cat_id in CATEGORIES and secs >= 60:
            info = CATEGORIES[cat_id]
            summary_list.append({
                "id": cat_id,
                "label": info["label"],
                "color": info["color"],
                "minutes": round(secs / 60),
                "percent": round((secs / grand_total) * 100) if grand_total > 0 else 0,
            })

    first_active = next((b for b in bucket_list if b["active_seconds"] > 0), None)
    last_active = next((b for b in reversed(bucket_list) if b["active_seconds"] > 0), None)

    return {
        "buckets": bucket_list,
        "summary": summary_list,
        "meta": {
            "total_active_minutes": round(sum(b["active_seconds"] for b in bucket_list) / 60),
            "first_activity": first_active["time"] if first_active else None,
            "last_activity": last_active["time"] if last_active else None,
        },
    }


def process_tasks(tasks: list, tz_offset_hours: int) -> list:
    """Process AI-generated tasks for display."""
    tz = timezone(timedelta(hours=tz_offset_hours))
    processed = []

    for task in tasks:
        # Parse times
        start_str = task.get("start_time", "")
        end_str = task.get("end_time", "")

        try:
            start_ts = datetime.fromisoformat(start_str.replace("Z", "+00:00"))
            start_local = start_ts.astimezone(tz).strftime("%H:%M")
        except:
            start_local = "—"

        try:
            end_ts = datetime.fromisoformat(end_str.replace("Z", "+00:00"))
            end_local = end_ts.astimezone(tz).strftime("%H:%M")
        except:
            end_local = "—"

        duration = task.get("duration_minutes", 0)
        if duration < 2:  # Skip very short tasks
            continue

        processed.append({
            "title": task.get("title", "Untitled"),
            "description": task.get("description", ""),
            "start_time": start_local,
            "end_time": end_local,
            "duration_minutes": duration,
            "apps": task.get("apps", []),
        })

    # Sort by start time
    processed.sort(key=lambda x: x["start_time"])
    return processed


# ── HTML Template ────────────────────────────────────────────────────────────

def format_duration(minutes: int) -> str:
    """Format minutes as 'Xh Ym' or 'Ym'."""
    if minutes >= 60:
        h = minutes // 60
        m = minutes % 60
        return f"{h}h {m}m" if m > 0 else f"{h}h"
    return f"{minutes}m"


def generate_html(timeline_data: dict, tasks: list, date_str: str) -> str:
    """Generate the complete HTML visualization."""

    meta = timeline_data["meta"]
    summary = timeline_data["summary"]
    buckets = timeline_data["buckets"]

    # Parse date for display
    try:
        date_obj = datetime.strptime(date_str, "%Y-%m-%d")
        date_display = date_obj.strftime("%A, %B %-d")
    except:
        date_display = date_str

    total_time = format_duration(meta.get("total_active_minutes", 0))
    time_range = f"{meta.get('first_activity', '—')} – {meta.get('last_activity', '—')}"

    # Generate timeline segments
    timeline_html = ""
    for bucket in buckets:
        dominant = bucket["dominant"]
        color = CATEGORIES.get(dominant, {}).get("color", "#e5e7eb")
        active = bucket["active_seconds"]
        height = min(48, max(4, int(active / 600 * 48))) if active > 0 else 4
        opacity = "1" if active > 30 else "0.3"

        label_html = f'<span class="timeline-label">{bucket["time"]}</span>' if bucket["show_label"] else ''

        timeline_html += f'''<div class="timeline-slot">
            <div class="timeline-bar" style="height: {height}px; background: {color}; opacity: {opacity};" title="{bucket['time']}"></div>
            {label_html}
        </div>'''

    # Generate category pills
    pills_html = ""
    for cat in summary:
        if cat["id"] == "idle":
            continue
        pills_html += f'''
        <div class="category-pill">
            <span class="pill-dot" style="background: {cat['color']};"></span>
            <span class="pill-label">{cat['label']}</span>
            <span class="pill-time">{format_duration(cat['minutes'])}</span>
        </div>'''

    # Generate task cards - this is the key part showing WHAT was done
    tasks_html = ""
    if tasks:
        for task in tasks:
            title = html.escape(task["title"])
            description = html.escape(task["description"])
            time_str = f"{task['start_time']} – {task['end_time']}"
            duration = format_duration(task["duration_minutes"])
            apps = ", ".join(task["apps"][:3]) if task["apps"] else ""

            tasks_html += f'''
            <div class="task-card">
                <div class="task-header">
                    <span class="task-time">{time_str}</span>
                    <span class="task-duration">{duration}</span>
                </div>
                <div class="task-title">{title}</div>
                <div class="task-description">{description}</div>
                {f'<div class="task-apps">{apps}</div>' if apps else ''}
            </div>'''
    else:
        tasks_html = '<div class="no-tasks">No task summaries available. Run Stubble to generate AI task descriptions.</div>'

    return f'''<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Timesheet – {date_str}</title>
    <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600&family=JetBrains+Mono:wght@400;500&display=swap" rel="stylesheet">
    <style>
        * {{ margin: 0; padding: 0; box-sizing: border-box; }}
        body {{
            font-family: 'Inter', -apple-system, sans-serif;
            background: #ffffff;
            color: #111827;
            line-height: 1.5;
            padding: 32px;
            max-width: 960px;
            margin: 0 auto;
        }}

        /* Header */
        .header {{
            display: flex;
            justify-content: space-between;
            align-items: flex-start;
            margin-bottom: 32px;
            padding-bottom: 24px;
            border-bottom: 1px solid #e5e7eb;
        }}
        .date {{ font-size: 24px; font-weight: 600; color: #111827; }}
        .meta {{ text-align: right; }}
        .meta-primary {{ font-size: 20px; font-weight: 600; color: #111827; }}
        .meta-secondary {{ font-size: 13px; color: #6b7280; font-family: 'JetBrains Mono', monospace; }}

        /* Timeline */
        .timeline-section {{ margin-bottom: 32px; }}
        .section-label {{
            font-size: 11px;
            font-weight: 600;
            color: #9ca3af;
            text-transform: uppercase;
            letter-spacing: 0.08em;
            margin-bottom: 12px;
        }}
        .timeline {{
            display: flex;
            align-items: flex-end;
            gap: 1px;
            padding: 16px 0 24px 0;
            overflow-x: auto;
        }}
        .timeline-slot {{
            display: flex;
            flex-direction: column;
            align-items: center;
            flex-shrink: 0;
            position: relative;
        }}
        .timeline-bar {{
            width: 8px;
            border-radius: 2px;
            transition: transform 0.15s;
            cursor: pointer;
        }}
        .timeline-slot:hover .timeline-bar {{
            transform: scaleY(1.15);
            opacity: 1 !important;
        }}
        .timeline-label {{
            font-size: 10px;
            color: #6b7280;
            font-family: 'JetBrains Mono', monospace;
            position: absolute;
            bottom: -18px;
            white-space: nowrap;
        }}

        /* Category Pills */
        .pills {{
            display: flex;
            flex-wrap: wrap;
            gap: 8px;
            margin-bottom: 32px;
        }}
        .category-pill {{
            display: flex;
            align-items: center;
            gap: 8px;
            padding: 8px 14px;
            background: #f9fafb;
            border: 1px solid #e5e7eb;
            border-radius: 20px;
        }}
        .pill-dot {{
            width: 8px;
            height: 8px;
            border-radius: 50%;
            flex-shrink: 0;
        }}
        .pill-label {{
            font-size: 13px;
            font-weight: 500;
            color: #374151;
        }}
        .pill-time {{
            font-size: 13px;
            font-weight: 600;
            color: #111827;
            font-family: 'JetBrains Mono', monospace;
        }}

        /* Task Cards */
        .tasks-section {{
            display: flex;
            flex-direction: column;
            gap: 16px;
        }}
        .task-card {{
            padding: 16px 20px;
            background: #fafafa;
            border: 1px solid #e5e7eb;
            border-radius: 12px;
            transition: border-color 0.15s, box-shadow 0.15s;
        }}
        .task-card:hover {{
            border-color: #d1d5db;
            box-shadow: 0 2px 8px rgba(0,0,0,0.04);
        }}
        .task-header {{
            display: flex;
            justify-content: space-between;
            align-items: center;
            margin-bottom: 8px;
        }}
        .task-time {{
            font-size: 12px;
            font-family: 'JetBrains Mono', monospace;
            color: #6b7280;
        }}
        .task-duration {{
            font-size: 12px;
            font-family: 'JetBrains Mono', monospace;
            color: #9ca3af;
            background: #f3f4f6;
            padding: 2px 8px;
            border-radius: 4px;
        }}
        .task-title {{
            font-size: 15px;
            font-weight: 600;
            color: #111827;
            margin-bottom: 6px;
        }}
        .task-description {{
            font-size: 14px;
            color: #4b5563;
            line-height: 1.6;
        }}
        .task-apps {{
            font-size: 12px;
            color: #9ca3af;
            margin-top: 10px;
            padding-top: 10px;
            border-top: 1px solid #e5e7eb;
        }}
        .no-tasks {{
            padding: 24px;
            text-align: center;
            color: #9ca3af;
            font-size: 14px;
            background: #f9fafb;
            border-radius: 12px;
        }}

        /* Footer */
        .footer {{
            margin-top: 40px;
            padding-top: 16px;
            border-top: 1px solid #e5e7eb;
            font-size: 11px;
            color: #9ca3af;
            text-align: center;
        }}
    </style>
</head>
<body>
    <div class="header">
        <div class="date">{date_display}</div>
        <div class="meta">
            <div class="meta-primary">{total_time} active</div>
            <div class="meta-secondary">{time_range}</div>
        </div>
    </div>

    <div class="timeline-section">
        <div class="section-label">Timeline</div>
        <div class="timeline">{timeline_html}</div>
    </div>

    <div class="section-label">Breakdown</div>
    <div class="pills">{pills_html}</div>

    <div class="section-label">What You Worked On</div>
    <div class="tasks-section">{tasks_html}</div>

    <div class="footer">Generated by Stubble</div>
</body>
</html>'''


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Generate Stubble timesheet visualization")
    parser.add_argument("--activities", required=True, help="Path to activity log JSON (from get_activity_log)")
    parser.add_argument("--tasks", required=True, help="Path to tasks JSON (from query_tasks)")
    parser.add_argument("--date", default=None, help="Date label (YYYY-MM-DD)")
    parser.add_argument("--timezone-offset", type=int, default=1, help="Hours offset from UTC")
    parser.add_argument("--output", default="/home/claude/timesheet.html", help="Output HTML path")

    args = parser.parse_args()

    # Load data
    activities = load_json_data(args.activities, "activities")
    tasks = load_json_data(args.tasks, "tasks")

    # Process
    timeline_data = process_timeline(activities, interval_minutes=10, tz_offset_hours=args.timezone_offset)
    processed_tasks = process_tasks(tasks, args.timezone_offset)

    # Determine date
    if args.date:
        date_str = args.date
    elif activities:
        date_str = activities[0].get("timestamp", "")[:10]
    else:
        date_str = datetime.now().strftime("%Y-%m-%d")

    # Generate HTML
    html_content = generate_html(timeline_data, processed_tasks, date_str)

    # Write output
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(html_content)

    # Print summary
    print(f"Wrote timesheet to {output_path}")
    print(f"Date: {date_str}")
    print(f"Tasks: {len(processed_tasks)}")
    print(f"Active: {timeline_data['meta'].get('total_active_minutes', 0)}m")


if __name__ == "__main__":
    main()
