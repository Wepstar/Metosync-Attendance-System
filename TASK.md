# TASK.md — living build checklist

Check items off as they're completed. This file is the actual answer to
"what's done" at any point — more reliable than memory across sessions.

## ✅ Done — September 2026 security audit & hardening

- [x] Reviewed and fixed `welcome.html` (RPC error handling, double-submit
      guard)
- [x] Reviewed and fixed `signup.html` (form no longer wipes on validation
      error, input escaping, guard-check errors surfaced honestly,
      double-submit guard, logo failure no longer strands a successful
      signup, orphaned-auth-account case now signs out with a clear message)
- [x] Full backend function audit — **51 functions** fixed for identity
      spoofing or missing authorization:
  - [x] Admin/registry identity-spoofing fixes (9): `admin_deactivate`,
        `admin_update_role`, `registry_admin_update_role`,
        `registry_admin_deactivate`, `registry_admin_invite`,
        `watchguard_approve_action`, `watchguard_reject_action`,
        `payment_request_initiate`, `payment_request_update`
  - [x] Platform-wide data-leak fixes (4): `platform_company_health`,
        `platform_report_summary`, `platform_watch_guard_events`,
        `platform_watch_guard_report`
  - [x] Payroll data-leak fix (1): `payroll_payables`
  - [x] Staff/admin management fixes (11): `admin_accept_invite`,
        `admin_approve_device`, `admin_create_invite`,
        `admin_get_latest_locations`, `admin_get_notifications`,
        `admin_list_company`, `admin_request_location_check`,
        `admin_request_location_for_all`, `admin_send_notification`,
        `create_staff`, `update_staff_profile`
  - [x] Registry/reporting fixes (6): `create_onboarding_invite`,
        `registry_admin_list_all`, `report_attendance_summary`,
        `report_payments_summary`, `report_payroll_summary`,
        `report_staff_summary`
  - [x] Watchguard channel security (2): `watchguard_create_channel`,
        `watchguard_delete_channel`
  - [x] Watch guard report/chat/log/API fixes (4): `watch_guard_report`,
        `watch_guard_log_event`, `watch_guard_chat`, `watch_guard_api`
  - [x] **Payment provider secret protection (3, most severe finding)**:
        `watchguard_set_payment_provider`, `watchguard_get_payment_provider`,
        `watchguard_list_payment_providers`
  - [x] Platform config protection (2): `watchguard_get_config`,
        `watchguard_set_config`
  - [x] Cross-company list/report leak fixes (6): `watchguard_open_findings`,
        `watchguard_payment_stats`, `watchguard_list_payment_requests`,
        `watchguard_event_log`, `watchguard_list_channels`,
        `watchguard_pending_escalations`
  - [x] Escalation/channel integrity fixes (2): `watchguard_mark_escalation`,
        `watchguard_update_channel`
  - [x] Platform gate-password fix (1): `set_section_password`
- [x] RLS policy review (20 policies) — 3 critical bypasses removed:
      `admin_users` self-role-escalation, `companies` billing-field bypass,
      `onboarding_invites` invite-code leak to any authenticated user
- [x] Confirmed no table has RLS fully disabled (24 tables are
      enabled-with-no-policy, which fails closed safely)
- [x] Confirmed `watchguard_evaluate_rules`/`watchguard_escalate` are wired
      into automatic DB triggers — deliberately left ungated to avoid
      breaking the pipeline; flagged for an idempotency-based fix instead
- [x] Identified live payment provider secret was a Paystack **test** key
      (not live), not attached to any company — lower real-world exposure
- [x] Rotated the exposed test key (walkthrough provided)
- [x] Dashboard-level security checklist written (leaked-password
      protection, MFA, session lifetimes, rate limits, Cloudflare, CORS) —
      pending manual action, not toggleable via available tools
- [x] `README.md`, `PRD.md`, `CLAUDE.md`, `PLANNING.md`, `TASK.md` drafted

## ⬜ Not yet done — open security items

- [ ] Remove the dormant `METO-` testing-mode bypass in
      `check_onboarding_invite` / `create_company_and_owner`
- [ ] Harmonize `onboarding_invites` invite-creation policy
      (`system_role = 'super_admin'`) with `is_platform_admin()`
- [ ] Audit edge functions
- [ ] Audit storage bucket policies
- [ ] Audit auth configuration
- [ ] Audit migration history
- [ ] Fix minor enumeration risks (`staff_start_login`, `check_staff_geofence`)
- [ ] Add idempotency protection to `watchguard_evaluate_rules` (prevent
      duplicate findings from a repeated/guessed `event_id`)
- [ ] Resolve dashboard-level checklist items (manual, in Supabase dashboard)
- [ ] Set up live Paystack key properly when that time comes (reminder is
      standing)

## ⬜ Phase 1 — Foundation

- [ ] **Administrator workspace**
  - [ ] Backend: confirm/extend existing staff, sites, attendance, leave,
        onboarding RPCs for dedicated workspace use
  - [ ] Backend: role/permission wiring for Administrator workspace access
  - [ ] Devin prompt written and sent
  - [ ] Frontend built
- [ ] **Finance & Payroll Manager workspace**
  - [ ] Backend: extend payroll/payment/deduction RPCs with budgets
  - [ ] Backend: tax compliance data model + RPCs
  - [ ] Devin prompt written and sent
  - [ ] Frontend built
- [ ] **Executive Director workspace**
  - [ ] Backend: reporting/analytics RPCs over Administrator + Finance data
  - [ ] Backend: approvals routing (high-risk actions surfaced here)
  - [ ] Devin prompt written and sent
  - [ ] Frontend built

## ⬜ Phase 2 — Operations

- [ ] Stores & Inventory workspace
- [ ] Operations Manager workspace
- [ ] Sales & Marketing workspace

## ⬜ Phase 3 — Support & Growth

- [ ] Resolve Compliance & Legal / Security & Access / Watchguard overlap
      (decide before building either)
- [ ] Customer Service workspace
- [ ] Procurement workspace
- [ ] Compliance & Legal workspace
- [ ] Training & Development workspace
- [ ] Security & Access workspace

## ⬜ Phase 4 — Executive Suite

- [ ] Board & Governance workspace
- [ ] Audit & Internal Control workspace (build as a Watchguard dashboard)
- [ ] Strategy & Planning workspace
