/// Promotion rules for a candidate pipeline. A lead writes these down once;
/// after that, "is v7 better?" stops being a meeting.
public struct PromotionGate: Sendable {
    public enum Failure: Sendable, Equatable, CustomStringConvertible {
        case holdoutAccuracyDropped(base: Int, candidate: Int)
        case holdoutRegressions([String])
        case ruleLeaksHoldout(String)
        case overBudget(cost: Double, budget: Double)
        case rulesWithoutHoldoutGain(added: Int)

        public var description: String {
            switch self {
            case .holdoutAccuracyDropped(let base, let candidate):
                return "Holdout passes fell from \(base) to \(candidate)"
            case .holdoutRegressions(let ids):
                return "Broke holdout cases: \(ids.joined(separator: ", "))"
            case .ruleLeaksHoldout(let id):
                return "Rule \(id) was written for a holdout case"
            case .overBudget(let cost, let budget):
                return "Run cost \(cost) is over the budget of \(budget)"
            case .rulesWithoutHoldoutGain(let added):
                return "Added \(added) rule(s) but holdout passes did not rise"
            }
        }
    }

    public enum Decision: Sendable, Equatable {
        case promote
        case reject([Failure])
    }

    /// How many holdout cases a candidate may break, even if it fixes more. Default 0.
    public let allowedHoldoutRegressions: Int
    public let costBudgetPerRun: Double
    /// When true, a candidate with more rules than its base must pass more
    /// holdout cases. Every rule is code someone maintains; it has to earn that.
    public let newRulesMustRaiseHoldout: Bool

    public init(allowedHoldoutRegressions: Int = 0,
                costBudgetPerRun: Double,
                newRulesMustRaiseHoldout: Bool = true) {
        self.allowedHoldoutRegressions = max(0, allowedHoldoutRegressions)
        self.costBudgetPerRun = costBudgetPerRun
        self.newRulesMustRaiseHoldout = newRulesMustRaiseHoldout
    }

    public func decide(base: EvalRun, candidate: EvalRun, candidateRules: [Rule], golden: GoldenSet) -> Decision {
        var failures: [Failure] = []
        for rule in candidateRules where rule.writtenFor.contains(where: { golden.split(of: $0) == .holdout }) {
            failures.append(.ruleLeaksHoldout(rule.id))
        }
        let report = RegressionReport(base: base, candidate: candidate)
        if report.holdout.candidatePassed < report.holdout.basePassed {
            failures.append(.holdoutAccuracyDropped(base: report.holdout.basePassed,
                                                    candidate: report.holdout.candidatePassed))
        }
        if report.holdout.broken.count > allowedHoldoutRegressions {
            failures.append(.holdoutRegressions(report.holdout.broken))
        }
        let added = candidate.ruleCount - base.ruleCount
        if newRulesMustRaiseHoldout, added > 0,
           report.holdout.candidatePassed <= report.holdout.basePassed {
            failures.append(.rulesWithoutHoldoutGain(added: added))
        }
        if candidate.cost > costBudgetPerRun {
            failures.append(.overBudget(cost: candidate.cost, budget: costBudgetPerRun))
        }
        return failures.isEmpty ? .promote : .reject(failures)
    }
}

/// The warning sign from the article: rules keep arriving, holdout doesn't move.
public enum PatchingAlarm: Sendable, Equatable {
    case healthy
    /// The last `steps` versions each added rules without raising holdout passes.
    case sliding(steps: Int, rulesAdded: Int)

    /// - Parameter window: how many consecutive flat, rule-adding steps trip the alarm.
    public static func evaluate(history: [EvalRun], window: Int = 2) -> PatchingAlarm {
        let window = max(1, window)
        guard history.count > window else { return .healthy }
        var steps = 0
        var added = 0
        for index in stride(from: history.count - 1, to: 0, by: -1) {
            let previous = history[index - 1]
            let current = history[index]
            let rulesAdded = current.ruleCount - previous.ruleCount
            let gained = current.passed(in: .holdout) - previous.passed(in: .holdout)
            guard rulesAdded > 0, gained <= 0 else { break }
            steps += 1
            added += rulesAdded
        }
        return steps >= window ? .sliding(steps: steps, rulesAdded: added) : .healthy
    }
}
