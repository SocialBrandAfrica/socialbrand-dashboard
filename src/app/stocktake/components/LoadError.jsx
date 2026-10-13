import Notice from './Notice'

// A read that failed: one plain sentence, then the way out. A sign-in that has ended gets a
// Sign in button that goes to the login page. Other buttons come in as children.
// props: message, signIn (true when the sign-in ended), onSignIn(), onTryAgain() (optional), children
export default function LoadError({ message, signIn, onSignIn, onTryAgain, children }) {
  return (
    <div className="stk-loaderror">
      <Notice kind="error" message={message || 'This did not load.'} />
      <div className="stk-actions">
        {signIn ? (
          <button type="button" className="stk-btn stk-btn-primary" onClick={() => onSignIn && onSignIn()}>
            Sign in
          </button>
        ) : null}
        {onTryAgain ? (
          <button type="button" className="stk-btn stk-btn-secondary" onClick={() => onTryAgain()}>
            Try again
          </button>
        ) : null}
        {children}
      </div>
    </div>
  )
}
