import { STEPS, STEP_LABELS } from '../routeState'

// The road through one list: Generate, Print, Count, Review, Finish. Not tabs. Each step is a place on a
// line, numbered, and the one you are on is marked. Generate is done once a list exists.
// props: current ('generate' or one of the four steps of a list), reachable (true once a list is open),
//        onStep(step), onGenerate() (the Generate step of an open list goes back to the lists)
export default function StepBar({ current, reachable, onStep, onGenerate }) {
  const all = ['generate', ...STEPS]
  const at = all.indexOf(current)
  return (
    <nav className="stk-steps" aria-label="Steps">
      <ol className="stk-steps-list">
        {all.map((step, i) => {
          const done = i < at
          const here = i === at
          const open = reachable || step === 'generate'
          const cls = 'stk-step' + (here ? ' stk-step-on' : '') + (done ? ' stk-step-done' : '')
          return (
            <li key={step} className={cls} aria-current={here ? 'step' : undefined}>
              <button
                type="button"
                className="stk-stepbtn"
                disabled={!open || here}
                onClick={() => (step === 'generate' ? onGenerate && onGenerate() : onStep && onStep(step))}
              >
                <span className="stk-stepno" aria-hidden="true">
                  {i + 1}
                </span>
                <span className="stk-steplabel">{STEP_LABELS[step]}</span>
              </button>
            </li>
          )
        })}
      </ol>
    </nav>
  )
}
