// What the page tells the person when something fails. The page shows a sentence from the server
// (an ApiError from ./api.js carries one) or this generic one. A raw JavaScript message such as
// "x is not a function" never reaches the screen.
//
// No imports: an ApiError is recognised by its name, so this module stays free of ./api.js.

export const GENERIC_ERROR = 'Something went wrong. Try again.'

export function isApiError(e) {
  return Boolean(e) && typeof e === 'object' && e.name === 'ApiError' && typeof e.message === 'string' && e.message !== ''
}

export function messageOf(e) {
  return isApiError(e) ? e.message : GENERIC_ERROR
}

// A 401 means the sign-in ended. The screen offers a Sign in button.
export function isSignedOut(e) {
  return isApiError(e) && e.status === 401
}

// The notice the page shows for a failed call.
export function errorNotice(e) {
  return {
    kind: 'error',
    message: messageOf(e),
    signIn: isSignedOut(e),
    cycleId: isApiError(e) && e.code === 'open_cycle_exists' ? e.cycleId : null,
  }
}
