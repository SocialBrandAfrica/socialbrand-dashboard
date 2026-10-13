import './stocktake.css'
import { APP_NAME } from '@/lib/appNames'

// The count app reached by path (dashboard.socialbrand.africa/stocktake) reads its own name.
// On stocktake.* the root layout already says so from the host.
// The icon is inline so the browser never asks for /favicon.ico, which this deployment does not serve.
const ICON =
  'data:image/svg+xml,' +
  encodeURIComponent(
    "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 32 32'><rect width='32' height='32' rx='7' fill='#ffd100'/>" +
      "<path d='M8 17l5 5 11-12' fill='none' stroke='#121612' stroke-width='3.5' stroke-linecap='round' stroke-linejoin='round'/></svg>"
  )

export const metadata = {
  title: APP_NAME.stocktake,
  icons: { icon: ICON },
}

// The root layout paints a dark body. This wrapper covers the viewport with the light page,
// and stocktake.css repaints the body behind it so no dark edge shows on overscroll.
export default function StocktakeLayout({ children }) {
  return <div className="stk-root">{children}</div>
}
