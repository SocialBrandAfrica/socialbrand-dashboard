// The one home for "what does this app's browser tab read" (BLOOM-035 item 8, R9).
//
// Every app on this deployment is reached by its own host (middleware.js rewrites
// the host to the app's route). The tab title is read from the HOST so the shared
// pages (/login, the auth gate) carry the same name as the app behind them, and a
// route layout can import the same constant when an app is reached by path.
//
// The static pages served by route.js (toolkit.html, pmini.html, bt.html) carry
// their own <title>; the strings for toolkit are kept identical here so the tab
// does not change name between sign-in and the app.

export const APP_NAME = {
  pulse: 'SocialBrand Pulse',
  bloom: 'Bloom',
  forge: 'Forge — Operations Toolkit',
  stocktake: 'SocialBrand Stocktake',
}

// Host prefix (the part before the first dot) to app. The prefixes are the ones
// middleware.js routes on. A host that matches none is the Pulse dashboard.
const HOST_APP = {
  orders: 'bloom',
  toolkit: 'forge',
  stocktake: 'stocktake',
}

export function appForHost(host) {
  const prefix = String(host || '').split('.')[0].toLowerCase()
  return HOST_APP[prefix] || 'pulse'
}

export function appNameForHost(host) {
  return APP_NAME[appForHost(host)]
}
