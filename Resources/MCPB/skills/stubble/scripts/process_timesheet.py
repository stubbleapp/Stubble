#!/usr/bin/env python3
"""
Process Stubble activity log data into timesheet buckets for visualization.

Usage:
    python3 process_timesheet.py <activity_log_path> [tasks_path] [--date YYYY-MM-DD] [--interval 10] [--timezone-offset 1]

Output:
    Writes /home/claude/timesheet_data.json with processed buckets.
"""

import json
import sys
import argparse
from datetime import datetime, timedelta, timezone
from collections import defaultdict
from pathlib import Path


# ── Category classification ──────────────────────────────────────────────────

CATEGORIES = {
    "deep_work":      {"label": "Deep Work",      "color": "#6366f1", "priority": 1},
    "research":       {"label": "Research",        "color": "#14b8a6", "priority": 2},
    "communication":  {"label": "Communication",   "color": "#f59e0b", "priority": 3},
    "social_media":   {"label": "Social Media",    "color": "#f43f5e", "priority": 4},
    "entertainment":  {"label": "Entertainment",   "color": "#8b5cf6", "priority": 5},
    "personal":       {"label": "Personal",        "color": "#10b981", "priority": 6},
    "meetings":       {"label": "Meetings",        "color": "#0ea5e9", "priority": 7},
    "idle":           {"label": "Idle",            "color": "#94a3b8", "priority": 8},
    "other":          {"label": "Other",           "color": "#78716c", "priority": 9},
}


def classify_activity(app_name: str, window_title: str, duration: int) -> str:
    """Classify an activity record into a category."""
    app = app_name.replace("\u200e", "").strip().lower()
    title = window_title.lower() if window_title else ""

    # Idle
    if app == "idle" and duration > 120:
        return "idle"

    # Deep work: Terminal with Claude Code, IDEs
    if app in ("terminal",):
        if "claude" in title or "tmpdir" in title:
            return "deep_work"
        return "deep_work"
    if app in ("code", "visual studio code", "cursor", "xcode", "intellij", "pycharm", "webstorm", "neovim", "vim"):
        return "deep_work"
    if app == "claude":
        return "deep_work"

    # Communication apps
    if app in ("mail", "gmail", "outlook"):
        return "communication"
    if "whatsapp" in app:
        return "communication"
    if app in ("slack", "telegram", "messages", "signal"):
        return "communication"
    if app in ("discord",) and "discord" in title:
        return "communication"

    # Meetings
    if app in ("zoom", "zoom.us") and ("meeting" in title or "zoom meeting" in title):
        return "meetings"
    if "google meet" in title or "meet.google.com" in title:
        return "meetings"
    if app in ("microsoft teams", "teams") and "meeting" in title:
        return "meetings"
    if app in ("granola",):
        return "meetings"

    # Browser-based classification
    if app in ("google chrome", "safari", "firefox", "arc", "brave", "edge"):
        return classify_browser(title)

    # Stubble app
    if app == "stubble":
        return "deep_work"

    # Auth prompts
    if app in ("coreautha", "coreauth"):
        return "other"

    return "other"


def classify_browser(title: str) -> str:
    """Classify browser window titles."""
    t = title.lower()

    # Entertainment
    if "chess.com" in t:
        return "entertainment"
    if "netflix" in t or "disney+" in t or "twitch" in t:
        return "entertainment"
    if "youtube" in t:
        # Tech/tutorial YouTube → research; otherwise entertainment
        tech_signals = ["tutorial", "talk", "conference", "explained", "how to", "course", "lecture", "code", "programming", "claude", "ai ", "llm", "ml ", "deploy"]
        if any(s in t for s in tech_signals):
            return "research"
        return "entertainment"
    if "spotify" in t:
        return "entertainment"

    # Social media
    if "home / x" in t or "search / x" in t or "/ x -" in t or "x - google" in t:
        # Check if it's research-adjacent
        research_signals = ["chronicle", "codex", "karpathy", "anthropic", "openai", "ai ", "llm", "startup"]
        if any(s in t for s in research_signals):
            return "research"
        return "social_media"
    if "linkedin" in t:
        if "feed" in t or "notification" in t:
            return "social_media"
        if "sales navigator" in t:
            return "deep_work"  # prospecting is work
        return "social_media"
    if "reddit.com" in t:
        return "social_media"
    if "instagram" in t or "facebook.com" in t:
        return "social_media"

    # Communication
    if "slack" in t:
        return "communication"
    if "gmail" in t or "mail.google" in t:
        return "communication"
    if "discord" in t:
        return "communication"

    # Deep work
    if "github.com" in t and ("pull" in t or "issues" in t or "code" in t or "commit" in t):
        return "deep_work"
    if "claude.ai" in t or "chatgpt" in t:
        return "deep_work"
    if "vercel" in t or "netlify" in t or "render" in t:
        return "deep_work"
    if "google docs" in t or "notion" in t or "figma" in t:
        return "deep_work"

    # Research
    if "hacker news" in t or "ycombinator" in t:
        return "research"
    if "arxiv" in t or "scholar.google" in t or "wikipedia" in t:
        return "research"
    if "blog" in t or "article" in t or "documentation" in t or "docs." in t:
        return "research"
    if "quora" in t:
        return "research"
    if "stubble" in t:
        return "research"
    if any(s in t for s in ["chronicle", "codex", "airjelly", "brie.io", "openchronicle"]):
        return "research"

    # Property / personal
    if any(s in t for s in ["grant mills", "commercial prop", "rightmove", "zoopla", "openrent", "case studies", "ministry of sound", "basis.london", "sony unit", "prowse place", "carlisle lane"]):
        return "personal"
    if any(s in t for s in ["amazon", "ebay", "bank", "hsbc", "barclays", "monzo", "nutmeg", "jpmorgan"]):
        return "personal"

    # Meetings
    if "meet.google" in t or "zoom" in t:
        return "meetings"

    # Prospect research (Torq, specific companies)
    if "torq software" in t:
        return "deep_work"

    return "other"


# ── Data processing ──────────────────────────────────────────────────────────

def load_activity_log(path: str) -> list:
    """Load and extract activities from the Stubble tool result file."""
    with open(path) as f:
        raw = json.load(f)

    # Handle different formats: direct list, or tool result wrapper
    if isinstance(raw, list) and len(raw) > 0 and "text" in raw[0]:
        data = json.loads(raw[0]["text"])
        return data.get("activities", [])
    elif isinstance(raw, dict) and "activities" in raw:
        return raw["activities"]
    elif isinstance(raw, list):
        return raw
    else:
        raise ValueError(f"Unrecognized activity log format in {path}")


def load_tasks(path: str) -> list:
    """Load tasks from query_tasks result."""
    if not path or not Path(path).exists():
        return []
    with open(path) as f:
        raw = json.load(f)
    if isinstance(raw, list) and len(raw) > 0 and "text" in raw[0]:
        data = json.loads(raw[0]["text"])
        return data.get("tasks", [])
    elif isinstance(raw, dict) and "tasks" in raw:
        return raw["tasks"]
    return []


def process_buckets(activities: list, interval_minutes: int, tz_offset_hours: int) -> dict:
    """Process raw activities into time buckets."""
    tz = timezone(timedelta(hours=tz_offset_hours))
    buckets = {}

    # Find the range of activity (skip overnight idle)
    timestamps = []
    for a in activities:
        ts = datetime.fromisoformat(a["timestamp"].replace("Z", "+00:00"))
        app = a.get("app_name", "").replace("\u200e", "")
        dur = a.get("duration_seconds", 0)
        if app == "Idle" and dur > 3600:
            continue
        timestamps.append(ts)

    if not timestamps:
        return {"buckets": [], "summary": {}}

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

        # Convert to UTC for comparison
        current_utc = current.astimezone(timezone.utc)
        next_utc = next_bucket.astimezone(timezone.utc)

        category_seconds = defaultdict(float)
        window_details = []  # for tooltips

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

            # Collect window details for tooltips (deduplicate)
            if title and overlap_secs >= 2:
                # Clean up title for display
                clean_title = title.split(" - Google Chrome")[0].split(" – Sam")[0].strip()
                if clean_title and len(clean_title) > 3:
                    window_details.append({
                        "title": clean_title[:80],
                        "app": app,
                        "seconds": round(overlap_secs),
                        "category": cat,
                    })

        # Determine dominant category
        total_active = sum(v for k, v in category_seconds.items() if k != "idle")
        total_idle = category_seconds.get("idle", 0)

        if total_active == 0 and total_idle == 0:
            dominant = "idle"
        else:
            dominant = max(category_seconds, key=lambda k: category_seconds[k])

        # Deduplicate and sort window details
        seen_titles = set()
        unique_details = []
        for d in sorted(window_details, key=lambda x: -x["seconds"]):
            short = d["title"][:50]
            if short not in seen_titles:
                seen_titles.add(short)
                unique_details.append(d)
            if len(unique_details) >= 4:
                break

        bucket_list.append({
            "time_start": current.strftime("%H:%M"),
            "time_end": next_bucket.strftime("%H:%M"),
            "timestamp_utc": current_utc.isoformat(),
            "categories": {k: round(v, 1) for k, v in sorted(category_seconds.items(), key=lambda x: -x[1])},
            "dominant": dominant,
            "active_seconds": round(total_active),
            "active_minutes": round(total_active / 60, 1),
            "details": unique_details,
        })

        current = next_bucket

    # Summary
    total_by_cat = defaultdict(float)
    for b in bucket_list:
        for cat, secs in b["categories"].items():
            total_by_cat[cat] += secs

    grand_total = sum(total_by_cat.values())
    summary_list = []
    for cat_id, secs in sorted(total_by_cat.items(), key=lambda x: -x[1]):
        if cat_id in CATEGORIES:
            info = CATEGORIES[cat_id]
            summary_list.append({
                "id": cat_id,
                "label": info["label"],
                "color": info["color"],
                "seconds": round(secs),
                "minutes": round(secs / 60, 1),
                "percent": round((secs / grand_total) * 100, 1) if grand_total > 0 else 0,
            })

    first_active = next((b for b in bucket_list if b["active_seconds"] > 0), None)
    last_active = next((b for b in reversed(bucket_list) if b["active_seconds"] > 0), None)

    return {
        "buckets": bucket_list,
        "categories": CATEGORIES,
        "summary": summary_list,
        "meta": {
            "total_active_minutes": round(sum(b["active_seconds"] for b in bucket_list) / 60),
            "total_buckets": len(bucket_list),
            "interval_minutes": interval_minutes,
            "first_activity": first_active["time_start"] if first_active else None,
            "last_activity": last_active["time_end"] if last_active else None,
            "timezone_label": f"UTC+{tz_offset_hours}" if tz_offset_hours >= 0 else f"UTC{tz_offset_hours}",
        },
    }


# ── Main ─────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Process Stubble activity log into timesheet data")
    parser.add_argument("activity_log", help="Path to activity log JSON")
    parser.add_argument("tasks", nargs="?", default=None, help="Path to tasks JSON (optional)")
    parser.add_argument("--date", default=None, help="Date label (YYYY-MM-DD)")
    parser.add_argument("--interval", type=int, default=10, help="Bucket interval in minutes")
    parser.add_argument("--timezone-offset", type=int, default=1, help="Hours offset from UTC")

    args = parser.parse_args()

    # Load data
    activities = load_activity_log(args.activity_log)
    tasks = load_tasks(args.tasks) if args.tasks else []

    # Process
    result = process_buckets(activities, args.interval, args.timezone_offset)

    # Add date and tasks
    if args.date:
        result["meta"]["date"] = args.date
    else:
        # Infer from first activity
        if activities:
            first_ts = activities[0].get("timestamp", "")
            if first_ts:
                result["meta"]["date"] = first_ts[:10]

    if tasks:
        result["tasks"] = [{
            "title": t.get("title", ""),
            "description": t.get("description", ""),
            "duration_minutes": t.get("duration_minutes", 0),
            "apps": t.get("apps", []),
            "start_time": t.get("start_time", ""),
            "end_time": t.get("end_time", ""),
        } for t in tasks]

    # Write output
    output_path = "/home/claude/timesheet_data.json"
    with open(output_path, "w") as f:
        json.dump(result, f, indent=2)

    print(f"Wrote {len(result['buckets'])} buckets to {output_path}")
    print(f"Date: {result['meta'].get('date', 'unknown')}")
    print(f"Active: {result['meta']['total_active_minutes']}m")
    print(f"Range: {result['meta']['first_activity']} – {result['meta']['last_activity']} {result['meta']['timezone_label']}")

    # Print summary
    print("\nBreakdown:")
    for s in result["summary"]:
        bar = "█" * max(1, int(s["percent"] / 5))
        print(f"  {s['label']:<16} {s['minutes']:>5.0f}m  {s['percent']:>5.1f}%  {bar}")


if __name__ == "__main__":
    main()
