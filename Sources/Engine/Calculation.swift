/// The calculation engine from the brief's §5: current grade, projected/needed grade, and status.
/// Works by evaluating a `Node` twice — once assuming every ungraded leaf scores 0 (worst case)
/// and once assuming it scores its max (best case) — and binary-searching between them for
/// "needed grade", which only works because `evaluate` is monotonic in `pendingFraction`
/// (every combination here is a weighted sum of non-negative contributions). `EngineTests`
/// checks that monotonicity against the 3 reference guides, per the brief's explicit request.
extension Node {
    /// This node's own maximum achievable value. Always 10 except for a `.sum` group, whose
    /// children's weights needn't cover the whole scale — e.g. a sub-group worth 40% of its
    /// parent reports a max of 4, so that 40% shows up correctly once its parent weighs it.
    public var scaleMax: Double {
        switch self {
        case .grade(let grade):
            return grade.scaleMax
        case .group(let group):
            switch group.combination {
            case .sum:
                return group.children.reduce(0) { $0 + $1.weight } * 10
            case .weightedAverage, .max, .min, .bestOf, .undecided:
                return 10
            }
        case .alternatives(let alternatives):
            return Self.activeBranches(alternatives).map(\.node.scaleMax).max() ?? 10
        case .bonus(let bonus):
            return bonus.parentCap
        case .requirement:
            return 0
        case .formula:
            return 10
        }
    }

    /// This node's value given `inputs` for any leaf that has one, and `pendingFraction` — a
    /// fraction (0 = worst, 1 = best) of *that leaf's own scale* — for any leaf that doesn't.
    /// Any unmet `.capAt` minimum below this node caps the result (see `rawValue` for the rest).
    public func evaluate(_ inputs: [String: Double], pendingFraction: Double) -> Double {
        let value = rawValue(inputs, pendingFraction: pendingFraction)
        return caps(inputs, pendingFraction).reduce(value, Swift.min)
    }

    /// The value before caps: each child weighed as it is, a child under a `.voids` minimum as a 0
    /// and one under a `.doesNotAverage` minimum left out (its weight goes to the rest).
    func rawValue(_ inputs: [String: Double], pendingFraction: Double) -> Double {
        switch self {
        case .grade(let grade):
            return inputs[grade.name] ?? pendingFraction * grade.scaleMax
        case .group(let group):
            // (weight, fraction of its own max) for every child that still counts.
            let parts: [(weight: Double, fraction: Double)] = group.children.compactMap { child in
                let max = child.node.scaleMax
                guard max > 0 else { return (child.weight, 0) }
                let value = child.node.rawValue(inputs, pendingFraction: pendingFraction)
                switch child.node.standing(value) {
                // A value no scale can hold (a hand-edited file) counts as a 0, never as a NaN.
                case .counts: return (child.weight, (value / max).isFinite ? value / max : 0)
                case .voided: return (child.weight, 0)
                case .left: return nil
                }
            }
            let fractions = parts.map(\.fraction)
            switch group.combination {
            case .weightedAverage:
                let totalWeight = parts.reduce(0) { $0 + $1.weight }
                let weighted = parts.reduce(0) { $0 + $1.weight * $1.fraction }
                return totalWeight > 0 ? (weighted / totalWeight) * 10 : 0
            case .sum:
                return parts.reduce(0) { $0 + $1.weight * $1.fraction } * 10
            case .max:
                return (fractions.max() ?? 0) * 10
            case .min:
                return (fractions.min() ?? 0) * 10
            case .bestOf(let n):
                let count = Swift.max(n, 1)
                let best = fractions.sorted(by: >).prefix(count)
                return best.isEmpty ? 0 : (best.reduce(0, +) / Double(best.count)) * 10
            case .undecided:
                return fractions.isEmpty ? 0 : (fractions.reduce(0, +) / Double(fractions.count)) * 10
            }
        case .alternatives(let alternatives):
            return Self.alternativesValue(alternatives, inputs, pendingFraction)
        case .bonus(let bonus):
            let value = inputs[bonus.name] ?? pendingFraction * bonus.scaleMax
            return Swift.min(value, bonus.parentCap)
        case .requirement:
            // Gradeless — not wired into the numeric result yet, see docs/modelo.md.
            return 0
        case .formula(let formula):
            // A variable that doesn't count (voided or left out) is a 0 in the formula.
            let values = formula.variables.mapValues { node in
                let value = node.rawValue(inputs, pendingFraction: pendingFraction)
                return node.standing(value) == .counts ? value : 0
            }
            // A hand-typed formula can divide by a grade that is still 0; a non-number would
            // otherwise reach the screen (and the JSON file) as NaN or infinity.
            let result = formula.expression.evaluate(values)
            return result.isFinite ? result : 0
        }
    }

    private enum Standing { case counts, voided, left }

    /// How this node counts in its parent given its own `value`: as it is, as a 0, or not at all.
    private func standing(_ value: Double) -> Standing {
        guard let minimum = ownMinimum, value < minimum.threshold else { return .counts }
        switch minimum.consequence {
        case .voids: return .voided
        case .doesNotAverage: return .left
        case .capAt, .fails, .sendsToExtraordinary: return .counts
        }
    }

    /// The nodes directly below this one.
    var children: [Node] {
        switch self {
        case .group(let group): group.children.map(\.node)
        case .formula(let formula): Array(formula.variables.values)
        case .alternatives(let alternatives): Self.activeBranches(alternatives).map(\.node)
        case .grade, .bonus, .requirement: []
        }
    }

    /// The cap of every unmet `.capAt` minimum below this node (not its own: that one caps
    /// whatever contains it) — "si no llegas a un 4 en el examen, la nota final no pasa de 4,5".
    /// Monotonic: raising a part past its threshold only ever lifts its cap.
    private func caps(_ inputs: [String: Double], _ pendingFraction: Double) -> [Double] {
        // A scheme's value already comes capped (`evaluate`), and only the one that counts may cap.
        if case .alternatives = self { return [] }
        return children.flatMap { child -> [Double] in
            var caps = child.caps(inputs, pendingFraction)
            if let minimum = child.ownMinimum, case .capAt(let cap) = minimum.consequence,
               child.rawValue(inputs, pendingFraction: pendingFraction) < minimum.threshold {
                caps.append(cap)
            }
            return caps
        }
    }

    /// Every leaf (`Grade`/`Bonus`) name under this node, in tree order.
    public func allLeafNames() -> [String] {
        switch self {
        case .grade(let grade):
            return [grade.name]
        case .group(let group):
            return group.children.flatMap { $0.node.allLeafNames() }
        case .alternatives(let alternatives):
            // A note two schemes share is one note.
            var seen: Set<String> = []
            return Self.activeBranches(alternatives).flatMap { $0.node.allLeafNames() }.filter { seen.insert($0).inserted }
        case .bonus(let bonus):
            return [bonus.name]
        case .requirement:
            return []
        case .formula(let formula):
            return formula.variables.values.flatMap { $0.allLeafNames() }
        }
    }

    /// Leaf names under this node that `inputs` doesn't have a value for yet.
    public func pendingLeaves(_ inputs: [String: Double]) -> [String] {
        allLeafNames().filter { inputs[$0] == nil }
    }

    /// The leaf node named `name`, searched recursively, if any.
    public func leaf(named name: String) -> Node? {
        switch self {
        case .grade(let grade):
            return grade.name == name ? self : nil
        case .group(let group):
            return group.children.lazy.compactMap { $0.node.leaf(named: name) }.first
        case .alternatives(let alternatives):
            return alternatives.branches.lazy.compactMap { $0.node.leaf(named: name) }.first
        case .bonus(let bonus):
            return bonus.name == name ? self : nil
        case .requirement:
            return nil
        case .formula(let formula):
            return formula.variables.values.lazy.compactMap { $0.leaf(named: name) }.first
        }
    }

    /// The pass threshold on this node's own computed result, if it declares one.
    public var minimumThreshold: Double? {
        ownMinimum?.threshold
    }

    /// The minimum set on this node itself (the subject root's is its pass threshold).
    public var ownMinimum: Minimum? {
        switch self {
        case .group(let group): group.minimum
        case .formula(let formula): formula.minimum
        case .grade(let grade): grade.minimum
        case .alternatives(let alternatives): alternatives.minimum
        default: nil
        }
    }

    /// Whether every `Minimum` with a `.fails` (or `.sendsToExtraordinary`) consequence in this
    /// subtree is met — e.g. "at least 40% on the exam or the subject is failed", which no average
    /// can make up for. Monotonic in `pendingFraction` like `evaluate`, so it can share the same
    /// binary search. `.capAt`, `.voids` and `.doesNotAverage` change the number instead, in
    /// `evaluate`.
    public func meetsMinimums(_ inputs: [String: Double], pendingFraction: Double) -> Bool {
        meetsMinimums(inputs, pendingFraction: pendingFraction, includingOwn: true)
    }

    func meetsMinimums(_ inputs: [String: Double], pendingFraction: Double, includingOwn: Bool) -> Bool {
        if includingOwn, let minimum = ownMinimum, minimum.consequence == .fails || minimum.consequence == .sendsToExtraordinary,
           rawValue(inputs, pendingFraction: pendingFraction) < minimum.threshold {
            return false
        }
        switch self {
        case .group(let group):
            return group.children.allSatisfy { $0.node.meetsMinimums(inputs, pendingFraction: pendingFraction) }
        case .formula(let formula):
            return formula.variables.values.allSatisfy { $0.meetsMinimums(inputs, pendingFraction: pendingFraction) }
        case .alternatives(let alternatives):
            // With the best of several, it's enough that one of them is passed cleanly.
            let branches = Self.activeBranches(alternatives)
            return branches.isEmpty || branches.contains { $0.node.meetsMinimums(inputs, pendingFraction: pendingFraction) }
        case .grade, .bonus, .requirement:
            return true
        }
    }

    /// The uniform fraction (0...1) every pending leaf would need of its own scale for this
    /// node's value to reach `target` *and* every failing minimum to be met — `nil` if that's out
    /// of reach even with full marks. "Misma nota en todos los pendientes" per the brief: later, a
    /// simulator could fix some and solve only the rest, but that's not needed yet.
    public func neededFraction(_ inputs: [String: Double], target: Double, tolerance: Double = 0.0001) -> Double? {
        func reaches(_ fraction: Double) -> Bool {
            passes(inputs, pendingFraction: fraction, target: target)
        }
        guard reaches(1) else { return nil }
        guard !reaches(0) else { return 0 }
        var low = 0.0
        var high = 1.0
        while high - low > tolerance {
            let mid = (low + high) / 2
            if reaches(mid) {
                high = mid
            } else {
                low = mid
            }
        }
        return high
    }

    /// The schemes that count: all of them when the best is taken, else the one chosen (the first
    /// when none is, or the choice points past the end).
    public static func activeBranches(_ alternatives: Alternatives) -> [Alternatives.Branch] {
        if alternatives.pickBest { return alternatives.branches }
        let index = alternatives.selected ?? 0
        let branch = alternatives.branches.indices.contains(index) ? alternatives.branches[index] : alternatives.branches.first
        return branch.map { [$0] } ?? []
    }

    /// The chosen scheme's grade, or the best of them. Whether it passes is a matter for `passes`:
    /// a scheme that misses a failing minimum can't be the one that passes, however high it is.
    private static func alternativesValue(_ alternatives: Alternatives, _ inputs: [String: Double], _ fraction: Double) -> Double {
        activeBranches(alternatives).map { $0.node.evaluate(inputs, pendingFraction: fraction) }.max() ?? 0
    }

    /// Whether this reaches `target` with every failing minimum below it met, assuming `fraction`
    /// on what's pending — or, with several schemes, whether one of them does on its own. Its own
    /// minimum (a subject's pass mark) is left out: `target` stands in for it, so a transcript that
    /// rounds can ask for 4,95. Monotonic in `fraction`, so it can be binary-searched.
    func passes(_ inputs: [String: Double], pendingFraction fraction: Double, target: Double) -> Bool {
        if case .alternatives(let alternatives) = self {
            let branches = Self.activeBranches(alternatives)
            return branches.contains { $0.node.passes(inputs, pendingFraction: fraction, target: target) }
        }
        return evaluate(inputs, pendingFraction: fraction) >= target && meetsMinimums(inputs, pendingFraction: fraction, includingOwn: false)
    }

    /// The scheme a student would go for: the chosen one, or the one needing the least on what's
    /// left (ties to the first).
    func bestBranch(_ inputs: [String: Double], target: Double) -> Node? {
        guard case .alternatives(let alternatives) = self else { return nil }
        let branches = Self.activeBranches(alternatives).map(\.node)
        guard alternatives.pickBest else { return branches.first }
        return branches.min { lhs, rhs in
            (lhs.neededFraction(inputs, target: target) ?? 2) < (rhs.neededFraction(inputs, target: target) ?? 2)
        }
    }
}

/// Whether passing is still reachable given what's been entered so far.
public enum PassStatus: Sendable, Equatable {
    /// Even the worst case (0 on everything pending) reaches the pass threshold.
    case guaranteed
    /// Reachable, but not guaranteed — depends on what's left.
    case possible
    /// Even the best case (max on everything pending) falls short.
    case impossible
}

extension Node {
    /// Status against this node's own `minimumThreshold`, or 5 (out of 10) if it doesn't declare
    /// one — the universal default for the Spanish grading scale the brief targets.
    /// A failed minimum anywhere (e.g. under 4 on an exam that needs it) also counts.
    public func status(_ inputs: [String: Double], threshold: Double? = nil) -> PassStatus {
        let threshold = threshold ?? minimumThreshold ?? 5
        if passes(inputs, pendingFraction: 0, target: threshold) { return .guaranteed }
        if !passes(inputs, pendingFraction: 1, target: threshold) { return .impossible }
        return .possible
    }
}

extension Node {
    /// The tree as the extraordinary sitting reads it: a `.sendsToExtraordinary` minimum has done
    /// its job by then, so it's dropped.
    public var forExtraordinary: Node {
        var node = self
        node.removeMinimums { $0.consequence == .sendsToExtraordinary }
        return node
    }

    /// Leaves under a `.sendsToExtraordinary` minimum that `inputs` already leaves unmet, even with
    /// full marks on anything pending — what has to be taken again in the extraordinary sitting.
    public func leavesSentToExtraordinary(_ inputs: [String: Double]) -> Set<String> {
        if let minimum = ownMinimum, minimum.consequence == .sendsToExtraordinary,
           rawValue(inputs, pendingFraction: 1) < minimum.threshold {
            return Set(allLeafNames())
        }
        return children.reduce(into: []) { $0.formUnion($1.leavesSentToExtraordinary(inputs)) }
    }

    private mutating func removeMinimums(where shouldRemove: (Minimum) -> Bool) {
        switch self {
        case .grade(var grade):
            if let minimum = grade.minimum, shouldRemove(minimum) { grade.minimum = nil }
            self = .grade(grade)
        case .group(var group):
            if let minimum = group.minimum, shouldRemove(minimum) { group.minimum = nil }
            for index in group.children.indices { group.children[index].node.removeMinimums(where: shouldRemove) }
            self = .group(group)
        case .formula(var formula):
            if let minimum = formula.minimum, shouldRemove(minimum) { formula.minimum = nil }
            for key in formula.variables.keys { formula.variables[key]?.removeMinimums(where: shouldRemove) }
            self = .formula(formula)
        case .alternatives(var alternatives):
            if let minimum = alternatives.minimum, shouldRemove(minimum) { alternatives.minimum = nil }
            for index in alternatives.branches.indices { alternatives.branches[index].node.removeMinimums(where: shouldRemove) }
            self = .alternatives(alternatives)
        case .bonus, .requirement:
            break
        }
    }
}

extension Node {
    /// What each pending leaf needs (as a fraction of its own scale) to reach `target`, sparing
    /// the final exam as much as possible: every other top-level part first aims at its own pass
    /// mark (`target` on its scale, so with a 10 already in one of two labs the other needs a 0),
    /// and the exam makes up the rest. When even a 10 in the exam isn't enough, it stays at a 10
    /// and the other pending leaves rise together. With no final exam pending there's nothing to
    /// spare: every pending leaf needs the same, just enough. `nil` when `target` is out of reach,
    /// an empty plan when nothing is pending.
    public func passPlan(_ inputs: [String: Double], target: Double) -> [String: Double]? {
        let pending = Set(pendingLeaves(inputs))
        guard !pending.isEmpty else { return [:] }
        guard neededFraction(inputs, target: target) != nil else { return nil }
        // Several schemes: the plan of the one to go for; what only the others ask for needs nothing.
        if let branch = bestBranch(inputs, target: target) {
            guard var plan = branch.passPlan(inputs, target: target) else { return nil }
            for leaf in pending where plan[leaf] == nil { plan[leaf] = 0 }
            return plan
        }

        let parts = children.isEmpty ? [self] : children
        let isExam = { (part: Node) in part.grades.contains { $0.isFinalExam == true } }
        let examLeaves = Set(parts.filter(isExam).flatMap { $0.allLeafNames() }).intersection(pending)
        // Aiming each part at a 5 only makes sense to leave the exam less to do; without one it
        // asks for far more than it takes (an 8 in one exam and still a 5 in the other).
        if examLeaves.isEmpty, let even = neededFraction(inputs, target: target) {
            return Dictionary(uniqueKeysWithValues: pending.map { ($0, even) })
        }

        // Each other part, on its own, up to its pass mark.
        var plan: [String: Double] = [:]
        for part in parts where !isExam(part) {
            let leaves = part.pendingLeaves(inputs)
            guard !leaves.isEmpty else { continue }
            let fraction = part.neededFraction(inputs, target: target / 10 * part.scaleMax) ?? 1
            for leaf in leaves { plan[leaf] = fraction }
        }

        // The exam, on top of that.
        if !examLeaves.isEmpty, let exam = neededFraction(inputs.merging(filled(plan)) { $1 }, target: target) {
            for leaf in examLeaves { plan[leaf] = exam }
            return plan
        }
        if examLeaves.isEmpty, neededFraction(inputs.merging(filled(plan)) { $1 }, target: target) == 0 {
            return plan
        }

        // Not enough: a 10 in the exam and the rest evenly, as high as it takes.
        let maxedExam = filled(Dictionary(uniqueKeysWithValues: examLeaves.map { ($0, 1.0) }))
        let rest = neededFraction(inputs.merging(maxedExam) { $1 }, target: target) ?? 1
        return Dictionary(uniqueKeysWithValues: pending.map { ($0, examLeaves.contains($0) ? 1 : rest) })
    }

    /// `fractions` turned into values on each leaf's own scale, ready to merge into the inputs.
    private func filled(_ fractions: [String: Double]) -> [String: Double] {
        fractions.reduce(into: [:]) { result, pair in
            if let max = leaf(named: pair.key)?.scaleMax { result[pair.key] = pair.value * max }
        }
    }
}
