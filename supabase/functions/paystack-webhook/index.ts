// Paystack webhook handler for transfer and charge events.
// Verifies HMAC-SHA512 signature before updating payment records.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const raw = await req.text();
    const signature = req.headers.get("x-paystack-signature");
    if (!signature) {
      return new Response(JSON.stringify({ error: "Missing signature" }), { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const adminClient = createClient(supabaseUrl, supabaseServiceKey, { auth: { persistSession: false } });

    let payload: any;
    try {
      payload = JSON.parse(raw);
    } catch {
      return new Response(JSON.stringify({ error: "Invalid JSON body" }), { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const reference = payload?.data?.reference;
    if (!reference) {
      return new Response(JSON.stringify({ error: "Missing reference" }), { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const { data: pr, error: prError } = await adminClient.rpc("payment_request_by_reference", { p_reference: reference });
    if (prError || !pr) {
      return new Response(JSON.stringify({ error: "Payment request not found", details: prError?.message }), { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }
    const paymentRequest = Array.isArray(pr) ? pr[0] : pr;

    const { data: provider, error: providerError } = await adminClient.rpc("watchguard_get_payment_provider", {
      p_company_id: paymentRequest.company_id,
      p_provider: "paystack",
    });
    if (providerError || !provider || !provider.secret_key_encrypted) {
      return new Response(JSON.stringify({ error: "Provider not found" }), { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const secret = provider.secret_key_encrypted;
    const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-512" }, false, ["sign"]);
    const sigBytes = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(raw));
    const computed = Array.from(new Uint8Array(sigBytes)).map(b => b.toString(16).padStart(2, "0")).join("");

    if (!constantTimeCompare(computed, signature)) {
      return new Response(JSON.stringify({ error: "Invalid signature" }), { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const event = payload.event;
    let status = "pending";
    if (event === "charge.success" || event === "transfer.success") status = "completed";
    else if (event === "transfer.failed" || event === "charge.failed") status = "failed";
    else if (event === "transfer.reversed") status = "reversed";

    const { error: updateError } = await adminClient.rpc("payment_request_update", {
      p_reference: reference,
      p_status: status,
      p_provider_reference: payload?.data?.id?.toString() || payload?.data?.transfer_code,
      p_metadata: payload,
    });

    if (updateError) {
      return new Response(JSON.stringify({ error: "Failed to update payment", details: updateError.message }), { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    return new Response(JSON.stringify({ success: true, status }), { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  } catch (err: any) {
    return new Response(JSON.stringify({ error: "Internal Server Error", details: err?.message || String(err) }), { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  }
});

function constantTimeCompare(a: string, b: string) {
  if (a.length !== b.length) return false;
  let result = 0;
  for (let i = 0; i < a.length; i++) {
    result |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return result === 0;
}
