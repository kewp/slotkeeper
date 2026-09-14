import SwiftUI

/// What this Mac can and cannot do with the local model, from `scripts/verdict.py --json`.
///
/// The script does all the judging from recorded evidence; this only carries it to the view.
struct Verdict {
    struct Item: Identifiable {
        var id: String { title }
        var title: String
        var detail: String
        var evidence: String
        var why: String?
        var kind: String?
        var fix: String?

        init(json o: [String: Any]) {
            title = o["title"] as? String ?? ""
            detail = o["detail"] as? String ?? ""
            evidence = o["evidence"] as? String ?? ""
            why = (o["why"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            kind = o["kind"] as? String
            fix = (o["fix"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }

        /// What kind of limit this is, in words a person decides on.
        var kindLabel: String? {
            switch kind {
            case "setting": return "fixable: a setting"
            case "memory": return "depends on free memory"
            case "hardware": return "hardware limit"
            case "unknown": return "cause not known yet"
            default: return nil
            }
        }

        var kindColour: Color {
            switch kind {
            case "setting": return .blue
            case "memory": return .orange
            case "hardware": return .gray
            default: return .purple
            }
        }
    }

    var headline: String
    var machine: String
    var window: Int?
    var memoryGB: Double?
    var keepsTokens: Int?
    var since: Date?
    var serverRunning: Bool
    var can: [Item]
    var cannot: [Item]
    var untested: [String]
    var yourUse: String?
    var yourUseWarning: String?

    init(json o: [String: Any]) {
        headline = o["headline"] as? String ?? ""
        machine = o["machine"] as? String ?? "this Mac"
        let s = o["settings"] as? [String: Any] ?? [:]
        window = s["window"] as? Int
        memoryGB = s["memory_gb"] as? Double
        keepsTokens = s["keeps_tokens"] as? Int
        since = (s["since"] as? String).flatMap(DashboardView.parseDate)
        serverRunning = s["server_running"] as? Bool ?? false
        can = (o["can"] as? [[String: Any]] ?? []).map(Item.init(json:))
        cannot = (o["cannot"] as? [[String: Any]] ?? []).map(Item.init(json:))
        untested = (o["untested"] as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }
        let use = o["your_use"] as? [String: Any]
        yourUse = use?["detail"] as? String
        yourUseWarning = use?["warning"] as? String
    }

    /// Commas, like every number the script writes, so one panel does not mix "98 304" and "98,304".
    static func grouped(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        f.usesGroupingSeparator = true
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    var settingsLine: String {
        var bits = [machine]
        if let w = window { bits.append("\(Verdict.grouped(w))-token window") }
        if let m = memoryGB { bits.append(String(format: "%.1f GB for the model", m)) }
        if let k = keepsTokens { bits.append("keeps \(Verdict.grouped(k)) tokens between turns") }
        if let d = since { bits.append("these settings since " + d.formatted(date: .abbreviated, time: .shortened)) }
        if !serverRunning { bits.append("server not running: settings from the last calibration") }
        return bits.joined(separator: " · ")
    }
}

/// The first thing the window shows: a large, plain answer to "what can this Mac do?"
struct VerdictPanel: View {
    var verdict: Verdict?
    var loading: Bool

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 18) {
                if let v = verdict {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("What this Mac can do with the local model")
                            .font(.headline).foregroundStyle(.secondary)
                        Text(v.headline)
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(v.settingsLine).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(alignment: .top, spacing: 32) {
                        VerdictColumn(title: "Can", symbol: "checkmark.circle.fill", colour: .green, items: v.can)
                        VerdictColumn(title: "Can't", symbol: "xmark.circle.fill", colour: .red, items: v.cannot)
                    }
                    if let use = v.yourUse {
                        Divider()
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Your own sessions").font(.title3.weight(.semibold))
                            Text(use).font(.body).fixedSize(horizontal: false, vertical: true)
                            if let warning = v.yourUseWarning {
                                Label(warning, systemImage: "exclamationmark.triangle.fill")
                                    .font(.body).foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    if !v.untested.isEmpty {
                        Text("Not tested at these settings: " + v.untested.joined(separator: ", "))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    Text(loading ? "Working out what this Mac can do…" : "Nothing measured yet")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                    Text("The answer comes from calibration and the background tests; "
                         + "it appears once either has run.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct VerdictColumn: View {
    var title: String
    var symbol: String
    var colour: Color
    var items: [Verdict.Item]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol)
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(colour)
            if items.isEmpty {
                Text("nothing measured").font(.body).foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                VerdictRow(item: item, colour: colour)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct VerdictRow: View {
    var item: Verdict.Item
    var colour: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.title).font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let label = item.kindLabel {
                    Text(label)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(item.kindColour.opacity(0.18)))
                        .foregroundStyle(item.kindColour)
                }
            }
            if !item.detail.isEmpty {
                Text(item.detail).font(.body).fixedSize(horizontal: false, vertical: true)
            }
            if let why = item.why {
                Text("Why: " + why).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let fix = item.fix {
                Text("Would take: " + fix).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(item.evidence).font(.caption).foregroundStyle(.tertiary)
        }
        .padding(.leading, 4)
        .overlay(alignment: .leading) {
            Rectangle().fill(colour.opacity(0.5)).frame(width: 3).offset(x: -8)
        }
    }
}
