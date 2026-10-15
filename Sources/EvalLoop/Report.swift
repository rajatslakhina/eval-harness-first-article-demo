/// The side-by-side page: what a candidate fixed and broke relative to a base,
/// per split. This is the artefact a reviewer reads instead of a notebook.
public struct RegressionReport: Sendable {
    public struct SplitDelta: Sendable, Equatable {
        public let fixed: [String]
        public let broken: [String]
        public let basePassed: Int
        public let candidatePassed: Int
        public let total: Int
    }

    public let base: String
    public let candidate: String
    public let dev: SplitDelta
    public let holdout: SplitDelta

    public init(base: EvalRun, candidate: EvalRun) {
        self.base = base.version
        self.candidate = candidate.version
        self.dev = RegressionReport.delta(base, candidate, .dev)
        self.holdout = RegressionReport.delta(base, candidate, .holdout)
    }

    public func delta(for split: Split) -> SplitDelta {
        split == .dev ? dev : holdout
    }

    private static func delta(_ base: EvalRun, _ candidate: EvalRun, _ split: Split) -> SplitDelta {
        var fixed: [String] = []
        var broken: [String] = []
        for result in candidate.results(in: split) {
            guard let before = base.result(for: result.caseID) else { continue }
            if result.passed && !before.passed { fixed.append(result.caseID) }
            if !result.passed && before.passed { broken.append(result.caseID) }
        }
        return SplitDelta(
            fixed: fixed,
            broken: broken,
            basePassed: base.passed(in: split),
            candidatePassed: candidate.passed(in: split),
            total: candidate.total(in: split)
        )
    }
}

/// "Does this rule generalise?", answered by the harness instead of by hope.
public struct RuleCheck: Sendable, Equatable {
    public enum Verdict: String, Sendable {
        /// It was written for a holdout case, so the holdout no longer measures anything.
        case leaksHoldout
        /// It broke at least one case that used to pass.
        case harmful
        /// It fixed at least one holdout case nobody wrote it for.
        case generalises
        /// It fixed only dev cases. It may be right, but nothing proves it yet.
        case patchOnly
        /// It changed no pass/fail outcome at all.
        case noEffect
    }

    public let ruleID: String
    public let verdict: Verdict
    public let fixedTargets: [String]
    public let fixedDevOthers: [String]
    public let fixedHoldout: [String]
    public let broken: [String]

    /// Evaluates `rule` by running `base` with and without it.
    public init(rule: Rule, on base: PipelineVersion, harness: Harness) {
        let leaked = rule.writtenFor.filter { harness.golden.split(of: $0) == .holdout }.sorted()
        let before = harness.run(base)
        let after = harness.run(base.adding(rule, as: "\(base.name) + \(rule.id)"))
        let report = RegressionReport(base: before, candidate: after)
        let devFixed = report.dev.fixed
        self.ruleID = rule.id
        self.fixedTargets = devFixed.filter { rule.writtenFor.contains($0) }
        self.fixedDevOthers = devFixed.filter { !rule.writtenFor.contains($0) }
        self.fixedHoldout = report.holdout.fixed
        self.broken = report.dev.broken + report.holdout.broken
        if !leaked.isEmpty {
            verdict = .leaksHoldout
        } else if !broken.isEmpty {
            verdict = .harmful
        } else if !fixedHoldout.isEmpty {
            verdict = .generalises
        } else if !devFixed.isEmpty {
            verdict = .patchOnly
        } else {
            verdict = .noEffect
        }
    }
}

/// A rule is redundant in a version when removing it changes no pass/fail
/// outcome. Patch rules tend to become redundant the day a general fix lands,
/// and nobody deletes them.
public enum RuleAudit {
    public static func redundantRules(in version: PipelineVersion, harness: Harness) -> [String] {
        let full = harness.run(version)
        return version.rules.compactMap { rule in
            let without = harness.run(version.removing(ruleID: rule.id))
            let same = zip(full.results, without.results).allSatisfy { $0.passed == $1.passed }
            return same ? rule.id : nil
        }
    }
}
