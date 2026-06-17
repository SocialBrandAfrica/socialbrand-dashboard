-- =============================================================================
-- create_eod_watchdog_cron.sql
-- SB-CC-EXTRACT-002 v1.1 req 2 (#3 loud-fail + #4 morning check) -- schedule the
-- central EOD watchdog. Authored for Pieter to deploy. Pairs with the edge
-- function supabase/functions/eod-watchdog/index.ts. NOT applied by CC (read-only).
--
-- Alerts key on DATA FRESHNESS (the function calls check_l1_feed_freshness, the
-- AUDIT-002 darkness detector), never on the extractor exit code. Central by
-- design: a fully-dark store cannot email about itself.
--
-- PIETER SETUP (once):
--  1. Deploy the function (--no-verify-jwt so pg_cron calls it with the shared
--     secret header instead of a JWT; the function enforces WATCHDOG_SECRET):
--       supabase functions deploy eod-watchdog --no-verify-jwt
--  2. Set the function secrets (dashboard > Edge Functions > eod-watchdog > Secrets,
--     or `supabase secrets set NAME=VALUE`):
--       RESEND_API_KEY  = <your Resend key>                  (already in the account)
--       WATCHDOG_SECRET = <a random string>                  (must match step 3)
--       EOD_ALERT_TO    = socialbrand.africa@gmail.com        (optional; this is the default)
--       EOD_ALERT_FROM  = SocialBrand Watchdog <onboarding@resend.dev>  (optional default;
--                         onboarding@resend.dev only delivers to the Resend account owner --
--                         switch to a verified domain, e.g. alerts@socialbrand.africa, for others)
--     (SUPABASE_URL + SUPABASE_SERVICE_ROLE_KEY are injected automatically.)
--  3. Keep the URL + shared secret out of cron.job -- store them in Vault:
--       select vault.create_secret('https://crklvhfwyxlisfcvqenc.supabase.co/functions/v1/eod-watchdog','eod_watchdog_url');
--       select vault.create_secret('<same WATCHDOG_SECRET as step 2>','eod_watchdog_secret');
--  4. Run this file (creates pg_net + the two cron jobs below).
--
-- RULE 7 -- prove a real email lands BEFORE trusting it. morning mode always
-- emails, so after deploy run it by hand and confirm it hits the inbox:
--   curl -i -X POST 'https://crklvhfwyxlisfcvqenc.supabase.co/functions/v1/eod-watchdog?mode=morning' \
--        -H 'x-watchdog-secret: <WATCHDOG_SECRET>'
--   -> expect a "[SocialBrand] Morning EOD check: GREEN -- all stores fresh"
--      email at socialbrand.africa@gmail.com. (loud_fail stays silent when green,
--      so it is NOT a good delivery test.)
--
-- pg_cron runs in UTC. SAST = UTC+2.  23:30 SAST = 21:30 UTC.  06:00 SAST = 04:00 UTC.
-- R28: schedule values dated 2026-06-17 (SB-CC-EXTRACT-002 v1.1), general defaults.
-- =============================================================================

create extension if not exists pg_net;

-- #3 loud-fail -- 23:30 SAST: emails ONLY if a store traded but did not land its EOD.
select cron.schedule(
  'eod-watchdog-loudfail',
  '30 21 * * *',
  $cron$
  select net.http_post(
    url     := (select decrypted_secret from vault.decrypted_secrets where name = 'eod_watchdog_url') || '?mode=loud_fail',
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'x-watchdog-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'eod_watchdog_secret')
               ),
    body    := '{"mode":"loud_fail"}'::jsonb
  );
  $cron$
);

-- #4 morning check -- 06:00 SAST: ALWAYS emails the governance line (GREEN or named stores).
select cron.schedule(
  'eod-watchdog-morning',
  '0 4 * * *',
  $cron$
  select net.http_post(
    url     := (select decrypted_secret from vault.decrypted_secrets where name = 'eod_watchdog_url') || '?mode=morning',
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'x-watchdog-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'eod_watchdog_secret')
               ),
    body    := '{"mode":"morning"}'::jsonb
  );
  $cron$
);

-- Verify:    select jobname, schedule, active from cron.job where jobname like 'eod-watchdog%';
-- Unschedule: select cron.unschedule('eod-watchdog-loudfail'); select cron.unschedule('eod-watchdog-morning');
