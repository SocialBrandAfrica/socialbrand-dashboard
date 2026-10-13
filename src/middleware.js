import { createServerClient } from '@supabase/ssr'
import { NextResponse } from 'next/server'

// getUser() may refresh the session and set new cookies on `response`. A rewrite builds a new
// response, so those cookies are copied across or the browser keeps the old, rotated token.
function carryCookies(from, to) {
  from.cookies.getAll().forEach((c) => to.cookies.set(c))
  return to
}

export async function middleware(request) {
  let response = NextResponse.next({
    request: { headers: request.headers },
  })

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
    {
      cookies: {
        getAll() { return request.cookies.getAll() },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value }) => request.cookies.set(name, value))
          response = NextResponse.next({ request })
          cookiesToSet.forEach(({ name, value, options }) =>
            response.cookies.set(name, value, options)
          )
        },
      },
    }
  )

  const { data: { user } } = await supabase.auth.getUser()
  const pathname = request.nextUrl.pathname
  const hostname = request.headers.get('host') || ''
  if (hostname.startsWith('bonnytyler.')) {
    return NextResponse.rewrite(new URL('/bt', request.url))
  }

  const isPublic =
    pathname === '/login' ||
    pathname.startsWith('/auth/') ||
    pathname === '/StockFlow-DevCorner-Demo.html' ||
    pathname.startsWith('/api/dev-corner/') ||
    pathname === '/bt'

  if (!user && !isPublic) {
    // The count app's API is called by fetch. A redirect to the login page would reach it as a
    // 200 page of HTML, so an expired session would look like a saved count. Answer 401 JSON.
    if (pathname.startsWith('/api/stocktake/')) {
      return NextResponse.json(
        { error: 'not authenticated', message: 'Sign in again to continue.' },
        { status: 401, headers: { 'Cache-Control': 'no-store' } }
      )
    }
    return NextResponse.redirect(new URL('/login', request.url))
  }

  if (user && pathname === '/login') {
    return NextResponse.redirect(new URL('/', request.url))
  }

  // orders.socialbrand.africa hosts the Bloom ordering applet on this same
  // deployment (host-based route, no separate Vercel project — SB-CC-BLOOM-001 §0c).
  // Placed AFTER the auth gate — Bloom writes real ordering decisions, unlike /bt.
  if (hostname.startsWith('orders.') && pathname === '/') {
    return carryCookies(response, NextResponse.rewrite(new URL('/bloom', request.url)))
  }

  // toolkit.socialbrand.africa hosts Forge, the operations toolkit (NORTH_STAR
  // v1.4 app #7; SB-CC-TOOLKIT-001). Same deployment, host-based route.
  // Placed AFTER the auth gate on purpose: Forge issues real floor work —
  // count lists, TLX zero files — so it is authenticated, never public like /bt.
  if (hostname.startsWith('toolkit.') && pathname === '/') {
    return carryCookies(response, NextResponse.rewrite(new URL('/toolkit', request.url)))
  }

  // stocktake.socialbrand.africa hosts the count app that replaces StockFlow counting
  // (SB-CC-STOCKTAKE-001). Same deployment, host-based route, AFTER the auth gate: it
  // writes real count cycles and issues TLX files. The query string is kept so the page
  // can hold its state (?store=...&cycle=...).
  if (hostname.startsWith('stocktake.') && pathname === '/') {
    const url = request.nextUrl.clone()
    url.pathname = '/stocktake'
    return carryCookies(response, NextResponse.rewrite(url))
  }

  return response
}

export const config = {
  matcher: [
    // html files are now included so StockFlow-DevCorner-Demo.html is auth-gated
    '/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico)$).*)',
  ],
}
