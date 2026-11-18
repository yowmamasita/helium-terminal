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
        // Busy and waiting for this pane's session, so Helium can show working, waiting and done.
        let state
        if (sessionID) {
          try {
            const session = api.state.session
            if (session.permission(sessionID)?.length || session.question(sessionID)?.length) state = "blocked"
            else state = (session.status(sessionID)?.type ?? "idle") === "idle" ? "idle" : "working"
          } catch {
            // An older or newer TUI without this API still reports the session.
          }
        }
        const key = `${sessionID}|${state}`
        if (key === previous) return
        previous = key

        let cwd
        try {
          cwd = process.cwd()
        } catch {
          // A deleted working directory must not break the TUI.
        }

        // Reporting atomically replaces metadata immediately, with no queue to retain.
        void reportSession({ kind: "opencode", sessionID, cwd, ...(state ? { state } : {}) })
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
