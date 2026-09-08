// Phase 1: Watchguard notification dispatcher.
// Sends email (Resend), SMS (Twilio), or webhook POST based on an escalation payload.
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
    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

    const adminClient = createClient(supabaseUrl, supabaseServiceKey || supabaseAnonKey, {
      auth: { persistSession: false },
    });

    const body = await req.json();
    const { escalation_id, channel_type, endpoint, company_name, severity, rule_name, description, proposed_action, metadata } = body;

    if (!escalation_id || !channel_type || !endpoint) {
      return new Response(
        JSON.stringify({ error: "Missing escalation_id, channel_type, or endpoint" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const subject = `[${severity.toUpperCase()}] Watchguard Alert — ${company_name || 'Metosync'}`;
    const html = `
      <div style="font-family: sans-serif; max-width: 600px; margin: auto;">
        <h2 style="color: ${severity === 'critical' ? '#dc2626' : severity === 'warning' ? '#d97706' : '#2563eb'}">${severity.toUpperCase()} Alert</h2>
        <p><strong>Company:</strong> ${escapeHtml(company_name || 'Unknown')}</p>
        <p><strong>Rule:</strong> ${escapeHtml(rule_name || '')}</p>
        <p><strong>Description:</strong> ${escapeHtml(description || '')}</p>
        <p><strong>Proposed AI action:</strong> ${escapeHtml(proposed_action || 'none')}</p>
        <p style="font-size: 12px; color: #6b7280;">This is an automated alert from Metosync Watchguard.</p>
      </div>
    `;

    let result: any = { dispatched: false };

    if (channel_type === "email") {
      const resendApiKey = Deno.env.get("RESEND_API_KEY");
      const senderEmail = Deno.env.get("SENDER_EMAIL") || "Metosync Watchguard <notifications@metosync.com>";

      if (!resendApiKey) {
        result = { dispatched: true, simulated: true, note: "RESEND_API_KEY not set" };
      } else {
        const emailResponse = await fetch("https://api.resend.com/emails", {
          method: "POST",
          headers: {
            "Authorization": `Bearer ${resendApiKey}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            from: senderEmail,
            to: [endpoint],
            subject,
            html,
          }),
        });
        const emailResult = await emailResponse.json();
        result = { dispatched: emailResponse.ok, channel: "email", provider_response: emailResult };
      }
    } else if (channel_type === "sms") {
      const twilioSid = Deno.env.get("TWILIO_ACCOUNT_SID");
      const twilioToken = Deno.env.get("TWILIO_AUTH_TOKEN");
      const twilioFrom = Deno.env.get("TWILIO_PHONE_NUMBER");

      if (!twilioSid || !twilioToken || !twilioFrom) {
        result = { dispatched: true, simulated: true, note: "Twilio credentials not set" };
      } else {
        const message = `${severity.toUpperCase()} Watchguard alert for ${company_name || 'Metosync'}: ${description}`;
        const twilioResponse = await fetch(`https://api.twilio.com/2010-04-01/Accounts/${twilioSid}/Messages.json`, {
          method: "POST",
          headers: {
            "Authorization": "Basic " + btoa(`${twilioSid}:${twilioToken}`),
            "Content-Type": "application/x-www-form-urlencoded",
          },
          body: new URLSearchParams({ From: twilioFrom, To: endpoint, Body: message }),
        });
        const twilioResult = await twilioResponse.json();
        result = { dispatched: twilioResponse.ok, channel: "sms", provider_response: twilioResult };
      }
    } else if (channel_type === "webhook") {
      const webhookResponse = await fetch(endpoint, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Metosync-Event": "watchguard.escalation",
          "X-Metosync-Severity": severity,
          ...(metadata?.headers || {}),
        },
        body: JSON.stringify(body),
      });
      const text = await webhookResponse.text();
      result = { dispatched: webhookResponse.ok, channel: "webhook", status: webhookResponse.status, body_preview: text.slice(0, 500) };
    } else {
      return new Response(
        JSON.stringify({ error: `Unsupported channel_type: ${channel_type}` }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const status = result.dispatched ? "sent" : "failed";
    const { data: markData, error: markError } = await adminClient.rpc("watchguard_mark_escalation", {
      p_escalation_id: escalation_id,
      p_status: status,
      p_response_body: JSON.stringify(result),
    });

    if (markError) {
      return new Response(
        JSON.stringify({ error: "Dispatch succeeded but failed to mark escalation", details: markError.message, result }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    return new Response(
      JSON.stringify({ success: true, status, result, escalation: markData }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (err: any) {
    return new Response(
      JSON.stringify({ error: "Internal Server Error", details: err?.message || String(err) }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});

function escapeHtml(value: string) {
  return String(value ?? "").replace(/[&<>'"]/g, char => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[char] || char));
}
