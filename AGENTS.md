# Metosync Agent Knowledge Base

This document is written for Watchguard (and future AI agents) so they can understand, diagnose, and patch the Metosync Attendance System like an expert.

## 1. Project Overview

- **Frontend**: static HTML/JS files (`platform.html`, `admin.html`, `staff.html`, `onboarding.html`, `signup.html`, `sentry.html`) plus `shared.js`.
- **Backend**: Supabase (Postgres, PostgREST, Realtime, Edge Functions).
- **Payments**: Paystack + Flutterwave (bank and MoMo) via `supabase/functions/*-payout` and `*-webhook`.
- **Monitoring**: Watchguard event logging, findings, AI-proposed actions, notifications/escalations, and owner dashboard review.
- **Migrations**: All SQL lives in `supabase/migrations/*.sql`. They must be run manually in the Supabase SQL Editor; GitHub pushes do not execute them.
- **PostgREST cache refresh** after schema/function changes:
  ```sql
  SELECT pg_notify('pgrst', 'reload schema');
  ```

## 2. Core Rules for Agents

- **Do not hard-code secrets** in source, commits, or chat. Payment/email/SMS keys are stored via Supabase provider config or environment variables.
- **Always verify SQL** before asking the user to run it, especially `GROUP BY` and aggregate queries.
- **Deploy Edge Functions** after any change:
  ```bash
  supabase functions deploy <name>
  ```
- **Test migrations on a fresh mental model**: if a previous migration failed, create a corrective follow-up (e.g., `0XX_fix_...sql`) instead of editing already-run SQL.
- **Preserve company scoping** in RPCs (`p_company_id`) and RLS policies.

## 3. Authentication & RBAC

### Admin roles (`admin_users.role`)
- `owner` — all permissions.
- `admin` — all except `manage_admins`.
- `manager` — staff, sites, notifications, reports.
- `payroll_officer` — payroll, payments, reports.
- `viewer` — read-only reports.

### Permission check
- Frontend: `can(permission)` in `admin.html` (loaded from `my_permissions` RPC).
- Backend: `has_permission(p_admin_id, p_permission)` SQL function.
- **Tabs are gated** in `admin.html` by `list_my_accessible_sections(p_company_id)`; the header menu is built from the returned sections, not by `can(...)`.
- **Common issue**: `admin_users_role_check` violation means existing rows have invalid/null roles. Fix with `028_fix_admin_role_constraint.sql`.

## 4. Admin Dashboard (`admin.html`) Layout

### Tab routing (`renderTabContent`)
- `executive` → `renderExecutive` (Company Staff)
- `staff` → `renderStaff`
- `sites` → `renderSites`
- `attendance` → `renderAttendance` (also embeds Location Checker + Broadcast Notifications)
- `payroll` → `renderPayroll`
- `records` → `renderRecords`
- `supplies` → `renderSupplies`
- `stores` → `renderStoresInventory`
- `settings` → settings
- `contact` → `renderContact`

> **Note**: Watch Guard was removed from the admin menu and now lives in the Owner Dashboard (`platform.html`) with whole-system access.
> **Note**: Admin management (`Admins` tab) was removed from `admin.html` and now lives in the Registry side (`platform.html`) for support-team access.

### Header menu (`renderDashboard`)
- On login, `admin.html` calls `list_my_accessible_sections(p_company_id)` and builds the top tab bar from the returned rows.
- `myAccessibleSections` is stored in memory and is the single source of truth for which header tabs exist; no tab is hardcoded or shown greyed-out.
- Only `section_code` values returned by that RPC appear as tabs; `section_name` is used for the label.
- `full_access = true` or `requires_password = false` means the tab renders directly.
- `requires_password = true` routes the tab through `guardSection` → `renderSectionGate`.
- `myAccessibleSections`, `sectionUnlocks`, and `tabSnapshots` are cleared on logout.

### Per-section password gates (`guardSection` / `renderSectionGate`)
- Every workspace tab from `list_my_accessible_sections` passes through `guardSection(el, code, renderFn)` in `renderTabContent`.
- `guardSection` looks up the section in `myAccessibleSections`.
- If `full_access` is true or `requires_password` is false, the render runs immediately.
- If `requires_password` is true, `renderSectionGate` shows a password prompt and calls `verify_company_section_password(p_company_id, p_section_code, p_password)`.
- `verify` must return `true` before the actual `renderFn` runs.
- Unlocks are memoized in `sectionUnlocks` (in-memory) and cleared on logout.

### Staff Tab (`renderStaff`)
**What it does**
- Add Staff form accepts full name, mobile, photo, department/role/staff code, pay rates, PIN, site.
- Photo is uploaded to the `staff-photos` Supabase Storage bucket and stored in `staff.photo_url`.
- Staff Catalog shows staff rows with thumbnail, name, phone, site, pay, status, device.
- Click any row or the **View** button to open a profile popup with all details.
- The popup has an **Edit** button top-right that toggles edit mode.
- Save calls `update_staff_profile` RPC.

**What can go wrong**
- Photo upload fails → `staff-photos` bucket missing or storage policies not applied. Run `030_staff_profiles.sql`.
- `create_staff` missing → run `030_staff_profiles.sql`.
- `update_staff_profile` does not save → verify `030_staff_profiles.sql` is applied and reload PostgREST schema.

### Attendance Tab (`renderAttendance`)
**Structure**
- Attendance is a sub-tab workspace (`attendanceSubTab`), nav sits at the top directly under the main header tabs; content renders below it.
- Destinations: **Daily Attendance** (default), **Set Status for a Day**, **Location Checker** (`manage_staff` only), **Broadcast Notifications** (`broadcast_notifications` only), **Attendance for Updated Date**.
- Deep links: `admin.html?tab=attendance&sub=setstatus|location|notify|bydate`.

**Daily Attendance**
- Trend chart + per-status cards + daily table for `attendanceDate` (date input in the card header changes it).
- Bulk actions, quick-status buttons, manual check-out with reason, CSV export.
- Real-time subscription refreshes attendance every minute or on any `attendance` change.

**Set Status for a Day**
- Staff picker + date + status + optional check-in/out + optional reason → `set_attendance_status`.

**Location Checker**
- `admin_get_latest_locations(p_company_id)` renders the per-staff table (status, accuracy, distance, verified time); per-row **Request Location** → `admin_request_location_check`; **Request All** → `admin_request_location_for_all`.

**Broadcast Notifications**
- Recipient select (All staff → `p_staff_id` null) + title + message → `admin_send_notification`.

**Attendance for Updated Date**
- Date picker → `report_attendance_summary(p_company_id, date, date)` → per-day totals cards.

**What can go wrong**
- Attendance table not loading → check `admin_list_attendance` RPC and `attendance` RLS.
- Bulk update fails silently → check `set_attendance_status` error in `errorMsg`.
- Quick-status preserves existing check-in/out but may create duplicate records if the row already exists; the RPC should upsert.
- Time inputs invalid → `parseTime` returns `undefined` and shows `Enter a valid hour and minute...`.

**How to fix simple issues**
- Missing data: verify `attendance` table has rows for `work_date`.
- Wrong status: use `set_attendance_status` with correct `p_status`.
- Real-time not updating: ensure `attendanceChannel` is unique per date and not duplicated.

### Location Checker (`renderLocationChecker`)
**What it does**
- Now an Attendance sub-tab (Attendance → Location Checker), gated by `manage_staff`.
- `admin_get_latest_locations` renders every staff member's last known location: inside/outside geofence status, accuracy, distance from site, verified time.
- Per-row **Request Location** → `admin_request_location_check`; **Request Location from All Staff** → `admin_request_location_for_all`.
- Green = inside geofence, red = outside.

**What can go wrong**
- Staff list empty → `staff` table or RLS issue.
- No location result → staff hasn't shared location yet (they see a prompt in `staff.html`).
- Geofence wrong → `sites.latitude/longitude/geofence_radius_meters` are null or wrong.
- Distance calculation error → `admin_get_latest_locations` function.

**Fixes**
- Verify `admin_request_location_check` and `admin_request_location_for_all` RPCs exist and handle `company_id`.
- Check `sites` coordinates.
- If map link broken, ensure latitude/longitude are numbers.

### Broadcast Notifications (`renderNotificationsAdmin`)
**What it does**
- Now an Attendance sub-tab (Attendance → Broadcast Notifications), gated by `broadcast_notifications`.
- Sends a notification to one staff or all staff (`p_staff_id` null for broadcast).
- Stores via `admin_send_notification` RPC; shows recent broadcast history.

**What can go wrong**
- Send fails → `admin_send_notification` missing or RLS.
- Real-time notification not received → verify staff subscription in `staff.html`.

### Leave Tab (`renderLeave`)
**What it does**
- Lives inside the Executive tab's sub-nav (Overview / Approvals / Reports / Leave) — not a top-level tab. `execSubTab === 'leave'` renders `renderLeave` into the Executive content area; deep link `admin.html?tab=executive&sub=leave`.
- `admin_list_leave_requests(p_company_id, p_status)` lists requests; filter chips: **Waiting** (default, `p_status='pending'`), **All** (`p_status=null`), **Approved**, **Rejected**.
- Each card reads in plain language: "Name — N days, Mar 4–6 — reason". Days/dates are computed defensively (`days`/`num_days`, or derived from `start_date`/`end_date`).
- Pending cards show an optional note field plus **Approve**/**Reject** → `admin_review_leave_request(p_request_id, p_decision, p_reason)` with `p_decision` = `'approved'`/`'rejected'`; list reloads after each action.

**What can go wrong**
- "function does not exist" → the two leave RPCs were built server-side only; deploy + `SELECT pg_notify('pgrst', 'reload schema');`.
- "not found / already reviewed" → another admin already actioned it; list refreshes anyway.
- Empty staff names → RPC row field may differ (`staff_name`/`full_name`/`name` all checked).

### Company Staff Tab (`renderExecutive`, tab id `executive`)
**Structure**
- Top-level tab labeled **Company Staff** (section code `executive`), shown only if `list_my_accessible_sections` returns it. Like other workspaces, it routes through `guardSection` and respects `full_access`/`requires_password`; the `verify_company_staff_password` gate is no longer used.
- Owners and executive directors additionally see a **Set/change password** form on the gate and a **🔑 Password** sub-tab inside, both calling `set_company_staff_password(p_company_id, p_password)`.
- Sub-nav (`execSubTab`) sits at the top under the header tabs: **Overview** (default), **Approvals**, **Reports**, **Leave**, plus owner/executive_director-only **🔓 Section Access** and **🔑 Password**.
- Deep links: `admin.html?tab=executive&sub=overview|approvals|reports|leave|access|password` — the gate still runs first.
- All data comes from RPCs only — no direct table queries in this section.

**Section Access** (`renderSectionAccess`) — `list_staff_section_access(p_company_id)` rendered as a staff × sections checkbox grid ("Uncheck a box to hide that section from that staff member"). Toggling calls `set_staff_section_access(p_admin_user_id, p_section_code, p_allowed)`; failures revert the checkbox and show the error. Row normalization (`sectionAccessTableHtml`) accepts flat `section_code` rows, a `sections` object, or a `sections` array. The same grid also exists for Metosync staff at **Registry → 🔐 Access** in `platform.html` (`renderRegistryAccess`, company picker via `platform_list_companies`).

**Overview** — `executive_dashboard_summary(p_company_id)` → plain-language cards: staff checked in today (`staff.checked_in_today`/`staff.total_active`), payroll still owed (`payroll.pending_amount`), next payroll period (`payroll.next_period_start`/`next_period_end`), payments waiting (`payments.pending_amount`), and a tappable "Needs your attention" card (`approvals_needed.critical` + `.warning`) that jumps to Approvals.

**Approvals** — `watchguard_open_findings(p_company_id)` → one card per finding (severity badge, rule name, description, suggested fix), optional reason input, Approve → `watchguard_approve_action(p_finding_id, p_user_id, p_reason)`, Reject → `watchguard_reject_action(...)`. `p_user_id` is `myProfile.id`; the server re-verifies identity from the session.

**Reports** — date range + Attendance/Payroll/Payments/Staff selector → `report_attendance_summary` / `report_payroll_summary` / `report_payments_summary` (all take `p_start`/`p_end`) / `report_staff_summary` (snapshot, `p_company_id` only, no dates).

**What can go wrong**
- Gate never opens → `verify_company_section_password` for `section_code = 'executive'` missing/false; the section must appear in `list_my_accessible_sections` and `requires_password` must be true for the prompt to appear.
- Access grid empty or checkbox reverts → `list_staff_section_access`/`set_staff_section_access` missing or erroring; check the red message under the grid.
- Section Access/Password sub-tabs missing → caller's `admin_users.role` isn't `owner`/`executive_director`.
- Overview error "function does not exist" → `executive_dashboard_summary` was built server-side only; confirm it's deployed and refresh the schema cache.
- Approve/Reject returns "not found or not open" → another admin already resolved the finding; the list refreshes after each action.
- Empty cards / `—` values → the RPC's JSON keys differ; the view reads `staff.*`, `payroll.*`, `payments.*`, `approvals_needed.*` (with top-level `next_period_*` fallback).

### Payments
- The top-level **Payments** tab was removed from `admin.html`. Staff payouts happen in **Payroll → Quick Pay** (Paystack) and **Quit Pay** settlements; payment history shows under Payroll History and Executive → Reports → Payments.
- The old `renderPayments` screen (payroll payables + payment-request history) is gone; if payables need a home again, rebuild it as a Payroll sub-destination using `payroll_payables`.

**What can go wrong**
- `payroll_payables` fails → `payment_requests` table missing or `GROUP BY` error (fixed by `026_fix_payroll_payables_groupby.sql`).
- Payout fails → provider not configured, invalid MoMo provider code (`MTN`, `VOD`, `TGO`), or wrong secret key.
- Webhook not updating → Edge Function not deployed, webhook secret mismatch, or payload format.

### Payroll Tab (`admin.html`)
**What it does**
- Payroll content lives inside the admin dashboard (same container as other tabs; no separate workspace pages, no Back button).
- All six payroll destinations are embedded in `admin.html` — the sub-nav (`payrollSubTabsHtml`) sits at the **top** of the payroll content area, directly under the main header tabs — the consistent rule for all sub-navs (Attendance, Executive, Payroll) (`payrollSubTab` state): **01 General Payroll** → **02 Taxes & Incentives** → **03 Final Review** → **� Budgets** → **�💸 Quick Pay** → **📋 Payroll History** → **🚪 Quit Pay**. Clicking a sub-tab re-renders only `.payroll-content` inside `#tabContent` — the admin header and main menu never unmount.
- `payroll.html`, `taxes.html`, and `review.html` are now bare redirect stubs — all their markup, topbar/window chrome, and scripts were removed; each just `location.replace`s to `admin.html?tab=payroll&sub=general|taxes|review` so old links/bookmarks keep working.
- Deep links: `admin.html?tab=payroll&sub=general|taxes|review|quickpay|history|quitpay`.
- **Payroll History** has nested tabs: **Payroll History** (period list) and **Reports** (range totals + list); both call `report_payroll_summary(p_company_id, p_start, p_end)`.
- **Quit Pay** calls `staff_quit_settlement_preview(p_staff_id, p_last_working_date)` (pro-rated salary, leave entitled/taken/unused, leave payout, active deductions — all computed server-side), then `staff_process_quit_settlement(...)` with mode `direct` or `itemized`; it creates a `payment_requests` row and marks staff inactive automatically. Both live in `033_quit_pay.sql`.
- Active sub-tab uses navy `#0d2a4d`; all payroll green was replaced with navy brand colors.
- **General Payroll** (`payrollGeneralHtml` + `wireGeneralPayroll`): needs an open draft period; if none exists the Add New Payroll Run form (`payrollStartPeriodHtml` → `create_payroll_period`) is shown instead. Toolbar: Apply All, Save, Delete Selected, Undo, Pay All, + New Payroll Run, staff search box, CSV Import (staff_code,weekday,weekend), Download Excel (CSV), Download PDF/Print (browser print), Export via Email.
- **Taxes & Incentives** (`payrollTaxesHtml` + `wireTaxesPayroll`): deduction-type CRUD via `add_deduction_type`/`apply_deduction_to_staff`, plus a per-staff Ghana PAYE/SSNIT breakdown card — `calculate_ghana_payroll_tax(p_gross_monthly_salary, p_year)` per staff member (gross = `monthly_salary || weekday_rate`). Rates are NEVER hardcoded in the frontend; they're Registry-editable (`tax_bands`/`ssnit_config` via `registry_set_tax_band`/`registry_set_ssnit_config`). Results are saved to `localStorage.metosync_payroll_breakdown` and displayed verbatim by Final Review — review never recalculates.
- **Final Review** (`payrollReviewHtml` + `wirePayrollReview`): summary cards + per-staff table from the saved breakdown (falls back to `payroll_entries` when absent). Approve/Lock update `payroll_periods.status`; Pay records payment for all saved entries via `mark_payroll_entries_paid`.
- **Budgets** (`payrollBudgetsHtml` + `wirePayrollBudgets`): plain-language set-a-budget form (optional department — blank = company-wide; re-saving the same department/period replaces the old figure) via `set_payroll_budget(p_company_id, p_department, p_period_start, p_period_end, p_budgeted_amount)`, and a budget-vs-actual card view via `payroll_budget_vs_actual(p_company_id, p_period_start, p_period_end)` — one card per department, green badge under budget / red over, variance + variance% read from the RPC row (no frontend math beyond display).
- Quick Pay lets an admin pay a staff member directly without a payroll entry.

**What can go wrong**
- Edge Function rejects because `payroll_entry_id` was still required → re-deploy `paystack-payout` and `flutterwave-payout`.
- `payment_request_initiate` rejects null `payroll_entry_id` → verify `025_platform_accounts_payments.sql` is applied.
- Provider not configured → set up Paystack/Flutterwave in Owner Dashboard or Accounts & Billing.

**Fixes**
- Run `025` or `026` SQL and refresh schema.
- Configure provider in Owner Dashboard or Accounts & Billing.
- Check Edge Function logs in Supabase.

### Records Tab (`renderRecords`)
**What it does**
- `list_document_templates(p_company_id)` renders the available record types as pick-cards (Meeting Minutes, Incident Report, Work Handover, Daily Action Planner are seeded). Selecting one builds the form **from that template's `field_schema`** — each `{key, label, type}` renders as text/textarea/date/number/select/checkbox; nothing is hardcoded per template.
- Save calls `submit_document(p_template_id, p_data)` — `p_data` is a JSON object keyed by field key.
- "View records" calls `list_document_submissions(p_company_id, p_template_type)` (`null` = all types), filterable by the type dropdown; each entry renders as a card with its stored key/value pairs.

**What can go wrong**
- "function does not exist" → the records RPCs were built server-side; deploy + `SELECT pg_notify('pgrst', 'reload schema');`.
- Empty form → `field_schema` may be a JSON string (handled via `JSON.parse`) or use `name` instead of `key` (both are read); a genuinely empty schema shows "no fields defined".
- Past entries show raw field keys prettified (`full_name` → "full name") since templates aren't joined to submissions for labels.

### Supplies & Equipment Tab (`renderSupplies`)
**What it does**
- `list_office_supplies(p_company_id, p_category)` (`null` = all) renders a table: item, quantity, assigned to, notes. Category filter repopulates from the loaded rows' categories.
- Add item → `add_office_supply(p_company_id, p_name, p_category, p_quantity, p_assigned_to, p_notes)`.
- Inline edit (✎) swaps quantity/assigned/notes cells into inputs → `update_office_supply(p_supply_id, p_quantity, p_assigned_to, p_notes)` — name and category are intentionally not editable after creation. Delete (🗑) confirms then calls `delete_office_supply(p_supply_id)`.

**What can go wrong**
- "function does not exist" → supplies RPCs built server-side; deploy + schema reload.
- Edit saves but name/category look unchanged → by design; those columns are fixed at creation.

### Stores & Inventory Tab (`renderStoresInventory`)
**What it does**
- Main tab: **Stores & Inventory**, with sub-tabs Suppliers / Items / Item In / Item Out / Purchase Orders.
- **Suppliers** — `list_suppliers`, `add_supplier`, `update_supplier` (deactivate/reactivate via `p_is_active`).
- **Items** — `list_inventory_items` shows name, SKU, unit, and current quantity. Items at or below `reorder_level` show a red "⚠ Running low" warning with the reorder-at figure. Add/edit use `add_inventory_item` / `update_inventory_item`.
- **Item In / Item Out** — `record_stock_movement(p_item_id, p_movement_type, p_quantity, p_reference, p_supplier_id)`. Item In can tag a supplier; Item Out pre-checks available quantity and turns the backend insufficient-stock error into "Not enough stock for this quantity.".
- **Purchase Orders** — `list_purchase_orders` (all statuses), `create_purchase_order(p_company_id, p_supplier_id, p_expected_date, p_items)` where `p_items` is an array of `{item_id, quantity, unit_cost}`, and `receive_purchase_order(p_po_id)` which marks the order received and updates stock automatically. UI text explicitly warns users not to also record an Item In after marking received.

**What can go wrong**
- "function does not exist" → stores RPCs built server-side; deploy + `SELECT pg_notify('pgrst', 'reload schema');`.
- Purchase order line items fail to save → `p_items` must be a JSON array of objects with `item_id`, `quantity`, and `unit_cost`; the frontend passes a JS array.
- "Not enough stock" on Item Out → the backend validates; try a smaller quantity or record an Item In first.
- Mark received doesn't add stock → `receive_purchase_order` is server-side; if stock stays unchanged, the function may have errored (check Edge/PostgREST logs).

### Team Invites (`platform.html` → Registry → ✉️ Team Invite)
**What it does**
- The only place team invites are created. The company-side "Invite Team" screen was removed from `admin.html` — `admin_create_invite` no longer permits company accounts.
- `renderRegistryInvite()` — organization select from `platform_list_companies()`, email field, role-tile grid from `list_active_portfolios()` (nothing hardcoded; `INVITE_ROLE_COLORS`/`INVITE_ROLE_ICONS` in platform.html keyed by portfolio `code`, hashed fallback for unknown codes).
- Calls `registry_admin_invite(p_company_id, p_email, p_role)` — returns an 8-char code valid for 7 days, shown with a Copy button.
- `p_role` is the portfolio `code`; for an invite to be accepted the code must satisfy the `admin_users.role` CHECK (`owner, admin, manager, payroll_officer, viewer`).

**What can go wrong**
- Tile grid empty or RPC error → `list_active_portfolios` missing; run `032_portfolios.sql` and refresh PostgREST.
- Invite accepted but role rejected → portfolio `code` not in the `admin_users.role` CHECK list.
- The old inline invite form on the Admins screen was removed — invites go through ✉️ Team Invite only.

### Portfolios (`platform.html` → Registry → 🗂 Portfolios)
**What it does**
- `registry_list_portfolios()` returns every portfolio (`code`, `display_name`, `description`, `is_active`, `sort_order`) as tiles.
- Toggle switch calls `registry_set_portfolio_active(p_code, p_is_active)`.
- Add form calls `registry_add_portfolio(p_code, p_display_name, p_description, p_sort_order)`.
- Seeded with the four RBAC roles so invite codes keep working with `admin_accept_invite`.

**What can go wrong**
- RPCs missing → run `032_portfolios.sql`, then `SELECT pg_notify('pgrst', 'reload schema');`.
- Newly added portfolio code not in `admin_users.role` CHECK → invite acceptance fails; add the code to the CHECK constraint first or keep codes aligned to RBAC roles.

### Activity Logs (`platform.html` → Registry → 📊 Activity Logs)
**What it does**
- `renderRegistryActivity` — "Central Registry & Combined Activity Logs" screen. Left sidebar: Organizations Overview stat cards from `platform_registry_overview()` (total firms / active / archived / pending approvals — field names read defensively) plus the Recent Organization Activity heatmap widget from `platform_activity_heatmap(p_days: 7)` (company × day grid shaded by `event_count`).
- Main table: `registry_list_all_activity_v2(p_company_id, p_start, p_end)` — columns Timestamp / Organization / Action By (name + role) / Action Type (category · action) / Details / Affected Records. Filters: organization dropdown (`platform_list_companies`, blank = all → `p_company_id: null`), date presets (Last 7 Days / This Month / Custom), client-side search, CSV export and print-to-PDF from loaded rows.
- "Affected Dates (Start–End)" from the mockup is intentionally omitted — no backing field exists yet.

**What can go wrong**
- "function does not exist" → RPCs built server-side; deploy + schema reload.
- Heatmap empty → check the RPC's param name (`p_days` assumed) and row shape (`day`/`event_count`/`company_name`).
- Sidebar stats show `—` → overview RPC field names differ from the aliases read in `renderRegistryActivity`.

## 5. Platform Dashboard (`platform.html`)

### Sections
- `gate` — password entry.
- `owner` — owner dashboard with company list, invites, Watchguard menu, Alerts, Payments providers.
- `registry` — cross-company registry.
- `accounts` — Accounts & Billing payment dashboard.
- `watchguard` — Watchguard findings dashboard.

### Provider Configuration
- `renderPaymentProviders` is context-aware: `backFn` and `title` parameters.
- Owner uses default Owner Dashboard back; Accounts & Billing uses its own back.
- Supports Paystack and Flutterwave secret/public keys, webhook secret, currency, live/test.

**Common issue**: `platform_section_passwords_section_check` violation → run `021_fix_section_password_constraint.sql`.

## 6. Registry Admin Management

### Location
- `platform.html` → `renderRegistry()` has an **Admins** button.
- `renderRegistryAdmins()` shows all admins across all companies and allows role updates/deactivation (invites moved to the ✉️ Team Invite screen).

### RPCs (`029_registry_admins.sql`)
- `registry_admin_list_all()` — returns every admin user with company name.
- `registry_admin_invite(p_company_id, p_email, p_role)` — generates an invite code for any company (used by the ✉️ Team Invite screen, not the Admins screen).
- `registry_admin_update_role(p_admin_id, p_role)` — updates an admin role.
- `registry_admin_deactivate(p_admin_id)` — deactivates an admin.

### Common issues
- `registry_admin_list_all` fails → migration `029` not run or RLS/GRANT missing.
- Invite not working → `admin_invites` table missing or `p_company_id` null.

## 7. Watchguard

### Tables
- `watchguard_events` — immutable action log.
- `watchguard_findings` — rule violations.
- `watchguard_ai_actions` — AI-proposed remediation.
- `watchguard_notification_channels` and `watchguard_escalations` — notifications.

### Rules
- Detects checkout-before-check-in, >24h shifts, geofence violations, too-short shifts, negative net pay, deductions > gross, duplicate payroll/payment refs, amount mismatches.

### Safe AI actions
- Require idempotency key, reason, model identity.
- Medium/high-risk actions require human approval.
- Accepts only named actions.

### Common issues
- Findings not appearing → triggers not deployed or `watchguard_event_log` not called.
- Notifications not sending → `dispatch-notification` Edge Function not deployed or channel URL wrong.

## 7. Payments Architecture

### Provider flow
1. Admin chooses provider and method in `admin.html`. **UI only offers Paystack** (Flutterwave was removed from all frontend selects/config screens; `payment_providers_provider_check` now allows only `paystack`/`stripe`).
2. Edge Function (`paystack-payout`) validates, creates `payment_request`, calls provider API.
3. Provider webhook (`paystack-webhook`) reconciles status.
4. Legacy `flutterwave-*` Edge Functions still exist server-side but are no longer reachable from the UI.

### MoMo provider codes
- Paystack: `MTN`, `VOD`, `TGO` with `type: mobile_money`.
- Flutterwave: `MTN`, `VOD`, `TGO` as `account_bank` in `/transfers`.

## 8. Common SQL Fixes

### Refresh API cache
```sql
SELECT pg_notify('pgrst', 'reload schema');
```

### Fix admin role check violation
```sql
supabase/migrations/028_fix_admin_role_constraint.sql
```

### Fix payroll payables GROUP BY
```sql
supabase/migrations/026_fix_payroll_payables_groupby.sql
```

## 9. Reporting & Analytics

### Admin Reports
- The old top-level **Reports** tab was removed from `admin.html` — company reports live in the **Executive → Reports** sub-tab (see above) and Payroll → Payroll History → Reports. The `report_*` RPCs are unchanged.

**What can go wrong**
- Reports fail → `031_reports_analytics.sql` not applied or `report_*` RPCs missing.
- Dates not filtering → verify `p_start` and `p_end` are `date` strings (YYYY-MM-DD).

### Owner Reports (`platform.html` → 📊 Reports button)
**What it does**
- `platform_report_summary` returns whole-system totals: companies, staff, attendance today, checked-in today, payroll pending, payments today.
- Shows company list for cross-org visibility.

## 10. Deployment Checklist

- [ ] SQL migrations run in Supabase SQL Editor in order.
- [ ] `SELECT pg_notify('pgrst', 'reload schema');` executed.
- [ ] Edge Functions deployed (`paystack-payout`, `paystack-webhook`, `flutterwave-payout`, `flutterwave-webhook`, `dispatch-notification`, `watchguard-ai`).
- [ ] Provider config saved and webhook URLs set.
- [ ] Frontend files uploaded/hosted.

## 11. Quick Diagnostic Questions

- Is the error in the browser console or Supabase logs?
- Did the latest migration run successfully?
- Is the PostgREST schema cache refreshed?
- Does the admin's `role` have the required permission?
- Is the company scoping (`company_id`) correct in the query?
