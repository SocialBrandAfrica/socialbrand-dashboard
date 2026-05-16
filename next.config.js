/** @type {import('next').NextConfig} */
const nextConfig = {
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
