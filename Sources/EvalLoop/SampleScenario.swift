/// A deterministic stand-in for an on-device categoriser of card-statement
/// descriptors ("SQ *BLUE BOTTLE COFFEE" → "Coffee").
///
/// It has one realistic weakness, built in on purpose: it keys on the leading
/// word, so payment-processor prefixes (`SQ *`, `TST*`, `PAYPAL *`) hide the
/// merchant. It is not a real model and the article does not claim it is; it
/// exists so the eval loop around it can be shown with numbers anyone can re-run.
public struct LeadingWordModel: EvalModel {
    public let costPerCall: Double
    public let lexicon: [String: String]

    public init(costPerCall: Double = 0.5, lexicon: [String: String] = LeadingWordModel.defaultLexicon) {
        self.costPerCall = costPerCall
        self.lexicon = lexicon
    }

    public func respond(to input: String) -> String {
        let upper = input.uppercased()
        let word = upper.prefix { $0.isLetter }
        return lexicon[String(word)] ?? "Other"
    }

    public static let defaultLexicon: [String: String] = [
        "STARBUCKS": "Coffee", "BLUE": "Coffee", "PHILZ": "Coffee",
        "CHIPOTLE": "Restaurants", "SWEETGREEN": "Restaurants",
        "UBER": "Transport", "LYFT": "Transport",
        "SHELL": "Fuel", "CHEVRON": "Fuel",
        "SAFEWAY": "Groceries", "TRADER": "Groceries", "WHOLEFDS": "Groceries",
        "NETFLIX": "Subscriptions", "SPOTIFY": "Subscriptions", "APPLE": "Subscriptions",
        "AMZN": "Shopping", "ATM": "Other",
    ]
}

/// The worked example used by the tests, the README and the demo app.
public enum SampleScenario {
    public static let cases: [GoldenCase] = [
        GoldenCase(id: "t01", input: "STARBUCKS #1182 SEATTLE", expected: "Coffee"),
        GoldenCase(id: "t02", input: "SQ *BLUE BOTTLE COFFEE", expected: "Coffee"),
        GoldenCase(id: "t03", input: "SQ *PHILZ COFFEE 019", expected: "Coffee"),
        GoldenCase(id: "t04", input: "PHILZ COFFEE MISSION", expected: "Coffee"),
        GoldenCase(id: "t05", input: "TST* CHIPOTLE 2231", expected: "Restaurants"),
        GoldenCase(id: "t06", input: "TST* PHILZ COFFEE", expected: "Coffee"),
        GoldenCase(id: "t07", input: "SWEETGREEN SOMA", expected: "Restaurants"),
        GoldenCase(id: "t08", input: "SQ *JOES PIZZA 4411", expected: "Restaurants"),
        GoldenCase(id: "t09", input: "UBER *TRIP HELP.UBER.COM", expected: "Transport"),
        GoldenCase(id: "t10", input: "LYFT *RIDE TUE 8PM", expected: "Transport"),
        GoldenCase(id: "t11", input: "PAYPAL *LYFT RIDE", expected: "Transport"),
        GoldenCase(id: "t12", input: "SHELL OIL 57444", expected: "Fuel"),
        GoldenCase(id: "t13", input: "TRADER JOE'S #552", expected: "Groceries"),
        GoldenCase(id: "t14", input: "PAYPAL *SPOTIFY P1B2", expected: "Subscriptions"),
        GoldenCase(id: "t15", input: "SAFEWAY #1290", expected: "Groceries"),
        GoldenCase(id: "t16", input: "WHOLEFDS MKT 10155", expected: "Groceries"),
        GoldenCase(id: "t17", input: "SQ *FARMERS MKT STALL 3", expected: "Groceries"),
        GoldenCase(id: "t18", input: "NETFLIX.COM", expected: "Subscriptions"),
        GoldenCase(id: "t19", input: "SPOTIFY USA", expected: "Subscriptions"),
        GoldenCase(id: "t20", input: "APPLE.COM/BILL", expected: "Subscriptions"),
        GoldenCase(id: "t21", input: "AMZN MKTP US*2K4", expected: "Shopping"),
        GoldenCase(id: "t22", input: "ATM WITHDRAWAL 0012", expected: "Other"),
        GoldenCase(id: "t23", input: "SQ *STARBUCKS RESERVE", expected: "Coffee"),
        GoldenCase(id: "t24", input: "CHEVRON 0091", expected: "Fuel"),
        GoldenCase(id: "t25", input: "TST* SWEETGREEN 88", expected: "Restaurants"),
        GoldenCase(id: "t26", input: "PAYPAL *AMZN DIGITAL", expected: "Shopping"),
    ]

    public static func goldenSet() -> GoldenSet {
        do {
            return try GoldenSet(cases: cases, holdoutPercent: 33)
        } catch {
            preconditionFailure("SampleScenario.cases is invalid: \(error)")
        }
    }

    public static func harness() -> Harness {
        Harness(model: LeadingWordModel(), golden: goldenSet())
    }

    // MARK: Rules

    /// A patch: an output override keyed on one merchant string.
    public static func patch(_ id: String, contains needle: String, category: String, writtenFor: Set<String>) -> Rule {
        Rule(id: id, writtenFor: writtenFor, action: .overrideOutput { input in
            input.uppercased().contains(needle) ? category : nil
        })
    }

    public static let blueBottle = patch("patch-blue-bottle", contains: "BLUE BOTTLE", category: "Coffee", writtenFor: ["t02"])
    public static let chipotle = patch("patch-chipotle", contains: "CHIPOTLE", category: "Restaurants", writtenFor: ["t05"])
    public static let paypalLyft = patch("patch-paypal-lyft", contains: "PAYPAL *LYFT", category: "Transport", writtenFor: ["t11"])
    public static let sweetgreen = patch("patch-sweetgreen", contains: "SWEETGREEN", category: "Restaurants", writtenFor: ["t25"])

    /// The general fix: remove the processor prefix so the model sees the merchant.
    /// Written after reading the dev failures as a group instead of one at a time.
    public static let processorPrefixes = ["SQ *", "TST* ", "TST*", "PAYPAL *"]
    public static let stripProcessorPrefix = Rule(
        id: "strip-processor-prefix",
        writtenFor: ["t02", "t03", "t05", "t11", "t25", "t26"],
        action: .rewriteInput { input in
            for prefix in processorPrefixes where input.uppercased().hasPrefix(prefix) {
                return String(input.dropFirst(prefix.count))
            }
            return nil
        }
    )

    /// The tempting one: written by peeking at holdout case t17. It also breaks t21.
    public static let mktMeansGroceries = patch("patch-mkt-groceries", contains: "MKT", category: "Groceries", writtenFor: ["t17"])

    // MARK: Versions

    public static let v1 = PipelineVersion(name: "v1 baseline", rules: [])
    public static let v2 = PipelineVersion(name: "v2 +2 patches", rules: [blueBottle, chipotle])
    public static let v3 = PipelineVersion(name: "v3 +2 patches", rules: [blueBottle, chipotle, paypalLyft, sweetgreen])
    public static let v4 = PipelineVersion(name: "v4 +prefix rule", rules: [blueBottle, chipotle, paypalLyft, sweetgreen, stripProcessorPrefix])
    public static let v5 = PipelineVersion(name: "v5 patches deleted", rules: [stripProcessorPrefix])

    public static let history: [PipelineVersion] = [v1, v2, v3, v4, v5]

    /// 26 calls at 0.5 units each is 13 per run; the budget leaves a little room.
    public static let gate = PromotionGate(costBudgetPerRun: 15)
}
