/// The thing under evaluation. In an app this wraps a Foundation Models
/// session, a Core ML model or a remote endpoint. In this repo it is a
/// deterministic stand-in, so every number in the README can be re-derived.
public protocol EvalModel: Sendable {
    /// Cost of one call, in whatever unit your team budgets in (cents, GPU
    /// seconds, minutes of wall clock). The harness only adds these up.
    var costPerCall: Double { get }
    func respond(to input: String) -> String
}

/// A hand-written fix-up applied around the model.
///
/// Every rule records the golden cases it was written to fix. That one field
/// is what lets the harness tell a rule that generalises from a rule that
/// memorises the failures someone happened to look at.
public struct Rule: Sendable, Identifiable {
    public enum Action: Sendable {
        /// Rewrites the input before the model sees it. Return `nil` to leave it.
        case rewriteInput(@Sendable (String) -> String?)
        /// Replaces the model's answer, given the original input. Return `nil` to leave it.
        case overrideOutput(@Sendable (String) -> String?)
    }

    public let id: String
    public let writtenFor: Set<String>
    public let action: Action

    public init(id: String, writtenFor: Set<String>, action: Action) {
        self.id = id
        self.writtenFor = writtenFor
        self.action = action
    }
}

/// One experiment: a named, ordered list of rules on top of the model.
public struct PipelineVersion: Sendable {
    public let name: String
    public let rules: [Rule]

    public init(name: String, rules: [Rule]) {
        self.name = name
        self.rules = rules
    }

    public func adding(_ rule: Rule, as name: String) -> PipelineVersion {
        PipelineVersion(name: name, rules: rules + [rule])
    }

    public func removing(ruleID: String) -> PipelineVersion {
        PipelineVersion(name: "\(name) − \(ruleID)", rules: rules.filter { $0.id != ruleID })
    }
}
