import Charts
import SwiftUI

/// First dashboard window: what the monitor and exerciser have recorded, as charts.
/// Reads the JSONL files directly; no server round-trips.
struct DashboardView: View {
    @State private var monitor: [MonitorSample] = []
    @State private var runs: [ExerciserRun] = []
    @State private var hours = 24.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Slotstream Dashboard").font(.title2).bold()
                    Spacer()
                    Picker("Window", selection: $hours) {
                        Text("6h").tag(6.0); Text("24h").tag(24.0); Text("3d").tag(72.0); Text("7d").tag(168.0)
                    }.pickerStyle(.segmented).frame(width: 220)
                    Button("Reload") { load() }
                }

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
            .padding(20)
        }
        .frame(minWidth: 820, minHeight: 700)
        .onAppear(perform: load)
        .onChange(of: hours) { _, _ in load() }
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
    }
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
