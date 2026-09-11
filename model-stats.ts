import type { Plugin } from "@opencode-ai/plugin"

const PROVIDER_ID = "slotstream"
const COMPLETED_TOAST_MS = 24 * 60 * 60 * 1000
const PREFILL_REFRESH_MS = 15 * 1000

type Timing = {
  firstOutputAt?: number
}

type InFlight = {
  agent: string
  contextLimit: number
  modelID: string
  runtimeURL?: string
  startedAt: number
  timer: ReturnType<typeof setInterval>
}

type RuntimeStats = {
  contextLimit?: number
  deviceRamGB?: number
  deviceWorkingSetGB?: number
  estimatedPrefillTokensPerSecond?: number
  estimatedWarmTokensPerSecond?: number
  expertsCachedPerLayer?: number
  expertsPerLayer?: number
  expectedPeakGB?: number
  fullyResident?: boolean
  modelMemoryBytes?: number
  prefixCacheEnabled?: boolean
  prefixCacheMaxTokens?: number
}

function formatDuration(milliseconds: number) {
  const seconds = milliseconds / 1000
  if (seconds < 60) return `${seconds.toFixed(1)}s`
  const minutes = Math.floor(seconds / 60)
  return `${minutes}m ${(seconds % 60).toFixed(0)}s`
}

function formatRate(tokens: number, milliseconds: number | undefined) {
  if (!milliseconds || milliseconds <= 0 || tokens <= 0) return "n/a"
  return `${(tokens / (milliseconds / 1000)).toFixed(1)} tok/s`
}

function formatBytes(bytes: number) {
  return `${(bytes / 1024 ** 3).toFixed(1)} GiB`
}

function formatSigned(value: number) {
  return `${value >= 0 ? "+" : ""}${value.toLocaleString()}`
}

function getRuntimeURL(baseURL: unknown) {
  if (typeof baseURL !== "string") return

  try {
    const url = new URL(baseURL)
    url.pathname = `${url.pathname.replace(/\/v1\/?$/, "").replace(/\/$/, "")}/api/ps`
    url.search = ""
    url.hash = ""
    return url.toString()
  } catch {
    return
  }
}

async function fetchRuntimeStats(runtimeURL: string, modelID: string): Promise<RuntimeStats | undefined> {
  try {
    const response = await fetch(runtimeURL, { signal: AbortSignal.timeout(2000) })
    if (!response.ok) return

    const body = (await response.json()) as {
      models?: Array<{
        model?: string
        name?: string
        size_vram?: number
        details?: {
          experts_per_layer?: number
          memory_plan?: {
            device_ram_gb?: number
            device_working_set_gb?: number
            est_prefill_tok_s?: number
            est_warm_tok_s?: number
            experts_per_layer_cached?: number
            expected_peak_gb?: number
            fully_resident?: boolean
            implementation_context_limit?: number
            prefix_cache_max_tokens?: number
            runtime_prefix_cache_enabled?: boolean
          }
        }
      }>
    }
    const model = body.models?.find((item) => item.model === modelID || item.name === modelID)
    if (!model) return

    const plan = model.details?.memory_plan
    return {
      contextLimit: plan?.implementation_context_limit,
      deviceRamGB: plan?.device_ram_gb,
      deviceWorkingSetGB: plan?.device_working_set_gb,
      estimatedPrefillTokensPerSecond: plan?.est_prefill_tok_s,
      estimatedWarmTokensPerSecond: plan?.est_warm_tok_s,
      expertsCachedPerLayer: plan?.experts_per_layer_cached,
      expertsPerLayer: model.details?.experts_per_layer,
      expectedPeakGB: plan?.expected_peak_gb,
      fullyResident: plan?.fully_resident,
      modelMemoryBytes: model.size_vram,
      prefixCacheEnabled: plan?.runtime_prefix_cache_enabled,
      prefixCacheMaxTokens: plan?.prefix_cache_max_tokens,
    }
  } catch {
    return
  }
}

export const ModelStats: Plugin = async ({ client, directory }) => {
  const timing = new Map<string, Timing>()
  const reported = new Set<string>()
  const messageAgents = new Map<string, string>()
  const inFlight = new Map<string, InFlight>()
  const runtimeByModel = new Map<string, RuntimeStats>()
  const runtimeURLByModel = new Map<string, string>()
  const contextByModel = new Map<string, number>()
  const previousPromptBySession = new Map<string, number>()

  const requestKey = (sessionID: string, agent: string) => `${sessionID}:${agent}`

  const showToast = async (title: string, message: string, duration: number) => {
    await client.tui.showToast({
      body: { title, message, variant: "info", duration },
      query: { directory },
    })
  }

  const stopPrefill = (sessionID: string, agent?: string) => {
    for (const [key, request] of inFlight) {
      if (!key.startsWith(`${sessionID}:`) || (agent && request.agent !== agent)) continue
      clearInterval(request.timer)
      inFlight.delete(key)
    }
  }

  const updateRuntime = async (modelID: string, runtimeURL: string) => {
    const runtime = await fetchRuntimeStats(runtimeURL, modelID)
    if (runtime) runtimeByModel.set(modelID, runtime)
    return runtime
  }

  const showPrefill = async (key: string) => {
    const request = inFlight.get(key)
    if (!request) return

    const runtime = runtimeByModel.get(request.modelID)
    const elapsed = formatDuration(Date.now() - request.startedAt)
    const details = [
      `waiting for first output | ${elapsed} elapsed`,
      `context limit ${(runtime?.contextLimit ?? request.contextLimit).toLocaleString()}`,
    ]
    if (runtime?.estimatedPrefillTokensPerSecond) {
      details.push(`plan ~${runtime.estimatedPrefillTokensPerSecond.toFixed(0)} prefill tok/s`)
    }
    if (runtime?.deviceWorkingSetGB && runtime.deviceRamGB) {
      details.push(`device ${runtime.deviceWorkingSetGB.toFixed(1)}/${runtime.deviceRamGB.toFixed(1)} GB`)
    }

    await showToast(`Model running: ${request.modelID} (${request.agent})`, details.join(" | "), PREFILL_REFRESH_MS + 2000)
  }

  const startPrefill = (
    sessionID: string,
    agent: string,
    modelID: string,
    contextLimit: number,
    runtimeURL?: string,
  ) => {
    const key = requestKey(sessionID, agent)
    stopPrefill(sessionID, agent)

    const request: InFlight = {
      agent,
      contextLimit,
      modelID,
      runtimeURL,
      startedAt: Date.now(),
      timer: setInterval(() => {
        const current = inFlight.get(key)
        if (!current) return
        if (current.runtimeURL) void updateRuntime(current.modelID, current.runtimeURL).then(() => showPrefill(key))
        else void showPrefill(key)
      }, PREFILL_REFRESH_MS),
    }
    inFlight.set(key, request)
    void showPrefill(key)
    if (runtimeURL) void updateRuntime(modelID, runtimeURL).then(() => showPrefill(key))
  }

  return {
    "chat.params": async (input) => {
      const providerID = input.provider?.info?.id ?? input.model.providerID
      if (providerID !== PROVIDER_ID || input.agent === "title") return

      const baseURL =
        input.provider?.options?.baseURL ??
        input.provider?.info?.options?.baseURL ??
        input.model.api.url
      const runtimeURL = getRuntimeURL(baseURL)
      contextByModel.set(input.model.id, input.model.limit.context)
      if (runtimeURL) runtimeURLByModel.set(input.model.id, runtimeURL)
      startPrefill(input.sessionID, input.agent, input.model.id, input.model.limit.context, runtimeURL)
    },

    event: async ({ event }) => {
      if (event.type === "session.idle") {
        stopPrefill(event.properties.sessionID)
        return
      }

      if (event.type === "message.part.updated") {
        const { part, delta } = event.properties
        const current = timing.get(part.messageID) ?? {}
        if (current.firstOutputAt) return

        const streamedText =
          (part.type === "text" || part.type === "reasoning") && Boolean(delta || part.text)
        const streamedTool =
          part.type === "tool" && (part.state.status !== "pending" || Boolean(part.state.raw))
        if (!streamedText && !streamedTool) return

        current.firstOutputAt = Date.now()
        timing.set(part.messageID, current)
        const agent = messageAgents.get(part.messageID)
        if (agent) stopPrefill(part.sessionID, agent)
        return
      }

      if (event.type !== "message.updated") return
      const info = event.properties.info
      if (info.role !== "assistant" || info.providerID !== PROVIDER_ID) return
      const agent = "agent" in info && typeof info.agent === "string" ? info.agent : info.mode
      if (agent === "title") return

      messageAgents.set(info.id, agent)
      const current = timing.get(info.id) ?? {}
      timing.set(info.id, current)
      if (!info.time.completed && !info.error) return

      stopPrefill(info.sessionID, agent)
      if (!info.time.completed || info.error || reported.has(info.id)) return

      reported.add(info.id)
      timing.delete(info.id)
      messageAgents.delete(info.id)
      if (reported.size > 500) reported.clear()

      const runtimeURL = runtimeURLByModel.get(info.modelID)
      const runtime = runtimeURL
        ? (await updateRuntime(info.modelID, runtimeURL)) ?? runtimeByModel.get(info.modelID)
        : runtimeByModel.get(info.modelID)
      const totalMs = Math.max(0, info.time.completed - info.time.created)
      const ttftMs = current.firstOutputAt
        ? Math.max(0, current.firstOutputAt - info.time.created)
        : undefined
      const decodeMs = current.firstOutputAt
        ? Math.max(0, info.time.completed - current.firstOutputAt)
        : undefined
      const fresh = info.tokens.input
      const cached = info.tokens.cache.read
      const cacheWrite = info.tokens.cache.write
      const output = info.tokens.output
      const reasoning = info.tokens.reasoning
      const prompt = fresh + cached
      const generated = output + reasoning
      const contextLimit = contextByModel.get(info.modelID) ?? runtime?.contextLimit
      const promptKey = requestKey(info.sessionID, agent)
      const previousPrompt = previousPromptBySession.get(promptKey)
      previousPromptBySession.set(promptKey, prompt)
      const cacheHitRate = prompt > 0 ? (cached / prompt) * 100 : 0

      const lines = [
        [
          `prompt ${prompt.toLocaleString()} (${fresh.toLocaleString()} new, ${cached.toLocaleString()} cached)`,
          `cache hit ${cacheHitRate.toFixed(1)}%${cacheWrite ? `, wrote ${cacheWrite.toLocaleString()}` : ""}`,
          previousPrompt === undefined ? "first step" : `change ${formatSigned(prompt - previousPrompt)}`,
        ].join(" | "),
        [
          `output ${output.toLocaleString()}${reasoning ? ` + ${reasoning.toLocaleString()} reasoning` : ""}`,
          `finish ${info.finish ?? "unknown"}`,
          `total ${formatDuration(totalMs)}`,
          `end-to-end ${formatRate(generated, totalMs)}`,
        ].join(" | "),
        [
          `TTFT ${ttftMs === undefined ? "n/a" : formatDuration(ttftMs)}`,
          `prefill ~${formatRate(fresh, ttftMs)}`,
          `decode ~${formatRate(generated, decodeMs)}`,
        ].join(" | "),
      ]

      if (contextLimit) {
        const headroom = Math.max(0, contextLimit - prompt)
        lines.splice(
          1,
          0,
          `context ${prompt.toLocaleString()}/${contextLimit.toLocaleString()} (${((prompt / contextLimit) * 100).toFixed(1)}%) | prompt headroom ${headroom.toLocaleString()}`,
        )
      }

      if (runtime) {
        const memory = []
        if (runtime.modelMemoryBytes) memory.push(`model ${formatBytes(runtime.modelMemoryBytes)}`)
        if (runtime.deviceWorkingSetGB && runtime.deviceRamGB) {
          memory.push(`device ${runtime.deviceWorkingSetGB.toFixed(1)}/${runtime.deviceRamGB.toFixed(1)} GB`)
        }
        if (runtime.expectedPeakGB) memory.push(`planned peak ${runtime.expectedPeakGB.toFixed(1)} GB`)
        if (memory.length) lines.push(memory.join(" | "))

        const residency = []
        if (runtime.expertsCachedPerLayer && runtime.expertsPerLayer) {
          residency.push(`experts ${runtime.expertsCachedPerLayer}/${runtime.expertsPerLayer}/layer`)
        }
        if (runtime.fullyResident !== undefined) {
          residency.push(runtime.fullyResident ? "fully resident" : "partial residency")
        }
        if (runtime.prefixCacheEnabled !== undefined) {
          residency.push(
            `prefix cache ${runtime.prefixCacheEnabled ? "on" : "off"}${runtime.prefixCacheMaxTokens ? ` (${runtime.prefixCacheMaxTokens.toLocaleString()} tok)` : ""}`,
          )
        }
        if (residency.length) lines.push(residency.join(" | "))

        const plannedRates = []
        if (runtime.estimatedPrefillTokensPerSecond) {
          plannedRates.push(`prefill ${runtime.estimatedPrefillTokensPerSecond.toFixed(0)} tok/s`)
        }
        if (runtime.estimatedWarmTokensPerSecond) {
          plannedRates.push(`warm decode ${runtime.estimatedWarmTokensPerSecond.toFixed(1)} tok/s`)
        }
        if (plannedRates.length) lines.push(`plan estimates: ${plannedRates.join(" | ")}`)
      }

      const summary = lines.join("\n")
      await Promise.allSettled([
        showToast(`Model stats: ${info.modelID} (${agent})`, summary, COMPLETED_TOAST_MS),
        client.app.log({
          body: {
            service: "model-stats",
            level: "info",
            message: summary.replaceAll("\n", " | "),
            extra: {
              sessionID: info.sessionID,
              messageID: info.id,
              modelID: info.modelID,
              agent,
              finish: info.finish ?? null,
              contextLimit: contextLimit ?? null,
              contextUsedPercent: contextLimit ? (prompt / contextLimit) * 100 : null,
              promptTokens: prompt,
              promptDelta: previousPrompt === undefined ? null : prompt - previousPrompt,
              freshInputTokens: fresh,
              cachedInputTokens: cached,
              cacheWriteTokens: cacheWrite,
              cacheHitRate,
              outputTokens: output,
              reasoningTokens: reasoning,
              ttftMs: ttftMs ?? null,
              decodeMs: decodeMs ?? null,
              totalMs,
              modelMemoryBytes: runtime?.modelMemoryBytes ?? null,
              deviceWorkingSetGB: runtime?.deviceWorkingSetGB ?? null,
              deviceRamGB: runtime?.deviceRamGB ?? null,
              expectedPeakGB: runtime?.expectedPeakGB ?? null,
              expertsCachedPerLayer: runtime?.expertsCachedPerLayer ?? null,
              expertsPerLayer: runtime?.expertsPerLayer ?? null,
              prefixCacheEnabled: runtime?.prefixCacheEnabled ?? null,
              prefixCacheMaxTokens: runtime?.prefixCacheMaxTokens ?? null,
            },
          },
        }),
      ])
    },
  }
}
