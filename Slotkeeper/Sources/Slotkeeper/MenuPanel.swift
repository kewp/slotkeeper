import AppKit
import Charts
import ServiceManagement
import SwiftUI

/// Open at Login, as a system login item (System Settings › General › Login Items).
/// Off unless turned on here; the model itself never loads at login.
enum LoginItem {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// nil on success, otherwise what went wrong, in words.
    @discardableResult
    static func set(_ on: Bool) -> String? {
        guard on != isOn else { return nil }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            return error.localizedDescription
        }
        return needsApproval ? "Allow Slotkeeper in System Settings › General › Login Items" : nil
    }
}

/// The idle stop is a small LaunchAgent (`slotkeeper idle`); its plist is the switch.
enum IdleStop {
    static var isOn: Bool {
        FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/LaunchAgents/local.slotkeeper-idle.plist")
    }
}

// The highlights: what the model is doing, the memory it takes, how fast it writes,
// and the jobs. Shared by the menu-bar panel and the dashboard's Now screen, so both
// say the same thing the same way. The technical detail lives under Advanced.

/// What the model is doing right now, read from the server log, which every client
/// shares: prefill lines while it reads a prompt, "prefill: done" once it starts
/// writing, and the request-summary line when the reply is finished. Prompts under
/// 2K tokens log no prefill lines, so a short request shows as idle until it ends.
enum Activity: Equatable {
    case idle
    case reading(done: Int, total: Int, left: String?)
    case writing

    static func fromLog(_ url: URL) -> Activity {
        guard let text = LogTail.read(url, bytes: 16_384),
              let last = text.split(separator: "\n").last(where: {
                  $0.contains("] prefill: ") || $0.contains("] request: ") || $0.contains(" exec ")
              }).map(String.init) else { return .idle }
        if last.contains("] request: ") || last.contains(" exec ") { return .idle }
        if last.contains("prefill: done") { return .writing }
        // "prefill: 4096/9125 tokens (45%), ~52 s left"
        if let r = last.range(of: #"prefill: \d+/\d+"#, options: .regularExpression) {
            let nums = last[r].dropFirst("prefill: ".count).split(separator: "/").compactMap { Int($0) }
            let left = last.range(of: #"~[^,]+ left"#, options: .regularExpression)
                .map { String(last[$0].dropFirst().dropLast(" left".count)) }
            if nums.count == 2 { return .reading(done: nums[0], total: nums[1], left: left) }
        }
        // "prefill: reading 9516 prompt tokens, ~1.3 min to the first token ..."
        if let r = last.range(of: #"reading \d+"#, options: .regularExpression),
           let total = Int(last[r].dropFirst("reading ".count)) {
            let left = last.range(of: #"~[^ ]+ [a-z]+ to the first"#, options: .regularExpression)
                .map { String(last[$0].dropFirst().dropLast(" to the first".count)) }
            return .reading(done: 0, total: total, left: left)
        }
        return .idle
    }
}

enum LogTail {
    static func read(_ url: URL, bytes: UInt64) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > bytes ? size - bytes : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Every finished request still in the log tail, oldest first, for the Now chart.
struct RecentReply: Identifiable {
    let id: Int
    let request: LastRequest

    static func fromLog(_ url: URL, limit: Int = 30) -> [RecentReply] {
        guard let text = LogTail.read(url, bytes: 262_144) else { return [] }
        let lines = text.split(separator: "\n").filter { $0.contains("] request: done") }.suffix(limit)
        return lines.enumerated().compactMap { i, line in
            LastRequest.parse(String(line)).map { RecentReply(id: i, request: $0) }
        }
    }
}

extension StatusModel {
    /// The menu bar text: nothing when idle (the icon says enough), otherwise a word or two.
    var compactTitle: String {
        switch state {
        case .stopped: return "Off"
        case .loading: return "Starting"
        case .unhealthy: return "!"
        case .ready:
            switch activity {
            case .reading(let done, let total, _): return total > 0 ? "\(done * 100 / total)%" : "Reading"
            case .writing: return "Writing"
            case .idle:
                if let started = jobs.runningStarted { return "Job \(Int(-started.timeIntervalSinceNow / 60))m" }
                return ""
            }
        }
    }

    var statusColor: Color {
        switch state {
        case .ready: return pressure == "critical" ? .red : (pressure == "warning" ? .orange : .green)
        case .loading: return .yellow
        case .unhealthy: return .red
        case .stopped: return .gray
        }
    }

    var statusText: String {
        switch state {
        case .ready: return "Ready"
        case .loading: return "Starting up"
        case .unhealthy: return "Not responding"
        case .stopped: return "Stopped"
        }
    }

    /// The model's share, other apps, and what macOS can hand out, in GB. "Available"
    /// counts the file cache: most of it is model weights read from disk, which macOS
    /// drops the moment an app needs the memory.
    var memorySplit: (model: Double, apps: Double, available: Double, total: Double)? {
        let total = Double(ProcessInfo.processInfo.physicalMemory) / 1e9
        guard let free = freePercent else { return nil }
        let available = total * Double(free) / 100
        let model = min(serverMemoryGB ?? 0, total - available)
        return (model, max(0, total - available - model), available, total)
    }

    var roomText: String {
        switch pressure {
        case "critical": return "Out of memory: requests may pause"
        case "warning": return "Tight: the model slows down to make room"
        default: return "Your Mac has room to spare"
        }
    }

    var roomColor: Color {
        switch pressure {
        case "critical": return .red
        case "warning": return .orange
        default: return .green
        }
    }
}

// MARK: - Tiles

struct Tile<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

/// What the model is doing, as a big icon and one line.
struct ActivityTile: View {
    @ObservedObject var status: StatusModel
    var large = false

    var body: some View {
        Tile(title: "Now", symbol: "sparkles") {
            HStack(spacing: 14) {
                symbolView
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline).font(large ? .title3.weight(.semibold) : .headline)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var job: String? { status.jobs.running }

    @ViewBuilder private var symbolView: some View {
        let size: CGFloat = large ? 56 : 42
        switch (status.state, status.activity) {
        case (.ready, .reading(let done, let total, _)):
            ZStack {
                Circle().stroke(Color.accentColor.opacity(0.2), lineWidth: 5)
                Circle().trim(from: 0, to: CGFloat(done) / CGFloat(max(total, 1)))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(done * 100 / max(total, 1))%").font(.caption.monospacedDigit().weight(.semibold))
            }
            .frame(width: size, height: size)
        default:
            Image(systemName: symbol)
                .font(.system(size: size * 0.5))
                .foregroundStyle(color)
                .frame(width: size, height: size)
                .background(Circle().fill(color.opacity(0.12)))
        }
    }

    private var symbol: String {
        switch status.state {
        case .stopped: return "moon.zzz.fill"
        case .loading: return "hourglass"
        case .unhealthy: return "exclamationmark.triangle.fill"
        case .ready:
            switch status.activity {
            case .writing: return "pencil.line"
            case .reading: return "book"
            case .idle: return job != nil ? "hammer.fill" : "checkmark.circle.fill"
            }
        }
    }

    private var color: Color {
        switch status.state {
        case .stopped: return .gray
        case .loading: return .yellow
        case .unhealthy: return .red
        case .ready: return status.activity == .idle && job == nil ? .green : .accentColor
        }
    }

    private var headline: String {
        switch status.state {
        case .stopped: return "The model is off"
        case .loading: return "Loading the model"
        case .unhealthy: return "Not responding"
        case .ready:
            switch status.activity {
            case .reading: return "Reading the prompt"
            case .writing: return "Writing a reply"
            case .idle: return job != nil ? "Job between steps" : "Idle"
            }
        }
    }

    private var detail: String? {
        switch status.state {
        case .ready:
            switch status.activity {
            case .reading(let done, let total, let left):
                return "\(done.formatted()) of \(total.formatted()) tokens" + (left.map { " · \($0) left" } ?? "")
            case .writing, .idle:
                if let job { return "for “\(job)”" }
                return status.activity == .idle ? "Waiting for a request" : nil
            }
        case .stopped: return "It loads when you start it or a job needs it"
        default: return nil
        }
    }
}

/// Where the Mac's memory is: the model, your apps, and what is still available.
struct MemoryTile: View {
    @ObservedObject var status: StatusModel

    var body: some View {
        Tile(title: "Memory", symbol: "memorychip") {
            if let m = status.memorySplit {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        segment(m.model, of: m.total, width: geo.size.width, color: .accentColor)
                        segment(m.apps, of: m.total, width: geo.size.width, color: .gray.opacity(0.6))
                        segment(m.available, of: m.total, width: geo.size.width, color: status.roomColor.opacity(0.35))
                    }
                }
                .frame(height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                HStack(spacing: 12) {
                    legend(.accentColor, "Model", m.model)
                    legend(.gray.opacity(0.6), "Apps", m.apps)
                    legend(status.roomColor.opacity(0.35), "Available", m.available)
                }
                .font(.caption)
                Text(status.roomText).font(.caption.weight(.medium)).foregroundStyle(status.roomColor)
            } else {
                Text("Reading memory…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func segment(_ gb: Double, of total: Double, width: CGFloat, color: Color) -> some View {
        Rectangle().fill(color).frame(width: max(0, width * CGFloat(gb / max(total, 1)) - 2))
    }

    private func legend(_ color: Color, _ name: String, _ gb: Double) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(name) \(String(format: "%.0f", gb)) GB").foregroundStyle(.secondary)
        }
    }
}

/// How fast the last reply was written, as a gauge.
struct SpeedTile: View {
    @ObservedObject var status: StatusModel
    /// The top of the gauge: a good day for this model on this Mac.
    static let scale = 5.0

    var body: some View {
        Tile(title: "Speed", symbol: "speedometer") {
            if let last = status.lastRequest, let tps = last.decodeTokS {
                HStack(spacing: 14) {
                    Gauge(value: min(tps, Self.scale), in: 0...Self.scale) {
                        Text("tok/s")
                    } currentValueLabel: {
                        Text(String(format: "%.1f", tps))
                    }
                    .gaugeStyle(.accessoryCircular)
                    .tint(Gradient(colors: [.orange, .yellow, .green]))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(String(format: "About %.0f words a minute", tps * 0.75 * 60)).font(.headline)
                        if let first = last.firstTokenS {
                            Text("Last reply started after \(Self.duration(first))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else if let failed = status.lastRequest?.failed {
                Label("The last request failed", systemImage: "xmark.octagon").foregroundStyle(.orange)
                Text(failed).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            } else {
                Text("No replies yet since the log began").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    static func duration(_ seconds: Double) -> String {
        if seconds < 90 { return "\(Int(seconds.rounded())) s" }
        if seconds < 5400 { return "\(Int((seconds / 60).rounded())) min" }
        return String(format: "%.1f h", seconds / 3600)
    }
}

/// The running job, how many wait, and the last result.
struct JobsTile: View {
    @ObservedObject var status: StatusModel

    var body: some View {
        let j = status.jobs
        Tile(title: "Jobs", symbol: "hammer") {
            if let running = j.running {
                HStack(spacing: 10) {
                    Image(systemName: "hammer.fill").foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(running).font(.headline).lineLimit(1)
                        if let started = j.runningStarted {
                            Text("Running for \(SpeedTile.duration(-started.timeIntervalSinceNow))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text(j.queued == 0 ? "Nothing running" : "Nothing running yet").foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                badge("\(j.queued) waiting", j.queued > 0 ? .blue : .gray)
                if let flag = j.pauseFlag { badge("paused", .orange).help(flag) }
                if let last = j.lastResults.first { badge(last.hasPrefix("ok") ? "last: done" : "last: " + (last.split(separator: ":").first.map(String.init) ?? "?"),
                                                          last.hasPrefix("ok") ? .green : .orange).help(last) }
                Spacer()
                if j.running != nil || j.queued > 0 || j.pauseFlag != nil {
                    Button(j.pauseFlag == nil ? "Pause" : "Resume") { status.toggleJobsPause() }
                        .controlSize(.small)
                }
            }
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }
}

// MARK: - Menu-bar panel

struct MenuPanel: View {
    @ObservedObject var status: StatusModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(status.statusColor).frame(width: 9, height: 9)
                Text(status.statusText).font(.headline)
                Spacer()
                Text("Qwen3.8 Flash-Next").font(.caption).foregroundStyle(.secondary)
            }
            ActivityTile(status: status)
            if status.state == .stopped {
                Button { status.run("start") } label: {
                    Label("Start the model", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                Text("Takes about a minute. Needs the model's drive connected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if status.state == .ready {
                MemoryTile(status: status)
                SpeedTile(status: status)
            }
            JobsTile(status: status)
            HStack {
                Button("Open Slotkeeper") { AppDelegate.shared?.showDashboard() }
                Spacer()
                Menu("More") { MoreMenu(status: status) }
                    .menuStyle(.borderlessButton).fixedSize()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(width: 330)
    }
}

struct MoreMenu: View {
    @ObservedObject var status: StatusModel

    var body: some View {
        Button("Start") { status.run("start") }.disabled(status.state != .stopped)
        Button("Stop") { status.run("stop") }.disabled(status.state == .stopped)
        Button("Restart") { status.run("restart") }.disabled(status.state == .stopped)
        Divider()
        Button("Open Server Log") { NSWorkspace.shared.open(status.logURL) }
        Button("Copy Endpoint") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(status.endpoint, forType: .string)
        }
        Button("Support Bundle") { status.run("bundle") }
        if !status.jobs.daemonInstalled {
            Button("Run Jobs Overnight") { status.run("jobs", "daemon", "start") }
        }
        Divider()
        Toggle("Open Slotkeeper at Login", isOn: Binding(
            get: { LoginItem.isOn }, set: { LoginItem.set($0) }))
        Toggle("Stop the Model When Idle (30 min)", isOn: Binding(
            get: { IdleStop.isOn }, set: { status.run("idle", $0 ? "start" : "stop") }))
    }
}

/// The two switches, with what they mean, for the dashboard's Advanced › Settings.
struct SettingsTile: View {
    @ObservedObject var status: StatusModel
    @State private var openAtLogin = LoginItem.isOn
    @State private var idleStop = IdleStop.isOn
    @State private var note: String?

    var body: some View {
        Tile(title: "Settings", symbol: "gearshape") {
            Toggle("Open Slotkeeper at login", isOn: $openAtLogin)
                .onChange(of: openAtLogin) { _, on in
                    note = LoginItem.set(on)
                    openAtLogin = LoginItem.isOn
                }
            Text("Puts the menu-bar item back after you log in. Off: open Slotkeeper yourself when you want it.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Stop the model after 30 minutes without requests", isOn: $idleStop)
                .onChange(of: idleStop) { _, on in status.run("idle", on ? "start" : "stop") }
            Text("Frees its memory when you are done. Start it again from the menu; a queued job starts it by itself.")
                .font(.caption).foregroundStyle(.secondary)
            Text("The model never loads at login.").font(.caption).foregroundStyle(.secondary)
            if let note { Text(note).font(.caption).foregroundStyle(.orange) }
        }
    }
}

// MARK: - Dashboard Now screen

struct NowScreen: View {
    @ObservedObject var status: StatusModel
    @State private var replies: [RecentReply] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Circle().fill(status.statusColor).frame(width: 12, height: 12)
                    Text(status.statusText).font(.title2.weight(.semibold))
                    Spacer()
                }
                ActivityTile(status: status, large: true)
                HStack(alignment: .top, spacing: 14) {
                    MemoryTile(status: status)
                    SpeedTile(status: status)
                }
                JobsTile(status: status)
                Tile(title: "Recent replies", symbol: "chart.bar") {
                    if replies.isEmpty {
                        Text("Replies show here as the model finishes them.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        HStack(alignment: .top, spacing: 18) {
                            chart("Writing speed (tokens/s)", color: .accentColor) { $0.decodeTokS }
                            chart("Wait for the first word (s)", color: .orange) { $0.firstTokenS }
                        }
                    }
                }
            }
            .padding(20)
        }
        .onAppear(perform: load)
        .onReceive(Timer.publish(every: 10, on: .main, in: .common).autoconnect()) { _ in load() }
    }

    private func load() { replies = RecentReply.fromLog(status.logURL) }

    private func chart(_ title: String, color: Color, value: @escaping (LastRequest) -> Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Chart(replies) { r in
                if let v = value(r.request) {
                    BarMark(x: .value("Reply", r.id), y: .value(title, v)).foregroundStyle(color)
                }
            }
            .chartXAxis(.hidden)
            .frame(height: 110)
        }
    }
}
