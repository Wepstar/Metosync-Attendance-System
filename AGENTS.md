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
- **Tabs are gated** in `admin.html` `renderDashboard()` by `can(...)`.
- **Common issue**: `admin_users_role_check` violation means existing rows have invalid/null roles. Fix with `028_fix_admin_role_constraint.sql`.

## 4. Admin Dashboard (`admin.html`) Layout

### Tab routing (`renderTabContent`)
- `staff` → `renderStaff`
- `sites` → `renderSites`
- `attendance` → `renderAttendance` (also embeds Location Checker + Broadcast Notifications)
- `payroll` → `renderPayroll`
- `payroll-history` → payroll history
- `payments` → `renderPayments`
- `settings` → settings
- `admins` → `renderAdmins`
- `contact` → `renderContact`

> **Note**: Watch Guard was removed from the admin menu and now lives in the Owner Dashboard (`platform.html`) with whole-system access.
> **Note**: Admin management (`Admins` tab) was removed from `admin.html` and now lives in the Registry side (`platform.html`) for support-team access.

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
**What it does**
- Shows trend chart and daily attendance table for `attendanceDate`.
- `Set Status for a Day` form lets an admin manually set a staff member's status, check-in, and check-out times.
- Bulk actions: select multiple staff and mark them all with one status.
- Quick status buttons and manual check-out with reason.
- **Location Checker** (if `manage_staff`) appears directly under `Set Status for a Day`.
- **Broadcast Notifications** (if `broadcast_notifications`) appears under Location Checker.
- Real-time subscription refreshes attendance every minute or on any `attendance` change for the selected date.

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
- Lists staff and their assigned site with geofence data.
- `Request Location` asks a single staff to share GPS coordinates.
- `Request All` sends mass location request.
- Displays coordinates, accuracy, distance from site, capture time, and a Google Maps link.
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
- Sends a notification to one staff or all staff.
- Stores via `admin_send_notification` RPC.

**What can go wrong**
- Send fails → `admin_send_notification` missing or RLS.
- Real-time notification not received → verify staff subscription in `staff.html`.

### Payments Tab (`renderPayments`)
**What it does**
- Lists unpaid payroll entries (`payroll_payables` RPC).
- Allows selecting provider (Paystack / Flutterwave) and method (Bank / MoMo).
- Creates `payment_request` via Edge Function and updates via webhooks.

**What can go wrong**
- `payroll_payables` fails → `payment_requests` table missing or `GROUP BY` error (fixed by `026_fix_payroll_payables_groupby.sql`).
- Payout fails → provider not configured, invalid MoMo provider code (`MTN`, `VOD`, `TGO`), or wrong secret key.
- Webhook not updating → Edge Function not deployed, webhook secret mismatch, or payload format.

### Quick Pay (`admin.html` Payroll tab → 💸 Quick Pay)
**What it does**
- Allows an admin to pay a staff member directly without a payroll entry.
- Uses the same `paystack-payout` / `flutterwave-payout` Edge Functions with `payroll_entry_id: null`.
- Validates MoMo provider codes and provider selection before calling the Edge Function.

**What can go wrong**
- Edge Function rejects because `payroll_entry_id` was still required → re-deploy `paystack-payout` and `flutterwave-payout`.
- `payment_request_initiate` rejects null `payroll_entry_id` → verify `025_platform_accounts_payments.sql` is applied.
- Provider not configured → set up Paystack/Flutterwave in Owner Dashboard or Accounts & Billing.

**Fixes**
- Run `025` or `026` SQL and refresh schema.
- Configure provider in Owner Dashboard or Accounts & Billing.
- Check Edge Function logs in Supabase.

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
- `renderRegistryAdmins()` shows all admins across all companies and allows invite/role/deactivate.

### RPCs (`029_registry_admins.sql`)
- `registry_admin_list_all()` — returns every admin user with company name.
- `registry_admin_invite(p_company_id, p_email, p_role, p_created_by)` — generates an invite code for any company.
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
1. Admin chooses provider and method in `admin.html`.
2. Edge Function (`paystack-payout` or `flutterwave-payout`) validates, creates `payment_request`, calls provider API.
3. Provider webhook (`paystack-webhook` / `flutterwave-webhook`) reconciles status.

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

## 9. Deployment Checklist

- [ ] SQL migrations run in Supabase SQL Editor in order.
- [ ] `SELECT pg_notify('pgrst', 'reload schema');` executed.
- [ ] Edge Functions deployed (`paystack-payout`, `paystack-webhook`, `flutterwave-payout`, `flutterwave-webhook`, `dispatch-notification`, `watchguard-ai`).
- [ ] Provider config saved and webhook URLs set.
- [ ] Frontend files uploaded/hosted.

## 10. Quick Diagnostic Questions

- Is the error in the browser console or Supabase logs?
- Did the latest migration run successfully?
- Is the PostgREST schema cache refreshed?
- Does the admin's `role` have the required permission?
- Is the company scoping (`company_id`) correct in the query?
