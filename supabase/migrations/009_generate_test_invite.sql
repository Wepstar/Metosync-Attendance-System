-- Generate a fresh onboarding test invite valid for 30 days.
-- Run this in Supabase SQL Editor after the onboarding schema is deployed.
-- The returned code can be used immediately on the welcome page.
SELECT create_onboarding_invite() AS test_invite_code;
