/// The outcome of one golden case under one pipeline version.
public struct CaseResult: Sendable, Equatable {
    public let caseID: String
    public let split: Split
    public let output: String
    public let passed: Bool
    /// IDs of the rules that changed something for this case, in order.
    public let firedRules: [String]
}

/// One run of one pipeline version over the whole golden set.
public struct EvalRun: Sendable {
    public let version: String
    public let ruleCount: Int
    public let results: [CaseResult]
    public let cost: Double

    public func results(in split: Split) -> [CaseResult] {
        results.filter { $0.split == split }
    }

    public func passed(in split: Split) -> Int {
        results(in: split).filter(\.passed).count
    }

    public func total(in split: Split) -> Int {
        results(in: split).count
    }

    /// Fraction passed in a split. A split with no cases scores 0, never NaN.
    public func accuracy(in split: Split) -> Double {
        let total = total(in: split)
        return total == 0 ? 0 : Double(passed(in: split)) / Double(total)
    }

    public func result(for caseID: String) -> CaseResult? {
        results.first { $0.caseID == caseID }
    }
}

/// Runs pipeline versions against a golden set. It holds no state between
/// runs, so two runs of the same version are identical by construction.
public struct Harness: Sendable {
    public let model: any EvalModel
    public let golden: GoldenSet

    public init(model: any EvalModel, golden: GoldenSet) {
        self.model = model
        self.golden = golden
    }

    public func run(_ version: PipelineVersion) -> EvalRun {
        var results: [CaseResult] = []
        results.reserveCapacity(golden.cases.count)
        for goldenCase in golden.cases {
            var input = goldenCase.input
            var fired: [String] = []
            for rule in version.rules {
                if case .rewriteInput(let rewrite) = rule.action,
                   let rewritten = rewrite(input), rewritten != input {
                    input = rewritten
                    fired.append(rule.id)
                }
            }
            var output = model.respond(to: input)
            for rule in version.rules {
                if case .overrideOutput(let override) = rule.action,
                   let replaced = override(goldenCase.input), replaced != output {
                    output = replaced
                    fired.append(rule.id)
                }
            }
            results.append(CaseResult(
                caseID: goldenCase.id,
                split: golden.split(of: goldenCase.id) ?? .dev,
                output: output,
                passed: output == goldenCase.expected,
                firedRules: fired
            ))
        }
        return EvalRun(
            version: version.name,
            ruleCount: version.rules.count,
            results: results,
            cost: Double(golden.cases.count) * model.costPerCall
        )
    }
}
