// One plain message line. An error reads as an alert, anything else as a status.
// props: kind ('error' | 'info'), message, action ({ label, onClick }), onClose
export default function Notice({ kind = 'info', message, action, onClose }) {
  if (!message) return null
  const isError = kind === 'error'
  return (
    <div className={'stk-notice' + (isError ? ' stk-notice-error' : '')} role={isError ? 'alert' : 'status'}>
      <p className="stk-notice-text">{message}</p>
      <div className="stk-notice-actions">
        {action ? (
          <button type="button" className="stk-btn stk-btn-secondary" onClick={action.onClick}>
            {action.label}
          </button>
        ) : null}
        {onClose ? (
          <button type="button" className="stk-link" onClick={onClose}>
            Close
          </button>
        ) : null}
      </div>
    </div>
  )
}
