/** Shared card wrapper used by all panels */
export default function Card({ title, children, className = '' }) {
  return (
    <div className={`bg-[#16213E] border border-[#0F3460] rounded-xl p-5 ${className}`}>
      {title && (
        <h2 className="text-sm font-semibold uppercase tracking-widest text-slate-400 mb-4">
          {title}
        </h2>
      )}
      {children}
    </div>
  )
}
