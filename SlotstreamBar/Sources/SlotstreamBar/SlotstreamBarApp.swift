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
    let endpoint = ProcessInfo.processInfo.environment["SLOTSTREAM_BASE_URL"] ?? "http://localhost:11434/v1"
    let model = ProcessInfo.processInfo.environment["SLOTSTREAM_MODEL"] ?? "qwen3.8-flash-next:4bit"
    var logURL: URL { home.appendingPathComponent("slotstream.log") }
    var metricsURL: URL { home.appendingPathComponent("metrics") }

    /// The control script. Override with SLOTSTREAM_CTL when the repo lives elsewhere.
    lazy var ctlPath: String = {
        if let env = ProcessInfo.processInfo.environment["SLOTSTREAM_CTL"] { return env }
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
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
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
            await MainActor.run {
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

    func run(_ command: String, _ arg: String? = nil) {
        Task { [weak self] in
            guard let self else { return }
            var args = [command]
            if let arg { args.append(arg) }
            let result = await Shell.run("/bin/bash", [ctlPath] + args, timeout: 240)
            let text = (result.stdout + result.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            await MainActor.run {
                self.lastActionOutput = text.split(separator: "\n").suffix(3).joined(separator: "\n")
                self.refresh()
            }
        }
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
