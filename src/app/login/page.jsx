'use client'

import { createBrowserClient } from '@supabase/ssr'

const supabase = createBrowserClient(
  process.env.NEXT_PUBLIC_SUPABASE_URL,
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY
)

async function signInWithGoogle() {
  await supabase.auth.signInWithOAuth({
    provider: 'google',
    options: {
      redirectTo: `${window.location.origin}/auth/callback`,
    },
  })
}

export default function LoginPage() {
  const searchParams = typeof window !== 'undefined' ? new URLSearchParams(window.location.search) : null
  const error = searchParams?.get('error')

  return (
    <div style={{
      minHeight: '100vh',
      background: '#0a0e1a',
      display: 'flex',
      alignItems: 'center',
      justifyContent: 'center',
      fontFamily: "'Geist', -apple-system, sans-serif",
      padding: 24,
    }}>
      {/* Aurora background */}
      <div style={{
        position: 'fixed', inset: 0, zIndex: 0, pointerEvents: 'none',
        background: 'radial-gradient(ellipse 70% 50% at 15% 0%, rgba(74,222,128,0.12), transparent 60%), radial-gradient(ellipse 50% 40% at 90% 30%, rgba(34,211,238,0.08), transparent 55%), radial-gradient(ellipse 60% 50% at 50% 100%, rgba(168,85,247,0.07), transparent 60%)',
      }} />

      <div style={{
        position: 'relative', zIndex: 1,
        width: '100%', maxWidth: 380,
        background: 'rgba(255,255,255,0.04)',
        border: '1px solid rgba(255,255,255,0.1)',
        borderRadius: 20,
        backdropFilter: 'blur(20px)',
        padding: 40,
        textAlign: 'center',
      }}>
        {/* Logo */}
        <div style={{ marginBottom: 28 }}>
          <h1 style={{
            fontFamily: 'Fraunces, Georgia, serif',
            fontWeight: 600, fontSize: 32,
            letterSpacing: '-0.02em', lineHeight: 1, margin: 0,
            color: '#f5f5f4',
          }}>
            Social<em style={{ fontStyle: 'italic', fontWeight: 300, color: '#4ade80' }}>Brand</em>
          </h1>
          <p style={{
            fontSize: 11, color: 'rgba(245,245,244,0.35)',
            textTransform: 'uppercase', letterSpacing: '0.14em', marginTop: 8,
          }}>
            Pulse
          </p>
        </div>

        <p style={{
          fontSize: 14, color: 'rgba(245,245,244,0.5)',
          lineHeight: 1.6, marginBottom: 28,
        }}>
          Sign in with your Google account to access your store dashboard.
        </p>

        {error && (
          <div style={{
            marginBottom: 20, padding: '10px 14px',
            background: 'rgba(239,68,68,0.1)',
            border: '1px solid rgba(239,68,68,0.25)',
            borderRadius: 8,
            fontSize: 13, color: 'rgba(239,68,68,0.9)',
          }}>
            Sign-in failed. Please try again.
          </div>
        )}

        <button
          onClick={signInWithGoogle}
          style={{
            width: '100%', padding: '14px 24px',
            display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 12,
            background: '#fff',
            border: 'none', borderRadius: 12,
            cursor: 'pointer',
            fontSize: 15, fontWeight: 600, color: '#1a1a2e',
            fontFamily: "'Geist', sans-serif",
            boxShadow: '0 4px 16px rgba(0,0,0,0.3)',
            transition: 'all 0.15s',
          }}
          onMouseOver={e => e.currentTarget.style.transform = 'translateY(-1px)'}
          onMouseOut={e => e.currentTarget.style.transform = 'translateY(0)'}
        >
          <svg width="20" height="20" viewBox="0 0 48 48">
            <path fill="#4285F4" d="M45.12 24.5c0-1.56-.14-3.06-.4-4.5H24v8.51h11.84c-.51 2.75-2.06 5.08-4.39 6.64v5.52h7.11c4.16-3.83 6.56-9.47 6.56-16.17z"/>
            <path fill="#34A853" d="M24 46c5.94 0 10.92-1.97 14.56-5.33l-7.11-5.52c-1.97 1.32-4.49 2.1-7.45 2.1-5.73 0-10.58-3.87-12.31-9.07H4.34v5.7C7.96 41.07 15.4 46 24 46z"/>
            <path fill="#FBBC05" d="M11.69 28.18C11.25 26.86 11 25.45 11 24s.25-2.86.69-4.18v-5.7H4.34C2.85 17.09 2 20.45 2 24c0 3.55.85 6.91 2.34 9.88l7.35-5.7z"/>
            <path fill="#EA4335" d="M24 10.75c3.23 0 6.13 1.11 8.41 3.29l6.31-6.31C34.91 4.18 29.93 2 24 2 15.4 2 7.96 6.93 4.34 14.12l7.35 5.7c1.73-5.2 6.58-9.07 12.31-9.07z"/>
          </svg>
          Sign in with Google
        </button>

        <p style={{
          marginTop: 24, fontSize: 11,
          color: 'rgba(245,245,244,0.2)', lineHeight: 1.6,
        }}>
          Access is assigned by Pieter van der Westhuizen.<br />
          Contact him if you do not have access yet.
        </p>
      </div>
    </div>
  )
}
