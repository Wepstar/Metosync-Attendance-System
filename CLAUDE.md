# CLAUDE.md — instructions for working on this project

Read this before touching any backend or frontend code. If you're an AI
picking up this project in a new session with no memory of prior sessions,
this file is what re-establishes the standard everything else was built to.

## What this project is

Metosync is an attendance/payroll platform (Supabase/Postgres backend,
static HTML/JS frontend) expanding into a full "Workspace Suite" — see
`PRD.md` for product vision and `PLANNING.md` for architecture. This file is
about *how* to build it correctly, not *what* to build.

## Design principles — built for first-time users, not power users

The target user is often intimidated by cumbersome, technical-looking
systems — many will be trying something like this for the first time. The
reaction we're building for is "this is easy, we love it," never "this
looks like too much work to learn." This applies to every workspace, not
just some of them, and every Devin prompt should carry these forward:

- **Plain, everyday language everywhere** — button labels, error messages,
  empty states. No jargon, no technical error codes shown to the user.
- **One task per screen.** Prefer several simple screens over one screen
  trying to do everything. Hide advanced/rarely-used options until asked
  for (progressive disclosure) rather than showing every field at once.
- **Borrow familiar patterns** from apps people already use daily in this
  region — WhatsApp, mobile money apps (MTN MoMo etc.). If a flow can look
  and feel like something the user has already learned elsewhere, it should.
- **Icons paired with text labels**, never icon-only — an unfamiliar icon
  with no label is exactly the kind of small friction that makes a system
  feel intimidating.
- **Mobile-first, generous touch targets.** Assume the primary device is a
  phone, not a desktop.
- **Clear, human feedback**: "Saved!" not "Operation completed
  successfully." Confirm what happened in words a non-technical person
  would say themselves.
- **Local context by default**: GHS currency formatting, local date format,
  familiar terms for roles/positions.
- **Consistent navigation across every workspace** — a pattern learned once
  in Attendance should work the same way in Payroll, Stores & Inventory,
  and everything after. This is a corollary of the architecture hooks in
  `PLANNING.md` — the shared hooks are technical; this is the same idea
  applied to what the user sees and learns.

When writing a Devin prompt, translate "build X" into "build X the way
someone who's never used a system like this before would find obvious."

## Non-negotiable security rules

These exist because a September 2026 audit found and fixed **51 functions**
with identity-spoofing or missing authorization, plus 3 RLS policies that
bypassed the RPC layer entirely, in a system that looked fine from the
outside. Every rule below maps to a real bug that was live in production.

1. **Identity always comes from `auth.uid()`**, never from a client-supplied
   parameter (`p_actor_id`, `p_user_id`, etc.). Never trust what a caller
   claims to be — look it up from the session.
2. **Every function checks company ownership**: `my_company_id() =
   target_company_id` or `is_platform_admin()`. A `company_id` parameter is
   not, by itself, authorization.
3. **No RLS policy may allow a direct table write that bypasses an RPC's
   own checks.** If in doubt, don't add a direct write policy at all — force
   the mutation through the vetted function.
4. **New tables get RLS enabled at creation**, before any policy exists.
   Fail-closed is safe; fail-open is not.
5. **Secrets are never returned to the frontend in full**, never logged, and
   treated as compromised — not just patched — the moment they're found to
   have been reachable without authorization.
6. **Idempotency keys** for anything that could be double-submitted
   (payments, approvals, staff creation).
7. **High-risk actions (financial, cross-company) require human approval**,
   never full automation — this is the whole point of Watchguard's design.
8. **Before shipping any new RPC or policy, ask**: could a caller supply a
   different ID than their own and get a different, unintended result? That
   one question would have caught most of the September 2026 findings.

## Collaboration model

- **Backend** (schema, RPCs, RLS, Watchguard) is built by Claude with live,
  audited Supabase access. This is where the rules above are enforced.
- **Frontend** is built by Devin/Windsurf against a *fixed interface* —
  an exact RPC name, its parameters, and what it returns. Devin never
  queries tables directly, never invents backend logic, and never gets
  direct Supabase project or migration access.
- Backend ships before its matching Devin prompt is written. See
  `PLANNING.md` §7 for the prompt template.

## Where things live

- `PRD.md` — product vision, target users, requirements, success metrics.
- `PLANNING.md` — architecture, data model conventions, roadmap detail,
  billing/offline strategy, existing-infrastructure inventory.
- `TASK.md` — the living checklist. Check items off as they're built; this
  is the actual source of truth for "what's done."

## How to pick up a new session

1. Read this file.
2. Read `TASK.md` to see what's already done and what's next.
3. Read the relevant section of `PLANNING.md` for the workspace you're
   building.
4. Before writing any RPC, re-read the non-negotiable rules above. Every one
   of them.
