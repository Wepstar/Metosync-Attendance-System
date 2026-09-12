# Metosync — Workspace Suite

This project's documentation now lives in four focused files instead of one
long one — read them in this order:

1. **`PRD.md`** — product vision, target users, requirements, success metrics
2. **`CLAUDE.md`** — non-negotiable security rules and how any AI (or human)
   should work in this repo
3. **`PLANNING.md`** — architecture, data model, roadmap detail, billing and
   offline strategy
4. **`TASK.md`** — the living checklist; check items off as they're built

Everything below this line is the original draft this got split from. Kept
for reference, but the four files above are now the source of truth.

---

This document is the single source of truth for how the Workspace Suite gets
built. Read it before writing any backend or frontend code — for both humans
and AI collaborators (Claude, Devin, or anyone who comes after).

Its job: let the project be built in small pieces, across many sessions and
by more than one AI, without losing the discipline established in the
September 2026 security audit or re-deciding the same architectural
questions twice.

---

## 1. Collaboration protocol

- **Claude (backend)** — owns the database schema, RPC functions, RLS
  policies, and Watchguard integration. Has live, audited Supabase access.
  Every backend change follows the security rules in Section 2, no exceptions.
- **Devin / Windsurf (frontend)** — owns UI only. Builds against a *fixed
  interface* Claude defines: an exact RPC name, its parameters, and what it
  returns. Devin never invents backend logic, never queries tables directly,
  and never receives direct Supabase project or migration access.
- **The handoff**: for every feature, backend ships first. Claude then writes
  a short, concrete prompt for Devin (template in Section 7) describing
  exactly which function to call and what the page needs to show/collect.
  Anything the frontend seems to need that doesn't exist yet goes back to
  Claude to build properly — never worked around on the frontend.

This split exists to save tokens/time while keeping one place (and one
consistent standard) responsible for anything that touches data or money.

---

## 2. Non-negotiable security rules

These come directly from the September 2026 audit, which found and fixed
**51 functions** with identity-spoofing or missing authorization, plus 3
RLS policies that bypassed the RPC layer entirely. Every rule below maps to
a real bug that existed in production.

1. **Identity always comes from `auth.uid()`**, never from a client-supplied
   parameter (`p_actor_id`, `p_user_id`, etc.). If a function needs to know
   who's calling, it looks it up from the session — it never trusts what the
   caller claims to be.
2. **Every function checks company ownership** before reading or writing
   company data: `my_company_id() = target_company_id` or
   `is_platform_admin()`. A `company_id` parameter is not, by itself,
   authorization to act on that company.
3. **RLS policies must never allow a direct table write that bypasses an
   RPC's checks.** If an RPC enforces a rule (e.g. only an owner can grant
   the owner role), no RLS policy should let the same table be edited
   directly in a way that skips that rule. When in doubt, don't add a direct
   write policy — force the mutation through the vetted function.
4. **New tables get RLS enabled from creation**, even before policies are
   written (fail-closed is safe; fail-open is not).
5. **Secrets (payment provider keys, webhook secrets, config values) are
   never returned to the frontend in full**, never logged, and treated as
   compromised the moment they're found to have been reachable without
   authorization — rotate, don't just patch.
6. **Idempotency keys** for any action that could plausibly be double-
   submitted (payments, approvals, staff creation).
7. **High-risk actions require human approval**, not full automation — this
   applies to anything financial or cross-company, per the Watchguard design.
8. **Before shipping any new RPC or policy, ask**: could a caller supply a
   different ID than their own and get a different, unintended result? That
   single question would have caught the majority of what the audit found.

---

## 3. Architecture hooks — every new workspace plugs into these three

- **Identity & scoping** — Section 2's rules, applied without exception.
- **Watchguard** — findings/events are tagged with `company_id`; tag them
  with a workspace/module name too, so monitoring extends to new workspaces
  automatically instead of needing a redesign each time.
- **Access & billing** — one `company_workspace_access` table (which company
  has which workspace enabled) sitting independently of `subscription_plan`.
  This is what lets tiered and pay-as-you-go billing coexist (Section 6).

---

## 4. Workspace Suite roadmap

### Phase 1 — Foundation (build first)

Recommended **build order** differs from the table below: Administrator and
Finance & Payroll generate real data; Executive Director is a reporting
layer over both, so it should be built last within this phase even though
it's listed first conceptually.

| Build order | Workspace | Primary user | Core functions | Notes |
|---|---|---|---|---|
| 1 | Administrator | HR/Admin | Staff, sites, attendance, leave, onboarding | Mostly existing functionality — wire into a dedicated workspace/role, not built from scratch |
| 2 | Finance & Payroll Manager | Finance Head | Payroll, payments, deductions, tax compliance, budgets | Payroll/payments/deductions exist; tax compliance and budgets are new |
| 3 | Executive Director | CEO/MD/Owner | Overview, approvals, strategic reports, company-wide analytics | Thin reporting layer over Administrator + Finance & Payroll data |

### Phase 2 — Operations (build next)

| Workspace | Primary user | Core functions |
|---|---|---|
| Stores & Inventory | Store Manager | Stock levels, assets, purchase orders, suppliers |
| Operations Manager | Ops Head | Projects, tasks, field staff, logistics |
| Sales & Marketing | Sales Head | Leads, clients, commissions, campaigns |

### Phase 3 — Support & Growth (build later)

| Workspace | Primary user | Core functions | Notes |
|---|---|---|---|
| Customer Service | Support Team | Tickets, complaints, feedback, SLA tracking | |
| Procurement | Procurement Officer | Vendors, RFQs, contracts, purchase approvals | |
| Compliance & Legal | Compliance Officer | Policies, licenses, audit trails, regulatory reports | Define ownership boundary with Security & Access and Watchguard before building |
| Training & Development | HR/Training | Courses, certifications, skills matrix, appraisals | |
| Security & Access | Security Head | Visitor logs, access control, incident reports | Overlaps with Watchguard/Compliance — resolve before building |

### Phase 4 — Executive Suite (advanced)

| Workspace | Primary user | Core functions | Notes |
|---|---|---|---|
| Board & Governance | Board Members | Board packs, resolutions, shareholder reports | |
| Audit & Internal Control | Internal Auditor | Audit trails, risk register, compliance checks | Build as a dashboard over Watchguard's existing event log — not a new system |
| Strategy & Planning | Strategy Team | OKRs, KPIs, budgets, forecasts | |

---

## 5. Roles to add

Current `SYSTEM_ROLES` (in `shared.js`): `super_admin`, `payroll_manager`,
`hr`, `view_only`. This roadmap implies adding, roughly in phase order:
`ops_manager`, `sales_head`, `store_manager`, `support_agent`,
`procurement_officer`, `compliance_officer`, `security_head`,
`training_lead`, `board_member`, `internal_auditor`, `strategy_lead`.

Given how many are coming, design the role→permission mapping as **data**
(a table), not as code branches — adding a role later should mean inserting
rows, not shipping a code change.

---

## 6. Billing model

**Hybrid**, using the two axes the schema already has:

- `subscription_plan` (trial / starter / professional / enterprise) — the
  base plan, priced to get a company in the door cheaply. Attendance is the
  natural hook (matches the existing free trial).
- `service_tier` / `company_workspace_access` — each additional workspace is
  a flat add-on fee, enabled independently per company.
- **Metered pay-as-you-go** only for genuinely variable-cost items: SMS
  notifications, payment-processing pass-through, file storage.

This uses existing schema rather than requiring a redesign.

---

## 7. Online / offline policy

Decided per workspace, not globally:

- **Offline-friendly**: individual, self-recorded data with low conflict
  risk — check-in/out, worksheets, draft incident reports. PWA + service
  worker + local storage, synced when connectivity returns.
- **Online-required**: anything reflecting shared/live state or money —
  payroll approvals, team dashboards, anything payment-related.
- **Never cache secrets or payment data on-device**, regardless of workspace.

---

## 8. Devin prompt template

Use this shape every time a backend piece is ready to hand off:

```
Build a [page/component name] for the [Workspace] workspace.

It should call the RPC `function_name(param1, param2, ...)`.
- What it does: [one sentence]
- Displays: [fields/columns returned]
- Collects from the user: [fields] and passes them to `function_name` on submit
- Session/identity: [how the page gets the current user's session — do not
  invent a new auth mechanism]

Constraints:
- Do NOT query Supabase tables directly — only call the RPC(s) listed above.
- Do NOT add any new backend logic, even small helper queries.
- Do NOT pass a user/company/staff ID as a parameter unless explicitly told
  to — identity comes from the existing session.
```

---

## 9. Existing infrastructure inventory (as of Sept 2026 audit)

Worth checking before building something that might already exist:

- `SERVICE_TIERS` already includes `administrator` and `stores_inventory` as
  unbuilt-but-planned tiers (defined in `shared.js`).
- `staff_leave_requests` and `staff_loan_requests` already provide a basic
  leave/loan approval workflow (start/end date or amount, reason, status,
  reviewer) — decide whether Administrator's leave feature extends this or
  replaces it with a formal template.
- Watchguard (tables: `watchguard_findings`, `watchguard_ai_actions`,
  `watchguard_events`; functions: `watchguard_ai_action`,
  `watchguard_approve_action`, `watchguard_evaluate_rules`, etc.) already
  provides risk-tiered findings, an approval flow, and an event log — reuse
  for Audit & Internal Control (Phase 4) rather than building parallel
  infrastructure.
- `attendance.is_offline_sync` column already anticipates offline check-in
  sync.

---

## 10. Known open security items (not yet resolved)

- `check_onboarding_invite` / `create_company_and_owner` contain a dormant
  "testing mode" bypass accepting any `METO-` code if `onboarding_invites`
  is empty. Inactive today (6 rows in the table) but live in code.
- `onboarding_invites`' "Platform admins can create invites" policy checks
  `admin_users.system_role = 'super_admin'` — a separate mechanism from
  `is_platform_admin()`/`platform_admins` used everywhere else. Needs
  harmonizing.
- Not yet audited: edge functions, storage bucket policies, auth
  configuration, migration history.
- Minor, low-severity: phone-number enumeration via `staff_start_login`;
  site-ID enumeration via `check_staff_geofence`.
- **Action item**: rotate the live payment provider secret key when it's
  first set up for real (test key already rotated) — never paste a live key
  into any chat; enter it through the app's own admin form.

---

## 11. Build log

| Date | Workspace | Backend status | Devin prompt sent? | Frontend status |
|---|---|---|---|---|
| _(fill in as work happens)_ | | | | |
