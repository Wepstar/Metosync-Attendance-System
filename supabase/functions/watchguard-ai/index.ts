// AI-facing entry point for the Watchguard remediation layer.
// Only exposes named actions. No raw SQL. Requires idempotency key + reason.
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const VALID_ACTIONS = [
  "flag_for_review",
  "escalate_to_human",
  "correct_attendance_record",
  "retry_payment",
  "reverse_payment",
];

serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    const authHeader = req.headers.get("Authorization");
    if (!authHeader || !authHeader.startsWith("Bearer ")) {
      return new Response(
        JSON.stringify({ error: "Unauthorized: Missing or invalid Authorization header" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const token = authHeader.replace("Bearer ", "").trim();
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";

    const supabaseClient = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: `Bearer ${token}` } },
      auth: { persistSession: false },
    });

    const { data: { user }, error: authError } = await supabaseClient.auth.getUser(token);
    if (authError || !user) {
      return new Response(
        JSON.stringify({ error: "Unauthorized: Invalid or expired token", details: authError?.message }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { data: adminProfile, error: profileError } = await supabaseClient
      .from("admin_users")
      .select("id, company_id, role")
      .eq("id", user.id)
      .maybeSingle();

    if (profileError || !adminProfile) {
      return new Response(
        JSON.stringify({ error: "Forbidden: Not an admin user" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const body = await req.json();
    const { company_id, action, payload, idempotency_key, reason, model_identity } = body;

    if (!company_id || typeof company_id !== "string") {
      return new Response(
        JSON.stringify({ error: "Bad Request: 'company_id' is required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
    if (!VALID_ACTIONS.includes(action)) {
      return new Response(
        JSON.stringify({ error: `Bad Request: 'action' must be one of ${VALID_ACTIONS.join(", ")}` }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
    if (!idempotency_key || typeof idempotency_key !== "string") {
      return new Response(
        JSON.stringify({ error: "Bad Request: 'idempotency_key' is required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
    if (!reason || typeof reason !== "string" || reason.length < 5) {
      return new Response(
        JSON.stringify({ error: "Bad Request: 'reason' is required and must be at least 5 characters" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
    if (!model_identity || typeof model_identity !== "string") {
      return new Response(
        JSON.stringify({ error: "Bad Request: 'model_identity' is required (e.g. 'gpt-4o-2024-05-13')" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Only platform owners can call on any company; company admins only on their own company.
    if (adminProfile.role !== "owner" && adminProfile.company_id !== company_id) {
      return new Response(
        JSON.stringify({ error: "Forbidden: You can only act on your own company" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const { data, error } = await supabaseClient.rpc("watchguard_ai_action", {
      p_company_id: company_id,
      p_action: action,
      p_payload: payload ?? {},
      p_idempotency_key: idempotency_key,
      p_reason: reason,
      p_model_identity: model_identity,
    });

    if (error) {
      return new Response(
        JSON.stringify({ error: "Watchguard action failed", details: error.message }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    return new Response(
      JSON.stringify({ success: true, result: data }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (err: any) {
    return new Response(
      JSON.stringify({ error: "Internal Server Error", details: err?.message || String(err) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
