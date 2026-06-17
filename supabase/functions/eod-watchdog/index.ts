// =============================================================================
// eod-watchdog  --  SB-CC-EXTRACT-002 v1.1 req 2 (#3 loud-fail + #4 morning check)
// =============================================================================
// Central EOD watchdog. Keys alerts on DATA FRESHNESS, never on the extractor
// exit code (the exit code lied -- see v1.16 truthful-status fix). Central by
// design: a fully-dark store cannot email about itself, so the check + the mail
// run here, off the stores.
//
// It REUSES the AUDIT-002 darkness detector check_l1_feed_freshness() (PM: reuse,
// do not rebuild) -- that RPC compares each store's sigma_sales / sigma_movements
// / l2_soh_daily max date against daily_snapshots (the TAC/PRSSALE "store traded"
// proxy) and returns { store: "fresh" | "<table> dark since X (TAC at Y); ..." }.
// A store flagged with TAC current but sigma behind == traded-but-did-not-land
// (the dangerous case); a no-trade day does not advance daily_snapshots, so it
// does not false-alert.
//
// Modes:
//   loud_fail (cron 23:30 SAST / 21:30 UTC): email ONLY if a store is behind;
//             SILENT when all five are fresh (so the real alert is never buried).
//   morning   (cron 06:00 SAST / 04:00 UTC): ALWAYS email the governance line --
//             GREEN when all fresh, else the named store(s) + reason.
//
// Email via Resend (RESEND_API_KEY). Recipient EOD_ALERT_TO (default the
// SocialBrand inbox). FROM default is Resend's onboarding sender, which delivers
// to the Resend account owner (socialbrand.africa@gmail.com); switch EOD_ALERT_FROM
// to a verified domain (e.g. alerts@socialbrand.africa) for other recipients.
//
// Deploy: supabase functions deploy eod-watchdog  (Pieter; see create_eod_watchdog_cron.sql).
// Rule 7: a real test email must hit the inbox before this is trusted -- the test
// curl is in create_eod_watchdog_cron.sql. R28: behaviour dated 2026-06-17, general.
// =============================================================================

import { createClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL    = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY     = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const RESEND_KEY      = Deno.env.get("RESEND_API_KEY") ?? "";
const ALERT_TO        = Deno.env.get("EOD_ALERT_TO")   ?? "socialbrand.africa@gmail.com";
const ALERT_FROM      = Deno.env.get("EOD_ALERT_FROM") ?? "SocialBrand Watchdog <onboarding@resend.dev>";
const WATCHDOG_SECRET = Deno.env.get("WATCHDOG_SECRET") ?? "";

async function sendEmail(subject: string, text: string) {
  if (!RESEND_KEY) return { sent: false, error: "RESEND_API_KEY not set" };
  const r = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: { "Authorization": `Bearer ${RESEND_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify({ from: ALERT_FROM, to: [ALERT_TO], subject, text }),
  });
  const body = await r.text();
  return { sent: r.ok, status: r.status, body };
}

Deno.serve(async (req) => {
  // Optional shared-secret guard. If WATCHDOG_SECRET is set, callers must send a
  // matching x-watchdog-secret header (lets the function be deployed --no-verify-jwt
  // and called from pg_cron without embedding the service key in cron.job).
  if (WATCHDOG_SECRET && req.headers.get("x-watchdog-secret") !== WATCHDOG_SECRET) {
    return new Response(JSON.stringify({ error: "forbidden" }), { status: 403 });
  }

  let mode = "loud_fail";
  try {
    mode = new URL(req.url).searchParams.get("mode") ?? mode;
    if (req.method === "POST") {
      const b = await req.json().catch(() => ({} as Record<string, unknown>));
      if (typeof b.mode === "string") mode = b.mode;
    }
  } catch (_) { /* keep default */ }

  const sb = createClient(SUPABASE_URL, SERVICE_KEY);

  // Reuse the darkness detector (writes per-store feed_check rows + returns JSONB).
  const { data, error } = await sb.rpc("check_l1_feed_freshness");
  if (error) {
    // The detector itself failing is also alert-worthy -- never fail silent.
    const mail = await sendEmail(
      "[SocialBrand] EOD watchdog ERROR (freshness check failed)",
      `mode=${mode}\ncheck_l1_feed_freshness failed: ${error.message}`,
    );
    return new Response(JSON.stringify({ ok: false, error: error.message, mail }), { status: 500 });
  }

  const freshness = (data ?? {}) as Record<string, string>;
  const flagged = Object.entries(freshness).filter(([, v]) => v !== "fresh");
  const stamp = new Date().toISOString();

  if (mode === "morning") {
    const subject = flagged.length === 0
      ? "[SocialBrand] Morning EOD check: GREEN -- all stores fresh"
      : `[SocialBrand] Morning EOD check: ${flagged.length} store(s) BEHIND`;
    const text = flagged.length === 0
      ? `All stores posted a fresh end-of-day.\n\n${JSON.stringify(freshness, null, 2)}\n\n(${stamp})`
      : `Stores behind on their Sigma end-of-day:\n\n` +
        flagged.map(([s, v]) => `  ${s}: ${v}`).join("\n") +
        `\n\nFull: ${JSON.stringify(freshness, null, 2)}\n\n(${stamp})`;
    const mail = await sendEmail(subject, text);
    return new Response(JSON.stringify({ ok: true, mode, flagged: flagged.map((f) => f[0]), mail }), { status: 200 });
  }

  // loud_fail: silent when everything is fresh.
  if (flagged.length === 0) {
    return new Response(JSON.stringify({ ok: true, mode, flagged: [], sent: false, note: "all green -- silent" }), { status: 200 });
  }
  const subject = `[SocialBrand] EOD ALERT: ${flagged.length} store(s) traded but did not land`;
  const text =
    `A traded day did not land its Sigma end-of-day by cutoff (the dangerous case --\n` +
    `store traded, but the ledger extract is behind):\n\n` +
    flagged.map(([s, v]) => `  ${s}: ${v}`).join("\n") +
    `\n\nCheck the store's extractor run / dw220sdb lock window.\n\n(${stamp})`;
  const mail = await sendEmail(subject, text);
  return new Response(JSON.stringify({ ok: true, mode, flagged: flagged.map((f) => f[0]), mail }), { status: 200 });
});
