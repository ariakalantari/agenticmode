const HARNESS = "opencode"
const SAFE_ID = /^[A-Za-z0-9._-]{1,180}$/

export const AgenticModePlugin = async ({ directory }) => {
  const active = new Map()
  const debug = process.env.AGENTICMODE_OPENCODE_DEBUG === "1"
  let queue = Promise.resolve()

  const report = (message) => {
    if (debug) console.error(`[agenticmode] ${message}`)
  }

  const invoke = async (...args) => {
    try {
      const child = Bun.spawn(["agenticmode", "activity", ...args], {
        stdout: "ignore",
        stderr: debug ? "inherit" : "ignore",
      })
      const status = await child.exited
      if (status !== 0) {
        report(`activity command exited with status ${status}`)
        return false
      }
      return true
    } catch (error) {
      report(`activity command could not run: ${error instanceof Error ? error.message : String(error)}`)
      return false
    }
  }

  const serialize = (operation) => {
    const result = queue.then(operation, operation)
    queue = result.catch(() => {})
    return result
  }

  const start = async (sessionID) => {
    if (!SAFE_ID.test(sessionID) || active.has(sessionID)) return
    const generation = `oc-${process.pid}-${Date.now()}-${crypto.randomUUID()}`
    if (await invoke("start", HARNESS, sessionID, String(process.pid), generation)) {
      active.set(sessionID, generation)
    }
  }

  const stop = async (sessionID) => {
    if (!SAFE_ID.test(sessionID)) return
    const generation = active.get(sessionID)
    const stopped = generation
      ? await invoke("stop", HARNESS, sessionID, String(process.pid), generation)
      : await invoke("stop-source", HARNESS, sessionID, String(process.pid))
    if (stopped) active.delete(sessionID)
  }

  const stopAll = async () => {
    for (const [sessionID, generation] of active) {
      await invoke("stop", HARNESS, sessionID, String(process.pid), generation)
    }
    active.clear()
    await invoke("stop-owner", HARNESS, String(process.pid))
  }

  return {
    event: ({ event }) => serialize(async () => {
      if (event.type === "session.status") {
        const sessionID = event.properties.sessionID
        const status = event.properties.status.type
        if (status === "busy" || status === "retry") await start(sessionID)
        if (status === "idle") await stop(sessionID)
        return
      }
      if (event.type === "session.idle") {
        await stop(event.properties.sessionID)
        return
      }
      if (event.type === "session.deleted") {
        await stop(event.properties.info.id)
        return
      }
      if (event.type === "server.instance.disposed" && event.properties.directory === directory) {
        await stopAll()
      }
    }),

    "shell.env": async (input, output) => {
      if (!input.sessionID || !SAFE_ID.test(input.sessionID)) return
      output.env.AGENTICMODE_CALLER_ACTIVITY_HARNESS = HARNESS
      output.env.AGENTICMODE_CALLER_ACTIVITY_SOURCE = input.sessionID
    },

    dispose: () => serialize(stopAll),
  }
}
