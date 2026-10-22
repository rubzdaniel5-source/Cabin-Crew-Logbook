# Claude Code Master Directive — CrewLogbook Business-Class Service
**Version 1.0 | 18 October 2026**

## Objective
Implement the Business-Class Service module in the existing CrewLogbook PWA. Read `CrewLogbook_Business_Class_Service_PRD_v1.0.docx` as the functional and architecture baseline.

Approved decisions:
- Aircraft layout: versioned configuration selected by aircraft registration, with explicit flight-level override when required.
- Order scope: passenger + flight sector + service occasion.
- Offline editing: designated primary order-taking device by default; other devices read-only or tightly controlled offline.
- Meal workflow: preordered special meals and onboard meal selection.
- Crew responsibility: optional per seat/service task, airline-configurable.
- Delivery: phased, offline foundation first.

## Non-negotiable guardrails
1. **Phase 0 is audit only. Do not edit files, write migrations, or change database/security policies during Phase 0.**
2. Inspect actual current repository and Supabase schema/migration history before naming physical tables, columns, migration numbers, functions, policies or routes.
3. Reuse existing flight, sector, aircraft, crew, passenger manifest, identity, tenant and authorization entities wherever possible. Do not create duplicate master data.
4. Read `CLAUDE.md`, `AGENTS.md`, `README.md` and relevant module instructions. Report missing files rather than assuming.
5. Inspect `git status`, branches, existing diffs, tests/build scripts, PWA manifest, `sw.js`, IndexedDB version/stores, startup code, manifest workflow, Supabase access and RLS.
6. Preserve all working features. No broad rewrite, unrelated refactor, or new dependency without evidence and approval.
7. Never use real passenger data in fixtures, screenshots, logs, test prompts or demo data.
8. No service-role secret in client code. Never disable RLS to make development easier.
9. No production migration, push, publish or deployment without explicit approval.
10. Do not claim tests passed unless actually run. Report passed/failed/skipped/unavailable checks honestly.

## Phase 0 — required audit report
Return:
- Repository/framework/routing/build/test inventory.
- Manifest flow end-to-end: source/import, flight/sector key, passenger stable ID, seat assignment, SSR/meal fields, updates, reseating, cancellation and permissions.
- Relevant database inventory: tables, columns, primary/foreign/unique constraints, indexes, triggers, functions, RLS policies, grants, storage policies and migration order.
- Offline inventory: app-shell startup dependencies, service worker cache, IndexedDB DB/version/stores, local write path, sync algorithm, conflict behavior and reproducible startup/data-loss defects.
- Mapping table for every logical entity/requirement in the PRD: existing implementation, reuse/extend/new/defer, evidence, risk.
- Exact migration sequence only after inspecting the real migration history.
- Smallest safe file-change plan and tests.
- Open questions and any conflict between this PRD and live code/schema.
Stop and wait for approval before Phase 1.

## Implementation phases (each requires review)
### Phase 1 — offline foundation
Fix app-shell launch/resume, durable local writes, transactional outbox, readiness/freshness status, retry and conflict safety using existing architecture where feasible. Do not build the full order UI yet.
Acceptance: a prepared package opens on a fresh offline launch; local changes survive app restart; sync never overwrites pending edits; retries are idempotent; statuses distinguish local/pending/synced/conflict.

### Phase 2 — data model and security
After schema mapping is approved, propose additive versioned SQL migrations, constraints, indexes, RLS/grants, server operations and positive/negative tests. Do not apply to production. Reconcile tenant and flight authorization with existing helpers.
Acceptance: clean-install and upgrade migration tests pass; cross-tenant and unauthorized-flight access is denied through table APIs and RPCs.

### Phase 3 — flight package and seat map
Add versioned aircraft configuration, registration default and explicit flight override, manifest-linked seat map, seat-list fallback, passenger panel, stale configuration and assignment-conflict states.
Acceptance: correct configuration and passenger assignments; reseating preserves passenger-owned orders; aircraft substitution requires reconciliation.

### Phase 4 — orders
Support preordered special meals, onboard selections, menu versions, courses, drinks, supplementary items, requested service times, separate allergy/dietary/preference records, persistent warnings, substitutions, exceptions and item-level service events.
Acceptance: local writes are durable; no false allergen-safe claims; item-level states and history work offline and sync safely.

### Phase 5 — service queue and crew responsibility
Add outstanding/due/served/deferred/exception queues, optional airline-configurable crew task assignment, handover and a minimal service summary.
Acceptance: crew can find outstanding service quickly and service history remains intact.

### Phase 6 — hardening and pilot
Run regression, offline, sync, security/RLS, privacy, accessibility, responsive, migration and synthetic-data end-to-end tests. Record unresolved risks and request explicit release approval.

## Architecture rules
- Flight sector is the operational scope; never use flight number alone as a unique key.
- Seat assignment is historical/time-aware; seat label is not passenger identity.
- Order uniqueness is passenger + sector + service occasion unless a deliberate replacement/revision workflow is approved.
- Use stable operation IDs, payload schema versions, expected revisions and explicit per-operation sync acknowledgments.
- Save order/event and outbox record atomically in local storage.
- Do not pull remote state over pending local changes without conflict-aware merge.
- Server validates user, tenant, flight assignment, role, parent consistency, state transition, allowed menu item and revision.
- Preserve historical menu/configuration versions.
- Allergy declarations must be distinct from dietary preferences; display source and verification status. Missing ingredient data must be explicit.
- “Saved on device” only after local transaction commit. “Synced” only after server acknowledgment.
- Use minimal passenger data, approved retention, local-cache expiry/logout cleanup and no sensitive data in logs/URLs/notifications.
- Secondary devices are read-only offline by default; multi-device offline editing requires an explicit policy and conflict tests.

## End-of-phase report
For each phase, report:
1. Files changed and why.
2. Schema changes and exact migration identifiers (if approved).
3. RLS and authorization changes.
4. Tests actually run and results.
5. Known limitations and risks.
6. Rollback or forward-recovery plan.
7. Suggested commit message.
8. What requires user approval next.

Do not begin implementation until the Phase 0 audit has been returned and approved.
