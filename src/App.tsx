import { TooltipProvider } from "@/components/ui/tooltip"
import { FloatingContextScreen } from "@/screens/floating-context"
import { MonitorScreen } from "@/screens/monitor"

export default function App() {
  return (
    <TooltipProvider>
      {window.location.hash === "#context" ? <FloatingContextScreen /> : <MonitorScreen />}
    </TooltipProvider>
  )
}
