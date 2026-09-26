import AppKit
import SwiftUI

/// Owns the dashboard window directly.
///
/// A SwiftUI `Window` scene cannot be reopened from outside a view: once it is closed
/// nothing is left listening, so the Dock icon did nothing at all. An AppKit window the
/// delegate keeps a reference to can always be brought back.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static private(set) var shared: AppDelegate?
    private var dashboard: NSWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        AppDelegate.shared = self
        // SLOTKEEPER_RENDER=<dir>: write the menu panel and the Now tiles as PNGs with live
        // data, then quit. How the panels are checked without clicking through the UI.
        if let dir = ProcessInfo.processInfo.environment["SLOTKEEPER_RENDER"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { Self.render(to: dir) }
            return
        }
        // Opened as a login item it stays in the menu bar, like the old launchd start.
        let launch = NSAppleEventManager.shared().currentAppleEvent
        if launch?.eventID == AEEventID(kAEOpenApplication),
           launch?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
            return
        }
        // Started by launchd at login it stays in the menu bar; opened by hand, the
        // person wants to see something.
        if ProcessInfo.processInfo.environment["SLOTKEEPER_BACKGROUND"] == nil {
            showDashboard()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showDashboard()
        return true
    }

    static func render(to dir: String) {
        let status = StatusModel.shared
        let now = VStack(alignment: .leading, spacing: 14) {
            ActivityTile(status: status, large: true)
            HStack(alignment: .top, spacing: 14) { MemoryTile(status: status); SpeedTile(status: status) }
            JobsTile(status: status)
        }.padding(20).frame(width: 760)
        for (name, view) in [("menu-panel", AnyView(MenuPanel(status: status))), ("now-screen", AnyView(now))] {
            for (scheme, suffix) in [(ColorScheme.light, "light"), (.dark, "dark")] {
                let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme)
                    .background(Color(nsColor: scheme == .dark ? .black : .white)))
                renderer.scale = 2
                if let tiff = renderer.nsImage?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                   let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(suffix).png"))
                }
            }
        }
        NSApplication.shared.terminate(nil)
    }

    /// In the Dock only while the window is open: closing it leaves just the menu-bar item,
    /// and opening it again (menu, Spotlight, Finder) brings the Dock icon back.
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === dashboard else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    func showDashboard() {
        NSApplication.shared.setActivationPolicy(.regular)
        if let window = dashboard {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Slotkeeper"
        window.contentViewController = NSHostingController(rootView: DashboardView(status: .shared))
        window.setFrameAutosaveName("SlotkeeperDashboard")
        window.isReleasedWhenClosed = false   // closing must not destroy it; it reopens
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        dashboard = window
    }
}

/// Menu-bar prototype that supervises the local Slotstream server.
///
/// It never loads the model itself. It polls the localhost API for state and shells out to
/// `scripts/slotkeeper` for lifecycle actions, so an engine failure cannot take down
/// the UI. Run with `swift run` from the package directory; the dock icon is suppressed.
@main
struct SlotkeeperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        // Menu bar only until the dashboard opens; showDashboard adds the Dock icon, Cmd-Tab
        // and the Window menu, and closing the window takes them away again.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(status: .shared)
        } label: {
            MenuBarLabel(status: .shared)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(after: .windowList) {
                Button("Slotkeeper Dashboard") { AppDelegate.shared?.showDashboard() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }
}

/// The item in the menu bar: an icon, and a word or two only when something is happening.
struct MenuBarLabel: View {
    @ObservedObject var status: StatusModel

    var body: some View {
        let title = status.compactTitle
        if title.isEmpty {
            Image(systemName: status.symbol)
        } else {
            Label(title, systemImage: status.symbol).labelStyle(.titleAndIcon)
        }
    }
}

enum ServerState: String {
    case stopped, loading, ready, unhealthy
}

@MainActor
final class StatusModel: ObservableObject {
    /// One model for the menu bar and the dashboard window, which AppKit owns.
    static let shared = StatusModel()
    @Published var state: ServerState = .stopped
    @Published var version = ""
    @Published var plan = PlanSummary()
    @Published var pressure = "unknown"
    @Published var freePercent: Int?
    @Published var lastActionOutput: String?
    @Published var profileName = "everyday"
    @Published var serverMemoryGB: Double?
    @Published var lastRequest: LastRequest?
    @Published var activity: Activity = .idle

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
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/slotkeeper").path,
            NSHomeDirectory() + "/slotkeeper/scripts/slotkeeper",
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
        case .ready:
            if pressure == "critical" { return "exclamationmark.triangle.fill" }
            return jobs.running != nil ? "hammer.fill" : "brain.head.profile"
        case .loading: return "hourglass"
        case .unhealthy: return "exclamationmark.triangle"
        case .stopped: return "brain.head.profile"
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
        if let gb = serverMemoryGB {
            lines.append(String(format: "server using %.1f GB", gb)
                + (plan.peakGB.map { String(format: " (planned peak %.1f GB)", $0) } ?? ""))
        }
        if let last = lastRequest { lines.append(last.summary) }
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
        // Nobody claimed this one -- a calibration probe, a direct API call, anything
        // that writes no marker. The server log still knows, and a 47-minute prefill
        // showing nothing here is how we spent 2026-09-12 guessing at an ETA.
        if let p = prefillProgress(since: nil) {
            var req = ActiveRequest(source: "request in flight (no marker: calibration or direct API)")
            req.lines.append(p)
            return req
        }
        return nil
    }

    // MARK: exerciser

    /// The overnight job queue, read from the same files scripts/jobs.py writes.
    struct JobsState {
        var daemonInstalled = false
        var pauseFlag: String?
        var queued = 0
        var running: String?
        var runningStarted: Date?
        var lastResults: [String] = []
        var lines: [String] {
            var out: [String] = []
            if let r = running {
                let mins = runningStarted.map { Int(-$0.timeIntervalSinceNow / 60) }
                out.append("running" + (mins.map { " \($0) min" } ?? "") + ": " + r)
            }
            if queued > 0 { out.append("\(queued) queued") }
            return out + lastResults.prefix(2)
        }
    }

    @Published var jobs = JobsState()

    var jobsHeadline: String {
        if let flag = jobs.pauseFlag { return "Jobs paused: \(flag)" }
        if jobs.running != nil { return "Job running" }
        if jobs.queued > 0 { return jobs.daemonInstalled ? "\(jobs.queued) jobs waiting for the night window" : "\(jobs.queued) jobs queued (runner not installed)" }
        return jobs.daemonInstalled ? "No jobs queued" : "Job runner not installed"
    }

    private func readJobs() -> JobsState {
        var st = JobsState()
        st.daemonInstalled = FileManager.default.fileExists(
            atPath: NSHomeDirectory() + "/Library/LaunchAgents/local.slotkeeper-jobs.plist")
        let root = home.appendingPathComponent("jobs")
        if let flag = try? String(contentsOf: root.appendingPathComponent("jobs.pause"), encoding: .utf8) {
            st.pauseFlag = flag.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func files(_ folder: String) -> [URL] {
            ((try? FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "json" }.sorted { $0.path > $1.path }
        }
        st.queued = files("queued").count
        func job(_ url: URL) -> [String: Any]? {
            guard let d = try? Data(contentsOf: url) else { return nil }
            return try? JSONSerialization.jsonObject(with: d) as? [String: Any]
        }
        if let first = files("running").first, let o = job(first) {
            st.running = (o["label"] as? String ?? o["task"] as? String)?.prefix(50).description
            st.runningStarted = (o["started"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        }
        st.lastResults = files("done").prefix(2).compactMap { url in
            guard let o = job(url) else { return nil }
            let result = o["result"] as? String ?? "?"
            let mins = (o["elapsed_s"] as? Double).map { String(format: "%.0f min", $0 / 60) } ?? "–"
            return "\(result): \((o["task"] as? String ?? "").prefix(40)) (\(mins))"
        }
        return st
    }

    func toggleJobsPause() {
        let flag = home.appendingPathComponent("jobs/jobs.pause")
        if jobs.pauseFlag == nil {
            try? FileManager.default.createDirectory(at: home.appendingPathComponent("jobs"), withIntermediateDirectories: true)
            try? "paused from the menu bar".write(to: flag, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: flag)
        }
        refresh()
    }

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
        st.installed = FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/LaunchAgents/local.slotkeeper-exerciser.plist")
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
            let jobsState = readJobs()
            let active = readActiveRequest(exerciser: ex, exerciserProgress: ex.progress)
            let cpu = await serverCPUPercent()
            let memory = await serverPID().flatMap { pid_t($0) }.flatMap { physicalFootprintGB(pid: $0) }
            let last = LastRequest.fromLog(logURL)
            let activity = Activity.fromLog(logURL)
            await MainActor.run {
                self.serverMemoryGB = memory
                self.lastRequest = last
                self.activity = activity
                self.exerciser = ex
                self.jobs = jobsState
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

    /// The server itself. `pgrep -f "slotstream serve"` also matches the caffeinate
    /// wrapper launchd starts it under, and it could come first.
    private func serverPID() async -> String? {
        let pid = await Shell.run("/usr/bin/pgrep", ["-x", "slotstream"]).stdout
            .split(separator: "\n").first.map(String.init) ?? ""
        return pid.isEmpty ? nil : pid
    }

    private func serverCPUPercent() async -> Double? {
        guard let pid = await serverPID() else { return nil }
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
            summary.peakGB = plan["expected_peak_gb"] as? Double
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
    var peakGB: Double?
    var notes: [String] = []
}

/// The server's own record of its last finished request (the request-summary patch),
/// e.g. "[18:52:10] request: done, 3071 prompt tokens (3071 read at 93 tok/s, 0 reused),
/// 480 generated at 11.65 tok/s, first token after 33.6 s, finish stop".
struct LastRequest {
    var time = ""
    var failed: String?
    var promptTokens: Int?
    var prefillTokS: Double?
    var generated: Int?
    var decodeTokS: Double?
    var firstTokenS: Double?

    var summary: String {
        if let failed { return "last request \(time) failed: \(failed)" }
        var parts: [String] = []
        if let g = generated, let d = decodeTokS { parts.append(String(format: "%d tokens at %.2f tok/s", g, d)) }
        if let f = firstTokenS { parts.append(String(format: "first token %.0f s", f)) }
        if let p = prefillTokS, let n = promptTokens { parts.append(String(format: "read %d at %.0f tok/s", n, p)) }
        return "last request \(time): " + parts.joined(separator: ", ")
    }

    /// The last "request:" line in the tail of the server log, or nil.
    static func fromLog(_ url: URL) -> LastRequest? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8),
              let line = text.split(separator: "\n").last(where: { $0.contains("] request: ") }) else { return nil }
        return parse(String(line))
    }

    static func parse(_ s: String) -> LastRequest? {
        guard s.contains("] request: ") else { return nil }
        func match(_ pattern: String) -> String? {
            guard let r = s.range(of: pattern, options: .regularExpression) else { return nil }
            return String(s[r])
        }
        func number(_ pattern: String) -> Double? {
            guard let m = match(pattern) else { return nil }
            let digits = m.components(separatedBy: CharacterSet(charactersIn: "0123456789.").inverted)
                .first(where: { !$0.isEmpty && $0 != "." })
            return digits.flatMap(Double.init)
        }
        var last = LastRequest()
        last.time = match(#"^\[[^\]]+\]"#).map { String($0.dropFirst().dropLast()) } ?? ""
        if let r = s.range(of: "request: failed ") {
            last.failed = String(s[r.upperBound...]).prefix(80).description
            return last
        }
        last.promptTokens = number(#"done, \d+ prompt"#).map(Int.init)
        last.prefillTokS = number(#"read at [\d.]+ tok/s"#)
        last.generated = number(#"\d+ generated"#).map(Int.init)
        last.decodeTokS = number(#"generated at [\d.]+ tok/s"#)
        last.firstTokenS = number(#"first token after [\d.]+ s"#)
        return last
    }
}

/// The server's physical footprint: what Activity Monitor calls Memory. RSS is
/// meaningless here because the experts are memory-mapped from disk.
func physicalFootprintGB(pid: pid_t) -> Double? {
    var info = rusage_info_v4()
    let ok = withUnsafeMutablePointer(to: &info) { ptr in
        ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
    }
    return ok == 0 ? Double(info.ri_phys_footprint) / 1e9 : nil
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
