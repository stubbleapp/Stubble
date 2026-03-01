/**
 * Stubble API Proxy — Cloudflare Worker
 *
 * Thin proxy between the Stubble macOS app and Google's Gemini API.
 * - Verifies Supabase JWTs (ES256 via JWKS)
 * - Enforces tier-based access (trial vs pro)
 * - Per-user rate limiting via KV
 * - Forwards requests to Gemini with the server-side API key
 * - Streams responses back to the client
 */

interface Env {
  GEMINI_API_KEY: string;
  SUPABASE_ANON_KEY: string;
  RATE_LIMITS: KVNamespace;
  ENVIRONMENT: string;
}

// Supabase project URL (for user lookup fallback)
const SUPABASE_URL = "https://uyeacjkroneihbtjswnv.supabase.co";

interface JWTPayload {
  sub: string; // user ID
  email?: string;
  exp: number;
  iat: number;
  role?: string;
  user_metadata?: {
    subscription_tier?: string;
    [key: string]: unknown;
  };
  app_metadata?: {
    provider?: string;
    [key: string]: unknown;
  };
}

// Rate limits per tier (requests per day)
const RATE_LIMITS = {
  trial: 200,
  pro: 2000,
};

const TRIAL_DAYS = 30;

// Gemini API base URL
const GEMINI_BASE = "https://generativelanguage.googleapis.com";

// Supabase JWKS URL for ES256 verification
const SUPABASE_JWKS_URL =
  "https://uyeacjkroneihbtjswnv.supabase.co/auth/v1/.well-known/jwks.json";

// JWKS cache timestamp (keys cached per-kid in getJWK)
let jwkFetchedAt = 0;
const JWK_CACHE_TTL = 3600_000; // 1 hour

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    // CORS preflight
    if (request.method === "OPTIONS") {
      return new Response(null, {
        headers: corsHeaders(),
      });
    }

    try {
      // 1. Extract and verify JWT
      const authHeader = request.headers.get("Authorization");
      if (!authHeader?.startsWith("Bearer ")) {
        return errorResponse(401, "missing_token", "Authorization header required");
      }

      const token = authHeader.slice(7);

      // Verify JWT using ES256 (JWKS) — Supabase's signing algorithm.
      // HS256 fallback intentionally removed to prevent algorithm downgrade attacks.
      const payload = await verifyJWT_ES256(token);
      if (!payload) {
        return errorResponse(401, "invalid_token", "Invalid or expired token");
      }

      // 2. Check expiry
      if (payload.exp < Date.now() / 1000) {
        return errorResponse(401, "token_expired", "Token has expired");
      }

      // 3. Determine tier
      const tier = await getTier(payload, env, token);

      if (tier === "expired") {
        return errorResponse(
          403,
          "trial_expired",
          "Your free trial has ended. Upgrade to Pro for unlimited access."
        );
      }

      // 4. Rate limiting
      const userId = payload.sub;
      const today = new Date().toISOString().slice(0, 10); // YYYY-MM-DD
      const kvKey = `rate:${userId}:${today}`;

      const currentCount = parseInt((await env.RATE_LIMITS.get(kvKey)) || "0") || 0;
      const limit = tier === "pro" ? RATE_LIMITS.pro : RATE_LIMITS.trial;

      if (currentCount >= limit) {
        return errorResponse(
          429,
          "rate_limited",
          tier === "pro"
            ? "Daily request limit reached. Please try again tomorrow."
            : "Daily request limit reached. Upgrade to Pro for unlimited access."
        );
      }

      // 5. Forward to Gemini (only allowed Gemini API paths)
      const url = new URL(request.url);
      if (!url.pathname.startsWith("/v1beta/models/") && !url.pathname.startsWith("/v1/models/")) {
        return errorResponse(400, "invalid_path", "Only Gemini model endpoints are allowed");
      }
      const geminiUrl = `${GEMINI_BASE}${url.pathname}${url.search}`;

      const geminiHeaders = new Headers();
      geminiHeaders.set(
        "Content-Type",
        request.headers.get("Content-Type") || "application/json"
      );
      geminiHeaders.set("x-goog-api-key", env.GEMINI_API_KEY);

      const geminiResponse = await fetch(geminiUrl, {
        method: request.method,
        headers: geminiHeaders,
        body: request.body,
      });

      // 6. Increment rate counter only on successful Gemini responses.
      // This prevents failed requests (5xx, 4xx) from consuming the user's quota.
      if (geminiResponse.ok) {
        await env.RATE_LIMITS.put(kvKey, String(currentCount + 1), {
          expirationTtl: 90000, // 25 hours
        });
      }

      // 7. Stream response back
      const responseHeaders = new Headers(corsHeaders());
      responseHeaders.set(
        "Content-Type",
        geminiResponse.headers.get("Content-Type") || "application/json"
      );

      // Preserve streaming headers
      if (geminiResponse.headers.get("Transfer-Encoding")) {
        responseHeaders.set(
          "Transfer-Encoding",
          geminiResponse.headers.get("Transfer-Encoding")!
        );
      }

      return new Response(geminiResponse.body, {
        status: geminiResponse.status,
        headers: responseHeaders,
      });
    } catch (error) {
      console.error("Worker error:", error);
      return errorResponse(500, "internal_error", "Internal server error");
    }
  },
};

// --- JWT Verification (ES256 via JWKS) ---

// Cache keyed by kid to handle key rotation
const cachedJWKs = new Map<string, CryptoKey>();

async function getJWK(kid?: string): Promise<CryptoKey | null> {
  // Return cached key if fresh and kid matches
  if (kid && cachedJWKs.has(kid) && Date.now() - jwkFetchedAt < JWK_CACHE_TTL) {
    return cachedJWKs.get(kid)!;
  }

  try {
    const response = await fetch(SUPABASE_JWKS_URL);
    if (!response.ok) return null;

    const jwks = (await response.json()) as { keys: (JsonWebKey & { kid?: string })[] };
    if (!jwks.keys?.length) return null;

    // Import all keys, indexed by kid
    cachedJWKs.clear();
    for (const jwk of jwks.keys) {
      const imported = await crypto.subtle.importKey(
        "jwk",
        jwk,
        { name: "ECDSA", namedCurve: "P-256" },
        false,
        ["verify"]
      );
      const keyId = jwk.kid || "default";
      cachedJWKs.set(keyId, imported);
    }
    jwkFetchedAt = Date.now();

    // Return the key matching the requested kid, or the first key
    if (kid && cachedJWKs.has(kid)) return cachedJWKs.get(kid)!;
    return cachedJWKs.values().next().value ?? null;
  } catch {
    return null;
  }
}

async function verifyJWT_ES256(token: string): Promise<JWTPayload | null> {
  try {
    const parts = token.split(".");
    if (parts.length !== 3) return null;

    const [headerB64, payloadB64, signatureB64] = parts;

    // Check algorithm and extract kid for key matching
    const headerJson = new TextDecoder().decode(base64UrlDecode(headerB64));
    const header = JSON.parse(headerJson) as { alg?: string; kid?: string };
    if (header.alg !== "ES256") return null;

    const key = await getJWK(header.kid);
    if (!key) return null;

    const data = new TextEncoder().encode(`${headerB64}.${payloadB64}`);

    // ES256 signatures in JWTs are raw r||s (64 bytes), not DER-encoded
    const signature = base64UrlDecode(signatureB64);

    const valid = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      key,
      signature,
      data
    );
    if (!valid) return null;

    // Decode payload
    const payloadJson = new TextDecoder().decode(base64UrlDecode(payloadB64));
    return JSON.parse(payloadJson) as JWTPayload;
  } catch {
    return null;
  }
}

function base64UrlDecode(str: string): Uint8Array {
  let padded = str.replace(/-/g, "+").replace(/_/g, "/");
  while (padded.length % 4) padded += "=";

  const binary = atob(padded);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

// --- Tier Logic ---

async function getTier(
  payload: JWTPayload,
  env: Env,
  rawToken: string
): Promise<"trial" | "pro" | "expired"> {
  // Check for pro subscription in user metadata
  const tier = payload.user_metadata?.subscription_tier;
  if (tier === "pro") return "pro";

  // Determine account creation time for trial calculation.
  // Priority: user_metadata.trial_start (set by Supabase trigger at signup)
  // Fallback: KV-cached creation time (fetched from Supabase user API once)
  let createdAtEpoch: number | null = null;

  // 1. Try trial_start from JWT user_metadata (most reliable — set at signup)
  const trialStart = payload.user_metadata?.trial_start;
  if (typeof trialStart === "number" && trialStart > 0) {
    createdAtEpoch = trialStart;
  }

  // 2. Fallback: check KV cache for this user's creation time
  if (createdAtEpoch === null) {
    const userId = payload.sub;
    const kvKey = `created:${userId}`;
    const cached = await env.RATE_LIMITS.get(kvKey);
    if (cached) {
      createdAtEpoch = parseInt(cached);
    } else {
      // 3. Last resort: fetch from Supabase user API and cache in KV
      try {
        // Use the current JWT to fetch the user's own profile
        const userResp = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
          headers: {
            Authorization: `Bearer ${rawToken}`,
            apikey: env.SUPABASE_ANON_KEY,
          },
        });
        if (userResp.ok) {
          const user = (await userResp.json()) as { created_at?: string };
          if (user.created_at) {
            createdAtEpoch = new Date(user.created_at).getTime() / 1000;
            // Cache for 90 days (won't change)
            await env.RATE_LIMITS.put(kvKey, String(Math.floor(createdAtEpoch)), {
              expirationTtl: 7776000, // 90 days
            });
          }
        }
      } catch {
        // Network error fetching user — fall through to iat fallback
      }
    }
  }

  // 4. Ultimate fallback: use iat (inaccurate but better than blocking)
  if (createdAtEpoch === null) {
    createdAtEpoch = payload.iat;
  }

  const now = Date.now() / 1000;
  const daysSinceCreation = (now - createdAtEpoch) / 86400;

  if (daysSinceCreation < TRIAL_DAYS) return "trial";

  return "expired";
}

// --- Helpers ---

function corsHeaders(): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
    "Access-Control-Max-Age": "86400",
  };
}

function errorResponse(
  status: number,
  code: string,
  message: string
): Response {
  return new Response(JSON.stringify({ error: { code, message } }), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...corsHeaders(),
    },
  });
}
