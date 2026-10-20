import { existsSync } from "node:fs"
import { reportSession } from "./report.mjs"

export default function activate(api) {
  if (!process.env.HELIUM_PANE_TOKEN || !process.env.HELIUM_AGENT_STATE_DIR) return

  async function report(_event, ctx) {
    if (!ctx.hasUI || ctx.mode !== "tui") return
    const manager = ctx.sessionManager
    const sessionFile = manager.getSessionFile()
    if (!sessionFile) return reportSession({ kind: "omp", sessionID: null })
    // Omp's public SessionManager is passed through as a read-only TS view.
    // Materialize an untouched session's header so a passive resume has a real
    // journal. This writes no prompt and does not start an agent turn.
    if (!existsSync(sessionFile)) await manager.ensureOnDisk()
    return reportSession({ kind: "omp", sessionID: manager.getSessionId(), sessionFile, cwd: ctx.cwd })
  }

  api.on("session_start", report)
  api.on("session_switch", report)
  api.on("session_branch", report)
}
