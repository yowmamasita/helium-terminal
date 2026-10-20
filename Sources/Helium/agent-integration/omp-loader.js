// Helium Terminal agent integration. Inert outside Helium.
export default async function helium(api) {
  const base = process.env.HELIUM_AGENT_INTEGRATION
  if (!base || !process.env.HELIUM_PANE_TOKEN) return
  const { default: activate } = await import(new URL("omp.mjs", base).href)
  return activate(api)
}
