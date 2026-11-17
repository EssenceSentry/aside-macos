export function AppIcon({ className = "size-8" }: { className?: string }) {
  return (
    <svg className={className} viewBox="0 0 40 40" role="img" aria-label="Aside">
      <rect width="40" height="40" rx="12" fill="var(--primary)" />
      <path
        d="M12 16v8m5-13v18m6-15v12m5-8v4"
        fill="none"
        stroke="var(--primary-foreground)"
        strokeWidth="3"
        strokeLinecap="round"
      />
    </svg>
  )
}
