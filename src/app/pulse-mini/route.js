// src/app/pulse-mini/route.js
// Serves StockFlow-DevCorner-Demo.html behind Pulse auth.
// The middleware protects this route (it is NOT a .html file, so it IS
// caught by the matcher).  Direct access to /StockFlow-DevCorner-Demo.html
// bypasses auth — this route is the auth-gated entry point.

import { NextResponse } from 'next/server'
import { readFileSync } from 'fs'
import { join } from 'path'

export async function GET() {
  const html = readFileSync(
    join(process.cwd(), 'public', 'StockFlow-DevCorner-Demo.html'),
    'utf8'
  )
  return new NextResponse(html, {
    headers: { 'Content-Type': 'text/html; charset=utf-8' },
  })
}
