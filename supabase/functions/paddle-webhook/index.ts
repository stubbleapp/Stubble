import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { createHmac } from "https://deno.land/std@0.168.0/node/crypto.ts";

const PADDLE_WEBHOOK_SECRET = Deno.env.get("PADDLE_WEBHOOK_SECRET")!;
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

interface PaddleWebhookEvent {
  event_type?: string;
  eventType?: string;
  data: {
    id: string;
    custom_data?: {
      user_id?: string;
    };
    customData?: {
      user_id?: string;
    };
    [key: string]: unknown;
  };
}

serve(async (req: Request): Promise<Response> => {
  // Only allow POST
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405 });
  }

  const body = await req.text();
  const signature = req.headers.get("paddle-signature");

  // Verify webhook signature (Paddle v2 API uses ts;h1=...)
  // TEMPORARY: Skip verification for testing (remove before production!)
  const skipVerification = Deno.env.get("SKIP_SIGNATURE_VERIFICATION") === "true";
  if (!skipVerification && !verifySignature(body, signature)) {
    console.error("Invalid webhook signature");
    return new Response("Invalid signature", { status: 401 });
  }

  let event: PaddleWebhookEvent;
  try {
    event = JSON.parse(body);
  } catch {
    console.error("Failed to parse webhook body");
    return new Response("Invalid JSON", { status: 400 });
  }

  // Extract user ID from custom_data (handle both snake_case and camelCase)
  const customData = event.data.custom_data || event.data.customData || {};
  const userId = customData.user_id;
  if (!userId) {
    console.error("No user_id in webhook payload:", JSON.stringify(event.data));
    return new Response("Missing user_id in custom_data", { status: 400 });
  }

  // Handle both event_type and eventType
  const eventType = event.event_type || event.eventType || "";

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_KEY, {
    auth: {
      autoRefreshToken: false,
      persistSession: false,
    },
  });

  console.log(`Processing ${eventType} for user ${userId}`);

  try {
    switch (eventType) {
      case "subscription.activated":
      case "subscription.resumed": {
        const { error } = await supabase.auth.admin.updateUserById(userId, {
          user_metadata: {
            subscription_tier: "pro",
            paddle_subscription_id: event.data.id,
            paddle_status: "active",
          },
        });
        if (error) throw error;
        console.log(`User ${userId} upgraded to pro`);
        break;
      }

      case "subscription.canceled":
      case "subscription.paused": {
        const status =
          event.event_type === "subscription.canceled" ? "canceled" : "paused";
        const { error } = await supabase.auth.admin.updateUserById(userId, {
          user_metadata: {
            subscription_tier: null,
            paddle_status: status,
          },
        });
        if (error) throw error;
        console.log(`User ${userId} subscription ${status}`);
        break;
      }

      case "subscription.past_due": {
        const { error } = await supabase.auth.admin.updateUserById(userId, {
          user_metadata: {
            paddle_status: "past_due",
          },
        });
        if (error) throw error;
        console.log(`User ${userId} subscription past_due`);
        break;
      }

      case "subscription.updated": {
        // Plan change — ensure tier is still pro
        const { error } = await supabase.auth.admin.updateUserById(userId, {
          user_metadata: {
            subscription_tier: "pro",
            paddle_subscription_id: event.data.id,
            paddle_status: "active",
          },
        });
        if (error) throw error;
        console.log(`User ${userId} subscription updated`);
        break;
      }

      default:
        console.log(`Unhandled event type: ${event.event_type}`);
    }
  } catch (error) {
    console.error(`Failed to update user ${userId}:`, error);
    return new Response("Internal error", { status: 500 });
  }

  return new Response("OK", { status: 200 });
});

function verifySignature(body: string, signature: string | null): boolean {
  if (!signature || !PADDLE_WEBHOOK_SECRET) {
    return false;
  }

  // Parse Paddle v2 signature format: ts=timestamp;h1=hash
  const parts: Record<string, string> = {};
  for (const part of signature.split(";")) {
    const [key, value] = part.split("=");
    if (key && value) {
      parts[key] = value;
    }
  }

  const ts = parts["ts"];
  const h1 = parts["h1"];
  if (!ts || !h1) {
    return false;
  }

  // Compute expected signature: HMAC-SHA256(ts:body)
  const payload = `${ts}:${body}`;
  const expected = createHmac("sha256", PADDLE_WEBHOOK_SECRET)
    .update(payload)
    .digest("hex");

  // Timing-safe comparison
  if (expected.length !== h1.length) {
    return false;
  }
  let mismatch = 0;
  for (let i = 0; i < expected.length; i++) {
    mismatch |= expected.charCodeAt(i) ^ h1.charCodeAt(i);
  }
  return mismatch === 0;
}
