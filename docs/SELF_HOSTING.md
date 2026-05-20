# Self-Hosting Stubble

This guide walks you through setting up your own Stubble infrastructure. There are three deployment options:

1. **Direct API Mode** (simplest) — Use your own Gemini API key, no backend needed
2. **Full Stack** — Supabase (auth) + Cloudflare Worker (proxy/rate limiting)
3. **Hybrid** — Supabase for auth, direct API for Gemini calls

## Option 1: Direct API Mode

The simplest approach — no backend infrastructure required.

### Setup

1. Get a Gemini API key from [Google AI Studio](https://aistudio.google.com/apikey)

2. Set the environment variable and build:

```bash
export GEMINI_API_KEY="your-gemini-api-key"

# Disable hosted service features
export CODESIGN_IDENTITY="-"          # Ad-hoc signing
export SPARKLE_FEED_URL=""            # No auto-updates
export SPARKLE_ED_KEY=""              # No update signing
export TELEMETRY_DECK_APP_ID=""       # No analytics

bash scripts/build-app.sh
open build/Stubble.app
```

3. The app will use your Gemini API key directly — no sign-in required.

### Limitations

- No user authentication (single-user only)
- No rate limiting (you manage your own API quota)
- No auto-updates (build from source for updates)

---

## Option 2: Full Stack Deployment

For multi-user deployments with authentication and rate limiting.

### Prerequisites

- [Supabase](https://supabase.com) account (free tier works)
- [Cloudflare](https://cloudflare.com) account (free tier works)
- [Node.js](https://nodejs.org) 18+ (for Wrangler CLI)
- Google Cloud project with OAuth credentials

### Step 1: Supabase Setup

1. **Create a new Supabase project** at [supabase.com/dashboard](https://supabase.com/dashboard)

2. **Enable Google OAuth**:
   - Go to Authentication → Providers → Google
   - Enable the provider
   - Create OAuth credentials in [Google Cloud Console](https://console.cloud.google.com/apis/credentials):
     - Application type: Web application
     - Authorized redirect URI: `https://YOUR_PROJECT.supabase.co/auth/v1/callback`
   - Paste Client ID and Client Secret into Supabase

3. **Run the trial start trigger migration** (enables trial tracking):
   - Go to SQL Editor in Supabase Dashboard
   - Run the migration from `supabase/migrations/001_trial_start_trigger.sql`:

```sql
-- Sets trial_start in user metadata at signup
CREATE OR REPLACE FUNCTION public.set_trial_start()
RETURNS TRIGGER AS $$
BEGIN
  NEW.raw_user_meta_data = COALESCE(NEW.raw_user_meta_data, '{}'::jsonb)
    || jsonb_build_object('trial_start', EXTRACT(EPOCH FROM NOW())::bigint);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS set_trial_start_trigger ON auth.users;
CREATE TRIGGER set_trial_start_trigger
  BEFORE INSERT ON auth.users
  FOR EACH ROW
  EXECUTE FUNCTION public.set_trial_start();

-- Backfill existing users
UPDATE auth.users
SET raw_user_meta_data = COALESCE(raw_user_meta_data, '{}'::jsonb)
  || jsonb_build_object('trial_start', EXTRACT(EPOCH FROM created_at)::bigint)
WHERE raw_user_meta_data->>'trial_start' IS NULL;
```

4. **Note your credentials**:
   - Project URL: `https://YOUR_PROJECT.supabase.co`
   - Anon key: Settings → API → `anon` `public` key

### Step 2: Cloudflare Worker Setup

1. **Install Wrangler CLI**:

```bash
npm install -g wrangler
wrangler login
```

2. **Create KV namespace** for rate limiting:

```bash
cd worker
wrangler kv:namespace create "RATE_LIMITS"
```

Note the namespace ID from the output.

3. **Create `wrangler.toml`** from the example:

```bash
cp wrangler.example.toml wrangler.toml
```

Edit `wrangler.toml`:
- Replace `YOUR_KV_NAMESPACE_ID` with the ID from step 2
- Set `SUPABASE_URL` to your Supabase project URL

4. **Set secrets**:

```bash
wrangler secret put GEMINI_API_KEY
# Paste your Gemini API key

wrangler secret put SUPABASE_ANON_KEY
# Paste your Supabase anon key
```

5. **Deploy**:

```bash
wrangler deploy
```

Note your Worker URL: `https://stubble-api.YOUR_SUBDOMAIN.workers.dev`

6. **(Optional) Custom domain**:
   - In Cloudflare dashboard, go to Workers → your worker → Triggers → Custom Domains
   - Add your domain (e.g., `api.yourdomain.com`)

### Step 3: Build the App

```bash
# Set your backend credentials
export STUBBLE_SUPABASE_URL="https://YOUR_PROJECT.supabase.co"
export STUBBLE_SUPABASE_ANON_KEY="your-supabase-anon-key"
export STUBBLE_PROXY_URL="https://stubble-api.YOUR_SUBDOMAIN.workers.dev"

# Optional: your own code signing (or use ad-hoc)
export CODESIGN_IDENTITY="-"          # Ad-hoc signing
export SPARKLE_FEED_URL=""            # Disable auto-updates
export SPARKLE_ED_KEY=""
export TELEMETRY_DECK_APP_ID=""       # Disable analytics

bash scripts/build-app.sh
```

### Step 4: Distribute

For ad-hoc signed builds:
- Users must right-click → Open the first time (Gatekeeper warning)
- TCC permissions (Screen Recording, Accessibility) reset on every rebuild

For proper distribution:
- Get a Developer ID certificate from Apple
- Set `CODESIGN_IDENTITY` to your certificate name
- Notarize with `scripts/publish-update.sh` (requires Apple Developer account)

---

## Option 3: Hybrid Mode

Use Supabase for authentication but direct API for Gemini calls (no rate limiting).

1. Follow Steps 1-3 of the Full Stack setup, but skip the Cloudflare Worker
2. Build with both Supabase credentials AND Gemini API key:

```bash
export STUBBLE_SUPABASE_URL="https://YOUR_PROJECT.supabase.co"
export STUBBLE_SUPABASE_ANON_KEY="your-supabase-anon-key"
export GEMINI_API_KEY="your-gemini-api-key"  # Enables direct mode

bash scripts/build-app.sh
```

The app will use Supabase for sign-in but bypass the proxy for AI requests.

---

## Upgrading

To update your self-hosted Stubble:

```bash
git pull origin main
bash scripts/build-app.sh
```

The database schema auto-migrates on launch.

---

## Troubleshooting

### "Backend not configured" error

- Check that `STUBBLE_SUPABASE_URL` doesn't contain `YOUR_`
- Verify the environment variables are set before running `build-app.sh`
- Check `~/Library/Application Support/Stubble/stubble.log` for details

### OAuth redirect fails

- Verify the redirect URI in Google Cloud Console matches exactly:
  `https://YOUR_PROJECT.supabase.co/auth/v1/callback`
- Check that Google OAuth is enabled in Supabase Authentication settings

### Rate limiting not working

- Verify the KV namespace ID in `wrangler.toml`
- Check Worker logs: `wrangler tail`
- Ensure `SUPABASE_ANON_KEY` secret is set

### Permissions reset after rebuild

This is expected with ad-hoc signing. Each rebuild creates a new code signature, requiring users to re-grant permissions. For stable permissions:
- Use a Developer ID certificate
- Or instruct users to remove/re-add the app in System Settings after updates

---

## Architecture Reference

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

┌──────────────────────────────────────────────────────────────────┐
│                    API Requests (Direct Mode)                     │
│                                                                   │
│   Stubble.app ─────────────────────────▶ Gemini API              │
│                                    (x-goog-api-key)               │
│                                                                   │
│   No authentication, no rate limiting, no proxy                   │
└──────────────────────────────────────────────────────────────────┘
```
