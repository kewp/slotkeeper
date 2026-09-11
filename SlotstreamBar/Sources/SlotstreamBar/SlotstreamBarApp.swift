import AppKit
import SwiftUI

/// Menu-bar prototype that supervises the local Slotstream server.
///
/// It never loads the model itself. It polls the localhost API for state and shells out to
/// `scripts/slotstream-ctl.sh` for lifecycle actions, so an engine failure cannot take down
/// the UI. Run with `swift run` from the package directory; the dock icon is suppressed.
@main
struct SlotstreamBarApp: App {
    @StateObject private var status = StatusModel()

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            StatusMenu(status: status)
        } label: {
            Label(status.menuTitle, systemImage: status.symbol)
                .labelStyle(.titleAndIcon)
        }
        .menuBarExtraStyle(.menu)
    }
}

struct StatusMenu: View {
    @ObservedObject var status: StatusModel

    var body: some View {
        Text(status.headline).font(.headline)
        ForEach(status.detailLines, id: \.self) { line in
            Text(line)
        }
        Divider()
        Button("Start (\(status.profileName))") { status.run("start") }.disabled(status.state != .stopped)
        Button("Stop") { status.run("stop") }.disabled(status.state == .stopped)
        Button("Restart") { status.run("restart") }.disabled(status.state == .stopped)
        Menu("Profile") {
            ForEach(["everyday", "conservative", "deep"], id: \.self) { name in
                Button(name + (name == status.profileName ? "  ✓" : "")) { status.run("profile", name) }
            }
            Text("Applies on next start. Keep OpenCode's context declaration in sync.").font(.caption)
        }
        Divider()
        if let req = status.activeRequest {
            Text("Active: \(req.source)").font(.headline)
            ForEach(req.lines, id: \.self) { Text($0) }
            if let cpu = status.serverCPU { Text(String(format: "server cpu %.0f%%", cpu)).font(.caption) }
        } else {
            Text("No request in flight").font(.headline)
        }
        Divider()
        Text(status.exerciserHeadline).font(.headline)
        if status.exerciser.installed {
            Text(status.exerciserSummary)
            ForEach(status.exerciser.last, id: \.self) { Text($0).font(.caption) }
            Button(status.exerciser.pauseFlag == nil ? "Pause Exerciser (save battery)" : "Resume Exerciser") { status.toggleExerciserPause() }
            Button("Stop Exerciser") { status.run("exerciser", "stop") }
        } else {
            Button("Start Exerciser") { status.run("exerciser", "start") }
        }
        Divider()
        Button("Copy Endpoint") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(status.endpoint, forType: .string)
        }
        Button("Open Server Log") { NSWorkspace.shared.open(status.logURL) }
        Button("Open Metrics Folder") { NSWorkspace.shared.open(status.metricsURL) }
        Button("Support Bundle") { status.run("bundle") }
        if let last = status.lastActionOutput, !last.isEmpty {
            Divider()
            Text(last).font(.caption).lineLimit(4)
        }
        Divider()
        Button("Quit SlotstreamBar") { NSApplication.shared.terminate(nil) }
    }
}

enum ServerState: String {
    case stopped, loading, ready, unhealthy
}

@MainActor
final class StatusModel: ObservableObject {
    @Published var state: ServerState = .stopped
    @Published var version = ""
    @Published var plan = PlanSummary()
    @Published var pressure = "unknown"
    @Published var freePercent: Int?
    @Published var lastActionOutput: String?
    @Published var profileName = "everyday"

    let home = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".slotstream")
    /// Settings shared with the scripts: ~/.slotstream/ctl.env (KEY=value), overridable by environment.
    static let settings: [String: String] = {
        var values: [String: String] = [:]
        let file = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".slotstream/ctl.env")
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            for line in text.split(separator: "\n") where line.contains("=") && !line.hasPrefix("#") {
                let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                values[parts[0]] = parts[1]
            }
        }
        for (key, value) in ProcessInfo.processInfo.environment where key.hasPrefix("SLOTSTREAM_") { values[key] = value }
        return values
    }()
    let endpoint = "http://localhost:\(StatusModel.settings["SLOTSTREAM_PORT"] ?? "11434")/v1"
    let model = StatusModel.settings["SLOTSTREAM_MODEL"] ?? "qwen3.8-flash-next:4bit"
    var logURL: URL { home.appendingPathComponent("slotstream.log") }
    var metricsURL: URL { home.appendingPathComponent("metrics") }

    /// The control script. Override with SLOTSTREAM_CTL when the repo lives elsewhere.
    lazy var ctlPath: String = {
        if let env = StatusModel.settings["SLOTSTREAM_CTL"] { return env }
        // Package dir -> repo root/scripts when run with `swift run`.
        let candidates = [
            URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/slotstream-ctl.sh").path,
            NSHomeDirectory() + "/opencode-model-stats/scripts/slotstream-ctl.sh",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[1]
    }()

    private var timer: Timer?
    private var apiBase: URL { URL(string: endpoint.replacingOccurrences(of: "/v1", with: ""))! }

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    var symbol: String {
        switch state {
        case .ready: return pressure == "critical" ? "exclamationmark.triangle.fill" : "brain.head.profile"
        case .loading: return "hourglass"
        case .unhealthy: return "exclamationmark.triangle"
        case .stopped: return "brain.head.profile"
        }
    }

    var menuTitle: String {
        switch state {
        case .ready: return plan.expertsPerLayer.map { "\($0)/L" } ?? "ready"
        case .loading: return "loading"
        case .unhealthy: return "!"
        case .stopped: return "off"
        }
    }

    var headline: String {
        switch state {
        case .ready: return "Slotstream \(version) ready"
        case .loading: return "Slotstream loading…"
        case .unhealthy: return "Slotstream not responding"
        case .stopped: return "Slotstream stopped"
        }
    }

    var detailLines: [String] {
        var lines = ["memory pressure \(pressure)" + (freePercent.map { ", \($0)% free" } ?? "")]
        guard state == .ready else { return lines }
        if let ctx = plan.maxContext { lines.append("context window \(ctx.formatted()) tokens") }
        if let e = plan.expertsPerLayer, let pool = plan.poolGB {
            lines.append("expert cache \(e)/layer (\(pool.formatted(.number.precision(.fractionLength(1)))) GB)")
        }
        if let d = plan.warmTokS, let p = plan.prefillTokS {
            lines.append("plan ~\(p.formatted(.number.precision(.fractionLength(0)))) prefill, ~\(d.formatted(.number.precision(.fractionLength(1)))) decode tok/s")
        }
        if let held = plan.prefixHeld, let max = plan.prefixMax {
            lines.append("prefix cache \(held.formatted())/\(max.formatted()) tokens")
        }
        if let note = plan.notes.last { lines.append(note) }
        return lines
    }

    // MARK: active request

    struct ActiveRequest {
        var source = ""            // "OpenCode (build)" or "Exerciser: code-review"
        var lines: [String] = []
    }
    @Published var activeRequest: ActiveRequest?
    @Published var serverCPU: Double?

    /// The newest prefill progress line from the server log, if it is newer than the request start
    /// and not yet followed by "prefill: done".
    private func prefillProgress(since start: Date?) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let span: UInt64 = 16_384
        try? handle.seek(toOffset: size > span ? size - span : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        let lines = text.split(separator: "\n").map(String.init)
        guard let last = lines.last(where: { $0.contains("prefill:") }) else { return nil }
        if last.contains("prefill: done") { return nil }
        // "[17:47:25] prefill: reading 19726 prompt tokens, ~2.0 min to the first token at this plan (...)"
        // "[17:28:40] prefill: 4096/9125 tokens (45%), ~52 s left"
        if let start, let stamp = last.split(separator: "]").first?.dropFirst() {
            let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
            let cal = Calendar.current
            if let t = f.date(from: String(stamp)) {
                var comps = cal.dateComponents([.year, .month, .day], from: start)
                let tc = cal.dateComponents([.hour, .minute, .second], from: t)
                comps.hour = tc.hour; comps.minute = tc.minute; comps.second = tc.second
                if let lineDate = cal.date(from: comps), lineDate < start.addingTimeInterval(-5) { return nil }
            }
        }
        var body = last
        if let r = body.range(of: "prefill: ") { body = String(body[r.upperBound...]) }
        if let r = body.range(of: " at this plan") { body = String(body[..<r.lowerBound]) }
        return "prefill " + body
    }

    private func readActiveRequest(exerciser: ExerciserState, exerciserProgress: [String: Any]?) -> ActiveRequest? {
        let iso = ISO8601DateFormatter()
        // OpenCode first: its marker is written by the plugin while a request is in flight.
        if let data = try? Data(contentsOf: home.appendingPathComponent("opencode-active")),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let startedMs = obj["startedAt"] as? Double {
            let start = Date(timeIntervalSince1970: startedMs / 1000)
            let updated = (obj["updatedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? start
            if Date().timeIntervalSince(updated) < 600 {
                var req = ActiveRequest(source: "OpenCode (\(obj["agent"] as? String ?? "request"))")
                let elapsed = Int(Date().timeIntervalSince(start))
                var first = "\(elapsed / 60)m \(elapsed % 60)s elapsed"
                if let prompt = obj["estimatedPromptTokens"] as? Int {
                    first += " | prompt ~\(prompt.formatted()) tok"
                    if let limit = obj["contextLimit"] as? Int, limit > 0 { first += " (\(prompt * 100 / limit)% of window)" }
                }
                req.lines.append(first)
                if let firstMs = obj["firstOutputAt"] as? Double {
                    let ttft = (firstMs - startedMs) / 1000
                    let chars = obj["outputChars"] as? Int ?? 0
                    let tools = obj["toolCalls"] as? Int ?? 0
                    let genSecs = max(1, Date().timeIntervalSince1970 - firstMs / 1000)
                    let rate = Double(chars) / 4 / genSecs
                    req.lines.append(String(format: "generating: TTFT %.0fs, ~%d tok out, ~%.1f tok/s, %d tool calls", ttft, chars / 4, rate, tools))
                } else if let p = prefillProgress(since: start) {
                    req.lines.append(p)
                } else {
                    req.lines.append("waiting for first output")
                }
                return req
            }
        }
        if let cur = exerciser.current {
            var req = ActiveRequest(source: "Exerciser: \(cur)")
            let elapsed = exerciser.currentStarted.map { Int(Date().timeIntervalSince($0)) } ?? 0
            var first = "\(elapsed / 60)m \(elapsed % 60)s elapsed"
            if let p = exerciserProgress, let prompt = p["prompt_tokens"] as? Int { first += " | prompt ~\(prompt.formatted()) tok" }
            req.lines.append(first)
            if let p = exerciserProgress, let ttft = p["ttft_s"] as? Double {
                let out = p["output_tokens"] as? Int ?? 0
                let rate = p["decode_tok_s"] as? Double ?? 0
                req.lines.append(String(format: "generating: TTFT %.1fs, %d tok out, %.1f tok/s", ttft, out, rate))
            } else if let p = prefillProgress(since: exerciser.currentStarted) {
                req.lines.append(p)
            } else {
                req.lines.append("waiting for first output")
            }
            return req
        }
        return nil
    }

    // MARK: exerciser

    struct ExerciserState {
        var installed = false
        var paused: String?
        var pauseFlag: String?
        var runs = 0, ok = 0, fail = 0, cycle = 0
        var current: String?
        var currentStarted: Date?
        var updated: Date?
        var last: [String] = []
        var progress: [String: Any]?
    }
    @Published var exerciser = ExerciserState()

    var exerciserHeadline: String {
        guard exerciser.installed else { return "Exerciser not installed" }
        if let flag = exerciser.pauseFlag { return "Exerciser paused: \(flag)" }
        if let cur = exerciser.current {
            let secs = exerciser.currentStarted.map { Int(Date().timeIntervalSince($0)) } ?? 0
            return "Exerciser running \(cur) (\(secs)s)"
        }
        if let why = exerciser.paused { return "Exerciser waiting: \(why)" }
        if let upd = exerciser.updated, Date().timeIntervalSince(upd) > 900 { return "Exerciser stale (no update for \(Int(Date().timeIntervalSince(upd) / 60)) min)" }
        return "Exerciser idle between tasks"
    }

    var exerciserSummary: String {
        "cycle \(exerciser.cycle) | \(exerciser.ok) ok, \(exerciser.fail) failed of \(exerciser.runs)"
    }

    private func readExerciser() -> ExerciserState {
        var st = ExerciserState()
        st.installed = FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/LaunchAgents/work.penz.slotstream-exerciser.plist")
        if let flag = try? String(contentsOf: home.appendingPathComponent("exerciser.pause"), encoding: .utf8) {
            st.pauseFlag = flag.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let data = try? Data(contentsOf: home.appendingPathComponent("exerciser.state.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return st }
        let iso = ISO8601DateFormatter()
        st.runs = obj["runs"] as? Int ?? 0
        st.ok = obj["ok"] as? Int ?? 0
        st.fail = obj["fail"] as? Int ?? 0
        st.cycle = obj["cycle"] as? Int ?? 0
        st.current = obj["current"] as? String
        st.paused = obj["paused"] as? String
        st.currentStarted = (obj["current_started"] as? String).flatMap { iso.date(from: $0) }
        st.updated = (obj["updated"] as? String).flatMap { iso.date(from: $0) }
        st.progress = obj["progress"] as? [String: Any]
        for item in (obj["last"] as? [[String: Any]] ?? []).prefix(4) {
            let task = item["task"] as? String ?? "?"
            let ok = item["ok"] as? Bool ?? false
            let ttft = (item["ttft_s"] as? Double).map { String(format: "%.1fs", $0) } ?? "–"
            let dec = (item["decode_tok_s"] as? Double).map { String(format: "%.1f tok/s", $0) } ?? "–"
            let prompt = (item["prompt_tokens"] as? Int).map { "\($0) tok" } ?? ""
            let note = (item["note"] as? String ?? "").prefix(40)
            st.last.append("\(ok ? "✓" : "✗") \(task) \(prompt) TTFT \(ttft) \(dec) \(note)")
        }
        return st
    }

    func toggleExerciserPause() {
        if exerciser.pauseFlag != nil { run("exerciser", "resume") } else { run("exerciser", "pause", "paused from menu bar") }
    }

    func refresh() {
        Task { [weak self] in
            guard let self else { return }
            let running = await Shell.run("/usr/bin/pgrep", ["-f", "slotstream serve"]).status == 0
            let version = await fetchVersion()
            let profile = (try? String(contentsOf: home.appendingPathComponent("profile"), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let (pressure, free) = await systemMemory()
            var plan = PlanSummary()
            if version != nil { plan = await fetchPlan() }
            let ex = readExerciser()
            let active = readActiveRequest(exerciser: ex, exerciserProgress: ex.progress)
            let cpu = await serverCPUPercent()
            await MainActor.run {
                self.exerciser = ex
                self.activeRequest = active
                self.serverCPU = cpu
                self.version = version ?? ""
                self.profileName = (profile?.isEmpty == false) ? profile! : "everyday"
                self.pressure = pressure
                self.freePercent = free
                self.plan = plan
                switch (running, version) {
                case (false, _): self.state = .stopped
                case (true, nil): self.state = plan.expertsPerLayer == nil && self.state != .ready ? .loading : .unhealthy
                case (true, .some): self.state = .ready
                }
            }
        }
    }

    func run(_ command: String, _ extra: String...) {
        Task { [weak self] in
            guard let self else { return }
            let args = [command] + extra
            let result = await Shell.run("/bin/bash", [ctlPath] + args, timeout: 240)
            let text = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run {
                self.lastActionOutput = text.split(separator: "\n").suffix(3).joined(separator: "\n")
                self.refresh()
            }
        }
    }

    private func serverCPUPercent() async -> Double? {
        let pid = await Shell.run("/usr/bin/pgrep", ["-f", "slotstream serve"]).stdout
            .split(separator: "\n").first.map(String.init) ?? ""
        guard !pid.isEmpty else { return nil }
        let out = await Shell.run("/bin/ps", ["-o", "%cpu=", "-p", pid]).stdout
        return Double(out.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "."))
    }

    private func fetchVersion() async -> String? {
        guard let data = await Http.get(apiBase.appendingPathComponent("api/version")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["version"] as? String
    }

    private func fetchPlan() async -> PlanSummary {
        var summary = PlanSummary()
        let body = try? JSONSerialization.data(withJSONObject: ["model": model])
        guard let data = await Http.post(apiBase.appendingPathComponent("api/show"), body: body ?? Data()),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let details = obj["details"] as? [String: Any] else { return summary }
        if let plan = details["memory_plan"] as? [String: Any] {
            summary.expertsPerLayer = plan["experts_per_layer_cached"] as? Int
            summary.poolGB = plan["pool_gb"] as? Double
            summary.maxContext = plan["max_context_tokens"] as? Int
            summary.prefillTokS = plan["est_prefill_tok_s"] as? Double
            summary.warmTokS = plan["est_warm_tok_s"] as? Double
            summary.notes = plan["notes"] as? [String] ?? []
        }
        if let cache = details["prefix_cache"] as? [String: Any] {
            summary.prefixHeld = cache["held_tokens"] as? Int
            summary.prefixMax = cache["max_tokens"] as? Int
        }
        return summary
    }

    private func systemMemory() async -> (String, Int?) {
        let level = await Shell.run("/usr/sbin/sysctl", ["-n", "kern.memorystatus_vm_pressure_level"]).stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pressure = ["1": "normal", "2": "warning", "4": "critical"][level] ?? "unknown"
        let text = await Shell.run("/usr/bin/memory_pressure", []).stdout
        var free: Int?
        if let range = text.range(of: #"free percentage:\s*(\d+)%"#, options: .regularExpression) {
            free = Int(text[range].filter(\.isNumber))
        }
        return (pressure, free)
    }
}

struct PlanSummary {
    var expertsPerLayer: Int?
    var poolGB: Double?
    var maxContext: Int?
    var prefillTokS: Double?
    var warmTokS: Double?
    var prefixHeld: Int?
    var prefixMax: Int?
    var notes: [String] = []
}

enum Http {
    static func get(_ url: URL) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "GET"
        return await send(request)
    }

    static func post(_ url: URL, body: Data) async -> Data? {
        var request = URLRequest(url: url, timeoutInterval: 3)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        return await send(request)
    }

    private static func send(_ request: URLRequest) async -> Data? {
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }
}

enum Shell {
    struct Result {
        var status: Int32
        var stdout: String
        var stderr: String
    }

    static func run(_ launchPath: String, _ arguments: [String], timeout: TimeInterval = 10) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: launchPath)
                process.arguments = arguments
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Result(status: -1, stdout: "", stderr: error.localizedDescription))
                    return
                }
                let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
                let stdout = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                deadline.cancel()
                continuation.resume(returning: Result(status: process.terminationStatus, stdout: stdout, stderr: stderr))
            }
        }
    }
}
