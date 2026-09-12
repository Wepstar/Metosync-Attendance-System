# PRD — Metosync Workspace Suite

## 1. Vision

Metosync starts as an attendance and payroll platform. The Workspace Suite
turns it into the operating system for how a whole organization runs — one
platform, one login per company, a dedicated workspace for each function of
the business, instead of separate tools for HR, finance, operations, and
oversight.

## 2. Problem

The businesses Metosync already serves — schools, farms, hotels,
construction firms, tech companies — run on a patchwork of paper, spreadsheets,
and disconnected apps for anything beyond clocking in and out. Owners lack a
single place to see how the business is actually doing; department heads lack
tools built for how they specifically work.

## 3. Target users (by workspace)

| Workspace | Primary user |
|---|---|
| Executive Director | CEO / MD / Owner |
| Finance & Payroll Manager | Finance Head |
| Administrator | HR / Office Admin |
| Stores & Inventory | Store Manager |
| Operations Manager | Ops Head |
| Sales & Marketing | Sales Head |
| Customer Service | Support Team |
| Procurement | Procurement Officer |
| Compliance & Legal | Compliance Officer |
| Training & Development | HR / Training Lead |
| Security & Access | Security Head |
| Board & Governance | Board Members |
| Audit & Internal Control | Internal Auditor |
| Strategy & Planning | Strategy Team |

## 4. Goals

- A company can turn on exactly the workspaces it needs and pay accordingly.
- Every workspace feels purpose-built for its user, not a generic table with
  a different label.
- Data entered in one workspace (e.g. attendance) is usable by another (e.g.
  payroll, or Executive Director's analytics) without duplicate entry.
- The platform remains genuinely secure as it grows — see `CLAUDE.md` and
  `PLANNING.md` for the non-negotiable rules this depends on.
- Works offline for individual, self-recorded actions; requires connectivity
  for anything shared or financial (see `PLANNING.md` §5).

## 5. Non-goals (for now)

- Not building bespoke workspaces per industry (school vs. farm vs. hotel) —
  a generic "custom/industry workspace" slot instead.
- Not building a fully offline-capable payroll/finance system — deliberately
  online-required.
- Not attempting Phase 3/4 workspaces before Phase 1/2 are solid and in use.

## 6. Requirements by phase

See `PLANNING.md` §3 for the full phase table with build order and
dependencies. Summary:

- **Phase 1 (Foundation)**: Administrator, Finance & Payroll Manager,
  Executive Director.
- **Phase 2 (Operations)**: Stores & Inventory, Operations Manager, Sales &
  Marketing.
- **Phase 3 (Support & Growth)**: Customer Service, Procurement, Compliance
  & Legal, Training & Development, Security & Access.
- **Phase 4 (Executive Suite)**: Board & Governance, Audit & Internal
  Control, Strategy & Planning.

## 7. Billing requirements

Hybrid model — base subscription plan + per-workspace add-on + metered
usage for variable-cost items only. Full detail in `PLANNING.md` §6.

## 8. Security & compliance requirements

Every requirement in `CLAUDE.md`'s non-negotiable rules is a hard product
requirement, not an implementation detail — they exist because a September
2026 audit found 51 real, exploitable vulnerabilities (identity spoofing,
missing authorization, RLS bypasses) in the existing backend. No workspace
ships without passing the same review standard.

## 9. Success metrics (initial)

- A company can be onboarded and using Administrator + Finance & Payroll
  within one sitting, no support ticket required.
- Zero new RPCs shipped without an identity/company-ownership check (tracked
  via the same review checklist used in the Sept 2026 audit).
- Executive Director's dashboard requires no new data entry — it's fully
  derived from Administrator + Finance & Payroll data.

## 10. Open questions

- Leave/loan requests: does Administrator's leave feature extend the
  existing `staff_leave_requests` table, or replace it with a formal
  template system? (see `PLANNING.md` §8)
- Where does "incident report" live — Administrator's document templates,
  Security & Access, or Compliance & Legal? Needs a decision before Phase 3.
