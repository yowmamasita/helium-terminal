import { reportSession } from "./report.mjs"

// OpenCode v1.18.34 injects its own Solid runtime into local TUI plugins.
// Read the frontend route, not backend session activity or the startup argv.
export default {
  id: "helium.session",
  async tui(api) {
    if (!process.env.HELIUM_PANE || !process.env.HELIUM_SOCKET || !process.env.HELIUM_PANE_TOKEN) return
    if (api.lifecycle.signal.aborted) return

    const { createRoot, createComputed } = await import("solid-js")
    if (api.lifecycle.signal.aborted) return

    let previous
    const dispose = createRoot((disposeRoot) => {
      createComputed(() => {
        const route = api.route.current
        const sessionID = route.name === "session" && typeof route.params?.sessionID === "string"
          ? route.params.sessionID
          : null
        if (sessionID === previous) return
        previous = sessionID

        let cwd
        try {
          cwd = process.cwd()
        } catch {
          // A deleted working directory must not break the TUI.
        }

        // Reporting atomically replaces metadata immediately, with no queue to retain.
        void reportSession({ kind: "opencode", sessionID, cwd })
      })
      return disposeRoot
    })

    api.lifecycle.onDispose(() => {
      // Disabling the plugin must not leave a stale selected session behind.
      dispose()
      return reportSession({ kind: "opencode", sessionID: null, inactive: true })
    })
  },
}
