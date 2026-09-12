# PLANNING.md — architecture & technical planning

## 1. Architecture hooks — every new workspace plugs into these three

- **Identity & scoping** — the non-negotiable rules in `CLAUDE.md`, applied
  without exception.
- **Watchguard** — findings/events are tagged with `company_id`; tag them
  with a workspace/module name too, so monitoring extends to new workspaces
  automatically instead of needing a redesign each time.
- **Access & billing** — one `company_workspace_access` table (which company
  has which workspace enabled) sitting independently of `subscription_plan`.
  This is what lets tiered and pay-as-you-go billing coexist (§6).

## 2. Data model conventions

- New role→permission mappings are **data** (a table), not code branches —
  Phase 3/4 alone add ~9 new roles; adding one later should mean inserting
  rows.
- One `document_templates` + `document_submissions` pair for any
  form/template-style feature (leave forms, incident reports, worksheets),
  not a new table per document type.
- Every new table: RLS enabled from creation (see `CLAUDE.md` rule 4).

## 3. Workspace roadmap

### Phase 1 — Foundation (build first)

Build order differs from conceptual order: Administrator and Finance &
Payroll generate real data; Executive Director is a reporting layer over
both, so it's built last within this phase.

| Order | Workspace | Primary user | Core functions | Notes |
|---|---|---|---|---|
| 1 | Administrator | HR/Admin | Staff, sites, attendance, leave, onboarding | Mostly existing functionality — wire into a dedicated workspace/role |
| 2 | Finance & Payroll Manager | Finance Head | Payroll, payments, deductions, tax compliance, budgets | Payroll/payments/deductions exist; tax compliance & budgets are new |
| 3 | Executive Director | CEO/MD/Owner | Overview, approvals, strategic reports, company-wide analytics | Thin reporting layer over 1 + 2, no new data entry |

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
| Compliance & Legal | Compliance Officer | Policies, licenses, audit trails, regulatory reports | Resolve overlap with Security & Access / Watchguard first |
| Training & Development | HR/Training | Courses, certifications, skills matrix, appraisals | |
| Security & Access | Security Head | Visitor logs, access control, incident reports | Resolve overlap with Compliance & Legal / Watchguard first |

### Phase 4 — Executive Suite (advanced)

| Workspace | Primary user | Core functions | Notes |
|---|---|---|---|
| Board & Governance | Board Members | Board packs, resolutions, shareholder reports | |
| Audit & Internal Control | Internal Auditor | Audit trails, risk register, compliance checks | Build as a dashboard over Watchguard's existing event log, not new infra |
| Strategy & Planning | Strategy Team | OKRs, KPIs, budgets, forecasts | |

## 4. Roles to add

Current `SYSTEM_ROLES` (in `shared.js`): `super_admin`, `payroll_manager`,
`hr`, `view_only`. This roadmap implies adding, roughly in phase order:
`ops_manager`, `sales_head`, `store_manager`, `support_agent`,
`procurement_officer`, `compliance_officer`, `security_head`,
`training_lead`, `board_member`, `internal_auditor`, `strategy_lead`.

## 5. Online / offline policy

Decided per workspace, not globally:

- **Offline-friendly**: individual, self-recorded, low-conflict-risk data —
  check-in/out, worksheets, draft incident reports. PWA + service worker +
  local storage, synced when connectivity returns.
- **Online-required**: shared/live state or anything money-related — payroll
  approvals, team dashboards, payment processing.
- **Never cache secrets or payment data on-device**, regardless of workspace.

## 6. Billing model

Hybrid, using the two axes the schema already has:

- `subscription_plan` (trial/starter/professional/enterprise) — base plan,
  priced to get a company in cheaply. Attendance is the natural hook
  (matches the existing free trial).
- `service_tier` / `company_workspace_access` — each additional workspace is
  a flat add-on fee, enabled independently per company.
- **Metered pay-as-you-go** only for genuinely variable-cost items: SMS,
  payment-processing pass-through, file storage.

## 7. Devin prompt template

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

## 8. Existing infrastructure inventory (as of Sept 2026 audit)

Check before building something that might already exist:

- `SERVICE_TIERS` already includes `administrator` and `stores_inventory`
  as unbuilt-but-planned tiers (`shared.js`).
- `staff_leave_requests` / `staff_loan_requests` already provide a basic
  leave/loan approval workflow — decide whether Administrator's leave
  feature extends this or replaces it with a formal template.
- Watchguard (`watchguard_findings`, `watchguard_ai_actions`,
  `watchguard_events`, `watchguard_ai_action`, `watchguard_approve_action`,
  `watchguard_evaluate_rules`, etc.) already provides risk-tiered findings,
  an approval flow, and an event log — reuse for Audit & Internal Control
  rather than building parallel infrastructure.
- `attendance.is_offline_sync` already anticipates offline check-in sync.

## 9. Known open items (not yet resolved)

- `check_onboarding_invite` / `create_company_and_owner` contain a dormant
  "testing mode" bypass accepting any `METO-` code if `onboarding_invites`
  is empty. Inactive today, still live in code.
- `onboarding_invites`'s invite-creation policy checks
  `admin_users.system_role = 'super_admin'` — a separate mechanism from
  `is_platform_admin()`/`platform_admins` used everywhere else. Needs
  harmonizing.
- Not yet audited: edge functions, storage bucket policies, auth
  configuration, migration history.
- Minor: phone-number enumeration via `staff_start_login`; site-ID
  enumeration via `check_staff_geofence`.
- Reminder: when the live (non-test) Paystack key is set up, enter it
  through the app's own admin form — never paste it into a chat.
