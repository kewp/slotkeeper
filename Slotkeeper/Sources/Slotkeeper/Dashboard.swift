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
    @State private var liveExpanded = false
    @State private var selectedRequest: OpenCodeRequest.ID?
    @State private var calibration: Calibration?
    @State private var verdict: Verdict?
    @State private var verdictLoading = false
    @State private var calibrating = false
    @State private var autoCalibrationStopped = false
    @State private var calibrationNote: String?
    @State private var calibrationProgress: CalibrationProgress?
    @State private var calibrationLog = ""
    @State private var calibrationLogExpanded = true
    @State private var budget: BudgetTables?
    @State private var attempts: [CalibrationAttempt] = []
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
                ScrollView { VStack(alignment: .leading, spacing: 18) { VerdictPanel(verdict: verdict, loading: verdictLoading); live; overview }.padding(20) }
                    .tabItem { Text("Overview") }
                ScrollView { VStack(alignment: .leading, spacing: 18) { capacityTab }.padding(20) }
                    .tabItem { Text("Capacity") }
                ScrollView { VStack(alignment: .leading, spacing: 18) { attemptsTab }.padding(20) }
                    .tabItem { Text("Measurements") }
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
        // Calibration publishes what it is doing; while it runs, follow it closely.
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            loadCalibration()
        }
        // The verdict moves as tests land; once a minute is plenty and keeps the script cheap.
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            loadVerdict()
        }
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
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    Circle().fill(status.activeRequest == nil ? Color.secondary : Color.green).frame(width: 8, height: 8)
                    Text(status.activeRequest.map { "In flight: " + $0.source } ?? "Server idle").font(.headline)
                    Spacer()
                    Text(liveSummary).font(.caption).foregroundStyle(.secondary)
                }
                if status.activeRequest != nil, let fraction = livePrefillFraction {
                    ProgressView(value: fraction) { Text(livePrefillLabel).font(.caption) }
                }
                DisclosureGroup("details", isExpanded: $liveExpanded) {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(status.activeRequest?.lines ?? [], id: \.self) { Text($0).font(.caption) }
                        ForEach(status.detailLines, id: \.self) { line in
                            Text(line).font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.font(.caption)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One line of context that stays visible when the details are collapsed.
    private var liveSummary: String {
        var bits: [String] = []
        if let line = status.activeRequest?.lines.first { bits.append(line) }
        if let cpu = status.serverCPU { bits.append(String(format: "cpu %.0f%%", cpu)) }
        return bits.joined(separator: "  |  ")
    }

    /// "4096/9125 tokens (45%), ~52 s left" -> 0.45
    /// Only the server's own progress line means progress: "4096/9125 tokens (45%), ~52 s left".
    /// The request's own summary also carries a percentage — of the context window — which is
    /// not progress at all and filled this bar with a meaningless number.
    private var livePrefillProgressLine: String? {
        status.activeRequest?.lines.first { $0.contains("/") && $0.contains("tokens (") }
    }

    private var livePrefillFraction: Double? {
        guard let line = livePrefillProgressLine,
              let open = line.range(of: "tokens ("), let close = line[open.upperBound...].firstIndex(of: "%")
        else { return nil }
        return Double(line[open.upperBound..<close]).map { $0 / 100 }
    }

    private var livePrefillLabel: String {
        livePrefillProgressLine ?? "reading the prompt"
    }

    /// The headline: what this machine can handle, measured rather than guessed.
    private var capacityCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Text("What this machine can handle").font(.caption).foregroundStyle(.secondary)
                if let c = calibration {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(c.promptText).font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("token prompts").font(.title3).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 24) {
                        ForEach(c.facts, id: \.label) { fact in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(fact.value).font(.headline)
                                Text(fact.label).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                    }
                    if let limit = c.limitedBy, !limit.contains("65,536") {
                        Text("limited by " + limit).font(.callout).foregroundStyle(.secondary)
                    }
                    Text(c.provenance).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text(calibrating ? "measuring…" : "not measured yet")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text(calibrating
                         ? "running real prompts at increasing sizes; this takes a while"
                         : "runs on its own when you are away, or start it now")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let p = calibrationProgress {
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text(p.headline).font(.callout)
                        Text(p.rows.isEmpty && p.attempts.isEmpty
                             ? "no prompt has finished yet at this configuration"
                             : "\(p.rows.filter(\.ok).count) prompts answered, "
                               + "\(p.rows.filter { !$0.ok }.count) refused, "
                               + "\(p.attempts.count) configurations tried")
                            .font(.caption).foregroundStyle(.secondary)
                        if let bar = p.fractionDone {
                            ProgressView(value: bar) { Text(p.step).font(.caption) }
                        }
                        ForEach(p.attempts) { attempt in
                            HStack(spacing: 8) {
                                Text(attempt.symbol).foregroundStyle(attempt.good ? .green : .secondary)
                                Text(attempt.what).frame(width: 210, alignment: .leading)
                                Text(attempt.result).foregroundStyle(.secondary)
                            }.font(.caption)
                        }
                        ForEach(p.rows) { row in
                            HStack(spacing: 8) {
                                Text(row.ok ? "✓" : "✗").foregroundStyle(row.ok ? .green : .red)
                                Text("\(row.window / 1000)K window, \(row.size.formatted()) tokens")
                                    .frame(width: 210, alignment: .leading)
                                Text(row.detail).foregroundStyle(.secondary)
                            }.font(.caption)
                        }
                        if !calibrationLog.isEmpty {
                            DisclosureGroup("what it is doing", isExpanded: $calibrationLogExpanded) {
                                Text(calibrationLog)
                                    .font(.system(.caption2, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.font(.caption)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 10) {
                    Button(calibrating ? "Measuring…" : "Measure now") { startCalibration() }
                        .disabled(calibrating)
                    Button(autoCalibrationStopped ? "Resume automatic" : "Stop automatic") { toggleAutoCalibration() }
                    if let note = calibrationNote { Text(note).font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func startCalibration() {
        calibrating = true
        calibrationNote = "started; the server restarts as it tries each window"
        DispatchQueue.global().async {
            _ = DashboardView.runScriptDetached("calibrate.py", ["--quick"])
        }
    }

    private func toggleAutoCalibration() {
        let flag = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".slotstream/calibrate.pause")
        if autoCalibrationStopped {
            try? FileManager.default.removeItem(at: flag)
            calibrationNote = "automatic calibration will run again when you are away"
        } else {
            try? "stopped from the app".write(to: flag, atomically: true, encoding: .utf8)
            calibrationNote = "automatic calibration stopped"
        }
        loadCalibration()
    }

    private func loadCalibration() {
        let home = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".slotstream")
        autoCalibrationStopped = FileManager.default.fileExists(
            atPath: home.appendingPathComponent("calibrate.pause").path)
        calibrating = !DashboardView.shell("/usr/bin/pgrep", ["-f", "calibrate.py"]).isEmpty
        calibrationProgress = CalibrationProgress(
            file: home.appendingPathComponent("calibration.progress.json"))
        // The running commentary, which is what the terminal shows.
        calibrationLog = DashboardView.tail(home.appendingPathComponent("calibrate.log"), lines: 14)
        if calibrationLog.isEmpty {
            calibrationLog = DashboardView.tail(home.appendingPathComponent("calibrate-auto.log"), lines: 14)
        }
        guard let data = try? Data(contentsOf: home.appendingPathComponent("calibration.json")),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            calibration = nil
            return
        }
        calibration = Calibration(
            comfortable: o["comfortable_prompt"] as? Int ?? 0,
            window: o["window"] as? Int ?? 0,
            largest: o["largest_prompt_ok"] as? Int,
            firstFailure: o["first_failure_at"] as? Int,
            ttft: o["ttft_median_s"] as? Double,
            ttftAtLargest: o["ttft_at_largest_s"] as? Double,
            decode: o["decode_median_tok_s"] as? Double,
            prefill: o["prefill_median_tok_s"] as? Double,
            machine: o["machine"] as? String ?? "",
            measured: (o["finished_at"] as? String).flatMap(DashboardView.parseDate),
            limitedBy: o["limited_by"] as? String)
    }

    /// Every configuration ever tried and what it did, so the next change has evidence.
    private var attemptsTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            ConfigurationTable(rows: configurations)
            GroupBox("Every attempt, newest first") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Each row is one server start or one prompt. A failure carries the server's own "
                        + "reason, which is what to act on.")
                        .font(.caption).foregroundStyle(.secondary)
                    Table(attempts) {
                        TableColumn("when") { Text($0.ts.formatted(date: .omitted, time: .standard)) }.width(70)
                        TableColumn("window") { Text($0.windowText) }.width(70)
                        TableColumn("memory") { Text($0.targetText) }.width(70)
                        TableColumn("keeping") { Text($0.retention) }.width(70)
                        TableColumn("prompt") { Text($0.sizeText) }.width(70)
                        TableColumn("result") { a in
                            Text(a.ok ? "ok" : "failed").foregroundStyle(a.ok ? .green : .red)
                        }.width(55)
                        TableColumn("first token") { Text($0.ttftText) }.width(80)
                        TableColumn("reading") { Text($0.prefillText) }.width(80)
                        TableColumn("why") { Text($0.reason).lineLimit(2) }
                    }
                    .frame(minHeight: 420)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear(perform: loadAttempts)
    }

    /// One line per configuration, so a change of setting can be judged at a glance.
    private var configurations: [ConfigurationSummary] {
        var grouped: [String: [CalibrationAttempt]] = [:]
        for a in attempts where a.window > 0 {
            grouped["\(a.window)|\(a.targetGB)|\(a.retention)", default: []].append(a)
        }
        return grouped.values.map(ConfigurationSummary.init).sorted {
            ($0.window, $0.targetGB) > ($1.window, $1.targetGB)
        }
    }

    private func loadAttempts() {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".slotstream/calibration-attempts.jsonl")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { attempts = []; return }
        attempts = text.split(separator: "\n").compactMap { line in
            guard let data = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ts = (o["ts"] as? String).flatMap(DashboardView.parseDate) else { return nil }
            return CalibrationAttempt(
                ts: ts, kind: o["kind"] as? String ?? "", window: o["window"] as? Int ?? 0,
                targetGB: o["target_gb"] as? Double ?? 0, retention: o["retention"] as? String ?? "default",
                size: o["size"] as? Int, promptTokens: o["prompt_tokens"] as? Int,
                ok: o["ok"] as? Bool ?? false, ttft: o["ttft_s"] as? Double,
                prefill: o["prefill_tok_s"] as? Double, decode: o["decode_tok_s"] as? Double,
                reason: o["reason"] as? String ?? "")
        }.sorted { $0.ts > $1.ts }
    }

    /// Why the numbers are what they are: where the memory goes, what each window would
    /// cost, what a different machine would do, and what the tests actually measured.
    private var capacityTab: some View {
        VStack(alignment: .leading, spacing: 18) {
            capacityCard
            GroupBox("Where the memory goes right now") {
                if let ledger = budget?.ledger, !ledger.items.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(ledger.items, id: \.name) { item in
                            HStack {
                                Text(item.name).frame(width: 260, alignment: .leading)
                                Text(String(format: "%.2f GB", item.gb)).monospacedDigit()
                                    .frame(width: 80, alignment: .trailing)
                                GeometryReader { geo in
                                    Rectangle().fill(.blue.opacity(0.35))
                                        .frame(width: max(2, geo.size.width * item.gb / max(1, ledger.targetGB)))
                                }.frame(height: 10)
                            }.font(.callout)
                        }
                        Divider()
                        Text(String(format: "expected peak %.2f GB against a %.2f GB target at a %@ window",
                                    ledger.peakGB, ledger.targetGB, ledger.window.formatted()))
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("the server is not answering right now").font(.callout).foregroundStyle(.secondary)
                }
            }
            WindowCostTable(rows: budgetWindows)
            MachineTable(rows: budgetMachines)
            GroupBox("Every prompt size we have tried") {
                if sweeps.isEmpty {
                    Text("nothing measured in this window yet").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Each row is one prompt sent at one configuration. Runs are labelled, and a "
                        + "failure in an older run says what that configuration could not do, not what "
                        + "the current one cannot.")
                        .font(.caption).foregroundStyle(.secondary)
                    Table(sweeps) {
                        TableColumn("when") { Text($0.ts.formatted(date: .omitted, time: .shortened)) }.width(60)
                        TableColumn("run") { Text($0.label.isEmpty ? "–" : $0.label) }.width(120)
                        TableColumn("prompt") { Text($0.prompt.map { $0.formatted() } ?? "–") }.width(70)
                        TableColumn("result") { r in
                            Text(r.ok ? "ok" : (r.errorCode ?? "failed")).foregroundStyle(r.ok ? .green : .red)
                        }.width(150)
                        TableColumn("to first token") { Text($0.ttft.map { String(format: "%.0f s", $0) } ?? "–") }.width(100)
                        TableColumn("reading") { Text($0.prefill.map { String(format: "%.0f tok/s", $0) } ?? "–") }.width(90)
                        TableColumn("generating") { Text($0.decode.map { String(format: "%.1f tok/s", $0) } ?? "–") }.width(90)
                        TableColumn("cache") { Text($0.expertsBefore.map { "\($0)/layer" } ?? "–") }
                    }.frame(minHeight: 220)
                    Text(sweepSummary).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear(perform: loadBudget)
    }

    /// The practical translation: at the measured rates, what does a prompt cost in time?
    private var sweepSummary: String {
        let ok = sweeps.filter { $0.ok && $0.prefill != nil }
        guard let rate = median(ok.compactMap(\.prefill)), rate > 0 else { return "" }
        let decode = median(sweeps.compactMap(\.decode)) ?? 0
        let cold = 25_000.0 / rate / 60
        return String(format: "At %.0f tok/s reading, a cold 25,000-token prompt takes about %.0f min to "
                      + "its first token; a follow-up that only adds 500 tokens takes about %.0f s. "
                      + "Generating 300 tokens at %.1f tok/s adds about %.0f s.",
                      rate, cold, 500 / rate, decode, decode > 0 ? 300 / decode : 0)
    }

    /// Newest first: the current configuration's evidence should be at the top.
    private var sweeps: [ExerciserRun] {
        runs.filter { $0.task.hasPrefix("sweep-") || $0.task.hasPrefix("calibrate-") }
            .sorted { $0.ts > $1.ts }
    }

    private var budgetWindows: [BudgetTables.WindowRow] { budget?.windows ?? [] }
    private var budgetMachines: [BudgetTables.MachineRow] { budget?.machines ?? [] }

    private func loadBudget() {
        var args = ["--tables", "--json"]
        if let experts = status.plan.expertsPerLayer { args += ["--experts", "\(experts)"] }
        if let percent = StatusModel.settings["SLOTSTREAM_MAX_RAM_PERCENT"] { args += ["--percent", percent] }
        let out = DashboardView.runScript("window-budget.py", args)
        guard let data = out.data(using: .utf8),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        budget = BudgetTables(json: o)
    }

    /// The one-screen answer to "how is it going": how long it has been up, what it has
    /// served, how the memory has behaved, and what is waiting.
    private var overview: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Right now") {
                HStack(alignment: .top, spacing: 28) {
                    ForEach(headlineStats, id: \.label) { stat in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stat.value).font(.title3).bold()
                            Text(stat.label).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Memory and cache over this window") {
                Chart {
                    ForEach(monitor) { s in
                        if let free = s.freePercent {
                            AreaMark(x: .value("Time", s.ts), y: .value("free %", free))
                                .foregroundStyle(.blue.opacity(0.12))
                        }
                    }
                    ForEach(monitor) { s in
                        if let e = s.experts {
                            LineMark(x: .value("Time", s.ts), y: .value("experts/layer", e))
                                .foregroundStyle(.orange).interpolationMethod(.stepEnd)
                        }
                    }
                    ForEach(pressureSpans, id: \.start) { span in
                        RectangleMark(xStart: .value("from", span.start), xEnd: .value("to", span.end))
                            .foregroundStyle(span.level == "critical" ? .red.opacity(0.18) : .orange.opacity(0.15))
                    }
                }
                .chartYAxisLabel("free % (area) and experts/layer (line)")
                .frame(height: 170)
                Text("Shaded: the kernel reported warning (orange) or critical (red) pressure. "
                    + "The line is the expert cache the governor chose to hold.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            GroupBox("Turn time over this window") {
                Chart(requests.filter { $0.ttft != nil && $0.error == nil }) { r in
                    PointMark(x: .value("when", r.ts), y: .value("TTFT s", r.ttft!))
                        .foregroundStyle(by: .value("turn", r.followup ? "follow-up" : "cold"))
                }
                .chartYAxisLabel("seconds to first token")
                .frame(height: 150)
                Text("Each dot is one of your turns. A follow-up that jumps to cold territory means the "
                    + "conversation was dropped from the prefix cache and re-read.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private struct Stat { var label: String; var value: String }

    private var headlineStats: [Stat] {
        let answered = requests.filter { $0.error == nil }
        let failed = requests.filter { $0.error != nil && $0.error != "in flight" }
        let busy = answered.compactMap(\.ttft).reduce(0, +) / 3600
        let reuse = median(requests.compactMap(\.cacheHitRate))
        let pressureMinutes = Double(monitor.filter { $0.pressure != "normal" }.count) * 0.5
        return [
            Stat(label: "server uptime", value: uptimeText),
            Stat(label: "your turns", value: "\(answered.count)" + (failed.isEmpty ? "" : " (\(failed.count) failed)")),
            Stat(label: "median turn", value: median(answered.compactMap(\.ttft)).map { String(format: "%.0f s", $0) } ?? "–"),
            Stat(label: "prompt reused", value: reuse.map { String(format: "%.0f%%", $0) } ?? "–"),
            Stat(label: "waiting on prefill", value: String(format: "%.1f h", busy)),
            Stat(label: "pressure", value: pressureMinutes > 0 ? String(format: "%.0f min", pressureMinutes) : "none"),
            Stat(label: "jobs", value: jobs.isEmpty ? "none" : "\(jobs.filter { $0.result == "queued" }.count) queued"),
        ]
    }

    private var uptimeText: String {
        let out = DashboardView.shell("/bin/ps", ["-o", "etime=", "-p", serverPID])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? "stopped" : out
    }

    private var serverPID: String {
        DashboardView.shell("/usr/bin/pgrep", ["-f", "slotstream serve"])
            .split(separator: "\n").first.map(String.init) ?? "0"
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
                    Chart(requests.suffix(40).filter { $0.ttft != nil }) { r in
                        BarMark(x: .value("turn", r.ts), y: .value("seconds", r.ttft ?? 0))
                            .foregroundStyle(by: .value("phase", "waiting for first token"))
                        BarMark(x: .value("turn", r.ts), y: .value("seconds", r.decodeSeconds ?? 0))
                            .foregroundStyle(by: .value("phase", "generating"))
                    }
                    .chartYAxisLabel("seconds")
                    .frame(height: 150)
                    Table(requests.suffix(80).reversed(), selection: $selectedRequest) {
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
                    if let turn = requests.first(where: { $0.id == selectedRequest }) {
                        Divider()
                        VStack(alignment: .leading, spacing: 3) {
                            Text(turn.ts.formatted(date: .omitted, time: .standard) + " · " + turn.project
                                + (turn.agent.isEmpty ? "" : " · " + turn.agent)).font(.callout).bold()
                            ForEach(turn.detailLines, id: \.self) { Text($0).font(.caption) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("select a turn to see what it read, reused and called").font(.caption).foregroundStyle(.secondary)
                    }
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

    static func tail(_ url: URL, lines: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 8_000 ? size - 8_000 : 0)
        let text = String(data: (try? handle.readToEnd()) ?? Data(), encoding: .utf8) ?? ""
        return text.split(separator: "\n").suffix(lines).joined(separator: "\n")
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
        let path = dir.appendingPathComponent(name).path
        // bash cannot run a Python file: it failed on the docstring, so every .py called
        // through here (window-budget.py) returned nothing and its tables stayed empty.
        if name.hasSuffix(".py") { return shell("/usr/bin/env", ["python3", path] + args) }
        return shell("/bin/bash", [path] + args)
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

    /// What this Mac can and cannot do, judged by scripts/verdict.py from recorded evidence.
    /// Off the main thread: it asks the server for its plan and can wait up to three seconds.
    private func loadVerdict() {
        let script = URL(fileURLWithPath: DashboardView.reportPath).deletingLastPathComponent()
            .appendingPathComponent("verdict.py").path
        if verdict == nil { verdictLoading = true }
        DispatchQueue.global(qos: .utility).async {
            let out = DashboardView.shell("/usr/bin/env", ["python3", script, "--json"])
            let parsed = out.data(using: .utf8)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .map(Verdict.init(json:))
            DispatchQueue.main.async {
                if let parsed { verdict = parsed }
                verdictLoading = false
            }
        }
    }

    private func load() {
        loadVerdict()
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
                    samples.append(MonitorSample(ts: ts, pressure: o["pressure"] as? String ?? "unknown",
                                                 experts: ss?["experts_per_layer"] as? Int,
                                                 freePercent: o["free_percent"] as? Double ?? (o["free_percent"] as? Int).map(Double.init)))
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
                cpuPeak: (o["process"] as? [String: Any])?["cpu_peak"] as? Double,
                label: o["label"] as? String ?? "", prefill: o["prefill_tok_s"] as? Double,
                errorCode: ((o["error"] as? [String: Any])?["code"] as? String)))
        }
        runs = rs.sorted { $0.ts < $1.ts }
        loadRequests(iso: date)
        loadJobs()
        loadCalibration()
        loadAttempts()
    }

    @discardableResult
    static func runScriptDetached(_ name: String, _ args: [String]) -> String {
        let dir = URL(fileURLWithPath: reportPath).deletingLastPathComponent()
        return shell("/usr/bin/env", ["python3", dir.appendingPathComponent(name).path] + args)
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
                cacheHitRate: o["cache_hit_rate"] as? Double,
                cachedTokens: o["cached_tokens"] as? Int, promptDelta: o["prompt_delta"] as? Int,
                decodeSeconds: o["decode_s"] as? Double, totalSeconds: o["total_s"] as? Double,
                tools: o["tools"] as? [String] ?? [], expertsPerLayer: o["experts_per_layer"] as? Int)
        }.sorted { $0.ts < $1.ts }
    }

    /// report.py sits beside the control script the menu bar already resolves.
    static var reportPath: String {
        let ctl = StatusModel.settings["SLOTSTREAM_CTL"] ?? NSHomeDirectory() + "/slotkeeper/scripts/slotkeeper"
        return URL(fileURLWithPath: ctl).deletingLastPathComponent().appendingPathComponent("report.py").path
    }
}

/// Kept out of the tab's body: SwiftUI's type checker gives up on long table literals.
struct ConfigurationTable: View {
    var rows: [ConfigurationSummary]
    var body: some View {
        GroupBox("What each configuration carried") {
            VStack(alignment: .leading, spacing: 3) {
                if rows.isEmpty {
                    Text("no measurements recorded yet").font(.callout).foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    HStack(spacing: 10) {
                        Text(row.title).frame(width: 300, alignment: .leading)
                        Text(row.verdict).foregroundStyle(row.carried > 0 ? Color.primary : Color.red)
                            .frame(width: 230, alignment: .leading)
                        Text(row.speed).foregroundStyle(.secondary)
                    }.font(.callout)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// One server start or one prompt, from ~/.slotstream/calibration-attempts.jsonl.
struct CalibrationAttempt: Identifiable {
    var id: String { "\(ts.timeIntervalSince1970)-\(kind)-\(window)-\(size ?? 0)" }
    var ts: Date
    var kind: String
    var window: Int
    var targetGB: Double
    var retention: String
    var size: Int?
    var promptTokens: Int?
    var ok: Bool
    var ttft: Double?
    var prefill: Double?
    var decode: Double?
    var reason: String

    var windowText: String { window >= 1000 ? "\(window / 1000)K" : "\(window)" }
    var targetText: String { String(format: "%.1f GB", targetGB) }
    var sizeText: String {
        guard let s = promptTokens ?? size else { return kind == "start" ? "–" : "?" }
        return s >= 1000 ? "\(s / 1000)K" : "\(s)"
    }
    var ttftText: String { ttft.map { String(format: "%.0f s", $0) } ?? "–" }
    var prefillText: String { prefill.map { String(format: "%.0f tok/s", $0) } ?? "–" }
}

/// What a whole configuration managed, gathered from its attempts.
struct ConfigurationSummary: Identifiable {
    var id: String { "\(window)-\(targetGB)-\(retention)" }
    var window: Int
    var targetGB: Double
    var retention: String
    var carried: Int
    var ttft: Double?
    var prefill: Double?
    var decode: Double?
    var failure: String?

    init(_ attempts: [CalibrationAttempt]) {
        let first = attempts[0]
        window = first.window
        targetGB = first.targetGB
        retention = first.retention
        let answered = attempts.filter { $0.ok && $0.kind == "prompt" }
        carried = answered.compactMap { $0.promptTokens ?? $0.size }.max() ?? 0
        let best = answered.max { ($0.promptTokens ?? 0) < ($1.promptTokens ?? 0) }
        ttft = best?.ttft
        prefill = best?.prefill
        decode = best?.decode
        failure = attempts.first { !$0.ok }?.reason
    }

    var title: String {
        "\(window.formatted()) window · " + String(format: "%.1f GB", targetGB) + " · keeping \(retention)"
    }
    var verdict: String {
        carried > 0 ? "carried \(carried.formatted()) tokens" : (failure.map { String($0.prefix(60)) } ?? "nothing ran")
    }
    var speed: String {
        var bits: [String] = []
        if let t = ttft { bits.append(String(format: "%.0f s to first token", t)) }
        if let p = prefill { bits.append(String(format: "%.0f tok/s reading", p)) }
        if let d = decode { bits.append(String(format: "%.1f tok/s generating", d)) }
        if carried > 0, let f = failure { bits.append("then: " + String(f.prefix(40))) }
        return bits.joined(separator: " · ")
    }
}

/// What calibration is doing right now, from ~/.slotstream/calibration.progress.json.
struct CalibrationProgress {
    struct Row: Identifiable {
        var id: String { "\(window)-\(size)" }
        var window: Int
        var size: Int
        var ok: Bool
        var ttft: Double?
        var error: String?
        var detail: String {
            if let e = error { return e }
            return ttft.map { String(format: "%.0f s to first token", $0) } ?? "done"
        }
    }

    struct Attempt: Identifiable {
        var id: String { "\(kind)-\(window)-\(targetGB)-\(at)" }
        var kind: String
        var window: Int
        var targetGB: Double
        var result: String
        var at: String
        var good: Bool { result.hasPrefix("works") || result.contains("accepted") }
        var symbol: String { good ? "✓" : "·" }
        var what: String {
            kind == "memory target"
                ? String(format: "%.1f GB memory target", targetGB)
                : "\(window.formatted()) window at \(String(format: "%.1f", targetGB)) GB"
        }
    }

    var phase: String
    var window: Int?
    var size: Int?
    var targetGB: Double?
    var windows: [Int]
    var rows: [Row]
    var attempts: [Attempt]

    init?(file: URL) {
        guard let data = try? Data(contentsOf: file),
              let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        phase = o["phase"] as? String ?? "working"
        window = o["window"] as? Int
        size = o["size"] as? Int
        windows = o["windows"] as? [Int] ?? []
        targetGB = o["target_gb"] as? Double
        rows = (o["rows"] as? [[String: Any]] ?? []).map {
            Row(window: $0["window"] as? Int ?? 0, size: $0["size"] as? Int ?? 0,
                ok: $0["ok"] as? Bool ?? false, ttft: $0["ttft_s"] as? Double,
                error: $0["error"] as? String)
        }
        attempts = (o["attempts"] as? [[String: Any]] ?? []).map {
            Attempt(kind: $0["kind"] as? String ?? "", window: $0["window"] as? Int ?? 0,
                    targetGB: $0["target_gb"] as? Double ?? 0,
                    result: $0["result"] as? String ?? "", at: $0["at"] as? String ?? "")
        }
    }

    var headline: String {
        guard let w = window else { return phase }
        var line = "testing a \(w.formatted()) window"
        if let t = targetGB { line += String(format: " at a %.1f GB memory target", t) }
        if windows.count > 1, let index = windows.firstIndex(of: w) {
            line += " (\(index + 1) of \(windows.count) to try)"
        }
        return line
    }

    var step: String {
        if let s = size { return "sending \(s.formatted()) tokens — " + phase }
        return phase
    }

    /// Rough progress: sizes finished against the four a window is worth.
    var fractionDone: Double? {
        guard let w = window else { return nil }
        let done = rows.filter { $0.window == w }.count
        return min(1, Double(done) / 4)
    }
}

/// The measured verdict, written by scripts/calibrate.py.
struct Calibration {
    var comfortable: Int
    var window: Int
    var largest: Int?
    var firstFailure: Int?
    var ttft: Double?
    var ttftAtLargest: Double?
    var decode: Double?
    var prefill: Double?
    var machine: String
    var measured: Date?
    var limitedBy: String?

    var promptText: String { comfortable >= 1000 ? "\(comfortable / 1000)K" : "\(comfortable)" }

    struct Fact { var label: String; var value: String }
    var facts: [Fact] {
        var out = [Fact(label: "context window", value: window >= 1000 ? "\(window / 1000)K" : "\(window)")]
        if let t = ttft { out.append(Fact(label: "to first token", value: String(format: "%.0f s", t))) }
        if let t = ttftAtLargest, let l = largest {
            out.append(Fact(label: "at \(l / 1000)K tokens", value: String(format: "%.0f s", t)))
        }
        if let d = decode { out.append(Fact(label: "generating", value: String(format: "%.1f tok/s", d))) }
        if let p = prefill { out.append(Fact(label: "reading", value: String(format: "%.0f tok/s", p))) }
        return out
    }

    var provenance: String {
        var bits: [String] = []
        if !machine.isEmpty { bits.append(machine) }
        if let f = firstFailure { bits.append("\(f / 1000)K failed for memory") }
        if let m = measured {
            bits.append("measured " + m.formatted(date: .abbreviated, time: .shortened))
        }
        return bits.joined(separator: " · ")
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
    var cachedTokens: Int?
    var promptDelta: Int?
    var decodeSeconds: Double?
    var totalSeconds: Double?
    var tools: [String] = []
    var expertsPerLayer: Int?

    /// The story of one turn, in the order you would ask about it.
    var detailLines: [String] {
        var out: [String] = []
        if let p = prompt {
            var line = "prompt \(p.formatted()) tokens"
            if let cached = cachedTokens { line += ", \(cached.formatted()) reused from the held conversation" }
            if let delta = promptDelta { line += ", \(delta.formatted()) new since the last turn" }
            out.append(line)
        }
        if let t = ttft {
            var line = String(format: "waited %.0f s for the first token", t)
            if let d = decodeSeconds { line += String(format: ", generated for %.0f s", d) }
            if let total = totalSeconds { line += String(format: ", %.0f s in total", total) }
            out.append(line)
        }
        if let o = output, o > 0 {
            out.append("\(o) output tokens" + (decode.map { String(format: " at %.1f tok/s", $0) } ?? ""))
        }
        if !tools.isEmpty { out.append("called: " + tools.joined(separator: ", ")) }
        if let e = expertsPerLayer { out.append("expert cache \(e)/layer at the time") }
        if let err = error { out.append("status: " + err) }
        return out
    }
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
    var freePercent: Double?
}

/// Kept out of the big view body: the type checker gives up on long table literals.
struct WindowCostTable: View {
    var rows: [BudgetTables.WindowRow]
    var body: some View {
        GroupBox("What each window would cost on this machine") {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("window").frame(width: 90, alignment: .leading)
                    Text("with the conversation kept").frame(width: 200, alignment: .leading)
                    Text("with retention off").frame(width: 180, alignment: .leading)
                }.font(.caption).foregroundStyle(.secondary)
                ForEach(rows) { row in
                    HStack {
                        Text(row.window.formatted()).frame(width: 90, alignment: .leading).monospacedDigit()
                        Text(row.fullText).foregroundStyle(row.fitsFull ? Color.primary : Color.red)
                            .frame(width: 200, alignment: .leading)
                        Text(row.noneText).foregroundStyle(row.fitsNone ? Color.primary : Color.red)
                            .frame(width: 180, alignment: .leading)
                    }.font(.callout)
                }
                Text("Every context token costs 27,648 bytes wherever it appears, so with the whole "
                    + "conversation kept each 1,000 tokens of window costs about 0.11 GB.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct MachineTable: View {
    var rows: [BudgetTables.MachineRow]
    var body: some View {
        GroupBox("What a different machine would do") {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("RAM").frame(width: 70, alignment: .leading)
                    Text("memory target").frame(width: 120, alignment: .leading)
                    Text("largest window").frame(width: 130, alignment: .leading)
                    Text("expert cache").frame(width: 120, alignment: .leading)
                }.font(.caption).foregroundStyle(.secondary)
                ForEach(rows) { m in
                    HStack {
                        Text("\(m.ramGB) GB").frame(width: 70, alignment: .leading)
                        Text(String(format: "%.1f GB", m.targetGB)).frame(width: 120, alignment: .leading)
                        Text(m.windowText).frame(width: 130, alignment: .leading)
                        Text(m.cacheText).frame(width: 120, alignment: .leading)
                    }.font(.callout).monospacedDigit()
                }
                Text("Above 65,536 the server refuses the window whatever the memory, so a larger machine "
                    + "buys a bigger expert cache and speed rather than more context.")
                    .font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct BudgetTables {
    struct WindowRow: Identifiable {
        var id: Int { window }
        var window: Int; var peakFull: Double; var peakNone: Double; var fitsFull: Bool; var fitsNone: Bool
        var fullText: String { String(format: "%.2f GB %@", peakFull, fitsFull ? "fits" : "does not fit") }
        var noneText: String { String(format: "%.2f GB %@", peakNone, fitsNone ? "fits" : "does not fit") }
    }
    struct MachineRow: Identifiable {
        var id: Int { ramGB }
        var ramGB: Int; var targetGB: Double; var largestWindow: Int; var expertsPerLayer: Int
        var windowText: String { largestWindow == 0 ? "does not fit" : largestWindow.formatted() }
        var cacheText: String { largestWindow == 0 ? "–" : "\(expertsPerLayer)/layer" }
    }
    struct Ledger { var window: Int; var targetGB: Double; var peakGB: Double
                    var items: [(name: String, gb: Double)] }

    var windows: [WindowRow] = []
    var machines: [MachineRow] = []
    var ledger: Ledger?

    init(json o: [String: Any]) {
        windows = (o["windows"] as? [[String: Any]] ?? []).map {
            WindowRow(window: $0["window"] as? Int ?? 0, peakFull: $0["peak_full_gb"] as? Double ?? 0,
                      peakNone: $0["peak_none_gb"] as? Double ?? 0,
                      fitsFull: $0["fits_full"] as? Bool ?? false, fitsNone: $0["fits_none"] as? Bool ?? false)
        }
        machines = (o["machines"] as? [[String: Any]] ?? []).map {
            MachineRow(ramGB: $0["ram_gb"] as? Int ?? 0, targetGB: $0["target_gb"] as? Double ?? 0,
                       largestWindow: $0["largest_window"] as? Int ?? 0,
                       expertsPerLayer: $0["experts_per_layer"] as? Int ?? 0)
        }
        if let l = o["ledger"] as? [String: Any] {
            ledger = Ledger(window: l["window"] as? Int ?? 0, targetGB: l["target_gb"] as? Double ?? 0,
                            peakGB: l["peak_gb"] as? Double ?? 0,
                            items: (l["items"] as? [[String: Any]] ?? []).map {
                                (name: $0["name"] as? String ?? "", gb: $0["gb"] as? Double ?? 0) })
        }
    }
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
    var label: String = ""
    var prefill: Double?
    var errorCode: String?
}
