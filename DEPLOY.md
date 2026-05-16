# SocialBrand Dashboard — Deploy to Vercel

## What this is
A read-only reporting dashboard for the SocialBrand retail group.
Data source: Supabase (project: socialbrand-data).
Tech: Next.js 14, React, Tailwind CSS, Recharts.

---

## Step 1 — Get the Supabase anon key

1. Go to https://supabase.com/dashboard/project/crklvhfwyxlisfcvqenc
2. Click **Project Settings** (cog icon, bottom left)
3. Click **API**
4. Copy the **anon / public** key (NOT the service_role key)
5. Paste it into `.env.local` (replace `REPLACE_WITH_ANON_KEY`)

> The anon key is safe to expose in a browser app — Supabase Row Level Security
> controls what it can actually read. The service_role key is NOT safe in a browser.

---

## Step 2 — Push to GitHub

1. Create a new GitHub repo (e.g. `socialbrand-dashboard`) — make it **private**
2. In a terminal, from this `socialbrand-dashboard` folder:

```
git init
git add .
git commit -m "Phase 3 initial dashboard"
git branch -M main
git remote add origin https://github.com/YOUR_USERNAME/socialbrand-dashboard.git
git push -u origin main
```

---

## Step 3 — Deploy on Vercel

1. Go to https://vercel.com and sign in (or sign up — it's free)
2. Click **Add New → Project**
3. Connect your GitHub account and choose the `socialbrand-dashboard` repo
4. Vercel auto-detects Next.js — leave the build settings as-is
5. Under **Environment Variables**, add:
   - `NEXT_PUBLIC_SUPABASE_URL` = `https://crklvhfwyxlisfcvqenc.supabase.co`
   - `NEXT_PUBLIC_SUPABASE_ANON_KEY` = (the key from Step 1)
6. Click **Deploy**

Vercel will give you a URL like `https://socialbrand-dashboard.vercel.app` — share this with Kagiso.

---

## Step 4 — Row Level Security (optional but recommended)

For now the dashboard uses the anon key, which can read all rows.
If you want to restrict it later (e.g. per-store access):

1. In Supabase → **Authentication → Policies**
2. Enable RLS on `daily_snapshots`
3. Add a policy that allows `SELECT` for authenticated users

You can skip this for testing — the anon key works fine.

---

## Local development

To run the dashboard on your own computer before deploying:

1. Install Node.js from https://nodejs.org (choose LTS)
2. Open PowerShell in this folder
3. Run: `npm install`
4. Run: `npm run dev`
5. Open http://localhost:3000 in Chrome

---

## Future: Moving to Replit

When ready to move from Vercel to Replit:
1. Create a new Replit with template: **Node.js** or **Next.js**
2. Upload all files from this folder into the Replit
3. In Replit Secrets, add the same two env vars (SUPABASE_URL and SUPABASE_ANON_KEY)
4. Click Run — Replit will install deps and start the app
5. The Replit URL replaces the Vercel URL

The code is identical — only the host changes.
