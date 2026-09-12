# CLAUDE.md — instructions for working on this project

Read this before touching any backend or frontend code. If you're an AI
picking up this project in a new session with no memory of prior sessions,
this file is what re-establishes the standard everything else was built to.

## What this project is

Metosync is an attendance/payroll platform (Supabase/Postgres backend,
static HTML/JS frontend) expanding into a full "Workspace Suite" — see
`PRD.md` for product vision and `PLANNING.md` for architecture. This file is
about *how* to build it correctly, not *what* to build.

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
