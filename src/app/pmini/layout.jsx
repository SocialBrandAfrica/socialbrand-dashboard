// src/app/pmini/layout.jsx
// Standalone layout for the partner-facing Pulse Mini page.
// Provides its own <html>/<body> so /pmini does NOT inherit the dashboard
// chrome from the root layout — fonts + viewport only.

export const metadata = {
  title: 'Sushi Consignment — SPAR Delareyville',
  description: 'Consignment settlement report for the HMR SUSHI counter',
}

export default function PminiLayout({ children }) {
  return (
    <html lang="en">
      <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=5, viewport-fit=cover" />
        <meta name="theme-color" content="#0b1120" />
        <meta name="mobile-web-app-capable" content="yes" />
        <meta name="apple-mobile-web-app-capable" content="yes" />
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="anonymous" />
        <link
          href="https://fonts.googleapis.com/css2?family=Fraunces:ital,opsz,wght@0,9..144,400;0,9..144,700;1,9..144,400&family=Geist+Mono:wght@400;600;700&display=swap"
          rel="stylesheet"
        />
        <style>{`
          *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
          body { background: #0b1120; color: #f5f5f4; font-family: system-ui, sans-serif; min-height: 100vh; }
          @keyframes spin { to { transform: rotate(360deg); } }
        `}</style>
      </head>
      <body>{children}</body>
    </html>
  )
}
