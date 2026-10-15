import SwiftUI
import EvalLoop

@main
struct DemoApp: App {
    var body: some Scene {
        WindowGroup {
            RootView(initialTab: UserDefaults.standard.string(forKey: "tab") ?? "runs")
        }
    }
}

// MARK: - Data computed once from the library

enum Model {
    static let harness = SampleScenario.harness()
    static let versions = SampleScenario.history
    static let runs: [EvalRun] = versions.map { harness.run($0) }

    static func alarm(upTo index: Int) -> PatchingAlarm {
        PatchingAlarm.evaluate(history: Array(runs.prefix(index + 1)))
    }

    /// Each version is judged against the version before it.
    static func decision(at index: Int) -> PromotionGate.Decision? {
        guard index > 0, index < runs.count, index < versions.count else { return nil }
        return SampleScenario.gate.decide(base: runs[index - 1], candidate: runs[index],
                                          candidateRules: versions[index].rules, golden: harness.golden)
    }

    static let checks: [RuleCheck] = [
        SampleScenario.blueBottle, SampleScenario.chipotle, SampleScenario.paypalLyft,
        SampleScenario.sweetgreen, SampleScenario.stripProcessorPrefix, SampleScenario.mktMeansGroceries,
    ].map { RuleCheck(rule: $0, on: SampleScenario.v1, harness: harness) }

    static let redundantInV4 = RuleAudit.redundantRules(in: SampleScenario.v4, harness: harness)
}

struct RootView: View {
    @State private var tab: String

    init(initialTab: String) {
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { RunsView() }
                .tabItem { Label("Runs", systemImage: "chart.bar.xaxis") }
                .tag("runs")
            NavigationStack { RulesView() }
                .tabItem { Label("Rules", systemImage: "checklist") }
                .tag("rules")
            NavigationStack { CasesView() }
                .tabItem { Label("Side by side", systemImage: "rectangle.split.2x1") }
                .tag("cases")
        }
    }
}

// MARK: - Runs

struct RunsView: View {
    var body: some View {
        List {
            Section {
                ForEach(Array(Model.runs.enumerated()), id: \.offset) { index, run in
                    RunRow(run: run, alarm: Model.alarm(upTo: index), decision: Model.decision(at: index))
                }
            } footer: {
                Text("26 golden cases, split by a hash of each ID: 19 dev, 7 holdout. Each version is gated against the one before it. Stand-in model, not a real one.")
            }
        }
        .navigationTitle("Eval loop")
    }
}

struct RunRow: View {
    let run: EvalRun
    let alarm: PatchingAlarm
    let decision: PromotionGate.Decision?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(run.version).font(.headline)
                Spacer()
                Text("\(run.ruleCount) rule\(run.ruleCount == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScoreBar(label: "Dev", passed: run.passed(in: .dev), total: run.total(in: .dev), tint: .gray)
            ScoreBar(label: "Holdout", passed: run.passed(in: .holdout), total: run.total(in: .holdout), tint: .blue)
            if case .sliding(let steps, let added) = alarm {
                Label("Rule-patching alarm: \(added) rules over \(steps) versions, holdout flat",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            switch decision {
            case .some(.promote):
                Label("Gate: promote", systemImage: "checkmark.seal.fill")
                    .font(.caption).foregroundStyle(.green)
            case .some(.reject(let failures)):
                Label("Gate: reject. \(failures.map(\.description).joined(separator: "; "))",
                      systemImage: "xmark.octagon.fill")
                    .font(.caption).foregroundStyle(.red)
            case .none:
                Text("Baseline").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct ScoreBar: View {
    let label: String
    let passed: Int
    let total: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.caption).frame(width: 56, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(tint)
                        .frame(width: total == 0 ? 0 : proxy.size.width * CGFloat(passed) / CGFloat(total))
                }
            }
            .frame(height: 8)
            Text("\(passed)/\(total)").font(.caption.monospacedDigit()).frame(width: 40, alignment: .trailing)
        }
    }
}

// MARK: - Rules

struct RulesView: View {
    var body: some View {
        List {
            Section("Does this rule generalise? (each added to v1 alone)") {
                ForEach(Model.checks, id: \.ruleID) { check in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(check.ruleID).font(.subheadline.monospaced())
                            Spacer()
                            VerdictBadge(verdict: check.verdict)
                        }
                        Text(summary(check)).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            Section("Redundant in v4 (removing them changes nothing)") {
                ForEach(Model.redundantInV4, id: \.self) { id in
                    Label(id, systemImage: "trash").font(.subheadline.monospaced())
                }
            }
        }
        .navigationTitle("Rules")
    }

    func summary(_ check: RuleCheck) -> String {
        var parts = ["fixes \(check.fixedTargets.count) target(s)"]
        if !check.fixedHoldout.isEmpty { parts.append("\(check.fixedHoldout.count) holdout: \(check.fixedHoldout.joined(separator: ", "))") }
        if !check.broken.isEmpty { parts.append("breaks \(check.broken.joined(separator: ", "))") }
        return parts.joined(separator: " · ")
    }
}

struct VerdictBadge: View {
    let verdict: RuleCheck.Verdict

    var body: some View {
        Text(verdict.rawValue)
            .font(.caption2.bold())
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    var color: Color {
        switch verdict {
        case .generalises: return .green
        case .patchOnly: return .orange
        case .leaksHoldout, .harmful: return .red
        case .noEffect: return .gray
        }
    }
}

// MARK: - Side by side

struct CasesView: View {
    @State private var showHoldoutOnly = false

    private var first: EvalRun? { Model.runs.first }
    private var last: EvalRun? { Model.runs.last }

    var body: some View {
        List {
            Toggle("Holdout only", isOn: $showHoldoutOnly)
            if let first, let last {
                Section("\(first.version)  →  \(last.version)") {
                    ForEach(Model.harness.golden.cases.filter { !showHoldoutOnly || Model.harness.golden.split(of: $0.id) == .holdout }) { golden in
                        CaseRow(golden: golden,
                                split: Model.harness.golden.split(of: golden.id) ?? .dev,
                                before: first.result(for: golden.id),
                                after: last.result(for: golden.id))
                    }
                }
            }
        }
        .navigationTitle("Side by side")
    }
}

struct CaseRow: View {
    let golden: GoldenCase
    let split: Split
    let before: CaseResult?
    let after: CaseResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(golden.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                if split == .holdout {
                    Text("HOLDOUT").font(.caption2.bold()).foregroundStyle(.blue)
                }
                Spacer()
                mark(before)
                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.secondary)
                mark(after)
            }
            Text(golden.input).font(.subheadline.monospaced())
            Text("expected \(golden.expected) · got \(after?.output ?? "–")")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    func mark(_ result: CaseResult?) -> some View {
        if let result {
            Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(result.passed ? Color.green : Color.red)
        } else {
            Image(systemName: "questionmark.circle")
        }
    }
}
