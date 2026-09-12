import Charts
import SwiftUI

/// First dashboard window: what the monitor and exerciser have recorded, as charts.
/// Reads the JSONL files directly; no server round-trips.
struct DashboardView: View {
    /// Shared with the menu bar, which already polls state every two seconds.
    @ObservedObject var status: StatusModel
    @State private var monitor: [MonitorSample] = []
    @State private var runs: [ExerciserRun] = []
    @State private var requests: [OpenCodeRequest] = []
    @State private var requestsNote: String?
    @State private var jobs: [JobRow] = []
    @State private var newJobRepo = NSHomeDirectory()
    @State private var newJobTask = ""
    @State private var newJobAuto = false
    @State private var jobActionNote: String?
    @State private var patchStatus = ""
    @State private var releases = ""
    @State private var logTail = ""
    @State private var logFilter = ""
    @State private var health: [String] = []
    @State private var stuckPressureNote = ""
    @State private var liveWasActive = false
    @State private var hours = 24.0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Slotkeeper").font(.title2).bold()
                Spacer()
                Picker("Window", selection: $hours) {
                    Text("6h").tag(6.0); Text("24h").tag(24.0); Text("3d").tag(72.0); Text("7d").tag(168.0)
                }.pickerStyle(.segmented).frame(width: 220)
                Button("Reload") { load() }
            }
            .padding(.horizontal, 20).padding(.top, 16)
            TabView {
                ScrollView { VStack(alignment: .leading, spacing: 18) { live; yourRequests }.padding(20) }
                    .tabItem { Text("Your work") }
                ScrollView { VStack(alignment: .leading, spacing: 18) { jobsTab }.padding(20) }
                    .tabItem { Text("Jobs") }
                ScrollView { VStack(alignment: .leading, spacing: 18) { systemTab }.padding(20) }
                    .tabItem { Text("System") }
                ScrollView { VStack(alignment: .leading, spacing: 18) { serverTab }.padding(20) }
                    .tabItem { Text("Server") }
                ScrollView { VStack(alignment: .leading, spacing: 18) { healthTab }.padding(20) }
                    .tabItem { Text("Health") }
            }
        }
        .frame(minWidth: 860, minHeight: 720)
        .onAppear(perform: load)
        .onChange(of: hours) { _, _ in load() }
        // While a request is running, refresh the table often enough to watch turns land,
        // and leave it alone when the server is idle: each reload spawns report.py.
        .onReceive(Timer.publish(every: 20, on: .main, in: .common).autoconnect()) { _ in
            if status.activeRequest != nil || liveWasActive {
                liveWasActive = status.activeRequest != nil
                loadRequests(iso: DashboardView.parseDate)
                loadJobs()
            }
        }
    }

    private var systemTab: some View {
        VStack(alignment: .leading, spacing: 18) {
                GroupBox("Expert cache and memory pressure") {
                    Chart {
                        ForEach(monitor) { s in
                            if let e = s.experts {
                                LineMark(x: .value("Time", s.ts), y: .value("experts/layer", e))
                                    .interpolationMethod(.stepEnd)
                            }
                        }
                        ForEach(pressureSpans, id: \.start) { span in
                            RectangleMark(xStart: .value("from", span.start), xEnd: .value("to", span.end))
                                .foregroundStyle(span.level == "critical" ? .red.opacity(0.18) : .orange.opacity(0.15))
                        }
                    }
                    .chartYAxisLabel("experts/layer")
                    .frame(height: 180)
                    Text("Shaded: warning (orange) and critical (red) pressure as reported by the kernel.").font(.caption).foregroundStyle(.secondary)
                }

                GroupBox("Time to first token by prompt size") {
                    Chart(runs.filter { $0.ttft != nil && $0.prompt != nil }) { r in
                        PointMark(x: .value("prompt tokens", r.prompt!), y: .value("TTFT s", r.ttft!))
                            .foregroundStyle(by: .value("task", r.task))
                            .symbol(by: .value("ok", r.ok ? "ok" : "failed"))
                    }
                    .chartXAxisLabel("prompt tokens").chartYAxisLabel("seconds")
                    .frame(height: 200)
                }

                GroupBox("Decode rate versus expert cache at request start") {
                    Chart(runs.filter { $0.decode != nil && $0.expertsBefore != nil }) { r in
                        PointMark(x: .value("experts/layer", r.expertsBefore!), y: .value("tok/s", r.decode!))
                            .foregroundStyle(by: .value("task", r.task))
                    }
                    .chartXAxisLabel("experts/layer").chartYAxisLabel("decode tok/s")
                    .frame(height: 180)
                }

                GroupBox("Recent runs") {
                    Table(runs.suffix(60).reversed()) {
                        TableColumn("time") { Text($0.ts.formatted(date: .omitted, time: .shortened)) }.width(70)
                        TableColumn("task") { Text($0.task) }.width(130)
                        TableColumn("ok") { Text($0.ok ? "✓" : "✗").foregroundStyle($0.ok ? .green : .red) }.width(24)
                        TableColumn("prompt") { Text($0.prompt.map { "\($0)" } ?? "–") }.width(60)
                        TableColumn("TTFT") { Text($0.ttft.map { String(format: "%.1fs", $0) } ?? "–") }.width(60)
                        TableColumn("decode") { Text($0.decode.map { String(format: "%.1f", $0) } ?? "–") }.width(55)
                        TableColumn("cpu") { Text($0.cpuPeak.map { String(format: "%.0f%%", $0) } ?? "–") }.width(45)
                        TableColumn("note") { Text($0.note).lineLimit(1) }
                    }
                    .frame(minHeight: 260)
                }

                summary
        }
    }

    private var summary: some View {
        let ok = runs.filter(\.ok).count
        let byTask = Dictionary(grouping: runs, by: \.task)
        return GroupBox("Summary") {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(runs.count) runs, \(ok) passed, \(runs.count - ok) failed")
                ForEach(byTask.keys.sorted(), id: \.self) { task in
                    let rs = byTask[task]!
                    let ttft = median(rs.compactMap(\.ttft)), dec = median(rs.compactMap(\.decode))
                    Text("\(task): \(rs.filter(\.ok).count)/\(rs.count) ok" + (ttft.map { String(format: ", TTFT median %.1fs", $0) } ?? "") + (dec.map { String(format: ", decode median %.2f tok/s", $0) } ?? ""))
                        .font(.callout)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The request happening right now, from the plugin's marker and the server log.
    private var live: some View {
        GroupBox(status.activeRequest == nil ? "Nothing in flight" : "In flight now") {
            VStack(alignment: .leading, spacing: 8) {
                if let req = status.activeRequest {
                    Text(req.source).font(.headline)
                    if let fraction = livePrefillFraction {
                        ProgressView(value: fraction) {
                            Text(livePrefillLabel).font(.caption)
                        }
                    }
                    ForEach(req.lines, id: \.self) { Text($0).font(.callout) }
                    if let cpu = status.serverCPU {
                        Text(String(format: "server cpu %.0f%%", cpu)).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text("The server is idle. Your next OpenCode turn shows up here with its prefill progress.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(status.detailLines, id: \.self) { line in
                    Text(line).font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "4096/9125 tokens (45%), ~52 s left" -> 0.45
    private var livePrefillFraction: Double? {
        for line in status.activeRequest?.lines ?? [] {
            guard let open = line.firstIndex(of: "("), let close = line[open...].firstIndex(of: "%") else { continue }
            if let value = Double(line[line.index(after: open)..<close]) { return value / 100 }
        }
        return nil
    }

    private var livePrefillLabel: String {
        status.activeRequest?.lines.first(where: { $0.contains("tokens") }) ?? "reading the prompt"
    }

    /// Your own OpenCode work, which is the point of the whole setup. Read through
    /// `scripts/report.py --requests`, which owns the query into OpenCode's database.
    private var yourRequests: some View {
        let answered = requests.filter { $0.error == nil }
        let failed = requests.filter { $0.error != nil && $0.error != "in flight" }
        let inFlight = requests.filter { $0.error == "in flight" }
        let long = answered.filter { ($0.prompt ?? 0) >= 8000 && $0.ttft != nil }
        let reused = long.filter(\.followup), cold = long.filter { !$0.followup }
        return GroupBox("Your OpenCode requests") {
            VStack(alignment: .leading, spacing: 8) {
                if let note = requestsNote {
                    Text(note).font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("\(answered.count) answered, \(failed.count) failed"
                        + (inFlight.isEmpty ? "" : ", \(inFlight.count) generating")
                        + ", \(Set(requests.map(\.session)).count) sessions")
                        .font(.callout)
                    if let rate = median(requests.compactMap(\.cacheHitRate)) {
                        Text(String(format: "the server reused a median %.0f%% of each prompt — a turn that reuses nothing pays the full prefill again", rate))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !long.isEmpty {
                        Text(reuseLine(reused: reused, cold: cold))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Chart(answered.filter { $0.ttft != nil && $0.prompt != nil }) { r in
                        PointMark(x: .value("prompt tokens", r.prompt!), y: .value("TTFT s", r.ttft!))
                            .foregroundStyle(by: .value("turn", r.followup ? "follow-up" : "cold"))
                    }
                    .chartXAxisLabel("prompt tokens").chartYAxisLabel("seconds")
                    .frame(height: 170)
                    Table(requests.suffix(80).reversed()) {
                        TableColumn("time") { Text($0.ts.formatted(date: .omitted, time: .shortened)) }.width(70)
                        TableColumn("project") { Text($0.project) }.width(110)
                        TableColumn("prompt") { Text($0.prompt.map { "\($0)" } ?? "–") }.width(60)
                        TableColumn("out") { Text($0.output.map { "\($0)" } ?? "–") }.width(50)
                        TableColumn("TTFT") { Text($0.ttft.map { String(format: "%.0fs", $0) } ?? "–") }.width(55)
                        TableColumn("decode") { Text($0.decode.map { String(format: "%.1f", $0) } ?? "–") }.width(55)
                        TableColumn("reused") { r in
                            Text(r.reuseText).foregroundStyle(r.reuseColour)
                        }.width(70)
                        TableColumn("turn") { Text($0.followup ? "follow-up" : "cold").foregroundStyle($0.followup ? .green : .secondary) }.width(75)
                        TableColumn("status") { r in
                            Text(r.error ?? "ok").foregroundStyle(r.error == nil ? .green : (r.error == "in flight" ? .orange : .red))
                        }
                    }
                    .frame(minHeight: 220)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// What is installed and what to do when it misbehaves.
    private var serverTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Installed build") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(patchStatus.isEmpty ? "reading…" : patchStatus).font(.system(.callout, design: .monospaced))
                    Text("Rebuild after changing patches/: scripts/slotkeeper patch").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Releases") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(releases.isEmpty ? "reading…" : releases).font(.system(.caption, design: .monospaced))
                    Text("Roll back with: scripts/install-release.sh --rollback <name>, then scripts/slotkeeper restart")
                        .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Server log") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("filter (e.g. failed, pressure, kept)", text: $logFilter).frame(width: 260)
                        Button("Reload") { loadServerTab() }
                        Spacer()
                        Button("Open in Console") { NSWorkspace.shared.open(DashboardView.serverLog) }
                    }
                    ScrollView {
                        Text(filteredLog).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 260)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear(perform: loadServerTab)
    }

    /// The things that quietly break a server meant to run for weeks.
    private var healthTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Background services") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(DashboardView.agents, id: \.label) { agent in
                        let installed = FileManager.default.fileExists(
                            atPath: NSHomeDirectory() + "/Library/LaunchAgents/\(agent.label).plist")
                        Text("\(installed ? "✓" : "✗")  \(agent.name) — \(installed ? agent.label : "not installed")")
                            .foregroundStyle(installed ? .primary : .secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Machine") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(health, id: \.self) { Text($0) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Stuck pressure level") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(stuckPressureNote)
                    Text("A level that stays elevated while memory is free used to refuse every request; "
                        + "the installed patches cross-check reclaimable memory, so this is now a warning, not an outage.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear(perform: loadHealth)
    }

    static let agents: [(name: String, label: String)] = [
        ("Slotstream server", "local.slotkeeper"),
        ("Metrics monitor", "local.slotkeeper-monitor"),
        ("Exerciser", "local.slotkeeper-exerciser"),
        ("Job runner", "local.slotkeeper-jobs"),
        ("Menu bar app", "local.slotkeeper-bar"),
    ]

    static var serverLog: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".slotstream/slotstream.log")
    }

    private var filteredLog: String {
        let lines = logTail.split(separator: "\n").map(String.init)
        let wanted = logFilter.trimmingCharacters(in: .whitespaces).lowercased()
        let kept = wanted.isEmpty ? lines : lines.filter { $0.lowercased().contains(wanted) }
        return kept.suffix(200).joined(separator: "\n")
    }

    private func loadServerTab() {
        patchStatus = DashboardView.runCtl(["patch", "--status"]).trimmingCharacters(in: .whitespacesAndNewlines)
        releases = DashboardView.runScript("install-release.sh", ["--list"]).trimmingCharacters(in: .whitespacesAndNewlines)
        if let handle = try? FileHandle(forReadingFrom: DashboardView.serverLog) {
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 200_000 ? size - 200_000 : 0)
            let data = (try? handle.readToEnd()) ?? Data()
            logTail = String(data: data, encoding: .utf8) ?? ""
        }
    }

    private func loadHealth() {
        var out: [String] = []
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfFileSystem(forPath: NSHomeDirectory()),
           let free = (attrs[.systemFreeSize] as? NSNumber)?.doubleValue {
            let gib = free / 1_073_741_824
            out.append(String(format: "disk free %.0f GiB%@", gib, gib < 6 ? "  ⚠︎ below the 6 GiB floor the control script enforces" : ""))
        }
        let batt = DashboardView.shell("/usr/bin/pmset", ["-g", "batt"])
        out.append(batt.contains("discharging")
            ? "on battery — the exerciser and job runner hold off until it is back on AC"
            : "on AC power")
        let assertions = DashboardView.shell("/usr/bin/pmset", ["-g", "assertions"])
        out.append(assertions.contains("PreventUserIdleSystemSleep           1")
            ? "sleep held off while the server runs (caffeinate)"
            : "no sleep assertion held — a long job can be cut short by idle sleep")
        health = out
        let level = DashboardView.shell("/usr/sbin/sysctl", ["-n", "kern.memorystatus_vm_pressure_level"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = ["1": "normal", "2": "warning", "4": "critical"][level] ?? level
        let free = DashboardView.shell("/usr/bin/memory_pressure", []).split(separator: "\n")
            .first(where: { $0.contains("free percentage") })?.split(separator: ":").last?
            .trimmingCharacters(in: .whitespaces) ?? "?"
        stuckPressureNote = level == "1"
            ? "kernel level normal, \(free) free"
            : "kernel level \(name) with \(free) free" + (Int(free.replacingOccurrences(of: "%", with: "")) ?? 0 > 50
                ? " — elevated while memory is free; reset with: sudo memory_pressure -l normal" : "")
    }

    static func shell(_ path: String, _ args: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe(); task.standardOutput = pipe; task.standardError = Pipe()
        do { try task.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func runCtl(_ args: [String]) -> String {
        let ctl = StatusModel.settings["SLOTSTREAM_CTL"] ?? NSHomeDirectory() + "/slotkeeper/scripts/slotkeeper"
        return shell("/bin/bash", [ctl] + args)
    }

    static func runScript(_ name: String, _ args: [String]) -> String {
        let dir = URL(fileURLWithPath: reportPath).deletingLastPathComponent()
        return shell("/bin/bash", [dir.appendingPathComponent(name).path] + args)
    }

    /// Unattended tasks: what is waiting, what ran, and a way to add one without the terminal.
    private var jobsTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Queue a task for the local model") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("repository path", text: $newJobRepo).frame(width: 280)
                        Toggle("approve tool calls (--auto)", isOn: $newJobAuto)
                        Spacer()
                        Button("Queue job") { addJob() }
                            .disabled(newJobRepo.isEmpty || newJobTask.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    TextEditor(text: $newJobTask).frame(height: 60).border(.quaternary)
                    Text(jobsAdvice).font(.caption).foregroundStyle(.secondary)
                    if let note = jobActionNote { Text(note).font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Jobs") {
                VStack(alignment: .leading, spacing: 8) {
                    if jobs.isEmpty {
                        Text("nothing queued or finished yet").font(.callout).foregroundStyle(.secondary)
                    }
                    Table(jobs) {
                        TableColumn("state") { j in
                            Text(j.result).foregroundStyle(j.result == "ok" ? .green : (j.result == "queued" || j.result == "running" ? .orange : .red))
                        }.width(70)
                        TableColumn("project") { Text($0.project) }.width(100)
                        TableColumn("task") { Text($0.task).lineLimit(1) }
                        TableColumn("elapsed") { Text($0.elapsed.map { String(format: "%.0f min", $0 / 60) } ?? "–") }.width(65)
                        TableColumn("changed") { Text($0.changedFiles.map { "\($0) files" } ?? "–") }.width(70)
                        TableColumn("log") { j in
                            Button("open") { NSWorkspace.shared.open(DashboardView.jobLog(j.id)) }.buttonStyle(.link)
                        }.width(45)
                    }
                    .frame(minHeight: 300)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var jobsAdvice: String {
        "One `opencode run` per job, one at a time, only while you are away: the runner waits for "
            + "your own OpenCode session, battery, memory pressure and the night window. Without --auto it "
            + "stops at the first tool call needing approval; with it, review the diff afterwards."
    }

    private func addJob() {
        var args = ["add", (newJobRepo as NSString).expandingTildeInPath, newJobTask]
        if newJobAuto { args.append("--auto") }
        let out = DashboardView.runJobs(args)
        jobActionNote = out.split(separator: "\n").first.map(String.init) ?? "queued"
        newJobTask = ""
        loadJobs()
    }

    /// Built outside the view body: the type checker gives up on long interpolated sums.
    private func reuseLine(reused: [OpenCodeRequest], cold: [OpenCodeRequest]) -> String {
        func med(_ rs: [OpenCodeRequest]) -> String {
            guard let m = median(rs.compactMap(\.ttft)) else { return "–" }
            return String(format: "%.0fs", m)
        }
        let a = "prompts over 8K: follow-up turns " + med(reused) + " median TTFT (n=\(reused.count))"
        let b = " vs cold " + med(cold) + " (n=\(cold.count))"
        return a + b + " — the gap is prefix reuse working"
    }

    private struct Span { var start: Date; var end: Date; var level: String }
    private var pressureSpans: [Span] {
        var spans: [Span] = []
        for s in monitor where s.pressure == "warning" || s.pressure == "critical" {
            if var last = spans.last, last.level == s.pressure, s.ts.timeIntervalSince(last.end) < 90 {
                last.end = s.ts; spans[spans.count - 1] = last
            } else {
                spans.append(Span(start: s.ts, end: s.ts.addingTimeInterval(30), level: s.pressure))
            }
        }
        return spans
    }

    private func median(_ v: [Double]) -> Double? {
        guard !v.isEmpty else { return nil }
        let s = v.sorted(); return s[s.count / 2]
    }

    private func load() {
        let home = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".slotstream/metrics")
        let since = Date().addingTimeInterval(-hours * 3600)
        let iso = ISO8601DateFormatter()
        let isoFrac = ISO8601DateFormatter(); isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ s: String) -> Date? { iso.date(from: s) ?? isoFrac.date(from: s) }

        var samples: [MonitorSample] = []
        if let files = try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil) {
            for f in files where f.lastPathComponent.hasPrefix("20") && f.pathExtension == "jsonl" {
                for line in (try? String(contentsOf: f, encoding: .utf8))?.split(separator: "\n") ?? [] {
                    guard let d = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                          let ts = (o["ts"] as? String).flatMap(date), ts >= since else { continue }
                    let ss = o["slotstream"] as? [String: Any]
                    samples.append(MonitorSample(ts: ts, pressure: o["pressure"] as? String ?? "unknown", experts: ss?["experts_per_layer"] as? Int))
                }
            }
        }
        monitor = samples.sorted { $0.ts < $1.ts }

        var rs: [ExerciserRun] = []
        for line in (try? String(contentsOf: home.appendingPathComponent("exerciser.jsonl"), encoding: .utf8))?.split(separator: "\n") ?? [] {
            guard let d = line.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let ts = (o["ts"] as? String).flatMap(date), ts >= since else { continue }
            rs.append(ExerciserRun(
                ts: ts, task: o["task"] as? String ?? "?", ok: o["ok"] as? Bool ?? false, note: o["note"] as? String ?? "",
                prompt: o["prompt_tokens"] as? Int, ttft: o["ttft_s"] as? Double, decode: o["decode_tok_s"] as? Double,
                expertsBefore: (o["plan_before"] as? [String: Any])?["experts_per_layer"] as? Int,
                cpuPeak: (o["process"] as? [String: Any])?["cpu_peak"] as? Double))
        }
        runs = rs.sorted { $0.ts < $1.ts }
        loadRequests(iso: date)
        loadJobs()
    }

    /// The job files are ours, so read them directly; only `add` goes through the script.
    private func loadJobs() {
        let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".slotstream/jobs")
        var rows: [JobRow] = []
        for folder in ["running", "queued", "done"] {
            let dir = root.appendingPathComponent(folder)
            for f in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            where f.pathExtension == "json" {
                guard let d = try? Data(contentsOf: f),
                      let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                      let id = o["id"] as? String else { continue }
                rows.append(JobRow(
                    id: id, repo: o["repo"] as? String ?? "", task: o["task"] as? String ?? "",
                    result: folder == "running" ? "running" : (o["result"] as? String ?? folder),
                    elapsed: o["elapsed_s"] as? Double, changedFiles: o["changed_files"] as? Int,
                    finished: o["finished"] as? String))
            }
        }
        jobs = rows.sorted { $0.id > $1.id }
    }

    static func jobLog(_ id: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".slotstream/jobs/logs/\(id).log")
    }

    @discardableResult
    static func runJobs(_ args: [String]) -> String {
        let script = URL(fileURLWithPath: reportPath).deletingLastPathComponent().appendingPathComponent("jobs.py").path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["python3", script] + args
        let pipe = Pipe(); task.standardOutput = pipe; task.standardError = pipe
        do { try task.run() } catch { return "could not run jobs.py: \(error.localizedDescription)" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func parseDate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        let frac = ISO8601DateFormatter(); frac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: s) ?? frac.date(from: s)
    }

    private func loadRequests(iso date: (String) -> Date?) {
        let script = DashboardView.reportPath
        guard FileManager.default.isExecutableFile(atPath: script) else {
            requestsNote = "scripts/report.py not found — set SLOTSTREAM_CTL to this repo's scripts/slotkeeper"
            return
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["python3", script, "--requests", "--json", "--hours", String(hours)]
        let pipe = Pipe(); task.standardOutput = pipe; task.standardError = Pipe()
        do { try task.run() } catch {
            requestsNote = "could not run report.py: \(error.localizedDescription)"; return
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            requestsNote = "report.py returned no requests (is OpenCode's database at ~/.local/share/opencode?)"
            return
        }
        requestsNote = rows.isEmpty ? "no requests to the local model in this window" : nil
        requests = rows.compactMap { o in
            guard let ts = (o["ts"] as? String).flatMap(date) else { return nil }
            return OpenCodeRequest(
                ts: ts, session: o["session"] as? String ?? "?", agent: o["agent"] as? String ?? "",
                cwd: o["cwd"] as? String, prompt: o["prompt"] as? Int, output: o["output"] as? Int,
                ttft: o["ttft_s"] as? Double, decode: o["decode_tok_s"] as? Double,
                error: o["error"] as? String, followup: o["followup"] as? Bool ?? false,
                cacheHitRate: o["cache_hit_rate"] as? Double)
        }.sorted { $0.ts < $1.ts }
    }

    /// report.py sits beside the control script the menu bar already resolves.
    static var reportPath: String {
        let ctl = StatusModel.settings["SLOTSTREAM_CTL"] ?? NSHomeDirectory() + "/slotkeeper/scripts/slotkeeper"
        return URL(fileURLWithPath: ctl).deletingLastPathComponent().appendingPathComponent("report.py").path
    }
}

struct JobRow: Identifiable {
    var id: String
    var repo: String
    var task: String
    var result: String
    var elapsed: Double?
    var changedFiles: Int?
    var finished: String?
    var project: String { URL(fileURLWithPath: repo).lastPathComponent }
}

struct OpenCodeRequest: Identifiable {
    var id: Date { ts }
    var ts: Date
    var session: String
    var agent: String
    var cwd: String?
    var prompt: Int?
    var output: Int?
    var ttft: Double?
    var decode: Double?
    var error: String?
    var followup: Bool
    /// What the server said it reused of this prompt, when the plugin recorded the turn.
    var cacheHitRate: Double?
    var reuseText: String { cacheHitRate.map { String(format: "%.0f%%", $0) } ?? "–" }
    var reuseColour: Color {
        guard let rate = cacheHitRate else { return .secondary }
        return rate >= 80 ? .green : (rate >= 20 ? .orange : .red)
    }
    /// The last path component is what you recognise: "prices-app", not the whole path.
    var project: String { cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "" }
}

struct MonitorSample: Identifiable {
    var id: Date { ts }
    var ts: Date
    var pressure: String
    var experts: Int?
}

struct ExerciserRun: Identifiable {
    var id: Date { ts }
    var ts: Date
    var task: String
    var ok: Bool
    var note: String
    var prompt: Int?
    var ttft: Double?
    var decode: Double?
    var expertsBefore: Int?
    var cpuPeak: Double?
}
