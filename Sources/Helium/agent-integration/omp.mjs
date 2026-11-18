import { existsSync } from "node:fs"
import { reportSession } from "./report.mjs"

// Shared by omp and Pi (omp is a Pi fork; a shared PI_CODING_AGENT_DIR loads this in both).
// Pi's read-only session manager has no ensureOnDisk, which is how the host is told apart.
export default function activate(api) {
  if (!process.env.HELIUM_PANE_TOKEN || !process.env.HELIUM_AGENT_STATE_DIR) return

  async function report(_event, ctx) {
    if (!ctx.hasUI || ctx.mode !== "tui") return
    const manager = ctx.sessionManager
    const kind = typeof manager.ensureOnDisk === "function" ? "omp" : "pi"
    const sessionFile = manager.getSessionFile()
    if (!sessionFile) return reportSession({ kind, sessionID: null })
    // Omp's public SessionManager is passed through as a read-only TS view.
    // Materialize an untouched session's header so a passive resume has a real
    // journal. This writes no prompt and does not start an agent turn. Pi writes
    // the file with the first message; Helium starts it fresh until then.
    if (kind === "omp" && !existsSync(sessionFile)) await manager.ensureOnDisk()
    return reportSession({ kind, sessionID: manager.getSessionId(), sessionFile, cwd: ctx.cwd })
  }

  // Pi re-emits session_start for /new, /resume and /fork; omp has the other two events.
  api.on("session_start", report)
  api.on("session_switch", report)
  api.on("session_branch", report)
}
