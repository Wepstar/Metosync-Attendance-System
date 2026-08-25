// shared.js — one place for Supabase setup and helpers used across every page.
// Fix something here, it's fixed everywhere — no more copy-paste drift.

const SUPABASE_URL = "https://lqgdyjvfirdhstcmepyr.supabase.co/rest/v1/"; // Project Settings → API
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxxZ2R5anZmaXJkaHN0Y21lcHlyIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODc1OTAxODQsImV4cCI6MjEwMzE2NjE4NH0.PUvRfQRMKjosn2-LyZWJU1wEOREFJ3jA4Z4TOGxEBA0";  // Project Settings → API

const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

function toggleEye(id, btn) {
  const input = document.getElementById(id);
  const showing = input.type === "text";
  input.type = showing ? "password" : "text";
  btn.textContent = showing ? "👁" : "🙈";
}

async function getSessionAndRole() {
  const { data: sessionData } = await sb.auth.getSession();
  if (!sessionData.session) return { session: null, isAdmin: false, role: null };
  const { data: isAdmin } = await sb.rpc('is_platform_admin');
  if (!isAdmin) return { session: sessionData.session, isAdmin: false, role: null };
  const { data: role } = await sb.rpc('platform_my_role');
  return { session: sessionData.session, isAdmin: true, role };
}