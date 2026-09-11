import type { Plugin } from "@opencode-ai/plugin"
import type { Part } from "@opencode-ai/sdk"
import { appendFileSync, mkdirSync, rmSync, writeFileSync } from "node:fs"
import { homedir } from "node:os"
import { join } from "node:path"

const PROVIDER_ID = "slotstream"
const COMPLETED_TOAST_MS = 24 * 60 * 60 * 1000
const PREFILL_REFRESH_MS = 15 * 1000
// Marker the background exerciser watches so it never competes with a real request.
const ACTIVE_MARKER = join(homedir(), ".slotstream", "opencode-active")
// One JSON line per completed or failed request, read by scripts/report.py and the app.
// client.app.log records do not reach OpenCode 1.18's log file, so this is the durable copy.
const METRICS_FILE = join(homedir(), ".slotstream", "metrics", "opencode.jsonl")

function recordMetrics<T extends Record<string, unknown>>(ok: boolean, extra: T): T {
  try {
    mkdirSync(join(homedir(), ".slotstream", "metrics"), { recursive: true })
    appendFileSync(METRICS_FILE, JSON.stringify({ ts: new Date().toISOString(), ok, ...extra }) + "\n")
  } catch {}
  return extra
}

type ActiveInfo = {
  sessionID: string
  agent: string
  modelID: string
  startedAt: number
  estimatedPromptTokens?: number
  contextLimit?: number
  firstOutputAt?: number
  outputChars: number
  toolCalls: number
  updatedAt: number
}
let active: ActiveInfo | undefined
let activeWrittenAt = 0

function writeActive(force = false) {
  if (!active) return
  const now = Date.now()
  if (!force && now - activeWrittenAt < 1000) return
  activeWrittenAt = now
  active.updatedAt = now
  try {
    mkdirSync(join(homedir(), ".slotstream"), { recursive: true })
    writeFileSync(ACTIVE_MARKER, JSON.stringify(active))
  } catch {}
}

function markActive(sessionID: string, agent: string, modelID: string, contextLimit?: number) {
  active = { sessionID, agent, modelID, startedAt: Date.now(), contextLimit, outputChars: 0, toolCalls: 0, updatedAt: Date.now() }
  writeActive(true)
}

function clearActive() {
  active = undefined
  try {
    rmSync(ACTIVE_MARKER, { force: true })
  } catch {}
}

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
  estimatedPromptTokens?: number
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
  prefillChunk?: number
  processResidentBytes?: number
  prefixCacheConversations?: number
  prefixCacheEnabled?: boolean
  prefixCacheEvictions?: number
  prefixCacheHeldGB?: number
  prefixCacheHeldTokens?: number
  prefixCacheHits?: number
  prefixCacheMaxTokens?: number
  prefixCacheMisses?: number
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

function estimatePartTokens(part: Part) {
  let value = ""
  if (part.type === "text" || part.type === "reasoning") value = part.text
  else if (part.type === "tool") value = JSON.stringify(part.state)
  else if (part.type === "subtask") value = `${part.description}\n${part.prompt}`
  else if (part.type === "file") value = `${part.filename ?? ""}\n${part.url}`
  else if (part.type === "patch") value = part.files.join("\n")

  return Math.ceil(value.length / 4) + 4
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
    const showURL = new URL(runtimeURL)
    showURL.pathname = showURL.pathname.replace(/\/api\/ps\/?$/, "/api/show")
    const [psResult, showResult] = await Promise.allSettled([
      fetch(runtimeURL, { signal: AbortSignal.timeout(2000) }),
      fetch(showURL, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ model: modelID }),
        signal: AbortSignal.timeout(2000),
      }),
    ])

    const psResponse = psResult.status === "fulfilled" && psResult.value.ok ? psResult.value : undefined
    const showResponse = showResult.status === "fulfilled" && showResult.value.ok ? showResult.value : undefined
    if (!psResponse && !showResponse) return

    const psBody = psResponse ? await psResponse.json() as {
      models?: Array<{
        model?: string
        name?: string
        size_vram?: number
        details?: {
          experts_per_layer?: number
          memory_plan?: MemoryPlan
        }
      }>
    } : undefined
    const showBody = showResponse ? await showResponse.json() as {
      details?: {
        experts_per_layer?: number
        memory_plan?: MemoryPlan
        prefix_cache?: PrefixCache
      }
    } : undefined
    const model = psBody?.models?.find((item) => item.model === modelID || item.name === modelID)
    const details = showBody?.details ?? model?.details
    if (!model && !details) return

    const plan = details?.memory_plan
    const cache = showBody?.details?.prefix_cache
    return {
      contextLimit: plan?.implementation_context_limit,
      deviceRamGB: plan?.device_ram_gb,
      deviceWorkingSetGB: plan?.device_working_set_gb,
      estimatedPrefillTokensPerSecond: plan?.est_prefill_tok_s,
      estimatedWarmTokensPerSecond: plan?.est_warm_tok_s,
      expertsCachedPerLayer: plan?.experts_per_layer_cached,
      expertsPerLayer: details?.experts_per_layer,
      expectedPeakGB: plan?.expected_peak_gb,
      fullyResident: plan?.fully_resident,
      prefillChunk: plan?.prefill_chunk,
      processResidentBytes: model?.size_vram,
      prefixCacheConversations: cache?.conversations,
      prefixCacheEnabled: cache?.enabled ?? plan?.runtime_prefix_cache_enabled,
      prefixCacheEvictions: cache?.evictions,
      prefixCacheHeldGB: cache?.held_gb,
      prefixCacheHeldTokens: cache?.held_tokens,
      prefixCacheHits: cache?.hits,
      prefixCacheMaxTokens: cache?.max_tokens ?? plan?.prefix_cache_max_tokens,
      prefixCacheMisses: cache?.misses,
    }
  } catch {
    return
  }
}

type MemoryPlan = {
  device_ram_gb?: number
  device_working_set_gb?: number
  est_prefill_tok_s?: number
  est_warm_tok_s?: number
  experts_per_layer_cached?: number
  expected_peak_gb?: number
  fully_resident?: boolean
  implementation_context_limit?: number
  prefill_chunk?: number
  prefix_cache_max_tokens?: number
  runtime_prefix_cache_enabled?: boolean
}

type PrefixCache = {
  conversations?: number
  enabled?: boolean
  evictions?: number
  held_gb?: number
  held_tokens?: number
  hits?: number
  max_tokens?: number
  misses?: number
}

type SystemMemoryStats = {
  availablePercent?: number
  pressure?: string
  swapUsedMB?: number
}

function errorDetails(error: unknown) {
  if (!error || typeof error !== "object") return { code: "unknown", message: String(error) }

  const value = error as { name?: string; data?: { message?: string } }
  const raw = value.data?.message ?? value.name ?? "unknown error"
  try {
    const parsed = JSON.parse(raw) as { code?: string; message?: string; type?: string }
    return {
      code: parsed.code ?? parsed.type ?? value.name ?? "unknown",
      message: parsed.message ?? raw,
    }
  } catch {
    return { code: value.name ?? "unknown", message: raw }
  }
}

export const ModelStats: Plugin = async ({ client, directory, $ }) => {
  const timing = new Map<string, Timing>()
  const reported = new Set<string>()
  const messageAgents = new Map<string, string>()
  const inFlight = new Map<string, InFlight>()
  const runtimeByModel = new Map<string, RuntimeStats>()
  const runtimeURLByModel = new Map<string, string>()
  const contextByModel = new Map<string, number>()
  const previousPromptBySession = new Map<string, number>()

  const requestKey = (sessionID: string, agent: string) => `${sessionID}:${agent}`

  const showToast = async (
    title: string,
    message: string,
    duration: number,
    variant: "info" | "success" | "warning" | "error" = "info",
  ) => {
    await client.tui.showToast({
      body: { title, message, variant, duration },
      query: { directory },
    })
  }

  const getSystemMemoryStats = async (): Promise<SystemMemoryStats> => {
    const [pressureResult, levelResult, swapResult] = await Promise.allSettled([
      $`memory_pressure`.quiet().nothrow(),
      $`sysctl -n kern.memorystatus_vm_pressure_level`.quiet().nothrow(),
      $`sysctl -n vm.swapusage`.quiet().nothrow(),
    ])
    const pressureText = pressureResult.status === "fulfilled" ? pressureResult.value.text() : ""
    const levelText = levelResult.status === "fulfilled" ? levelResult.value.text().trim() : ""
    const swapText = swapResult.status === "fulfilled" ? swapResult.value.text() : ""
    const available = pressureText.match(/System-wide memory free percentage:\s*(\d+)%/)
    const swap = swapText.match(/used\s*=\s*([\d.,]+)M/)
    const pressure = levelText === "4" ? "critical" : levelText === "2" ? "warning" : levelText === "1" ? "normal" : undefined

    return {
      availablePercent: available ? Number(available[1]) : undefined,
      pressure,
      swapUsedMB: swap ? Number(swap[1]?.replace(",", ".")) : undefined,
    }
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

  const estimatePromptTokens = async (sessionID: string, agent: string) => {
    try {
      const response = await client.session.messages({
        path: { id: sessionID },
        query: { directory, limit: 200 },
      })
      const messages = response.data
      if (!messages) return previousPromptBySession.get(requestKey(sessionID, agent))

      const baselineIndex = messages.findLastIndex(({ info }) =>
        info.role === "assistant" &&
        info.providerID === PROVIDER_ID &&
        info.mode === agent &&
        Boolean(info.time.completed) &&
        !info.error,
      )
      if (baselineIndex < 0) return

      const baseline = messages[baselineIndex]?.info
      if (!baseline || baseline.role !== "assistant") return
      const baselineTokens = baseline.tokens.input + baseline.tokens.cache.read
      const addedTokens = messages.slice(baselineIndex).reduce(
        (total, message) => total + 4 + message.parts.reduce((sum, part) => sum + estimatePartTokens(part), 0),
        0,
      )
      return baselineTokens + addedTokens
    } catch {
      return previousPromptBySession.get(requestKey(sessionID, agent))
    }
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
    if (request.estimatedPromptTokens && runtime?.estimatedPrefillTokensPerSecond) {
      const totalSeconds = request.estimatedPromptTokens / runtime.estimatedPrefillTokensPerSecond
      const remainingSeconds = Math.max(0, totalSeconds - (Date.now() - request.startedAt) / 1000)
      details.push(
        `prompt ~${request.estimatedPromptTokens.toLocaleString()} tok`,
        `cache-miss ETA ~${formatDuration(totalSeconds * 1000)} (${formatDuration(remainingSeconds * 1000)} left)`,
      )
    }
    if (runtime?.estimatedPrefillTokensPerSecond) {
      details.push(
        `plan ~${runtime.estimatedPrefillTokensPerSecond.toFixed(0)} prefill tok/s${runtime.prefillChunk ? ` @ ${runtime.prefillChunk}-tok chunks` : ""}`,
      )
    }
    if (runtime?.prefixCacheEnabled && runtime.prefixCacheMaxTokens !== undefined) {
      details.push(
        `prefix cache ${(runtime.prefixCacheHeldTokens ?? 0).toLocaleString()}/${runtime.prefixCacheMaxTokens.toLocaleString()} tok held`,
      )
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
      markActive(input.sessionID, input.agent, input.model.id, input.model.limit.context)
      startPrefill(input.sessionID, input.agent, input.model.id, input.model.limit.context, runtimeURL)
      const key = requestKey(input.sessionID, input.agent)
      void estimatePromptTokens(input.sessionID, input.agent).then((estimatedPromptTokens) => {
        const request = inFlight.get(key)
        if (!request || !estimatedPromptTokens) return
        request.estimatedPromptTokens = estimatedPromptTokens
        if (active && active.sessionID === input.sessionID) {
          active.estimatedPromptTokens = estimatedPromptTokens
          writeActive(true)
        }
        void showPrefill(key)
      })
    },

    event: async ({ event }) => {
      if (event.type === "session.status" && event.properties.status.type === "retry") {
        const tracked = [...inFlight.entries()].find(([key]) =>
          key.startsWith(`${event.properties.sessionID}:`),
        )?.[1]
        if (!tracked) return

        const waitMs = Math.max(0, event.properties.status.next - Date.now())
        await showToast(
          `Slotstream recovering: attempt ${event.properties.status.attempt}/5`,
          `${event.properties.status.message} | retrying in ${formatDuration(waitMs)}`,
          Math.max(3000, waitMs + 1000),
          "warning",
        )
        return
      }

      if (event.type === "session.idle") {
        stopPrefill(event.properties.sessionID)
        if (inFlight.size === 0) clearActive()
        return
      }

      if (event.type === "message.part.updated") {
        const { part, delta } = event.properties
        if (active && active.sessionID === part.sessionID) {
          if ((part.type === "text" || part.type === "reasoning") && delta) active.outputChars += delta.length
          else if (part.type === "tool" && part.state.status === "completed") active.toolCalls += 1
          writeActive()
        }
        const current = timing.get(part.messageID) ?? {}
        if (current.firstOutputAt) return

        const streamedText =
          (part.type === "text" || part.type === "reasoning") && Boolean(delta || part.text)
        const streamedTool =
          part.type === "tool" && (part.state.status !== "pending" || Boolean(part.state.raw))
        if (!streamedText && !streamedTool) return

        current.firstOutputAt = Date.now()
        if (active && active.sessionID === part.sessionID && !active.firstOutputAt) {
          active.firstOutputAt = current.firstOutputAt
          writeActive(true)
        }
        timing.set(part.messageID, current)
        stopPrefill(part.sessionID)
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
      if (inFlight.size === 0) clearActive()
      if (info.error) {
        if (reported.has(info.id)) return
        reported.add(info.id)
        timing.delete(info.id)
        messageAgents.delete(info.id)
        if (reported.size > 500) reported.clear()

        const runtimeURL = runtimeURLByModel.get(info.modelID)
        const [runtime, systemMemory] = await Promise.all([
          runtimeURL
            ? updateRuntime(info.modelID, runtimeURL).then((value) => value ?? runtimeByModel.get(info.modelID))
            : Promise.resolve(runtimeByModel.get(info.modelID)),
          getSystemMemoryStats(),
        ])
        const error = errorDetails(info.error)
        const elapsedMs = Math.max(0, (info.time.completed ?? Date.now()) - info.time.created)
        const lines = [
          `${error.code}: ${error.message}`,
          `failed ${current.firstOutputAt ? "after" : "before"} first output after ${formatDuration(elapsedMs)}`,
        ]
        if (runtime) {
          const plan = []
          if (runtime.processResidentBytes) plan.push(`process resident ${formatBytes(runtime.processResidentBytes)}`)
          if (runtime.expectedPeakGB) plan.push(`planned peak ${runtime.expectedPeakGB.toFixed(1)} GB`)
          if (runtime.expertsCachedPerLayer && runtime.expertsPerLayer) {
            plan.push(`experts ${runtime.expertsCachedPerLayer}/${runtime.expertsPerLayer}/layer`)
          }
          if (plan.length) lines.push(plan.join(" | "))
          if (runtime.prefixCacheHits !== undefined && runtime.prefixCacheMisses !== undefined) {
            lines.push(
              `prefix cache ${runtime.prefixCacheHits} hits, ${runtime.prefixCacheMisses} misses, ${runtime.prefixCacheEvictions ?? 0} evictions | ${(runtime.prefixCacheHeldTokens ?? 0).toLocaleString()} tok held`,
            )
          }
        }
        const memory = []
        if (systemMemory.pressure) memory.push(`pressure ${systemMemory.pressure}`)
        if (systemMemory.availablePercent !== undefined) memory.push(`${systemMemory.availablePercent}% available`)
        if (systemMemory.swapUsedMB !== undefined) memory.push(`swap ${systemMemory.swapUsedMB.toFixed(0)} MB`)
        if (memory.length) lines.push(`macOS after failure: ${memory.join(" | ")}`)

        const summary = lines.join("\n")
        await Promise.allSettled([
          showToast(`Model failed: ${info.modelID} (${agent})`, summary, COMPLETED_TOAST_MS, "error"),
          client.app.log({
            body: {
              service: "model-stats",
              level: "error",
              message: summary.replaceAll("\n", " | "),
              extra: recordMetrics(false, {
                sessionID: info.sessionID,
                messageID: info.id,
                modelID: info.modelID,
                agent,
                errorCode: error.code,
                errorMessage: error.message,
                elapsedMs,
                pressure: systemMemory.pressure ?? null,
                availableMemoryPercent: systemMemory.availablePercent ?? null,
                swapUsedMB: systemMemory.swapUsedMB ?? null,
                processResidentBytes: runtime?.processResidentBytes ?? null,
                expectedPeakGB: runtime?.expectedPeakGB ?? null,
                expertsCachedPerLayer: runtime?.expertsCachedPerLayer ?? null,
                prefixCacheHeldTokens: runtime?.prefixCacheHeldTokens ?? null,
                prefixCacheHits: runtime?.prefixCacheHits ?? null,
                prefixCacheMisses: runtime?.prefixCacheMisses ?? null,
                prefixCacheEvictions: runtime?.prefixCacheEvictions ?? null,
              }),
            },
          }),
        ])
        return
      }
      if (!info.time.completed || reported.has(info.id)) return

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
        if (runtime.processResidentBytes) memory.push(`process resident ${formatBytes(runtime.processResidentBytes)}`)
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

        if (runtime.prefixCacheHits !== undefined && runtime.prefixCacheMisses !== undefined) {
          lines.push(
            [
              `prefix runtime ${runtime.prefixCacheHits} hits, ${runtime.prefixCacheMisses} misses, ${runtime.prefixCacheEvictions ?? 0} evictions`,
              `${(runtime.prefixCacheHeldTokens ?? 0).toLocaleString()} tok held${runtime.prefixCacheHeldGB !== undefined ? ` (${runtime.prefixCacheHeldGB.toFixed(2)} GB)` : ""}`,
              `${runtime.prefixCacheConversations ?? 0} conversations`,
            ].join(" | "),
          )
        }

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
            extra: recordMetrics(true, {
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
              processResidentBytes: runtime?.processResidentBytes ?? null,
              deviceWorkingSetGB: runtime?.deviceWorkingSetGB ?? null,
              deviceRamGB: runtime?.deviceRamGB ?? null,
              expectedPeakGB: runtime?.expectedPeakGB ?? null,
              expertsCachedPerLayer: runtime?.expertsCachedPerLayer ?? null,
              expertsPerLayer: runtime?.expertsPerLayer ?? null,
              prefixCacheEnabled: runtime?.prefixCacheEnabled ?? null,
              prefixCacheEvictions: runtime?.prefixCacheEvictions ?? null,
              prefixCacheHeldGB: runtime?.prefixCacheHeldGB ?? null,
              prefixCacheHeldTokens: runtime?.prefixCacheHeldTokens ?? null,
              prefixCacheHits: runtime?.prefixCacheHits ?? null,
              prefixCacheMaxTokens: runtime?.prefixCacheMaxTokens ?? null,
              prefixCacheMisses: runtime?.prefixCacheMisses ?? null,
            }),
          },
        }),
      ])
    },
  }
}
