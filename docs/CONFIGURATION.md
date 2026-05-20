# Configuration Reference

This document lists all environment variables used by Stubble.

## API Configuration

These variables configure how Stubble connects to AI services.

| Variable | Description | Default |
|----------|-------------|---------|
| `GEMINI_API_KEY` | Direct Gemini API key. When set, requests bypass the proxy and go directly to Google's Gemini API. No authentication required. | — |
| `STUBBLE_SUPABASE_URL` | Supabase project URL for authentication. | `https://YOUR_PROJECT.supabase.co` |
| `STUBBLE_SUPABASE_ANON_KEY` | Supabase public anon key. Safe to embed — only grants access to auth endpoints. | `YOUR_SUPABASE_ANON_KEY` |
| `STUBBLE_PROXY_URL` | Cloudflare Worker proxy URL. All proxy-mode AI requests go through this. | `https://YOUR_WORKER.workers.dev` |

### API Mode Selection

Stubble automatically selects the API mode based on configuration:

1. **Direct mode** — If `GEMINI_API_KEY` is set, requests go directly to Gemini
2. **Proxy mode** — If Supabase is configured and user is signed in, requests go through the proxy

## Build Configuration

These variables are used by `scripts/build-app.sh`.

| Variable | Description | Default |
|----------|-------------|---------|
| `APP_NAME` | Application display name | `Stubble` |
| `BUNDLE_ID` | macOS bundle identifier | `com.samattias.stubble` |
| `GITHUB_REPO` | GitHub repository for version auto-increment | `samattias/stubble-releases` |
| `CODESIGN_IDENTITY` | Code signing identity. Set to `-` for ad-hoc signing. | `Developer ID Application: ...` |
| `TEAM_ID` | Apple Developer Team ID. Set to empty for self-hosted builds. | `M3QBXSJ3A2` |
| `SPARKLE_FEED_URL` | URL for Sparkle auto-update feed. Set to empty to disable. | GitHub releases URL |
| `SPARKLE_ED_KEY` | EdDSA public key for Sparkle updates. Set to empty to disable. | Production key |
| `TELEMETRY_DECK_APP_ID` | TelemetryDeck app ID for analytics. Set to empty to disable. | Production ID |

## Billing Configuration (Optional)

These are only needed if you're setting up your own billing.

| Variable | Description | Default |
|----------|-------------|---------|
| `STUBBLE_PADDLE_PRICE_ID` | Paddle price ID for Pro subscription | `YOUR_PADDLE_PRICE_ID` |
| `STUBBLE_CHECKOUT_URL` | Checkout page URL | `https://stubble.ai/checkout` |
| `STUBBLE_ENTERPRISE_URL` | Enterprise contact URL | `mailto:hello@stubble.app` |

## Cloudflare Worker Configuration

These are set in `worker/wrangler.toml` or via `wrangler secret put`.

| Variable | Type | Description |
|----------|------|-------------|
| `GEMINI_API_KEY` | Secret | Google Gemini API key (server-side) |
| `SUPABASE_ANON_KEY` | Secret | Supabase anon key for user lookup fallback |
| `SUPABASE_URL` | Var | Supabase project URL |
| `ENVIRONMENT` | Var | Environment name (`production` or `development`) |

## Example: Self-Hosted Build

Minimal configuration for a self-hosted build with direct API mode:

```bash
# Required: Your Gemini API key
export GEMINI_API_KEY="AIza..."

# Disable hosted service features
export CODESIGN_IDENTITY="-"
export SPARKLE_FEED_URL=""
export SPARKLE_ED_KEY=""
export TELEMETRY_DECK_APP_ID=""

# Build
bash scripts/build-app.sh
```

## Example: Full Stack Deployment

Configuration for a complete self-hosted stack:

```bash
# Supabase
export STUBBLE_SUPABASE_URL="https://yourproject.supabase.co"
export STUBBLE_SUPABASE_ANON_KEY="eyJ..."

# Cloudflare Worker
export STUBBLE_PROXY_URL="https://api.yourdomain.com"

# Build settings
export CODESIGN_IDENTITY="-"          # Or your Developer ID
export SPARKLE_FEED_URL=""            # Or your update feed
export SPARKLE_ED_KEY=""
export TELEMETRY_DECK_APP_ID=""

# Build
bash scripts/build-app.sh
```

## Runtime vs Build-Time Variables

| Timing | Variables | Notes |
|--------|-----------|-------|
| **Build-time** | `CODESIGN_IDENTITY`, `TEAM_ID`, `SPARKLE_*`, `TELEMETRY_*`, `GITHUB_REPO` | Baked into the app bundle |
| **Runtime** | `GEMINI_API_KEY`, `STUBBLE_*` | Read from environment at launch |

Runtime variables can be set in your shell profile or passed when launching the app:

```bash
GEMINI_API_KEY="..." open build/Stubble.app
```

Or set in a launch agent for persistent configuration.
