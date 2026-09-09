// Flutterwave webhook handler for transfer events.
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
    const signature = req.headers.get("HTTP_VERIF_HASH") || req.headers.get("verif-hash");

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
      p_provider: "flutterwave",
    });
    if (providerError || !provider || !provider.webhook_secret) {
      return new Response(JSON.stringify({ error: "Provider not found" }), { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    if (signature !== provider.webhook_secret) {
      return new Response(JSON.stringify({ error: "Invalid webhook signature" }), { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const event = payload.event;
    const dataStatus = payload?.data?.status;
    let status = "pending";
    if (event === "transfer.completed" || dataStatus === "SUCCESSFUL") status = "completed";
    else if (event === "transfer.failed" || dataStatus === "FAILED") status = "failed";
    else if (event === "transfer.reversed" || dataStatus === "REVERSED") status = "reversed";

    const { error: updateError } = await adminClient.rpc("payment_request_update", {
      p_reference: reference,
      p_status: status,
      p_provider_reference: payload?.data?.id?.toString() || payload?.data?.reference,
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
