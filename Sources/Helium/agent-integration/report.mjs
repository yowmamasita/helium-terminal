import { writeFileSync, renameSync, unlinkSync } from "node:fs"
import { join } from "node:path"

let previous

// Tiny, atomic metadata files avoid a persistent connection, watcher, timer, or
// burst of socket clients while many panes resume at once. Never write prompts.
export function reportSession(selection) {
  const directory = process.env.HELIUM_AGENT_STATE_DIR
  const token = process.env.HELIUM_PANE_TOKEN
  if (!directory || !token || !process.env.HELIUM_PANE) return Promise.resolve()
  const record = JSON.stringify({ ...selection, pid: process.pid, token })
  if (record === previous) return Promise.resolve()
  const destination = join(directory, `${process.pid}.json`)
  const temporary = `${destination}.tmp`
  try {
    writeFileSync(temporary, record, { mode: 0o600 })
    renameSync(temporary, destination)
    previous = record
  } catch {
    // Closing Helium removes the pane directory. A failed report must not break an agent.
    try { unlinkSync(temporary) } catch {}
  }
  return Promise.resolve()
}
