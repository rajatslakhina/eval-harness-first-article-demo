import XCTest
@testable import EvalLoop

final class GoldenSetTests: XCTestCase {
    func testSplitIsAPureFunctionOfID() {
        for golden in SampleScenario.cases {
            XCTAssertEqual(GoldenSet.split(forID: golden.id, holdoutPercent: 33),
                           GoldenSet.split(forID: golden.id, holdoutPercent: 33))
        }
    }

    func testAddingCasesNeverMovesExistingCasesBetweenSplits() throws {
        let original = SampleScenario.goldenSet()
        let extra = (1...40).map { GoldenCase(id: "new-\($0)", input: "NEW \($0)", expected: "Other") }
        let grown = try GoldenSet(cases: SampleScenario.cases + extra, holdoutPercent: 33)
        for golden in SampleScenario.cases {
            XCTAssertEqual(original.split(of: golden.id), grown.split(of: golden.id), golden.id)
        }
    }

    func testSampleSplitSizes() {
        let golden = SampleScenario.goldenSet()
        XCTAssertEqual(golden.cases(in: .dev).count, 19)
        XCTAssertEqual(golden.cases(in: .holdout).map(\.id), ["t06", "t07", "t14", "t15", "t17", "t23", "t24"])
        XCTAssertNil(golden.split(of: "missing"))
        XCTAssertEqual(GoldenSet.split(forID: "t01", holdoutPercent: -5), .dev)
        XCTAssertEqual(GoldenSet.split(forID: "t01", holdoutPercent: 500), .holdout)
    }

    func testValidation() {
        XCTAssertThrowsError(try GoldenSet(cases: [])) {
            XCTAssertEqual($0 as? GoldenSetError, .empty)
        }
        let one = GoldenCase(id: "a", input: "x", expected: "y")
        XCTAssertThrowsError(try GoldenSet(cases: [one, one])) {
            XCTAssertEqual($0 as? GoldenSetError, .duplicateID("a"))
        }
        XCTAssertThrowsError(try GoldenSet(cases: SampleScenario.cases, holdoutPercent: 0)) {
            XCTAssertEqual($0 as? GoldenSetError, .holdoutPercentOutOfRange(0))
        }
        XCTAssertThrowsError(try GoldenSet(cases: SampleScenario.cases, holdoutPercent: 100)) {
            XCTAssertEqual($0 as? GoldenSetError, .holdoutPercentOutOfRange(100))
        }
        // A single case can only land in one split, so the other one is empty.
        XCTAssertThrowsError(try GoldenSet(cases: [one])) { error in
            guard case .emptySplit = error as? GoldenSetError else {
                return XCTFail("expected emptySplit, got \(error)")
            }
        }
    }
}

final class HarnessTests: XCTestCase {
    let harness = SampleScenario.harness()

    func testHistoryScores() {
        let runs = SampleScenario.history.map(harness.run)
        XCTAssertEqual(runs.map { $0.passed(in: .dev) }, [12, 14, 16, 18, 18])
        XCTAssertEqual(runs.map { $0.passed(in: .holdout) }, [3, 3, 3, 6, 6])
        XCTAssertEqual(runs.map(\.ruleCount), [0, 2, 4, 5, 1])
        XCTAssertEqual(runs.map(\.cost), [13, 13, 13, 13, 13])
        XCTAssertEqual(runs[0].accuracy(in: .holdout), 3.0 / 7.0, accuracy: 1e-9)
    }

    func testRunsAreDeterministic() {
        XCTAssertEqual(harness.run(SampleScenario.v4).results, harness.run(SampleScenario.v4).results)
    }

    func testFiredRulesOnlyRecordRulesThatChangedSomething() {
        let run = harness.run(SampleScenario.v4)
        // The prefix rule already produces "Coffee", so the Blue Bottle patch changes nothing.
        XCTAssertEqual(run.result(for: "t02")?.firedRules, ["strip-processor-prefix"])
        XCTAssertEqual(run.result(for: "t01")?.firedRules, [])
    }

    func testRemainingFailuresAreTheHardCases() {
        let failing = harness.run(SampleScenario.v5).results.filter { !$0.passed }
        XCTAssertEqual(failing.map(\.caseID), ["t08", "t17"])
    }

    func testEmptySplitAccuracyIsZeroNotNaN() {
        let run = EvalRun(version: "empty", ruleCount: 0, results: [], cost: 0)
        XCTAssertEqual(run.accuracy(in: .holdout), 0)
    }
}

final class RuleCheckTests: XCTestCase {
    let harness = SampleScenario.harness()

    func testPatchesOnlyFixWhatTheyWereWrittenFor() {
        for rule in [SampleScenario.blueBottle, SampleScenario.chipotle,
                     SampleScenario.paypalLyft, SampleScenario.sweetgreen] {
            let check = RuleCheck(rule: rule, on: SampleScenario.v1, harness: harness)
            XCTAssertEqual(check.verdict, .patchOnly, rule.id)
            XCTAssertEqual(Set(check.fixedTargets), rule.writtenFor, rule.id)
            XCTAssertTrue(check.fixedHoldout.isEmpty, rule.id)
            XCTAssertTrue(check.fixedDevOthers.isEmpty, rule.id)
            XCTAssertTrue(check.broken.isEmpty, rule.id)
        }
    }

    func testPrefixRuleGeneralisesToHoldout() {
        let check = RuleCheck(rule: SampleScenario.stripProcessorPrefix, on: SampleScenario.v1, harness: harness)
        XCTAssertEqual(check.verdict, .generalises)
        XCTAssertEqual(check.fixedHoldout, ["t06", "t14", "t23"])
        XCTAssertTrue(check.broken.isEmpty)
    }

    func testRuleWrittenForAHoldoutCaseIsALeakEvenThoughItBreaksThings() {
        let check = RuleCheck(rule: SampleScenario.mktMeansGroceries, on: SampleScenario.v1, harness: harness)
        XCTAssertEqual(check.verdict, .leaksHoldout)
        XCTAssertEqual(check.fixedHoldout, ["t17"])
        XCTAssertEqual(check.broken, ["t21"])
    }

    func testHarmfulAndNoEffect() {
        let harmful = SampleScenario.patch("coffee-is-food", contains: "COFFEE", category: "Restaurants", writtenFor: ["t08"])
        XCTAssertEqual(RuleCheck(rule: harmful, on: SampleScenario.v1, harness: harness).verdict, .harmful)
        let inert = SampleScenario.patch("never", contains: "ZZZ", category: "Other", writtenFor: ["t08"])
        XCTAssertEqual(RuleCheck(rule: inert, on: SampleScenario.v1, harness: harness).verdict, .noEffect)
    }

    func testPatchesBecomeRedundantOnceTheGeneralRuleLands() {
        XCTAssertEqual(RuleAudit.redundantRules(in: SampleScenario.v4, harness: harness),
                       ["patch-blue-bottle", "patch-chipotle", "patch-paypal-lyft", "patch-sweetgreen"])
        XCTAssertEqual(RuleAudit.redundantRules(in: SampleScenario.v5, harness: harness), [])
    }
}

final class GateAndAlarmTests: XCTestCase {
    let harness = SampleScenario.harness()

    func testGateRejectsPatchesAndPromotesTheGeneralFix() {
        let gate = SampleScenario.gate
        let v1 = harness.run(SampleScenario.v1)
        XCTAssertEqual(gate.decide(base: v1, candidate: harness.run(SampleScenario.v2),
                                   candidateRules: SampleScenario.v2.rules, golden: harness.golden),
                       .reject([.rulesWithoutHoldoutGain(added: 2)]))
        // Gated against v2 (as the demo app does), v3 adds two more rules with no holdout gain.
        XCTAssertEqual(gate.decide(base: harness.run(SampleScenario.v2), candidate: harness.run(SampleScenario.v3),
                                   candidateRules: SampleScenario.v3.rules, golden: harness.golden),
                       .reject([.rulesWithoutHoldoutGain(added: 2)]))
        XCTAssertEqual(gate.decide(base: v1, candidate: harness.run(SampleScenario.v3),
                                   candidateRules: SampleScenario.v3.rules, golden: harness.golden),
                       .reject([.rulesWithoutHoldoutGain(added: 4)]))
        XCTAssertEqual(gate.decide(base: v1, candidate: harness.run(SampleScenario.v4),
                                   candidateRules: SampleScenario.v4.rules, golden: harness.golden),
                       .promote)
        // Deleting the four redundant patches is a promotion too: fewer rules, same holdout.
        XCTAssertEqual(gate.decide(base: harness.run(SampleScenario.v4), candidate: harness.run(SampleScenario.v5),
                                   candidateRules: SampleScenario.v5.rules, golden: harness.golden),
                       .promote)
    }

    func testGateCatchesLeaksRegressionsAndBudget() {
        let v5 = SampleScenario.v5
        let leaky = v5.adding(SampleScenario.mktMeansGroceries, as: "v6 leaky")
        let decision = SampleScenario.gate.decide(base: harness.run(v5), candidate: harness.run(leaky),
                                                  candidateRules: leaky.rules, golden: harness.golden)
        XCTAssertEqual(decision, .reject([.ruleLeaksHoldout("patch-mkt-groceries")]))

        let harmful = SampleScenario.patch("fuel-everywhere", contains: "0", category: "Fuel", writtenFor: ["t08"])
        let broken = v5.adding(harmful, as: "v6 harmful")
        guard case .reject(let failures) = SampleScenario.gate.decide(
            base: harness.run(v5), candidate: harness.run(broken),
            candidateRules: broken.rules, golden: harness.golden) else {
            return XCTFail("a rule that breaks holdout cases must not be promoted")
        }
        XCTAssertTrue(failures.contains(.holdoutRegressions(["t15"])), "\(failures)")
        XCTAssertTrue(failures.contains(.holdoutAccuracyDropped(base: 6, candidate: 5)), "\(failures)")

        let tight = PromotionGate(costBudgetPerRun: 10)
        XCTAssertEqual(tight.decide(base: harness.run(v5), candidate: harness.run(v5),
                                    candidateRules: v5.rules, golden: harness.golden),
                       .reject([.overBudget(cost: 13, budget: 10)]))
    }

    func testPatchingAlarm() {
        let runs = SampleScenario.history.map(harness.run)
        XCTAssertEqual(PatchingAlarm.evaluate(history: Array(runs[0...1])), .healthy)
        XCTAssertEqual(PatchingAlarm.evaluate(history: Array(runs[0...2])), .sliding(steps: 2, rulesAdded: 4))
        XCTAssertEqual(PatchingAlarm.evaluate(history: Array(runs[0...3])), .healthy)
        XCTAssertEqual(PatchingAlarm.evaluate(history: runs, window: 10), .healthy)
        XCTAssertEqual(PatchingAlarm.evaluate(history: [], window: 0), .healthy)
    }
}
