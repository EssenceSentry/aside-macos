import { ContextMenu } from "@base-ui/react/context-menu"
import type { ReactElement } from "react"
import { cn } from "@/lib/utils"

export type ContextAction = {
  label: string
  run: () => void
  disabled?: boolean
  destructive?: boolean
  separator?: boolean
}

export function ContextActions({
  children,
  actions,
  onOpen,
  disabled = false,
}: {
  children: ReactElement
  actions: ContextAction[]
  onOpen?: () => void
  disabled?: boolean
}) {
  return (
    <ContextMenu.Root
      disabled={disabled}
      onOpenChange={(open) => {
        if (open) onOpen?.()
      }}
    >
      <ContextMenu.Trigger render={children} />
      <ContextMenu.Portal>
        <ContextMenu.Positioner className="z-50">
          <ContextMenu.Popup
            finalFocus={false}
            className="min-w-48 rounded-lg border bg-card p-1 text-foreground shadow-lg outline-none"
          >
            {actions.map((action) => (
              <ContextMenu.Group key={action.label}>
                {action.separator && <ContextMenu.Separator className="my-1 h-px bg-border" />}
                <ContextMenu.Item
                  disabled={action.disabled}
                  onClick={action.run}
                  className={cn(
                    "flex cursor-default select-none items-center rounded-md px-3 py-1.5 text-sm outline-none data-highlighted:bg-muted data-disabled:opacity-45",
                    action.destructive && "text-destructive"
                  )}
                >
                  {action.label}
                </ContextMenu.Item>
              </ContextMenu.Group>
            ))}
          </ContextMenu.Popup>
        </ContextMenu.Positioner>
      </ContextMenu.Portal>
    </ContextMenu.Root>
  )
}
