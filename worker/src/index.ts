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

const TRIAL_DAYS = 5;

// Gemini API base URL
const GEMINI_BASE = "https://generativelanguage.googleapis.com";

// Maximum response size from Gemini (50MB)
const MAX_RESPONSE_SIZE = 50 * 1024 * 1024;

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
      // Normalize path to prevent traversal attacks (e.g., /v1beta/../admin/)
      const normalizedPath = normalizePath(url.pathname);
      if (!normalizedPath.startsWith("/v1beta/models/") && !normalizedPath.startsWith("/v1/models/")) {
        return errorResponse(400, "invalid_path", "Only Gemini model endpoints are allowed");
      }
      // Reject oversized payloads before forwarding to Gemini (10MB limit)
      const contentLength = request.headers.get("Content-Length");
      if (contentLength && parseInt(contentLength) > 10 * 1024 * 1024) {
        return errorResponse(413, "payload_too_large", "Request body exceeds 10MB limit");
      }

      const geminiUrl = `${GEMINI_BASE}${normalizedPath}${url.search}`;

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

      // 7. Stream response back with size limiting
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

      // Wrap response body with size-limiting transform stream
      const limitedBody = geminiResponse.body
        ? createSizeLimitedStream(geminiResponse.body, MAX_RESPONSE_SIZE)
        : null;

      return new Response(limitedBody, {
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
    if (parts.length !== 3) {
      console.warn("JWT verification failed: invalid token format (expected 3 parts)");
      return null;
    }

    const [headerB64, payloadB64, signatureB64] = parts;

    // Check algorithm and extract kid for key matching
    const headerJson = new TextDecoder().decode(base64UrlDecode(headerB64));
    const header = JSON.parse(headerJson) as { alg?: string; kid?: string };
    if (header.alg !== "ES256") {
      console.warn(`JWT verification failed: unsupported algorithm ${header.alg}`);
      return null;
    }

    const key = await getJWK(header.kid);
    if (!key) {
      console.warn(`JWT verification failed: could not fetch JWKS key (kid: ${header.kid})`);
      return null;
    }

    const data = new TextEncoder().encode(`${headerB64}.${payloadB64}`);

    // ES256 signatures in JWTs are raw r||s (64 bytes), not DER-encoded
    const signature = base64UrlDecode(signatureB64);

    const valid = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      key,
      signature,
      data
    );
    if (!valid) {
      console.warn("JWT verification failed: signature invalid");
      return null;
    }

    // Decode payload
    const payloadJson = new TextDecoder().decode(base64UrlDecode(payloadB64));
    return JSON.parse(payloadJson) as JWTPayload;
  } catch (error) {
    console.warn("JWT verification failed: exception during verification", error);
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

  // 4. Ultimate fallback: use iat and cache it so subsequent requests are consistent.
  // Without caching, each token refresh would reset the trial start to the new iat,
  // causing the trial to appear to never expire (or reset unexpectedly).
  if (createdAtEpoch === null) {
    console.warn(`getTier: no trial_start for user ${payload.sub}, caching iat as fallback`);
    const kvKey = `created:${payload.sub}`;
    createdAtEpoch = payload.iat;
    // Cache this permanently so the trial calculation is consistent across refreshes
    await env.RATE_LIMITS.put(kvKey, String(Math.floor(createdAtEpoch)), {
      expirationTtl: 7776000, // 90 days
    });
  }

  const now = Date.now() / 1000;
  const daysSinceCreation = (now - createdAtEpoch) / 86400;

  if (daysSinceCreation < TRIAL_DAYS) return "trial";

  return "expired";
}

// --- Helpers ---

function corsHeaders(): Record<string, string> {
  return {
    "Access-Control-Allow-Origin": "https://stubble.ai",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
    "Access-Control-Max-Age": "86400",
    "Strict-Transport-Security": "max-age=31536000; includeSubDomains",
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

/**
 * Normalize a URL path to resolve .. and . segments, preventing path traversal.
 * For example: /v1beta/../admin/ becomes /admin/
 */
function normalizePath(path: string): string {
  const segments = path.split("/");
  const normalized: string[] = [];

  for (const segment of segments) {
    if (segment === "..") {
      // Go up one directory (but don't go above root)
      normalized.pop();
    } else if (segment !== "." && segment !== "") {
      normalized.push(segment);
    }
  }

  return "/" + normalized.join("/");
}

/**
 * Wraps a ReadableStream with a size limit. Aborts the stream if the limit is exceeded.
 */
function createSizeLimitedStream(
  source: ReadableStream<Uint8Array>,
  maxSize: number
): ReadableStream<Uint8Array> {
  let totalBytes = 0;

  return source.pipeThrough(
    new TransformStream<Uint8Array, Uint8Array>({
      transform(chunk, controller) {
        totalBytes += chunk.byteLength;
        if (totalBytes > maxSize) {
          console.warn(`Response size limit exceeded: ${totalBytes} > ${maxSize}`);
          controller.error(new Error("Response too large"));
          return;
        }
        controller.enqueue(chunk);
      },
    })
  );
}
