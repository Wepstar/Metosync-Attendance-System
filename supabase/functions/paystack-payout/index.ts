// Paystack payroll payout via Transfer API.
// Creates a transfer recipient (if needed) and initiates a transfer.
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

    const { payroll_entry_id, staff_id, amount, reason, bank_account_number, bank_code, bank_name } = await req.json();
    if (!payroll_entry_id || !staff_id || !amount || !bank_account_number || !bank_code || !bank_name) {
      return new Response(JSON.stringify({ error: "Missing required fields" }), { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const companyId = adminProfile.company_id;
    const { data: staff, error: staffError } = await client.from("staff").select("id, full_name, email, bank_account_number, bank_code, bank_name").eq("id", staff_id).maybeSingle();
    if (staffError || !staff) {
      return new Response(JSON.stringify({ error: "Staff not found" }), { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    // Update staff bank details if they changed.
    if (staff.bank_account_number !== bank_account_number || staff.bank_code !== bank_code || staff.bank_name !== bank_name) {
      await adminClient.from("staff").update({ bank_account_number, bank_code, bank_name }).eq("id", staff_id);
    }

    const { data: provider, error: providerError } = await adminClient.rpc("watchguard_get_payment_provider", {
      p_company_id: companyId,
      p_provider: "paystack",
    });
    if (providerError || !provider || !provider.secret_key_encrypted) {
      return new Response(JSON.stringify({ error: "Paystack not configured" }), { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const reference = `METOSYNC_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`.toUpperCase();

    // Initialize the payment request record.
    const { data: pr, error: prError } = await adminClient.rpc("payment_request_initiate", {
      p_company_id: companyId,
      p_staff_id: staff_id,
      p_payroll_entry_id: payroll_entry_id,
      p_amount: amount,
      p_currency: provider.currency || "GHS",
      p_reference: reference,
      p_provider: "paystack",
    });
    if (prError) {
      return new Response(JSON.stringify({ error: prError.message }), { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const secretKey = provider.secret_key_encrypted;
    const baseUrl = provider.is_live ? "https://api.paystack.co" : "https://api.paystack.co"; // same endpoint, test/live by key

    // 1. Create transfer recipient.
    const recipientRes = await fetch(`${baseUrl}/transferrecipient`, {
      method: "POST",
      headers: { Authorization: `Bearer ${secretKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        type: "nuban",
        name: staff.full_name,
        account_number: bank_account_number,
        bank_code: bank_code,
        currency: provider.currency || "GHS",
      }),
    });
    const recipientJson = await recipientRes.json();
    if (!recipientRes.ok || !recipientJson.status || !recipientJson.data?.recipient_code) {
      await adminClient.rpc("payment_request_update", { p_reference: reference, p_status: "failed", p_metadata: { error: recipientJson } });
      return new Response(JSON.stringify({ error: "Paystack recipient creation failed", details: recipientJson }), { status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const recipientCode = recipientJson.data.recipient_code;

    // 2. Initiate transfer.
    const transferRes = await fetch(`${baseUrl}/transfer`, {
      method: "POST",
      headers: { Authorization: `Bearer ${secretKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        source: "balance",
        reason: reason || "Metosync payroll payout",
        amount: Math.round(amount * 100),
        recipient: recipientCode,
        reference,
      }),
    });
    const transferJson = await transferRes.json();

    // Test mode often succeeds immediately; live may require OTP finalize.
    if (!transferRes.ok || !transferJson.status) {
      await adminClient.rpc("payment_request_update", { p_reference: reference, p_status: "failed", p_metadata: { error: transferJson } });
      return new Response(JSON.stringify({ error: "Paystack transfer initiation failed", details: transferJson }), { status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" } });
    }

    const transferData = transferJson.data;
    if (transferData?.status === "success" || transferData?.status === "pending") {
      await adminClient.rpc("payment_request_update", {
        p_reference: reference,
        p_status: transferData.status === "success" ? "completed" : "processing",
        p_provider_reference: transferData.transfer_code,
        p_metadata: { recipient_code: recipientCode, transfer: transferData },
      });
    }

    return new Response(
      JSON.stringify({ success: true, reference, transfer: transferData, requires_otp: transferData?.status === "otp" }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (err: any) {
    return new Response(JSON.stringify({ error: "Internal Server Error", details: err?.message || String(err) }), { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } });
  }
});
