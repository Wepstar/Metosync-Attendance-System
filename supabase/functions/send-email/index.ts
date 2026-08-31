// Follow this setup guide to deploy to your Supabase project:
// https://supabase.com/docs/guides/functions
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

serve(async (req: Request) => {
  // 1. Handle CORS preflight requests
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // 2. Validate Authorization header presence
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

    // 3. Initialize Supabase client scoped to caller's JWT
    const supabaseClient = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: `Bearer ${token}` } },
      auth: { persistSession: false },
    });

    // 4. Cryptographically verify caller's JWT token
    const { data: { user }, error: authError } = await supabaseClient.auth.getUser(token);
    if (authError || !user) {
      return new Response(
        JSON.stringify({ error: "Unauthorized: Invalid or expired authentication token", details: authError?.message }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // 5. Verify the user is an active admin in admin_users (or platform admin)
    const { data: adminProfile, error: profileError } = await supabaseClient
      .from("admin_users")
      .select("id, company_id, role")
      .eq("id", user.id)
      .maybeSingle();

    if (profileError || !adminProfile) {
      return new Response(
        JSON.stringify({ error: "Forbidden: User is not authorized as a company admin" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // 6. Parse and validate request payload
    const { to, subject, html } = await req.json();

    if (!to || typeof to !== "string" || !to.includes("@")) {
      return new Response(
        JSON.stringify({ error: "Bad Request: A valid 'to' email address is required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!subject || typeof subject !== "string") {
      return new Response(
        JSON.stringify({ error: "Bad Request: 'subject' is required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!html || typeof html !== "string") {
      return new Response(
        JSON.stringify({ error: "Bad Request: 'html' content is required" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // 7. Send email via Resend (or configured provider)
    const resendApiKey = Deno.env.get("RESEND_API_KEY");
    const senderEmail = Deno.env.get("SENDER_EMAIL") || "Metosync <notifications@metosync.com>";

    if (!resendApiKey) {
      // If RESEND_API_KEY is not yet configured in project secrets, return a helpful notice
      console.warn("RESEND_API_KEY is not set. Email delivery is simulated in development.");
      return new Response(
        JSON.stringify({
          success: true,
          simulated: true,
          message: "Authorization verified. (Set RESEND_API_KEY secret in Supabase Dashboard to enable live sending)",
          to,
          subject,
        }),
        { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const emailResponse = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${resendApiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        from: senderEmail,
        to: [to],
        subject,
        html,
      }),
    });

    const emailResult = await emailResponse.json();

    if (!emailResponse.ok) {
      return new Response(
        JSON.stringify({ error: "Email delivery failed", details: emailResult }),
        { status: 502, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    return new Response(
      JSON.stringify({ success: true, id: emailResult.id }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (err: any) {
    return new Response(
      JSON.stringify({ error: "Internal Server Error", details: err?.message || String(err) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
