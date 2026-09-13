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

## ✅ Done — role invitation flow (decision + audit trail)

- [x] Decided: signup stays minimal (owner only) — no role/position selection
      at signup. Owner invites named people to specific roles afterward, in
      Admin.
- [x] Fixed a real gap: `admin_create_invite` and `admin_accept_invite`
      previously did not write to `company_activity_log`, so inviting/
      accepting a role never appeared in the platform Registry. Both now
      call `log_company_activity`, so Registry's "activity" feed shows
      `admin_invited` and `admin_invite_accepted` events automatically
      (confirmed `registry_list_all_activity`/`registry_list_company_activity`
      already read from that table — no Registry-side change needed)
- [ ] Devin: build the "Invite team member" UI in Admin (role dropdown +
      email, Invenity-style tile grid for role selection) — prompt below
- [ ] Extend `SYSTEM_ROLES` beyond the current four (`super_admin`,
      `payroll_manager`, `hr`, `view_only`) once new workspace roles are
      finalized (blocks adding Payroll Manager/Administrator/Executive
      Director as literal selectable roles, not just workspace names)

## ✅ Done — portfolio catalog (Registry-editable roles)

- [x] **Correction**: the role list given to Devin in the previous prompt was
      wrong — it described `admin_users.system_role` (a mostly-unused,
      separate column) instead of `admin_users.role`, which is what
      `admin_create_invite` actually sets. Devin should NOT build against
      "Super Admin/Payroll Manager/HR/View-Only" as previously stated.
- [x] Created `portfolios` catalog table (code, display_name, description,
      is_active, sort_order), replacing the hardcoded CHECK constraint on
      `admin_users.role` with a proper foreign key — adding a new portfolio
      going forward means inserting a row via Registry, not a migration
- [x] Seeded with all 5 legacy roles (owner, admin, manager,
      payroll_officer, viewer — preserved, no existing data broken) plus 13
      new portfolios: Executive Director, Stores & Inventory, Operations
      Manager, Sales & Marketing, Customer Service, Procurement, Compliance
      & Legal, Training & Development, Security & Access, Board &
      Governance, Audit & Internal Control, Strategy & Planning
  - [x] Note: reused existing `admin` role/permissions as "Administrator"
        rather than adding a duplicate code — worth confirming this is right
- [x] Added `registry_list_portfolios()`, `registry_add_portfolio()`,
      `registry_set_portfolio_active()` (platform-admin gated, for Registry
      UI) and `list_active_portfolios()` (company-admin readable, for the
      invite dropdown)
- [ ] Devin: build Registry's portfolio management screen (list/add/
      deactivate) and update the invite-role dropdown to call
      `list_active_portfolios()` instead of a hardcoded list

## ✅ Done — closing the last known critical items

- [x] Removed the dormant `METO-` testing-mode bypass from
      `check_onboarding_invite` and `create_company_and_owner` — both now
      require a genuine active, unused, unexpired invite row, no exceptions
- [x] **Found while fixing the above (more severe than originally flagged)**:
      `create_company_and_owner` sets `system_role = 'super_admin'` on every
      new company's owner — meaning the `onboarding_invites` "Platform
      admins can create invites" policy (which checked
      `system_role = 'super_admin'`) let **any company owner**, not just
      platform staff, directly insert new onboarding invite codes,
      bypassing `create_onboarding_invite`'s platform-admin gate via a
      different path. Policy now correctly checks `is_platform_admin()`
- [x] `create_company_and_owner` now explicitly sets `admin_users.role =
      'owner'` (previously relied on an implicit default, never set explicitly)
- [ ] Still open: harmonize remaining `system_role` usage elsewhere with the
      `is_platform_admin()`/`platform_admins` mechanism (lower urgency now
      that the one exploitable instance is fixed)
- [ ] Still open: edge functions, storage bucket policies, auth config,
      migration history audits; minor enumeration risks

## ✅ Done — Payroll workspace menu additions (backend)

- [x] Confirmed live page structure via `payroll.html` (fetched directly):
      a "Payroll workspace" with a numbered 3-step wizard — 01 General
      Payroll, 02 Taxes & Incentives, 03 Final Review
- [x] **Payroll History**: no new backend needed — existing
      `report_payroll_summary`, `payroll_periods`, and `payroll_entries`
      already hold everything needed. This is purely a Devin frontend task.
- [x] **Quit Pay (final settlement)**: built from scratch — no backend
      existed previously.
  - [x] `staff_quit_settlement_preview(p_staff_id, p_last_working_date)` —
        read-only, returns pro-rated final salary, leave entitlement/taken/
        unused days, leave payout, and a list of the staff member's active
        deductions (name + amount where set) for the admin to review
  - [x] `staff_process_quit_settlement(...)` — flexible per request: mode
        `'direct'` (admin enters one lump sum) or `'itemized'` (admin
        chooses which of final salary / leave payout / a deduction amount
        to include); creates a payment request, sets staff to inactive,
        logs to company_activity_log (→ visible in Registry)
  - [x] Calculation assumptions documented in the migration comments
        (simple pro-ration, full annual leave entitlement not tenure-
        pro-rated, GHS 30-day divisor) — flagged as adjustable, not
        presented as definitive HR/legal policy
- [ ] Devin: add "Payroll History" and "Quit Pay" as menu items in the
      Payroll workspace, alongside General Payroll/Taxes & Incentives/
      Final Review — prompt below

## ✅ Done — Flutterwave removal & menu ordering feedback

- [x] Removed `flutterwave` from the backend's allowed payment providers
      (`payment_providers_provider_check` now only permits paystack/stripe)
      — confirmed no company had a flutterwave row, so this was safe
- [x] Confirmed via direct page fetch that the Payroll workspace nav (General
      Payroll/Taxes & Incentives/Final Review) is JS-rendered, not static —
      "Quick Pay appearing twice" and Flutterwave in the UI weren't visible
      in the fetched markup, trusting user's direct browser observation
- [ ] Devin: fix duplicate "Quick Pay" menu entry, remove Flutterwave from
      any frontend provider list/dropdown, reorder the Payroll workspace
      menu to: General Payroll, Taxes & Incentives, Final Review, Quick
      Pay, Payroll History — and add "Reports" as a sub-item within Payroll
      History — prompt below

## ✅ Done — Attendance workspace menu additions (backend already existed)

- [x] Confirmed all four requested items map to existing, already-secured
      backend — no new migration needed, pure Devin frontend task:
      "Set Status for a Day" → `set_attendance_status`; "Location Checker"
      → `admin_get_latest_locations` + `admin_request_location_check` +
      `admin_request_location_for_all`; "Broadcast Notifications" →
      `admin_send_notification`; "Attendance for updated date" (viewing
      attendance for any chosen date, not just today) → `report_attendance_summary`
- [ ] Devin: add the four tabs inside Attendance — prompt below

## ✅ Done — Executive reports gap fixed, Registry invite already existed

- [x] Caught a gap in the earlier ED "Reports" spec — it omitted Payments
      Summary. Corrected: Executive's Reports tab now matches the existing
      Reports & Analytics section exactly (Attendance by Date, Payroll
      Summary, Payments Summary), reusing `report_attendance_summary`,
      `report_payroll_summary`, `report_payments_summary` — no new backend
- [x] Confirmed `registry_admin_invite(p_company_id, p_email, p_role)`
      already exists and is already platform-admin-gated (fixed in the
      original audit) — Metosync Registry staff generating invite codes on
      behalf of organizations needs zero new backend, just a Registry UI
- [x] **Decided**: company owners lose self-invite entirely. Revoked
      `admin_create_invite`'s EXECUTE grant from anon/authenticated (not
      just an internal check — the grant itself is gone, so it can't be
      quietly re-enabled by a future frontend call). Confirmed only
      service_role/postgres retain access. Team invites are now exclusively
      a Registry/Metosync-staff action via `registry_admin_invite`.
- [ ] Devin: the earlier "Invite team member" screen built for company
      Admin should be REMOVED — that path no longer works and will error if
      left in place. Only the Registry-side "Generate team invite" screen
      (from the prior prompt) should exist going forward.
- [ ] Devin: add Payments Summary to Executive's Reports tab; build a
      "Generate team invite" screen in Registry — prompt below

## ⬜ Phase 1 — Foundation

**Note**: the Attendance and Payroll menu work above (Set Status for a Day,
Location Checker, Broadcast Notifications, Payroll History, Quick Pay,
etc.) *is* Phase 1 in progress — Attendance = Administrator workspace core,
Payroll = Finance & Payroll workspace core. Reframed below to reflect that.

- [~] **Administrator workspace** — in progress via Attendance menu buildout
  - [x] Backend: staff/attendance RPCs confirmed secure and sufficient
        (set_attendance_status, admin_get_latest_locations,
        admin_request_location_check/for_all, admin_send_notification,
        report_attendance_summary)
  - [ ] Devin: Attendance tabs sent, not yet confirmed complete
  - [x] Sites: confirmed already fully covered (`add_site`, `delete_site`)
  - [x] **Leave: found and closed a real gap** — staff could submit a leave
        request (`staff_request_leave`) but nothing let an admin act on it.
        Built `admin_list_leave_requests(p_company_id, p_status)` and
        `admin_review_leave_request(p_request_id, p_decision, p_reason)`
        (approve/reject, logs to company_activity_log → visible in Registry,
        same pattern as the invite audit trail)
  - [x] Onboarding: confirmed zero new backend needed — `add_staff` (create
        record, already logs to `staff_changes` for Registry visibility),
        `admin_send_notification` (welcome message), and
        `add_staff_custom_fields` (optional extra fields) already cover it
  - [ ] Devin: build the Onboarding wizard — prompt below. **This closes out
        every planned Administrator workspace item.**
- [~] **Finance & Payroll Manager workspace** — in progress via Payroll menu buildout
  - [x] Backend: Quick Pay (final settlement) built; Payroll History backed
        by existing report_payroll_summary; Flutterwave removed
  - [x] **Tax compliance built**: Ghana PAYE + SSNIT as Registry-editable
        data (`tax_bands`, `ssnit_config` tables), not hardcoded logic —
        `calculate_ghana_payroll_tax(p_gross_monthly_salary, p_year)`
        returns SSNIT employee/employer, taxable income, PAYE, net pay.
        2026 rates sourced via web search (multiple independent sources
        agree) — **not pulled from GRA's primary gazette directly; verify
        against GRA's actual publication or a tax advisor before this
        touches real payroll.** Tested against a worked example, matches
        exactly. `registry_set_tax_band`/`registry_set_ssnit_config` let
        Metosync staff update rates via Registry when GRA revises them.
  - [ ] Devin: surface this in the Taxes & Incentives step of the payroll
        wizard — prompt below
  - [ ] Budgets — not yet started, the one remaining Finance & Payroll item
- [ ] Devin: **consolidate, don't duplicate** — the Admin header's "Reports
      & Analytics" menu (Attendance by Date, Payroll Summary, Payments
      Summary) uses the same three functions already specced for
      Executive's Reports tab. Confirm Executive's version works, then
      remove the Admin header version entirely — prompt below
- [~] **Executive Director workspace** — backend started
  - [x] `executive_dashboard_summary(p_company_id)` built — one combined
        "at a glance" view (staff/attendance today, pending payroll,
        next payroll period, pending payments, open Watchguard findings by
        severity), since nothing previously combined these
  - [x] Approvals and drill-down reuse existing functions rather than
        duplicating logic: `watchguard_open_findings` (approvals),
        `report_attendance_summary`/`report_payroll_summary`/
        `report_staff_summary` (drill-down detail)
  - [ ] Devin prompt sent — build below
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
