import { createBrowserClient } from '@supabase/ssr'

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL
const supabaseKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY

if (!supabaseUrl || !supabaseKey) {
  throw new Error('Missing Supabase environment variables. Check .env.local or Vercel project settings.')
}

// Singleton — prevents "Multiple GoTrueClient instances" in Next.js dev hot-reload.
// createBrowserClient manages cookie-based session storage for auth.
const globalKey = Symbol.for('supabase.client')
if (!globalThis[globalKey]) {
  globalThis[globalKey] = createBrowserClient(supabaseUrl, supabaseKey)
}

export const supabase = globalThis[globalKey]
