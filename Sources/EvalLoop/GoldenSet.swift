/// Which side of the golden set a case lives on.
///
/// `dev` cases are the ones you look at, debug against and write rules for.
/// `holdout` cases are the ones you promise not to look at. They are the only
/// honest answer to "did that change generalise?".
public enum Split: String, Sendable, CaseIterable {
    case dev
    case holdout
}

/// One labelled example: an input and the output a correct feature produces.
public struct GoldenCase: Hashable, Sendable, Identifiable {
    public let id: String
    public let input: String
    public let expected: String

    public init(id: String, input: String, expected: String) {
        self.id = id
        self.input = input
        self.expected = expected
    }
}

public enum GoldenSetError: Error, Equatable, Sendable {
    case empty
    case duplicateID(String)
    case holdoutPercentOutOfRange(Int)
    case emptySplit(Split)
}

/// A golden set with a split that is fixed by the case IDs, not by a random
/// seed or by whoever ran the notebook last.
///
/// The split is a pure function of `(id, holdoutPercent)`: a stable FNV-1a hash
/// of the ID, modulo 100. Adding a case never moves an existing case between
/// dev and holdout, so a holdout result from last week is still comparable.
public struct GoldenSet: Sendable {
    public let cases: [GoldenCase]
    public let holdoutPercent: Int
    private let splitByID: [String: Split]

    public init(cases: [GoldenCase], holdoutPercent: Int = 33) throws {
        guard !cases.isEmpty else { throw GoldenSetError.empty }
        guard (1...99).contains(holdoutPercent) else {
            throw GoldenSetError.holdoutPercentOutOfRange(holdoutPercent)
        }
        var seen = Set<String>()
        var splits: [String: Split] = [:]
        for golden in cases {
            guard seen.insert(golden.id).inserted else {
                throw GoldenSetError.duplicateID(golden.id)
            }
            splits[golden.id] = GoldenSet.split(forID: golden.id, holdoutPercent: holdoutPercent)
        }
        for split in Split.allCases where !splits.values.contains(split) {
            throw GoldenSetError.emptySplit(split)
        }
        self.cases = cases
        self.holdoutPercent = holdoutPercent
        self.splitByID = splits
    }

    /// The split for a case in this set, or `nil` for an unknown ID.
    public func split(of id: String) -> Split? {
        splitByID[id]
    }

    public func cases(in split: Split) -> [GoldenCase] {
        cases.filter { splitByID[$0.id] == split }
    }

    /// Deterministic assignment. Exposed so the property can be tested directly.
    /// Out-of-range percentages are clamped to 0...100 rather than trapping.
    public static func split(forID id: String, holdoutPercent: Int) -> Split {
        let percent = UInt64(min(100, max(0, holdoutPercent)))
        return fnv1a(id) % 100 < percent ? .holdout : .dev
    }

    static func fnv1a(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
