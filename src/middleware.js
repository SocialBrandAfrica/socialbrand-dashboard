import { createServerClient } from '@supabase/ssr'
import { NextResponse } from 'next/server'

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
    return NextResponse.redirect(new URL('/login', request.url))
  }

  if (user && pathname === '/login') {
    return NextResponse.redirect(new URL('/', request.url))
  }

  // orders.socialbrand.africa hosts the Bloom ordering applet on this same
  // deployment (host-based route, no separate Vercel project — SB-CC-BLOOM-001 §0c).
  // Placed AFTER the auth gate — Bloom writes real ordering decisions, unlike /bt.
  if (hostname.startsWith('orders.') && pathname === '/') {
    return NextResponse.rewrite(new URL('/bloom', request.url))
  }

  return response
}

export const config = {
  matcher: [
    // html files are now included so StockFlow-DevCorner-Demo.html is auth-gated
    '/((?!_next/static|_next/image|favicon.ico|.*\\.(?:svg|png|jpg|jpeg|gif|webp|ico)$).*)',
  ],
}
