import './globals.css'
import { headers } from 'next/headers'
import { appNameForHost } from '@/lib/appNames'

// The tab reads the app's own name, taken from the host the request came in on
// (BLOOM-035 item 8). orders.* reads Bloom, toolkit.* reads Forge, the rest Pulse.
export async function generateMetadata() {
  const host = headers().get('host') || ''
  return {
    title: appNameForHost(host),
    description: 'Cross-store retail intelligence for SocialBrand',
  }
}

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=5, viewport-fit=cover" />
        <meta name="theme-color" content="#070D1A" />
        <meta name="mobile-web-app-capable" content="yes" />
        <meta name="apple-mobile-web-app-capable" content="yes" />
      </head>
      <body className="min-h-screen bg-[#1A1A2E] text-slate-200 antialiased">
        {children}
      </body>
    </html>
  )
}
