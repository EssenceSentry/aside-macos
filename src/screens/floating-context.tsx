import { CircleHelp, X } from "lucide-react"
import { useCallback, useEffect, useState } from "react"
import { Button } from "@/components/ui/button"
import { request, useAside } from "@/lib/bridge"
import type { Source } from "@/lib/types"
import { AssistantPane } from "@/screens/assistant"
import type { Act } from "@/screens/shared"

export function FloatingContextScreen() {
  const state = useAside()
  const [busy, setBusy] = useState(new Set<string>())
  const [error, setError] = useState<string | null>(null)
  const act = useCallback<Act>(async (action, payload = {}) => {
    setBusy((current) => new Set(current).add(action))
    try {
      await request(action, payload)
      setError(null)
      return true
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason))
      return false
    } finally {
      setBusy((current) => {
        const next = new Set(current)
        next.delete(action)
        return next
      })
    }
  }, [])
  useEffect(() => {
    void act("getState")
    const inspect = (event: Event) => {
      void act("showTranscriptSource", { source: (event as CustomEvent<Source>).detail })
    }
    window.addEventListener("aside-inspect-source", inspect)
    return () => window.removeEventListener("aside-inspect-source", inspect)
  }, [act])
  const alert = error ?? state.runtime.lastError
  return (
    <main className="floating-context" aria-label="Floating contextual help">
      {alert && (
        <div role="alert" className="error-banner">
          <CircleHelp className="size-4 shrink-0" />
          <span className="min-w-0 flex-1 break-words">{alert}</span>
          <Button
            variant="ghost"
            size="icon-xs"
            aria-label="Dismiss error"
            onClick={() => {
              setError(null)
              void request("clearError")
            }}
          >
            <X />
          </Button>
        </div>
      )}
      <AssistantPane
        state={state}
        act={act}
        busy={busy}
        floating
        onContext={() => void act("showMeetingContext")}
      />
    </main>
  )
}
