// Helium Terminal agent integration. Inert outside Helium.
export default {
  id: "helium.session",
  async setup(ctx) {
    const base = process.env.HELIUM_AGENT_INTEGRATION
    if (!base || !process.env.HELIUM_PANE_TOKEN) return
    const { default: plugin } = await import(new URL("opencode-v2.mjs", base).href)
    return plugin.setup(ctx)
  },
}
