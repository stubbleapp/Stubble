# Stubble

A native macOS app that tracks your desktop activity and uses AI to transform it into meaningful insights — tasks, project summaries, and personalized recommendations.

**[Download](https://stubble.ai)** · **[Privacy Policy](https://stubble.ai/privacy)** · **[Terms of Service](https://stubble.ai/terms)**

## How it works

Stubble runs quietly in the background, observing your work across apps:

- **Activity monitoring** — tracks app switches, window titles, browser URLs, and document paths
- **Screen capture** — periodic screenshots with local OCR (Apple Vision)
- **File system** — monitors changes in your code and document directories
- **Calendar & meetings** — integrates with macOS Calendar and Granola meeting notes

Every 15 minutes, Stubble's AI synthesizes this context into high-level tasks and project activities. Over time, it learns your projects, tools, and workflows to provide increasingly relevant insights.

## Requirements

- macOS 14.0 (Sonoma) or later
- Free 30-day trial, then $X/month for Pro

## Installation

1. Download from [stubble.ai](https://stubble.ai)
2. Move `Stubble.app` to Applications
3. Launch and follow the setup wizard

The wizard guides you through granting permissions (Accessibility and Screen Recording) and signing in with Google.

## Features

### Intelligent task grouping
Raw activity is clustered into meaningful tasks like "Reviewing PR #342 in GitHub" or "Writing API documentation in Notion." Tasks include time ranges, apps used, and relevant links extracted from your screen.

### Project activities
Related tasks are grouped into higher-level projects. Stubble tracks time across projects and shows your work distribution at a glance.

### Day timeline
A visual timeline of your day with tasks, away periods, and project context. Expand any task to see constituent activities and screenshots.

### AI chat
Ask questions about your work in natural language:
- "What did I work on this morning?"
- "How much time did I spend on the API this week?"
- "Summarize my meetings from yesterday"

### Personalized recommendations
Based on your recent activity and interests, Stubble suggests relevant articles, tools, and learning resources. Recommendations appear in the Chat tab when you're not in a conversation.

### Persistent memory
Stubble learns about you over time — your role, projects, technologies, and interests. This context personalizes AI responses and recommendations across sessions.

### Meeting integration
Automatically pulls meeting notes and transcripts from [Granola](https://granola.ai) for richer context in summaries and chat.

### Privacy-first
- All data stays on your machine
- Screenshots are never uploaded
- Only activity metadata (titles, OCR text) is sent to the AI for summarization
- Optional analytics can be disabled in Settings

## Data storage

All data is stored locally in `~/Library/Application Support/Stubble/`:

| File | Contents |
|---|---|
| `stubble.db` | SQLite database (activities, tasks, projects) |
| `screenshots/` | JPEG files organized by date |
| `settings.json` | Preferences and configuration |
| `memory.json` | Learned context about your work |

Screenshots are automatically pruned (images after 100, full records after 30 days).

## Support

- **Issues**: [github.com/anthropics/claude-code/issues](https://github.com/anthropics/claude-code/issues)
- **Website**: [stubble.ai](https://stubble.ai)

## License

Proprietary. See [LICENSE](LICENSE) for details.
