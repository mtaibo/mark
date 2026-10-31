import Testing
import Engine

/// `passPlan`: the other parts aim at their own pass mark, the final exam makes up the rest.
struct PassPlanTests {
    /// Labs (two, 20%), a test (20%) and the final exam (60%).
    private let root = Node.group(Group(name: "Asignatura", combination: .weightedAverage, children: [
        WeightedChild(weight: 0.2, node: .group(Group(name: "Prácticas", combination: .weightedAverage, children: [
            WeightedChild(weight: 1, node: .grade(Grade(name: "P1"))),
            WeightedChild(weight: 1, node: .grade(Grade(name: "P2"))),
        ]))),
        WeightedChild(weight: 0.2, node: .grade(Grade(name: "Test"))),
        WeightedChild(weight: 0.6, node: .grade(Grade(name: "Examen", isFinalExam: true))),
    ]))

    @Test func otherPartsAimAtAFiveAndTheExamMakesUpTheRest() throws {
        let plan = try #require(root.passPlan([:], target: 5))
        #expect(abs(plan["P1"]! - 0.5) < 0.001)
        #expect(abs(plan["P2"]! - 0.5) < 0.001)
        #expect(abs(plan["Test"]! - 0.5) < 0.001)
        #expect(abs(plan["Examen"]! - 0.5) < 0.001)
    }

    @Test func aStrongLabLeavesLessForTheOtherOne() throws {
        let plan = try #require(root.passPlan(["P1": 8], target: 5))
        #expect(abs(plan["P2"]! - 0.2) < 0.001)
        #expect(plan["P1"] == nil)
    }

    @Test func aWeakStartIsMadeUpInTheExam() throws {
        // 0.2*1 + 0.2*0 + 0.6*x = 5 → x = 8.
        let plan = try #require(root.passPlan(["P1": 1, "P2": 1, "Test": 0], target: 5))
        #expect(abs(plan["Examen"]! - 0.8) < 0.001)
    }

    @Test func aHigherPassMarkRaisesEveryPartsAim() throws {
        let heavy = Node.group(Group(name: "A", combination: .weightedAverage, children: [
            WeightedChild(weight: 0.6, node: .grade(Grade(name: "Trabajo"))),
            WeightedChild(weight: 0.4, node: .grade(Grade(name: "Examen", isFinalExam: true))),
        ]))
        // Passing with a 7: a 7 in the work, then 0.6*7 + 0.4*x = 7 → x = 7.
        let plan = try #require(heavy.passPlan([:], target: 7))
        #expect(abs(plan["Trabajo"]! - 0.7) < 0.001)
        #expect(abs(plan["Examen"]! - 0.7) < 0.001)
        // With a 1 in the work, even a 10 in the exam leaves it at 4,6.
        #expect(heavy.passPlan(["Trabajo": 1], target: 7) == nil)
    }

    @Test func theExamStaysAtATenWhenTheRestHasToRise() throws {
        let three = Node.group(Group(name: "A", combination: .weightedAverage, children: [
            WeightedChild(weight: 0.3, node: .grade(Grade(name: "Hecho"))),
            WeightedChild(weight: 0.3, node: .grade(Grade(name: "Trabajo"))),
            WeightedChild(weight: 0.4, node: .grade(Grade(name: "Examen", isFinalExam: true))),
        ]))
        // 0.3*0 + 0.3*5 + 0.4*x = 5 → x = 8,75, fine; with target 6: x = 11,25 → exam 10, work 6,67.
        let plan = try #require(three.passPlan(["Hecho": 0], target: 6))
        #expect(plan["Examen"] == 1)
        #expect(abs(plan["Trabajo"]! - 2.0 / 3) < 0.001)
    }

    @Test func withoutAFinalExamThePendingPartsShareWhatsLeft() throws {
        // Two exams (45 % each) and a book (10 %), an 8 in the first: 3,6 in, 1,4 to go over 55 %.
        let continuous = Node.group(Group(name: "A", combination: .weightedAverage, children: [
            WeightedChild(weight: 0.45, node: .grade(Grade(name: "1er Examen"))),
            WeightedChild(weight: 0.45, node: .grade(Grade(name: "2do Examen"))),
            WeightedChild(weight: 0.1, node: .grade(Grade(name: "Libro"))),
        ]))
        let plan = try #require(continuous.passPlan(["1er Examen": 8], target: 5))
        #expect(abs(plan["2do Examen"]! - 1.4 / 5.5) < 0.001)
        #expect(abs(plan["Libro"]! - 1.4 / 5.5) < 0.001)
    }

    @Test func thePlanReachesTheTargetForEveryReferenceSubject() {
        for subject in Subject.all {
            guard let plan = subject.root.passPlan([:], target: 5) else { continue }
            let inputs = plan.reduce(into: [String: Double]()) { result, pair in
                result[pair.key] = pair.value * (subject.root.leaf(named: pair.key)?.scaleMax ?? 10) + 0.001
            }
            #expect(subject.root.evaluate(inputs, pendingFraction: 0) >= 5 - 0.01, "\(subject.name)")
        }
    }
}
