// Flutterwave payroll payout via Transfers API.
// Supports Ghana bank and mobile money (MoMo) payouts.
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
    const authHeader = req.headers.get("Authorization");
    if (!authHeader || !authHeader.startsWith("Bearer ")) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const token = authHeader.replace("Bearer ", "").trim();
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

    const client = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: `Bearer ${token}` } },
      auth: { persistSession: false },
    });
    const adminClient = createClient(supabaseUrl, supabaseServiceKey || supabaseAnonKey, { auth: { persistSession: false } });

    const { data: { user }, error: authError } = await client.auth.getUser(token);
    if (authError || !user) {
      return new Response(JSON.stringify({ error: "Invalid token" }), { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const { data: adminProfile } = await client.from("admin_users").select("id, company_id, role").eq("id", user.id).maybeSingle();
    if (!adminProfile) {
      return new Response(JSON.stringify({ error: "Not an admin" }), { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const { payroll_entry_id, staff_id, amount, reason, method = "bank", bank_account_number, bank_code, bank_name } = await req.json();
    if (!payroll_entry_id || !staff_id || !amount || !bank_account_number || !bank_code || !bank_name) {
      return new Response(JSON.stringify({ error: "Missing required fields" }), { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const transferMethod = method === "momo" ? "mobile_money" : "bank";
    const validMomoProviders = new Set(["MTN", "VOD", "TGO"]);
    if (transferMethod === "mobile_money" && !validMomoProviders.has(bank_code.toUpperCase())) {
      return new Response(JSON.stringify({ error: "Invalid MoMo provider code. Use MTN, VOD, or TGO" }), { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const companyId = adminProfile.company_id;
    const { data: staff, error: staffError } = await client.from("staff").select("id, full_name, bank_account_number, bank_code, bank_name").eq("id", staff_id).maybeSingle();
    if (staffError || !staff) {
      return new Response(JSON.stringify({ error: "Staff not found" }), { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    if (staff.bank_account_number !== bank_account_number || staff.bank_code !== bank_code || staff.bank_name !== bank_name) {
      await adminClient.from("staff").update({ bank_account_number, bank_code, bank_name }).eq("id", staff_id);
    }

    const { data: provider, error: providerError } = await adminClient.rpc("watchguard_get_payment_provider", {
      p_company_id: companyId,
      p_provider: "flutterwave",
    });
    if (providerError || !provider || !provider.secret_key_encrypted) {
      return new Response(JSON.stringify({ error: "Flutterwave not configured" }), { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const reference = `METOSYNC_FW_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`.toUpperCase();

    const { data: pr, error: prError } = await adminClient.rpc("payment_request_initiate", {
      p_company_id: companyId,
      p_staff_id: staff_id,
      p_payroll_entry_id: payroll_entry_id,
      p_amount: amount,
      p_currency: provider.currency || "GHS",
      p_reference: reference,
      p_provider: "flutterwave",
    });
    if (prError) {
      return new Response(JSON.stringify({ error: prError.message }), { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const secretKey = provider.secret_key_encrypted;
    const accountBank = transferMethod === "mobile_money" ? bank_code.toUpperCase() : bank_code;

    const transferRes = await fetch("https://api.flutterwave.com/v3/transfers", {
      method: "POST",
      headers: { Authorization: `Bearer ${secretKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        account_bank: accountBank,
        account_number: bank_account_number,
        amount: amount,
        currency: provider.currency || "GHS",
        narration: reason || "Metosync payroll payout",
        reference,
      }),
    });
    const transferJson = await transferRes.json();

    if (!transferRes.ok || transferJson.status !== "success") {
      await adminClient.rpc("payment_request_update", { p_reference: reference, p_status: "failed", p_metadata: { error: transferJson } });
      return new Response(JSON.stringify({ error: "Flutterwave transfer failed", details: transferJson }), { status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const transferData = transferJson.data;
    const paymentStatus = transferData?.status === "SUCCESSFUL" ? "completed" : "processing";

    await adminClient.rpc("payment_request_update", {
      p_reference: reference,
      p_status: paymentStatus,
      p_provider_reference: transferData?.id?.toString() || transferData?.reference,
      p_metadata: { method: transferMethod, transfer: transferData },
    });

    return new Response(
      JSON.stringify({ success: true, reference, transfer: transferData, status: paymentStatus }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (err: any) {
    return new Response(JSON.stringify({ error: "Internal Server Error", details: err?.message || String(err) }), { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  }
});
