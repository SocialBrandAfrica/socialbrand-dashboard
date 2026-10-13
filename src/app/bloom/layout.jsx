import { APP_NAME } from '@/lib/appNames'

// Bloom reached by path (for example dashboard.socialbrand.africa/bloom) reads
// Bloom as well. On orders.* the root layout already says so from the host.
export const metadata = {
  title: APP_NAME.bloom,
}

export default function BloomLayout({ children }) {
  return children
}
