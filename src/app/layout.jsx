import './globals.css'

export const metadata = {
  title: 'SocialBrand Pulse',
  description: 'Cross-store retail intelligence for SocialBrand',
}

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=5" />
      </head>
      <body className="min-h-screen bg-[#1A1A2E] text-slate-200 antialiased">
        {children}
      </body>
    </html>
  )
}
