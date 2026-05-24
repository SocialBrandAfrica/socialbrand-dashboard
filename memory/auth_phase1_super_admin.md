---
name: auth-phase1-super-admin
description: Auth access tier decision — Phase 1 all users are super-admin
metadata:
  type: decision
  date: 2026-05-24
---

## Decision

All authenticated users have super-admin (owner) access until access tiers are
formally introduced. This was confirmed by Pieter on 2026-05-24 during Session 18.

## What this means in code

In `src/app/page.jsx`, `loadProfile()`:
- If user has a `user_profiles` row, it is fetched and used for display name only.
- If no `user_profiles` row exists, a synthetic `{ role: 'owner' }` profile is used.
- `setStoreCodes([...ALL_STORE_CODES])` is ALWAYS called — all 5 stores visible.
- `isManagerLocked` is hardcoded `false` — store selector always shown.

The "Access Pending" screen and store-isolation logic are code-complete but dormant.
Re-enable by restoring role-based `setStoreCodes` and removing the `isManagerLocked = false` override.

## Google OAuth credentials (location record — not stored in git)

- Google Cloud project: `dashboardsocialbrandafrica`
- Client ID + Secret: stored in Supabase Auth > Providers > Google (public repo -- do not commit)
- Authorized redirect URI: `https://crklvhfwyxlisfcvqenc.supabase.co/auth/v1/callback`
- Supabase project: `crklvhfwyxlisfcvqenc`
- Google provider enabled in Supabase: YES (enabled 2026-05-24)

## When tiers are introduced

1. Remove `isManagerLocked = false` override
2. Restore role-based `setStoreCodes`: if `role !== 'owner' && store_code`, lock to that store
3. Restore "Access Pending" path: `setUserProfile(data ?? null)` and render pending screen
4. Run `sql/mobile_auth_setup.sql` if not yet done (adds columns + RLS policy)
5. Add manager rows to `user_profiles` with their `store_code` and `role = 'manager'`
