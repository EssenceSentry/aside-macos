import { X } from "lucide-react"
import { cloneElement, isValidElement, type ReactNode, useEffect, useId, useRef } from "react"
import { Button } from "@/components/ui/button"
import type { Meeting } from "@/lib/types"

export type ModalName =
  | "new"
  | "details"
  | "settings"
  | "passage"
  | "glossary"
  | "export"
  | "speakers"
  | "delete"
  | null
export type Act = (action: string, payload?: Record<string, unknown>) => Promise<boolean>
export const languageNames = { auto: "English + Spanish", en: "English", es: "Español" }

export function dateLabel(date: string) {
  return new Date(date).toLocaleDateString(undefined, { month: "short", day: "numeric" })
}

export function Modal({
  title,
  description,
  children,
  close,
}: {
  title: string
  description?: string
  children: ReactNode
  close: () => void
}) {
  const ref = useRef<HTMLDialogElement>(null)
  useEffect(() => {
    const element = ref.current
    if (!element) return
    element.showModal()
    const onCancel = (event: Event) => {
      event.preventDefault()
      close()
    }
    element.addEventListener("cancel", onCancel)
    return () => {
      element.removeEventListener("cancel", onCancel)
      element.close()
    }
  }, [close])
  return (
    <dialog ref={ref} className="aside-dialog" aria-label={title}>
      <div className="flex items-start justify-between gap-4">
        <div>
          <h2 className="text-xl">{title}</h2>
          {description && (
            <p className="mt-2 text-sm leading-relaxed text-muted-foreground measure">
              {description}
            </p>
          )}
        </div>
        <Button variant="ghost" size="icon" aria-label="Close dialog" onClick={close}>
          <X />
        </Button>
      </div>
      <div className="mt-6">{children}</div>
    </dialog>
  )
}

export function Field({
  label,
  hint,
  children,
}: {
  label: string
  hint?: string
  children: ReactNode
}) {
  const id = useId()
  const control = isValidElement<{ id?: string }>(children)
    ? cloneElement(children, { id })
    : children
  return (
    <label htmlFor={id} className="grid gap-2 text-sm font-medium">
      {label}
      {control}
      {hint && (
        <span className="text-xs font-normal leading-relaxed text-muted-foreground">{hint}</span>
      )}
    </label>
  )
}

export function LanguageSelect({
  id,
  value,
  onChange,
}: {
  id?: string
  value: Meeting["language"]
  onChange: (value: Meeting["language"]) => void
}) {
  return (
    <select
      id={id}
      aria-label="Meeting language"
      value={value}
      onChange={(event) => onChange(event.target.value as Meeting["language"])}
      className="aside-select"
    >
      <option value="auto">English + Spanish</option>
      <option value="en">English</option>
      <option value="es">Español</option>
    </select>
  )
}
