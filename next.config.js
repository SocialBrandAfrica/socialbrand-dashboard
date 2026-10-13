/** @type {import('next').NextConfig} */
const nextConfig = {
  // exceljs (the stocktake count sheets and uploads, SB-CC-STOCKTAKE-001) leans on Node streams, zlib and
  // dynamic requires. Leave it as a runtime require on the server, never bundled by webpack.
  experimental: {
    serverComponentsExternalPackages: ['exceljs'],
  },
  // xlsx uses Node.js built-ins that don't exist in Edge runtime.
  // Marking it as an external for server components, and it's only
  // used in a 'use client' component so this is just for safety.
  webpack: (config) => {
    config.resolve.fallback = {
      ...config.resolve.fallback,
      fs: false,
      path: false,
      stream: false,
      crypto: false,
    }
    return config
  },
}

module.exports = nextConfig
