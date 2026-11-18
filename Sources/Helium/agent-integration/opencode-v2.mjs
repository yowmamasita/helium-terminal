import { reportSession } from "./report.mjs"

// OpenCode V2 (2.3.2) TUI plugin API: setup(ctx), with the active route in ctx.ui.router.
// V2 skips V1's tui.json plugin entries, so this loads from <config>/opencode/plugins/helium-terminal/.
export default {
  id: "helium.session",
  async setup(ctx) {
    if (!process.env.HELIUM_PANE || !process.env.HELIUM_SOCKET || !process.env.HELIUM_PANE_TOKEN) return
    const { createRoot, createComputed } = await import("solid-js")

    let previous
    const dispose = createRoot((disposeRoot) => {
      createComputed(() => {
        const route = ctx.ui.router.current()
        // Session tabs keep several conversations open; only the active route is resumed.
        const sessionID = route?.type === "session" && typeof route.sessionID === "string" ? route.sessionID : null
        if (sessionID === previous) return
        previous = sessionID

        let cwd
        try {
          cwd = process.cwd()
        } catch {
          // A deleted working directory must not break the TUI.
        }
        void reportSession({ kind: "opencode", sessionID, cwd })
      })
      return disposeRoot
    })

    return () => {
      dispose()
      return reportSession({ kind: "opencode", sessionID: null, inactive: true })
    }
  },
}
