import './globals.css'

export const metadata = {
  title: 'SocialBrand Pulse',
  description: 'Cross-store retail intelligence for SocialBrand',
}

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body className="min-h-screen bg-[#1A1A2E] text-slate-200 antialiased">
        {children}
      </body>
    </html>
  )
}
