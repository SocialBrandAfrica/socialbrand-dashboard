import './stocktake.css'
import { APP_NAME } from '@/lib/appNames'

// The count app reached by path (dashboard.socialbrand.africa/stocktake) reads its own name.
// On stocktake.* the root layout already says so from the host.
export const metadata = {
  title: APP_NAME.stocktake,
}

// The root layout paints a dark body. This wrapper covers the viewport with the light page,
// and stocktake.css repaints the body behind it so no dark edge shows on overscroll.
export default function StocktakeLayout({ children }) {
  return <div className="stk-root">{children}</div>
}
